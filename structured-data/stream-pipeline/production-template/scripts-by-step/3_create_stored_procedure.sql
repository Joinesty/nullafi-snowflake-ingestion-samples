-- =============================================================================
-- Step 3: Create the Encryption Stored Procedure
-- =============================================================================
-- A generic procedure that encrypts data via the Nullafi API and inserts
-- results into the corresponding target table.
--
-- KEY DESIGN DECISIONS:
--   - Sends ALL fields to the API, not just known sensitive ones. The Nullafi
--     API uses the obfuscatedDataTypes parameter to detect and encrypt only
--     the values that match those data type patterns (e.g., credit cards, SSNs).
--     Non-sensitive fields pass through unchanged.
--   - Batches all rows into a SINGLE API call by sending them as a JSON array.
--     This drastically reduces HTTP overhead vs row-by-row processing.
--
-- Parameters:
--   MODE           - 'backfill' (full table) or 'incremental' (stream only)
--   SOURCE_TABLE   - Fully qualified source table name
--   TARGET_TABLE   - Fully qualified target table name
--   STREAM_NAME    - Fully qualified stream name (used when mode='incremental')
--
-- PLACEHOLDERS:
--   {{PROCEDURE_DATABASE}}   - Database for the procedure
--   {{PROCEDURE_SCHEMA}}     - Schema for the procedure
--   {{PROCEDURE_NAME}}       - Name of the procedure
--   {{INTEGRATION_NAME}}     - External access integration name (from step 1)
--   {{SECRET_DATABASE}}      - Database where the secret is stored
--   {{SECRET_SCHEMA}}        - Schema where the secret is stored
--   {{SECRET_NAME}}          - Name of the Nullafi API key secret
--   {{NULLAFI_HOSTNAME}}     - Nullafi API hostname
--   {{NULLAFI_NAMESPACE}}    - Namespace identifier for Nullafi logging
--   {{DATA_TYPES}}           - Comma-separated Nullafi data type identifiers
--                              (e.g., CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS)
--   {{MASK_FORMATS}}         - Comma-separated mask format IDs, one per data type
--                              (e.g., CYPHER,CYPHER,CYPHER,CYPHER)
--   {{BATCH_SIZE}}           - Number of rows per API call (e.g., 50, 100)
-- =============================================================================

CREATE OR REPLACE PROCEDURE {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
  MODE VARCHAR,
  SOURCE_TABLE VARCHAR,
  TARGET_TABLE VARCHAR,
  STREAM_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = ({{INTEGRATION_NAME}})
SECRETS = ('nullafi_key' = {{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}})
AS
$$
import _snowflake
import requests
import json
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BATCH_SIZE = {{BATCH_SIZE}}

def run(session, mode, source_table, target_table, stream_name):
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    api_url = "https://{{NULLAFI_HOSTNAME}}/api/scan-dynamic"
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    params = {
        "namespace": "{{NULLAFI_NAMESPACE}}",
        "obfuscatedDataTypes": "{{DATA_TYPES}}",
        "maskFormats": "{{MASK_FORMATS}}",
        "storeOriginalValues": "true"
    }
    
    # Determine data source
    if mode == 'backfill':
        df = session.table(source_table)
    elif mode == 'incremental':
        df = session.table(stream_name)
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
        
        # Build a JSON array with ALL fields from each row.
        # The API will detect and encrypt only values matching the configured
        # obfuscatedDataTypes — everything else passes through unchanged.
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
            target_df.write.mode("append").save_as_table(target_table)
            inserted_count += len(insert_rows)
        except Exception as e:
            errors.append(f"Batch {batch_start}-{batch_start+len(batch)}: Insert error - {str(e)}")
    
    result = f"Processed {len(rows)} rows in {-(-len(rows)//BATCH_SIZE)} batch(es). Inserted: {inserted_count}."
    if errors:
        result += f" Errors ({len(errors)}): " + "; ".join(errors[:5])
    
    return result
$$;
