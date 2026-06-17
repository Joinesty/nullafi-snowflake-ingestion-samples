-- =============================================================================
-- Step 0: Create landing stage and target table
-- =============================================================================
-- Stage MUST use SNOWFLAKE_SSE -- AI_PARSE_DOCUMENT cannot read client-side
-- encrypted stages.

CREATE STAGE IF NOT EXISTS POS.PUBLIC.NULLAFI_LANDING_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing stage for raw image files';

CREATE TABLE IF NOT EXISTS POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED (
  FILE_NAME             VARCHAR,
  EXTRACTED_TEXT_MASKED VARCHAR,
  LOADED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
