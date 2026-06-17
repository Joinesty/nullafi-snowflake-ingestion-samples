-- =============================================================================
-- Step 1: Create the parse-extract procedure
-- =============================================================================
-- For IMAGE files (PNG, JPG, JPEG, TIFF), this:
--   1. Runs AI_PARSE_DOCUMENT (OCR) to extract text   <-- AI MODEL SEES RAW PII
--   2. Masks the extracted text via the Nullafi API
--   3. Stores the masked text in the target table
--
-- ** SECURITY CAVEAT **
-- Step 1 exposes the raw image (and its PII) to an AI model during OCR, BEFORE
-- masking. This happens inside Snowflake's Cortex boundary (not an external LLM,
-- not used for training), but if your policy forbids any AI model seeing raw PII,
-- do not use this pipeline. For images there is no alternative -- OCR must read
-- the raw pixels to locate PII before it can be masked.
--
-- Reuses NULLAFI_API_ACCESS and NULLAFI_API_KEY_SECRET.

CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_PARSE_EXTRACT_IMAGES(
  MODE VARCHAR,
  SOURCE_STAGE VARCHAR,
  TARGET_TABLE VARCHAR,
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
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}

def run(session, mode, source_stage, target_table, stream_name):
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

    paths = [p for p in paths if os.path.splitext(p)[1].lower() in IMAGE_EXTS]
    if not paths:
        return "No image files to process."

    inserted, errors = [], []
    for rel in paths:
        try:
            esc = rel.replace("'", "''")
            ocr = session.sql(
                f"SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT('@{source_stage}', '{esc}', "
                f"{{'mode': 'OCR'}}):content::STRING AS C"
            ).collect()
            text = ocr[0]["C"] if ocr and ocr[0]["C"] else ""
            if not text.strip():
                errors.append(f"{rel}: empty OCR result")
                continue

            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "text/plain"}
            resp = requests.post(api_url, headers=headers, params=base_params,
                                 data=text.encode("utf-8"), timeout=120, verify=False)
            resp.raise_for_status()
            masked = resp.text

            session.sql(
                f"INSERT INTO {target_table} (FILE_NAME, EXTRACTED_TEXT_MASKED) VALUES (?, ?)",
                params=[os.path.basename(rel), masked]
            ).collect()
            inserted.append(rel)
        except Exception as e:
            errors.append(f"{rel}: {str(e)}")

    result = f"Processed {len(inserted)}/{len(paths)} images into {target_table}."
    if inserted:
        result += " OK: " + ", ".join(os.path.basename(p) for p in inserted) + "."
    if errors:
        result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;
