-- =============================================================================
-- Step 0: Create Secret for Nullafi API Key
-- =============================================================================
-- Stores the API key securely in Snowflake. The stored procedure references
-- this secret at runtime — the key never appears in procedure code.
--
-- PLACEHOLDERS:
--   {{SECRET_DATABASE}}      - Database to store the secret (e.g., ADMIN)
--   {{SECRET_SCHEMA}}        - Schema to store the secret (e.g., SECURITY)
--   {{SECRET_NAME}}          - Name of the secret (e.g., NULLAFI_API_KEY)
--   {{NULLAFI_API_KEY}}      - Your actual Nullafi API key value
-- =============================================================================

USE ROLE SYSADMIN; -- or a role with CREATE SECRET privilege

CREATE OR REPLACE SECRET {{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}}
  TYPE = GENERIC_STRING
  SECRET_STRING = '{{NULLAFI_API_KEY}}';
