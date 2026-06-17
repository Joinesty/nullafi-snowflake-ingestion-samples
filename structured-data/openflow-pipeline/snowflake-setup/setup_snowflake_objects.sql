-- =============================================================================
-- Openflow Pipeline - Snowflake Setup
-- =============================================================================
-- This script creates all Snowflake objects needed BEFORE importing the
-- Openflow flow definition. Run these in order.
--
-- PLACEHOLDERS:
--   {{OPENFLOW_USER}}        - Service user for Openflow
--   {{OPENFLOW_ROLE}}        - Role for Openflow access
--   {{OPENFLOW_WAREHOUSE}}   - Warehouse for Openflow operations
--   {{SOURCE_DATABASE}}      - Source database name
--   {{SOURCE_SCHEMA}}        - Source schema name
--   {{TARGET_DATABASE}}      - Target (encrypted) database name
--   {{TARGET_SCHEMA}}        - Target schema name
--   {{RSA_PUBLIC_KEY}}       - RSA public key (for key-pair auth in BYOC)
-- =============================================================================


-- #############################################################################
-- STEP 1: Create the Openflow service user and role
-- #############################################################################

USE ROLE ACCOUNTADMIN;

-- Create the role
CREATE ROLE IF NOT EXISTS {{OPENFLOW_ROLE}};

-- Create a service user (no password — uses key-pair or managed token)
CREATE USER IF NOT EXISTS {{OPENFLOW_USER}}
  TYPE = SERVICE
  DEFAULT_ROLE = {{OPENFLOW_ROLE}}
  COMMENT = 'Service user for Nullafi encryption Openflow pipeline';

GRANT ROLE {{OPENFLOW_ROLE}} TO USER {{OPENFLOW_USER}};

-- For BYOC deployments using key-pair auth:
-- ALTER USER {{OPENFLOW_USER}} SET RSA_PUBLIC_KEY = '{{RSA_PUBLIC_KEY}}';


-- #############################################################################
-- STEP 2: Create a warehouse for Openflow
-- #############################################################################

CREATE WAREHOUSE IF NOT EXISTS {{OPENFLOW_WAREHOUSE}} WITH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;

GRANT USAGE, OPERATE ON WAREHOUSE {{OPENFLOW_WAREHOUSE}} TO ROLE {{OPENFLOW_ROLE}};


-- #############################################################################
-- STEP 3: Grant source database access (read-only)
-- #############################################################################

GRANT USAGE ON DATABASE {{SOURCE_DATABASE}} TO ROLE {{OPENFLOW_ROLE}};
GRANT USAGE ON SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};
GRANT SELECT ON ALL TABLES IN SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};
GRANT SELECT ON FUTURE TABLES IN SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};


-- #############################################################################
-- STEP 4: Create the target database and grant write access
-- #############################################################################

CREATE DATABASE IF NOT EXISTS {{TARGET_DATABASE}};
CREATE SCHEMA IF NOT EXISTS {{TARGET_DATABASE}}.{{TARGET_SCHEMA}};

GRANT USAGE ON DATABASE {{TARGET_DATABASE}} TO ROLE {{OPENFLOW_ROLE}};
GRANT USAGE, CREATE TABLE ON SCHEMA {{TARGET_DATABASE}}.{{TARGET_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA {{TARGET_DATABASE}}.{{TARGET_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};
GRANT INSERT, SELECT ON FUTURE TABLES IN SCHEMA {{TARGET_DATABASE}}.{{TARGET_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};


-- #############################################################################
-- STEP 5: Create the stream on the source table(s)
-- #############################################################################
-- The ConsumeSnowflakeStream processor reads from these streams.
-- Create one stream per source table you want to replicate.

-- GRANT CREATE STREAM ON SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}} TO ROLE {{OPENFLOW_ROLE}};

-- The stream can be created here or let the Openflow processor create it:
-- CREATE OR REPLACE STREAM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.USERS_ARGENTINA_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.USERS_ARGENTINA
--   APPEND_ONLY = TRUE;

-- GRANT SELECT ON STREAM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.USERS_ARGENTINA_STREAM
--   TO ROLE {{OPENFLOW_ROLE}};


-- #############################################################################
-- STEP 6: Create target tables (with PK/FK constraints, in dependency order)
-- #############################################################################
-- Mirror your source schema structure here.
-- Same ordering rules as the stream-pipeline approach:
--   TIER 1 (parents) first, then TIER 2, then TIER 3 (leaf tables).

-- Example:
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.USERS_ARGENTINA_ENCRYPTED (
--   FIRST_NAME VARCHAR,
--   LAST_NAME VARCHAR,
--   EMAIL VARCHAR,
--   HOME_ADDRESS VARCHAR,
--   CC_NUMBER VARCHAR,
--   ... (all columns matching source)
-- );


-- #############################################################################
-- STEP 7: Configure network access for Nullafi API
-- #############################################################################
-- For Snowflake Deployments: Add the Nullafi hostname to the allowed domains
-- via the Openflow UI (Runtime Settings > Network > Allowed Domains).
--
-- For BYOC: The compute pool already has outbound internet access by default.
--
-- Hostname to allow: {{NULLAFI_HOSTNAME}} (e.g., test2.broknus.com)
