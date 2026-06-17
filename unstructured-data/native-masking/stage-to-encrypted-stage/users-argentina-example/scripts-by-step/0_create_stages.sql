-- =============================================================================
-- Step 0: Create landing and encrypted target stages
-- =============================================================================
-- IMPORTANT: Stages MUST use server-side encryption (SNOWFLAKE_SSE).
-- Client-side encryption (the default) breaks Cortex functions like
-- PARSE_DOCUMENT and can prevent downstream AI consumption of the files.
-- Directory tables are enabled so we can list files and attach a stream.

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing stage for raw files to be encrypted';

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Target stage for Nullafi-encrypted files';
