-- Step 0: Create a secret to store the Nullafi API key
-- Replace '<your-nullafi-api-key>' with your actual API key

CREATE OR REPLACE SECRET POS.PUBLIC.NULLAFI_API_KEY_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<your-nullafi-api-key>';
