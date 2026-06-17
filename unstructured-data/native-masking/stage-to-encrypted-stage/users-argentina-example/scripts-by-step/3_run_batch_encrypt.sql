-- =============================================================================
-- Step 3: Batch-encrypt all files currently in the landing stage
-- =============================================================================
-- 'all' mode processes every file in the source stage directory table.
-- Supported formats are masked and written to the encrypted stage; images
-- are skipped (they require the parse-extract pipeline).

CALL POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
  'all',
  'POS.PUBLIC.NULLAFI_LANDING_STAGE',
  'POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE',
  ''
);
