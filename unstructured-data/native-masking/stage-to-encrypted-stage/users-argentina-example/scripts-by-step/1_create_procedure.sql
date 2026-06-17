-- =============================================================================
-- Step 1: Create the file-encryption stored procedure
-- =============================================================================
-- Reads files from a source stage, sends each to the Nullafi /api/scan-dynamic
-- endpoint, and writes the encrypted file (same format) to a target stage.
--
-- Reuses the existing NULLAFI_API_ACCESS integration and NULLAFI_API_KEY_SECRET
-- created for the structured-data pipeline.
--
-- MODE:
--   'all'         - process every file currently in the source stage directory
--   'incremental' - process only new files from the provided directory stream
--
-- Natively masked formats (file in -> encrypted file out, same format):
--   CSV, JSON, XML, TXT, HTML, PDF, XLSX, DOCX, PPTX
-- Image formats (PNG, JPG, TIFF, ...) are NOT natively maskable and are
-- skipped here -- route those through the parse-extract pipeline instead.

CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
  MODE VARCHAR,
  SOURCE_STAGE VARCHAR,
  TARGET_STAGE VARCHAR,
  STREAM_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (NULLAFI_API_ACCESS)
SECRETS = ('nullafi_key' = POS.PUBLIC.NULLAFI_API_KEY_SECRET)
AS
$$
import _snowflake
import requests
import os
import tempfile
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Formats Nullafi masks natively (file in -> encrypted file out, same format).
CONTENT_TYPES = {
    ".csv": "text/csv",
    ".json": "application/json",
    ".xml": "application/xml",
    ".txt": "text/plain",
    ".html": "text/html",
    ".pdf": "application/pdf",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
}
# Image formats are NOT natively maskable -> use the parse-extract pipeline instead.
SKIP_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".gif", ".bmp"}

def run(session, mode, source_stage, target_stage, stream_name):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://test2.broknus.com/api/scan-dynamic"
    base_params = {
        "namespace": "snowflake_unstructured",
        "obfuscatedDataTypes": "CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS",
        "maskFormats": "CYPHER,CYPHER,CYPHER,CYPHER",
        "storeOriginalValues": "true",
    }

    if mode == 'all':
        rows = session.sql(f"SELECT RELATIVE_PATH FROM DIRECTORY(@{source_stage})").collect()
        paths = [r["RELATIVE_PATH"] for r in rows]
    elif mode == 'incremental':
        rows = session.sql(
            f"SELECT RELATIVE_PATH FROM {stream_name} WHERE METADATA$ACTION = 'INSERT'"
        ).collect()
        paths = [r["RELATIVE_PATH"] for r in rows]
    else:
        return f"Invalid mode: {mode}. Use 'all' or 'incremental'."

    if not paths:
        return "No files to process."

    tmp = tempfile.mkdtemp()
    processed, skipped, errors = [], [], []

    for rel in paths:
        ext = os.path.splitext(rel)[1].lower()
        if ext in SKIP_EXTS:
            skipped.append(rel)
            continue
        ctype = CONTENT_TYPES.get(ext)
        if ctype is None:
            skipped.append(rel)
            continue
        try:
            session.file.get(f"@{source_stage}/{rel}", tmp)
            local_in = os.path.join(tmp, os.path.basename(rel))
            with open(local_in, "rb") as fh:
                content = fh.read()

            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": ctype}
            resp = requests.post(api_url, headers=headers, params=base_params,
                                 data=content, timeout=120, verify=False)
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
    if processed:
        result += " OK: " + ", ".join(os.path.basename(p) for p in processed) + "."
    if skipped:
        result += " Skipped (unsupported, use parse-extract): " + ", ".join(os.path.basename(p) for p in skipped) + "."
    if errors:
        result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;
