-- =============================================================================
-- Step 0: Create landing stage and target table
-- =============================================================================
-- Stage MUST use server-side encryption (SNOWFLAKE_SSE).
-- The target table stores one row per file with the masked content as text.

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing stage for raw files to be masked into a table';

CREATE TABLE IF NOT EXISTS POS.PUBLIC.NULLAFI_MASKED_FILES (
  FILE_NAME       VARCHAR,
  FILE_FORMAT     VARCHAR,
  MASKED_CONTENT  VARCHAR,
  LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
