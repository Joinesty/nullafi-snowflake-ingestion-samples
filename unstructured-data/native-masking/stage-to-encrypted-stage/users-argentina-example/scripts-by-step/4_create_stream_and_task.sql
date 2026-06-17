-- =============================================================================
-- Step 4: Create the directory-table stream and the scheduled task
-- =============================================================================
-- The stream tracks new files added to the landing stage. The task fires every
-- minute when the stream has data and encrypts only the new files (incremental).

CREATE OR REPLACE STREAM POS.PUBLIC.NULLAFI_LANDING_STREAM
  ON STAGE POS.PUBLIC.NULLAFI_LANDING_STAGE;

CREATE OR REPLACE TASK POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('POS.PUBLIC.NULLAFI_LANDING_STREAM')
AS
  CALL POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_FILES(
    'incremental',
    'POS.PUBLIC.NULLAFI_LANDING_STAGE',
    'POS.PUBLIC.NULLAFI_ENCRYPTED_STAGE',
    'POS.PUBLIC.NULLAFI_LANDING_STREAM'
  );

ALTER TASK POS.PUBLIC.NULLAFI_ENCRYPT_STAGE_TASK RESUME;
