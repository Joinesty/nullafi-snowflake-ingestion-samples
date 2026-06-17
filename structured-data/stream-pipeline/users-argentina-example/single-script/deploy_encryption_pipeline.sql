-- =============================================================================
-- Nullafi Encryption Pipeline - Full Deployment Script
-- =============================================================================
-- This script sets up an automated pipeline that:
-- 1. Encrypts sensitive fields (CC_NUMBER, US_SSN, IBAN, EMAIL) via Nullafi API
-- 2. Migrates data from USERS_ARGENTINA to USERS_ARGENTINA_ENCRYPTED
-- 3. Keeps the tables in sync automatically using a Stream + Task
--
-- Prerequisites:
--   - A Nullafi API key with Data Scanning permission
--   - A warehouse (default: COMPUTE_WH)
--   - Privileges: CREATE SECRET, CREATE NETWORK RULE, CREATE INTEGRATION,
--                 CREATE STREAM, CREATE TASK, CREATE PROCEDURE on POS.PUBLIC
--
-- Configuration:
--   - Replace '<your-nullafi-api-key>' with your actual Nullafi API key
--   - Replace 'test2.broknus.com' with your Nullafi hostname if different
--   - Replace 'COMPUTE_WH' with your warehouse if different
--   - Adjust SCHEDULE interval on the task if 1 minute is too frequent
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Step 0: Create a secret to store the Nullafi API key
-- -----------------------------------------------------------------------------

CREATE OR REPLACE SECRET POS.PUBLIC.NULLAFI_API_KEY_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<your-nullafi-api-key>';


-- -----------------------------------------------------------------------------
-- Step 1: Create network rule and external access integration
-- -----------------------------------------------------------------------------

CREATE OR REPLACE NETWORK RULE POS.PUBLIC.NULLAFI_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('test2.broknus.com');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION NULLAFI_API_ACCESS
  ALLOWED_NETWORK_RULES = (POS.PUBLIC.NULLAFI_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (POS.PUBLIC.NULLAFI_API_KEY_SECRET)
  ENABLED = TRUE;


-- -----------------------------------------------------------------------------
-- Step 2: Create the Python stored procedure
-- Sends ALL fields to the API in batches. The API detects and encrypts only
-- values matching the configured obfuscatedDataTypes.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE POS.PUBLIC.ENCRYPT_AND_INSERT_USERS_ARGENTINA(MODE VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (NULLAFI_API_ACCESS)
SECRETS = ('nullafi_key' = POS.PUBLIC.NULLAFI_API_KEY_SECRET)
AS
$$
import _snowflake
import requests
import json
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BATCH_SIZE = 100

def run(session, mode):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://test2.broknus.com/api/scan-dynamic"
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    params = {
        "namespace": "snowflake_migration",
        "obfuscatedDataTypes": "CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS",
        "maskFormats": "CYPHER,CYPHER,CYPHER,CYPHER",
        "storeOriginalValues": "true"
    }
    
    if mode == 'backfill':
        df = session.table("POS.PUBLIC.USERS_ARGENTINA")
    elif mode == 'incremental':
        df = session.table("POS.PUBLIC.USERS_ARGENTINA_STREAM")
    else:
        return f"Invalid mode: {mode}. Use 'backfill' or 'incremental'."
    
    rows = df.collect()
    
    if len(rows) == 0:
        return "No rows to process."
    
    # Get column names, excluding stream metadata columns
    all_columns = [field.name for field in df.schema.fields]
    columns = [c for c in all_columns if c not in 
               ('METADATA$ACTION', 'METADATA$ISUPDATE', 'METADATA$ROW_ID')]
    
    inserted_count = 0
    errors = []
    
    # Process rows in batches
    for batch_start in range(0, len(rows), BATCH_SIZE):
        batch = rows[batch_start:batch_start + BATCH_SIZE]
        
        # Send ALL fields to the API - it will detect and encrypt only
        # values matching the configured obfuscatedDataTypes
        payload = []
        for row in batch:
            row_data = {}
            for col in columns:
                val = row[col]
                if val is not None:
                    row_data[col] = str(val)
                else:
                    row_data[col] = None
            payload.append(row_data)
        
        # Single API call for the entire batch
        try:
            response = requests.post(
                api_url,
                headers=headers,
                params=params,
                json=payload,
                timeout=120,
                verify=False
            )
            response.raise_for_status()
            encrypted_batch = response.json()
        except Exception as e:
            errors.append(f"Batch {batch_start}-{batch_start+len(batch)}: API error - {str(e)}")
            continue
        
        # Insert the encrypted batch into the target table
        insert_rows = []
        for encrypted_row in encrypted_batch:
            insert_values = []
            for col in columns:
                insert_values.append(encrypted_row.get(col))
            insert_rows.append(insert_values)
        
        try:
            target_df = session.create_dataframe(insert_rows, schema=columns)
            target_df.write.mode("append").save_as_table("POS.PUBLIC.USERS_ARGENTINA_ENCRYPTED")
            inserted_count += len(insert_rows)
        except Exception as e:
            errors.append(f"Batch {batch_start}-{batch_start+len(batch)}: Insert error - {str(e)}")
    
    result = f"Processed {len(rows)} rows in {-(-len(rows)//BATCH_SIZE)} batch(es). Inserted: {inserted_count}."
    if errors:
        result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    
    return result
$$;


-- -----------------------------------------------------------------------------
-- Step 3: Initial backfill - encrypt all existing rows
-- -----------------------------------------------------------------------------

TRUNCATE TABLE POS.PUBLIC.USERS_ARGENTINA_ENCRYPTED;

CALL POS.PUBLIC.ENCRYPT_AND_INSERT_USERS_ARGENTINA('backfill');


-- -----------------------------------------------------------------------------
-- Step 4: Create stream (AFTER backfill so it only captures new rows)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE STREAM POS.PUBLIC.USERS_ARGENTINA_STREAM
  ON TABLE POS.PUBLIC.USERS_ARGENTINA
  APPEND_ONLY = TRUE;


-- -----------------------------------------------------------------------------
-- Step 5: Create and resume the scheduled task
-- -----------------------------------------------------------------------------

CREATE OR REPLACE TASK POS.PUBLIC.ENCRYPT_USERS_ARGENTINA_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('POS.PUBLIC.USERS_ARGENTINA_STREAM')
AS
  CALL POS.PUBLIC.ENCRYPT_AND_INSERT_USERS_ARGENTINA('incremental');

ALTER TASK POS.PUBLIC.ENCRYPT_USERS_ARGENTINA_TASK RESUME;
