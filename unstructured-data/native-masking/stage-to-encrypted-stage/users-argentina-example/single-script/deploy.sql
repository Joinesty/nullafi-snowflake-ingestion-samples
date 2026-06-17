-- =============================================================================
-- Nullafi Stage-to-Encrypted-Stage Pipeline - USERS_ARGENTINA Example
-- =============================================================================
-- Full deployment in one file. Reads files from a landing stage, masks PII via
-- the Nullafi API, and writes encrypted files (same format) to a target stage.
-- Reuses the existing NULLAFI_API_ACCESS integration and NULLAFI_API_KEY_SECRET.
--
-- Run order: stages -> procedure -> generate test files -> batch encrypt ->
--            stream + task -> verify.
-- =============================================================================


-- ----- Stages (server-side encryption required for Cortex compatibility) -----
CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing stage for raw files to be encrypted';

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Target stage for Nullafi-encrypted files';


-- ----- Encryption procedure -----
CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
  MODE VARCHAR, SOURCE_STAGE VARCHAR, TARGET_STAGE VARCHAR, STREAM_NAME VARCHAR
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


-- ----- Stream + task for incremental processing -----
CREATE OR REPLACE STREAM POS.PUBLIC.NULLAFI_LANDING_STREAM
  ON STAGE POS.PUBLIC.NULLAFI_LANDING_STAGE;

CREATE OR REPLACE TASK POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('POS.PUBLIC.NULLAFI_LANDING_STREAM')
AS
  CALL POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
    'incremental', 'POS.PUBLIC.NULLAFI_LANDING_STAGE',
    'POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE', 'POS.PUBLIC.NULLAFI_LANDING_STREAM');

ALTER TASK POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_TASK RESUME;

-- ----- Optional: generate test files and run an initial batch -----
-- (See scripts-by-step/2_generate_test_files.sql for GENERATE_TEST_FILES.)
-- CALL POS.PUBLIC.GENERATE_TEST_FILES('POS.PUBLIC.NULLAFI_LANDING_STAGE');
-- CALL POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES('all',
--   'POS.PUBLIC.NULLAFI_LANDING_STAGE', 'POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE', '');
