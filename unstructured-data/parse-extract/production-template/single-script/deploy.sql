-- =============================================================================
-- Nullafi Parse-Extract Pipeline - PRODUCTION TEMPLATE
-- =============================================================================
-- For IMAGES (PNG/JPG/JPEG/TIFF): OCR via AI_PARSE_DOCUMENT, mask the extracted
-- text via Nullafi, store masked text in a target table. Fill all {{PLACEHOLDERS}}.
--
-- ** CAVEAT: AI_PARSE_DOCUMENT reads the raw image, so an AI model sees raw PII
--    BEFORE masking (inside Snowflake's Cortex boundary). Use only if acceptable
--    under your compliance policy. **
--
-- Stage MUST use SNOWFLAKE_SSE (AI_PARSE_DOCUMENT cannot read CSE stages).
-- =============================================================================

USE ROLE SYSADMIN;
CREATE OR REPLACE SECRET {{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}}
  TYPE = GENERIC_STRING SECRET_STRING = '{{NULLAFI_API_KEY}}';

USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE NETWORK RULE {{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}}
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('{{NULLAFI_HOSTNAME}}');
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {{INTEGRATION_NAME}}
  ALLOWED_NETWORK_RULES = ({{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}})
  ALLOWED_AUTHENTICATION_SECRETS = ({{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}})
  ENABLED = TRUE;

CREATE STAGE IF NOT EXISTS {{LANDING_DATABASE}}.{{LANDING_SCHEMA}}.{{LANDING_STAGE}}
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE TABLE IF NOT EXISTS {{TABLE_DATABASE}}.{{TABLE_SCHEMA}}.{{TARGET_TABLE}} (
  FILE_NAME VARCHAR, EXTRACTED_TEXT_MASKED VARCHAR,
  LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

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
import _snowflake, requests, os, urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
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

CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.{{STREAM_NAME}}
  ON STAGE {{LANDING_DATABASE}}.{{LANDING_SCHEMA}}.{{LANDING_STAGE}};

CREATE OR REPLACE TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.{{TASK_NAME}}
  WAREHOUSE = {{WAREHOUSE}}
  SCHEDULE = '{{SCHEDULE}}'
  WHEN SYSTEM$STREAM_HAS_DATA('{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.{{STREAM_NAME}}')
AS
  CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
    'incremental',
    '{{LANDING_DATABASE}}.{{LANDING_SCHEMA}}.{{LANDING_STAGE}}',
    '{{TABLE_DATABASE}}.{{TABLE_SCHEMA}}.{{TARGET_TABLE}}',
    '{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.{{STREAM_NAME}}');

ALTER TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.{{TASK_NAME}} RESUME;
