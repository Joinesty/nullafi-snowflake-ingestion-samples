-- =============================================================================
-- Nullafi Stage-to-Table Pipeline - USERS_ARGENTINA Example
-- =============================================================================
-- Reads TEXT files from the landing stage, masks PII via the Nullafi API, and
-- inserts masked content into POS.PUBLIC.NULLAFI_MASKED_FILES (one row/file).
-- Reuses NULLAFI_API_ACCESS and NULLAFI_API_KEY_SECRET.
-- =============================================================================

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE TABLE IF NOT EXISTS POS.PUBLIC.NULLAFI_MASKED_FILES (
  FILE_NAME VARCHAR, FILE_FORMAT VARCHAR, MASKED_CONTENT VARCHAR,
  LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_ENCRYPT_FILES_TO_TABLE(
  MODE VARCHAR, SOURCE_STAGE VARCHAR, TARGET_TABLE VARCHAR, STREAM_NAME VARCHAR
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
import _snowflake, requests, os, tempfile, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
TEXT_CONTENT_TYPES = {".csv":"text/csv",".json":"application/json",".xml":"application/xml",".txt":"text/plain",".html":"text/html"}
def run(session, mode, source_stage, target_table, stream_name):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://test2.broknus.com/api/scan-dynamic"
    base_params = {"namespace":"snowflake_unstructured","obfuscatedDataTypes":"CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS","maskFormats":"CYPHER,CYPHER,CYPHER,CYPHER","storeOriginalValues":"true"}
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

CREATE OR REPLACE STREAM POS.PUBLIC.NULLAFI_LANDING_STREAM_TBL
  ON STAGE POS.PUBLIC.NULLAFI_LANDING_STAGE;

CREATE OR REPLACE TASK POS.PUBLIC.NULLAFI_FILES_TO_TABLE_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('POS.PUBLIC.NULLAFI_LANDING_STREAM_TBL')
AS
  CALL POS.PUBLIC.NULLAFI_ENCRYPT_FILES_TO_TABLE(
    'incremental', 'POS.PUBLIC.NULLAFI_LANDING_STAGE',
    'POS.PUBLIC.NULLAFI_MASKED_FILES', 'POS.PUBLIC.NULLAFI_LANDING_STREAM_TBL');

ALTER TASK POS.PUBLIC.NULLAFI_FILES_TO_TABLE_TASK RESUME;

-- Optional initial batch:
-- CALL POS.PUBLIC.GENERATE_TEST_FILES('POS.PUBLIC.NULLAFI_LANDING_STAGE');
-- CALL POS.PUBLIC.NULLAFI_ENCRYPT_FILES_TO_TABLE('all',
--   'POS.PUBLIC.NULLAFI_LANDING_STAGE', 'POS.PUBLIC.NULLAFI_MASKED_FILES', '');
