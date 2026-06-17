-- Step 4: Create an append-only stream on the source table
-- This must be created AFTER the backfill so it only captures new rows going forward

CREATE OR REPLACE STREAM POS.PUBLIC.USERS_ARGENTINA_STREAM
  ON TABLE POS.PUBLIC.USERS_ARGENTINA
  APPEND_ONLY = TRUE;
