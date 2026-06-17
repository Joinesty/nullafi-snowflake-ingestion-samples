-- =============================================================================
-- Step 1: Create the stage-to-table masking procedure
-- =============================================================================
-- Reads TEXT files from the source stage, masks PII via the Nullafi API, and
-- inserts the masked content into the target table (one row per file).
-- Reuses NULLAFI_API_ACCESS and NULLAFI_API_KEY_SECRET.
--
-- MODE: 'all' (every file in stage) or 'incremental' (new files from stream).
-- Text formats handled: CSV, JSON, XML, TXT, HTML.
-- Binary (PDF, XLSX, ...) and images are skipped -- use stage-to-encrypted-stage
-- (to keep files) or parse-extract (for images).

CREATE OR REPLACE PROCEDURE POS.PUBLIC.NULLAFI_ENCRYPT_FILES_TO_TABLE(
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
import tempfile
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TEXT_CONTENT_TYPES = {
    ".csv": "text/csv",
    ".json": "application/json",
    ".xml": "application/xml",
    ".txt": "text/plain",
    ".html": "text/html",
}

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

    if not paths:
        return "No files to process."

    tmp = tempfile.mkdtemp()
    inserted, skipped, errors = [], [], []

    for rel in paths:
        ext = os.path.splitext(rel)[1].lower()
        ctype = TEXT_CONTENT_TYPES.get(ext)
        if ctype is None:
            skipped.append(rel)
            continue
        try:
            session.file.get(f"@{source_stage}/{rel}", tmp)
            local_in = os.path.join(tmp, os.path.basename(rel))
            with open(local_in, "r", encoding="utf-8", errors="replace") as fh:
                content = fh.read()

            headers = {"Authorization": f"Bearer {api_key}", "Content-Type": ctype}
            resp = requests.post(api_url, headers=headers, params=base_params,
                                 data=content.encode("utf-8"), timeout=120, verify=False)
            resp.raise_for_status()
            masked = resp.text

            session.sql(
                f"INSERT INTO {target_table} (FILE_NAME, FILE_FORMAT, MASKED_CONTENT) VALUES (?, ?, ?)",
                params=[os.path.basename(rel), ext.lstrip("."), masked]
            ).collect()
            inserted.append(rel)
        except Exception as e:
            errors.append(f"{rel}: {str(e)}")

    result = f"Inserted {len(inserted)}/{len(paths)} files into {target_table}."
    if inserted:
        result += " OK: " + ", ".join(os.path.basename(p) for p in inserted) + "."
    if skipped:
        result += " Skipped (non-text): " + ", ".join(os.path.basename(p) for p in skipped) + "."
    if errors:
        result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    return result
$$;
