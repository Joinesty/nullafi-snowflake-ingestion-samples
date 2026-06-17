-- =============================================================================
-- NULLAFI ENCRYPTION PIPELINE - PRODUCTION DEPLOYMENT (Single File)
-- =============================================================================
--
-- Full database-to-database encryption pipeline using Nullafi's dynamic scan API.
-- Supports multiple tables with primary key and foreign key constraints.
--
-- WHAT THIS DOES:
--   1. Creates infrastructure (secret, network rule, external access integration)
--   2. Creates a generic encryption procedure (reusable across all tables)
--   3. Creates the target encrypted database with the same schema + constraints
--   4. Backfills all existing data through the Nullafi API
--   5. Sets up streams + tasks for automatic incremental encryption
--
-- EXECUTION ORDER MATTERS:
--   - Target tables: created parent-first (FK targets must exist)
--   - Backfill truncate: child-first (to avoid FK violations)
--   - Backfill insert: parent-first (FK references must exist)
--   - Streams: created after backfill (so they only track new rows)
--   - Tasks resumed: child-first (Snowflake requirement for DAG tasks)
--
-- =============================================================================
-- PLACEHOLDER REFERENCE
-- =============================================================================
--
-- Replace these placeholders throughout the script before execution:
--
-- INFRASTRUCTURE:
--   {{SECRET_DATABASE}}        - Database for the API key secret
--   {{SECRET_SCHEMA}}          - Schema for the secret
--   {{SECRET_NAME}}            - Name of the secret object
--   {{NULLAFI_API_KEY}}        - Your Nullafi API key value
--   {{NETWORK_RULE_DB}}        - Database for the network rule
--   {{NETWORK_RULE_SCHEMA}}    - Schema for the network rule
--   {{NETWORK_RULE_NAME}}      - Name of the network rule
--   {{NULLAFI_HOSTNAME}}       - Nullafi API hostname (e.g., api.nullafi.com)
--   {{INTEGRATION_NAME}}       - Name of the external access integration
--
-- PROCEDURE:
--   {{PROCEDURE_DATABASE}}     - Database for the stored procedure
--   {{PROCEDURE_SCHEMA}}       - Schema for the stored procedure
--   {{PROCEDURE_NAME}}         - Name of the procedure
--   {{NULLAFI_NAMESPACE}}      - Namespace for Nullafi activity logging
--   {{DATA_TYPES}}             - Nullafi data type identifiers (comma-separated)
--   {{MASK_FORMATS}}           - Mask format IDs (comma-separated, one per type)
--   {{BATCH_SIZE}}             - Number of rows per API call (e.g., 50, 100)
--
-- DATA:
--   {{SOURCE_DATABASE}}        - Source database name
--   {{SOURCE_SCHEMA}}          - Source schema name
--   {{TARGET_DATABASE}}        - Target (encrypted) database name
--   {{TARGET_SCHEMA}}          - Target schema name
--
-- ORCHESTRATION:
--   {{STREAM_DATABASE}}        - Database for streams
--   {{STREAM_SCHEMA}}          - Schema for streams
--   {{TASK_DATABASE}}          - Database for tasks
--   {{TASK_SCHEMA}}            - Schema for tasks
--   {{WAREHOUSE}}              - Warehouse for task execution
--   {{SCHEDULE}}               - Task schedule (e.g., '1 MINUTE')
--
-- =============================================================================


-- #############################################################################
-- STEP 0: CREATE SECRET
-- #############################################################################

USE ROLE SYSADMIN;

CREATE OR REPLACE SECRET {{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}}
  TYPE = GENERIC_STRING
  SECRET_STRING = '{{NULLAFI_API_KEY}}';


-- #############################################################################
-- STEP 1: CREATE NETWORK RULE AND EXTERNAL ACCESS INTEGRATION
-- #############################################################################

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE {{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}}
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('{{NULLAFI_HOSTNAME}}');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {{INTEGRATION_NAME}}
  ALLOWED_NETWORK_RULES = ({{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}})
  ALLOWED_AUTHENTICATION_SECRETS = ({{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}})
  ENABLED = TRUE;


-- #############################################################################
-- STEP 2: CREATE TARGET DATABASE AND TABLES (in dependency order)
-- #############################################################################

CREATE DATABASE IF NOT EXISTS {{TARGET_DATABASE}};
CREATE SCHEMA IF NOT EXISTS {{TARGET_DATABASE}}.{{TARGET_SCHEMA}};

-- TIER 1: Root tables (no FK dependencies)
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS (
--   DEPARTMENT_ID NUMBER PRIMARY KEY,
--   DEPARTMENT_NAME VARCHAR,
--   LOCATION VARCHAR
-- );

-- TIER 2: Tables referencing TIER 1
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES (
--   EMPLOYEE_ID NUMBER PRIMARY KEY,
--   FIRST_NAME VARCHAR,
--   LAST_NAME VARCHAR,
--   EMAIL VARCHAR,
--   SSN VARCHAR,
--   DEPARTMENT_ID NUMBER,
--   CONSTRAINT FK_DEPT FOREIGN KEY (DEPARTMENT_ID)
--     REFERENCES {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS(DEPARTMENT_ID)
-- );

-- TIER 3: Leaf tables
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS (
--   ORDER_ID NUMBER PRIMARY KEY,
--   EMPLOYEE_ID NUMBER,
--   CC_NUMBER VARCHAR,
--   CONSTRAINT FK_EMP FOREIGN KEY (EMPLOYEE_ID)
--     REFERENCES {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES(EMPLOYEE_ID)
-- );


-- #############################################################################
-- STEP 3: CREATE STORED PROCEDURE
-- #############################################################################
-- Sends ALL fields to the API in batches. The Nullafi API detects and encrypts
-- only values matching the configured obfuscatedDataTypes — everything else
-- passes through unchanged. No need to specify which columns are sensitive.

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
        # The API detects and encrypts only values matching obfuscatedDataTypes.
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


-- #############################################################################
-- STEP 4: BACKFILL ALL TABLES (truncate child-first, insert parent-first)
-- #############################################################################

-- Truncate in reverse dependency order (leaf tables first)
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS;
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES;
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS;

-- Backfill in forward dependency order (parent tables first)
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS',
--   ''
-- );
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES',
--   ''
-- );
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS',
--   ''
-- );


-- #############################################################################
-- STEP 5: CREATE STREAMS (after backfill)
-- #############################################################################

-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.DEPARTMENTS_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS
--   APPEND_ONLY = TRUE;

-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.EMPLOYEES_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES
--   APPEND_ONLY = TRUE;

-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.ORDERS_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS
--   APPEND_ONLY = TRUE;


-- #############################################################################
-- STEP 6: CREATE AND RESUME TASKS (DAG: parents scheduled, children chained)
-- #############################################################################

-- Root task (has SCHEDULE)
-- CREATE OR REPLACE TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_DEPARTMENTS_TASK
--   WAREHOUSE = {{WAREHOUSE}}
--   SCHEDULE = '{{SCHEDULE}}'
--   WHEN SYSTEM$STREAM_HAS_DATA('{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.DEPARTMENTS_STREAM')
-- AS
--   CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--     'incremental',
--     '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS',
--     '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS',
--     '{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.DEPARTMENTS_STREAM'
--   );

-- Child task (AFTER parent)
-- CREATE OR REPLACE TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_EMPLOYEES_TASK
--   WAREHOUSE = {{WAREHOUSE}}
--   AFTER {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_DEPARTMENTS_TASK
--   WHEN SYSTEM$STREAM_HAS_DATA('{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.EMPLOYEES_STREAM')
-- AS
--   CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--     'incremental',
--     '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES',
--     '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES',
--     '{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.EMPLOYEES_STREAM'
--   );

-- Leaf task (AFTER child)
-- CREATE OR REPLACE TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_ORDERS_TASK
--   WAREHOUSE = {{WAREHOUSE}}
--   AFTER {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_EMPLOYEES_TASK
--   WHEN SYSTEM$STREAM_HAS_DATA('{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.ORDERS_STREAM')
-- AS
--   CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--     'incremental',
--     '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS',
--     '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS',
--     '{{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.ORDERS_STREAM'
--   );

-- Resume in reverse order (leaf first, root last)
-- ALTER TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_ORDERS_TASK RESUME;
-- ALTER TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_EMPLOYEES_TASK RESUME;
-- ALTER TASK {{TASK_DATABASE}}.{{TASK_SCHEMA}}.ENCRYPT_DEPARTMENTS_TASK RESUME;


-- #############################################################################
-- STEP 7: VERIFY
-- #############################################################################

-- Check row counts
-- SELECT 'DEPARTMENTS' AS tbl,
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS) AS src,
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS) AS tgt
-- UNION ALL
-- SELECT 'EMPLOYEES',
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES),
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES)
-- UNION ALL
-- SELECT 'ORDERS',
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS),
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS);

-- Check task history
-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--   SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -24, CURRENT_TIMESTAMP()),
--   RESULT_LIMIT => 50
-- ))
-- ORDER BY SCHEDULED_TIME DESC;
