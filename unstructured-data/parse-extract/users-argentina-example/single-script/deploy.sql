-- =============================================================================
-- Nullafi Parse-Extract Pipeline - USERS_ARGENTINA Example
-- =============================================================================
-- For IMAGES (PNG/JPG/JPEG/TIFF): OCR via AI_PARSE_DOCUMENT, mask the extracted
-- text via Nullafi, store in POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED.
--
-- ** CAVEAT: AI_PARSE_DOCUMENT (an AI model) reads the raw image, so PII is seen
--    by a model BEFORE masking. Use only if Cortex-internal AI processing of raw
--    PII is acceptable under your compliance policy. **
--
-- Stage MUST use SNOWFLAKE_SSE. Reuses NULLAFI_API_ACCESS + NULLAFI_API_KEY_SECRET.
-- =============================================================================

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE TABLE IF NOT EXISTS POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED (
  FILE_NAME VARCHAR, EXTRACTED_TEXT_MASKED VARCHAR,
  LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_PARSE_EXTRACT_IMAGES(
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
import _snowflake, requests, os, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
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
    paths = [p for p in paths if os.path.splitext(p)[1].lower() in IMAGE_EXTS]
    if not paths:
        return "No image files to process."
    inserted, errors = [], []
    for rel in paths:
        try:
            esc = rel.replace("'", "''")
            ocr = session.sql(f"SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT('@{source_stage}', '{esc}', {{'mode': 'OCR'}}):content::STRING AS C").collect()
            text = ocr[0]["C"] if ocr and ocr[0]["C"] else ""
            if not text.strip():
                errors.append(f"{rel}: empty OCR result"); continue
            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "text/plain"}
            resp = requests.post(api_url, headers=headers, params=base_params, data=text.encode("utf-8"), timeout=120, verify=False)
            resp.raise_for_status()
            session.sql(f"INSERT INTO {target_table} (FILE_NAME, EXTRACTED_TEXT_MASKED) VALUES (?, ?)",
                        params=[os.path.basename(rel), resp.text]).collect()
            inserted.append(rel)
        except Exception as e:
            errors.append(f"{rel}: {str(e)}")
    result = f"Processed {len(inserted)}/{len(paths)} images into {target_table}."
    if inserted: result += " OK: " + ", ".join(os.path.basename(p) for p in inserted) + "."
    if errors:   result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;

CREATE OR REPLACE STREAM POS.PUBLIC.NULLAFI_LANDING_STREAM_IMG
  ON STAGE POS.PUBLIC.NULLAFI_LANDING_STAGE;

CREATE OR REPLACE TASK POS.PUBLIC.NULLAFI_PARSE_EXTRACT_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('POS.PUBLIC.NULLAFI_LANDING_STREAM_IMG')
AS
  CALL POS.PUBLIC.NULLAFI_PARSE_EXTRACT_IMAGES(
    'incremental', 'POS.PUBLIC.NULLAFI_LANDING_STAGE',
    'POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED', 'POS.PUBLIC.NULLAFI_LANDING_STREAM_IMG');

ALTER TASK POS.PUBLIC.NULLAFI_PARSE_EXTRACT_TASK RESUME;
