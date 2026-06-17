-- =============================================================================
-- Step 2: Generate test files and run an initial batch load
-- =============================================================================
-- Reuses GENERATE_TEST_FILES (see stage-to-encrypted-stage example, step 2)
-- to populate the landing stage from USERS_ARGENTINA data.

CALL POS.PUBLIC.GENERATE_TEST_FILES('POS.PUBLIC.NULLAFI_LANDING_STAGE');

-- Batch-load all text files in the stage into the table
CALL POS.PUBLIC.NULLAFI_ENCRYPT_FILES_TO_TABLE(
  'all',
  'POS.PUBLIC.NULLAFI_LANDING_STAGE',
  'POS.PUBLIC.NULLAFI_MASKED_FILES',
  ''
);
