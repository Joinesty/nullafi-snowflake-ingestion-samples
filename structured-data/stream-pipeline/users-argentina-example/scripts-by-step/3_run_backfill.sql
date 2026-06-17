-- Step 3: Initial backfill
-- Truncates the target table and re-encrypts all existing rows from the source table

TRUNCATE TABLE POS.PUBLIC.USERS_ARGENTINA_ENCRYPTED;

CALL POS.PUBLIC.ENCRYPT_AND_INSERT_USERS_ARGENTINA('backfill');
