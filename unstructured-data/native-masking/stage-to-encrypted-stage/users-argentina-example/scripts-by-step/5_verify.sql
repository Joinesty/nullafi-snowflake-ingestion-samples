-- =============================================================================
-- Step 5: Verify the pipeline
-- =============================================================================

-- 1. List the encrypted output files
LIST @POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE;

-- 2. Helper to read a text file from a stage (for inspecting masked content)
CREATE OR REPLACE PROCEDURE POS.PUBLIC.READ_STAGE_FILE_TEXT(STAGE_PATH VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
from snowflake.snowpark.files import SnowflakeFile
def run(session, stage_path):
    with SnowflakeFile.open(stage_path, 'rb') as f:
        data = f.read()
    return data.decode('utf-8', errors='replace')[:3000]
$$;

-- 3. Inspect a masked text file (emails/cards/SSNs/IBANs should be NFA_ tokens)
CALL POS.PUBLIC.READ_STAGE_FILE_TEXT(
  BUILD_SCOPED_FILE_URL('@POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE', 'enc_users_sample.csv')
);

-- 4. Confirm masking inside a PDF by parsing it (requires SSE stage)
SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
  '@POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE', 'enc_users_sample.pdf', {'mode': 'OCR'}
):content::STRING AS pdf_text;

-- 5. Test incremental: add a new file, confirm the stream + task pick it up
--    (or run the procedure in incremental mode manually)
-- CALL POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
--   'incremental',
--   'POS.PUBLIC.NULLAFI_LANDING_STAGE',
--   'POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE',
--   'POS.PUBLIC.NULLAFI_LANDING_STREAM'
-- );
