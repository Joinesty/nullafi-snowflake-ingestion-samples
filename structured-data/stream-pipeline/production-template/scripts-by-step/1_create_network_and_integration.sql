-- =============================================================================
-- Step 1: Create Network Rule and External Access Integration
-- =============================================================================
-- Enables the stored procedure to make outbound HTTPS calls to the Nullafi API.
--
-- PLACEHOLDERS:
--   {{SECRET_DATABASE}}      - Database where the secret is stored
--   {{SECRET_SCHEMA}}        - Schema where the secret is stored
--   {{SECRET_NAME}}          - Name of the secret created in step 0
--   {{NETWORK_RULE_DB}}      - Database for the network rule (e.g., ADMIN)
--   {{NETWORK_RULE_SCHEMA}}  - Schema for the network rule (e.g., SECURITY)
--   {{NETWORK_RULE_NAME}}    - Name of the network rule
--   {{NULLAFI_HOSTNAME}}     - Nullafi API hostname (e.g., api.nullafi.com)
--   {{INTEGRATION_NAME}}     - Name of the external access integration
-- =============================================================================

USE ROLE ACCOUNTADMIN; -- Required for CREATE INTEGRATION

CREATE OR REPLACE NETWORK RULE {{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}}
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('{{NULLAFI_HOSTNAME}}');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {{INTEGRATION_NAME}}
  ALLOWED_NETWORK_RULES = ({{NETWORK_RULE_DB}}.{{NETWORK_RULE_SCHEMA}}.{{NETWORK_RULE_NAME}})
  ALLOWED_AUTHENTICATION_SECRETS = ({{SECRET_DATABASE}}.{{SECRET_SCHEMA}}.{{SECRET_NAME}})
  ENABLED = TRUE;
