-- =============================================================================
-- Step 1: Create the file-encryption stored procedure
-- =============================================================================
-- PLACEHOLDERS:
--   {{PROCEDURE_DATABASE}}, {{PROCEDURE_SCHEMA}}, {{PROCEDURE_NAME}}
--   {{INTEGRATION_NAME}}, {{SECRET_DATABASE}}, {{SECRET_SCHEMA}}, {{SECRET_NAME}}
--   {{NULLAFI_HOSTNAME}}, {{NULLAFI_NAMESPACE}}, {{DATA_TYPES}}, {{MASK_FORMATS}}
--
-- MODE: 'all' (every file in source stage) or 'incremental' (new files from stream).
-- Natively masked: CSV, JSON, XML, TXT, HTML, PDF, XLSX, DOCX, PPTX.
-- Images are skipped -> use the parse-extract pipeline.

CREATE OR REPLACE PROCEDURE {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
  MODE VARCHAR, SOURCE_STAGE VARCHAR, TARGET_STAGE VARCHAR, STREAM_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = ({{INTEGRATION_NAME}})
SECRETS = ('nullafi_key' = {{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}})
AS
$$
import _snowflake, requests, os, tempfile, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

CONTENT_TYPES = {
    ".csv": "text/csv", ".json": "application/json", ".xml": "application/xml",
    ".txt": "text/plain", ".html": "text/html", ".pdf": "application/pdf",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
}
SKIP_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".gif", ".bmp"}

def run(session, mode, source_stage, target_stage, stream_name):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://{{NULLAFI_HOSTNAME}}/api/scan-dynamic"
    base_params = {
        "namespace": "{{NULLAFI_NAMESPACE}}",
        "obfuscatedDataTypes": "{{DATA_TYPES}}",
        "maskFormats": "{{MASK_FORMATS}}",
        "storeOriginalValues": "true",
    }
    if mode == 'all':
        rows = session.sql(f"SELECT RELATIVE_PATH FROM DIRECTORY(@{source_stage})").collect()
        paths = [r["RELATIVE_PATH"] for r in rows]
    elif mode == 'incremental':
        rows = session.sql(f"SELECT RELATIVE_PATH FROM {stream_name} WHERE METADATA$ACTION = 'INSERT'").collect()
        paths = [r["RELATIVE_PATH"] for r in rows]
    else:
        return f"Invalid mode: {mode}. Use 'all' or 'incremental'."
    if not paths:
        return "No files to process."
    tmp = tempfile.mkdtemp()
    processed, skipped, errors = [], [], []
    for rel in paths:
        ext = os.path.splitext(rel)[1].lower()
        if ext in SKIP_EXTS or CONTENT_TYPES.get(ext) is None:
            skipped.append(rel); continue
        ctype = CONTENT_TYPES[ext]
        try:
            session.file.get(f"@{source_stage}/{rel}", tmp)
            local_in = os.path.join(tmp, os.path.basename(rel))
            with open(local_in, "rb") as fh:
                content = fh.read()
            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": ctype}
            resp = requests.post(api_url, headers=headers, params=base_params, data=content, timeout=120, verify=False)
            resp.raise_for_status()
            local_out = os.path.join(tmp, "enc_" + os.path.basename(rel))
            with open(local_out, "wb") as fh:
                fh.write(resp.content)
            session.file.put(local_out, f"@{target_stage}", auto_compress=False, overwrite=True)
            processed.append(rel)
        except Exception as e:
            errors.append(f"{rel}: {str(e)}")
    session.sql(f"ALTER STAGE {target_stage} REFRESH").collect()
    result = f"Processed {len(processed)}/{len(paths)} files -> @{target_stage}."
    if processed: result += " OK: " + ", ".join(os.path.basename(p) for p in processed) + "."
    if skipped:   result += " Skipped (use parse-extract): " + ", ".join(os.path.basename(p) for p in skipped) + "."
    if errors:    result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;
