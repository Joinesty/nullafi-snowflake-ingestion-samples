-- Step 2: Create the Python stored procedure
-- This procedure reads rows, sends ALL fields to the Nullafi API in batches,
-- and inserts the encrypted results into the target table.
-- The API detects sensitive values based on the obfuscatedDataTypes parameter.
--
-- mode = 'backfill' -> reads all rows from the source table
-- mode = 'incremental' -> reads only new rows from the stream

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
