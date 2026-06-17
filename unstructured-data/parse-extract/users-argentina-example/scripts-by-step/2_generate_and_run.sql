-- =============================================================================
-- Step 2: Generate a test image and run parse-extract
-- =============================================================================
-- GENERATE_TEST_FILES (see stage-to-encrypted-stage example, step 2) produces a
-- users_sample.png containing PII rendered as text. Run it, then process images.

CALL POS.PUBLIC.GENERATE_TEST_FILES('POS.PUBLIC.NULLAFI_LANDING_STAGE');

CALL POS.PUBLIC.NULLAFI_PARSE_EXTRACT_IMAGES(
  'all',
  'POS.PUBLIC.NULLAFI_LANDING_STAGE',
  'POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED',
  ''
);
