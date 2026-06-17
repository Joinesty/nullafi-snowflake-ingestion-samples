-- =============================================================================
-- Step 1: Create the stage-to-table masking procedure
-- =============================================================================
-- PLACEHOLDERS: {{PROCEDURE_*}}, {{INTEGRATION_NAME}}, {{SECRET_*}},
--   {{NULLAFI_HOSTNAME}}, {{NULLAFI_NAMESPACE}}, {{DATA_TYPES}}, {{MASK_FORMATS}}
-- Text formats handled: CSV, JSON, XML, TXT, HTML. Others skipped.

CREATE OR REPLACE PROCEDURE {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
  MODE VARCHAR, SOURCE_STAGE VARCHAR, TARGET_TABLE VARCHAR, STREAM_NAME VARCHAR
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
TEXT_CONTENT_TYPES = {".csv":"text/csv",".json":"application/json",".xml":"application/xml",".txt":"text/plain",".html":"text/html"}
def run(session, mode, source_stage, target_table, stream_name):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://{{NULLAFI_HOSTNAME}}/api/scan-dynamic"
    base_params = {"namespace":"{{NULLAFI_NAMESPACE}}","obfuscatedDataTypes":"{{DATA_TYPES}}","maskFormats":"{{MASK_FORMATS}}","storeOriginalValues":"true"}
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
    inserted, skipped, errors = [], [], []
    for rel in paths:
        ext = os.path.splitext(rel)[1].lower()
        ctype = TEXT_CONTENT_TYPES.get(ext)
        if ctype is None:
            skipped.append(rel); continue
        try:
            session.file.get(f"@{source_stage}/{rel}", tmp)
            with open(os.path.join(tmp, os.path.basename(rel)), "r", encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": ctype}
            resp = requests.post(api_url, headers=headers, params=base_params, data=content.encode("utf-8"), timeout=120, verify=False)
            resp.raise_for_status()
            session.sql(f"INSERT INTO {target_table} (FILE_NAME, FILE_FORMAT, MASKED_CONTENT) VALUES (?, ?, ?)",
                        params=[os.path.basename(rel), ext.lstrip("."), resp.text]).collect()
            inserted.append(rel)
        except Exception as e:
            errors.append(f"{rel}: {str(e)}")
    result = f"Inserted {len(inserted)}/{len(paths)} files into {target_table}."
    if inserted: result += " OK: " + ", ".join(os.path.basename(p) for p in inserted) + "."
    if skipped:  result += " Skipped (non-text): " + ", ".join(os.path.basename(p) for p in skipped) + "."
    if errors:   result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;
