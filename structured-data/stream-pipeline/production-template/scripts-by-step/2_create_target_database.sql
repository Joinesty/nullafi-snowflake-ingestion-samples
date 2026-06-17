-- =============================================================================
-- Step 2: Create Target Database and Schema Structure
-- =============================================================================
-- Creates the encrypted target database mirroring the source structure.
-- Tables are created in dependency order (parent tables first) to respect
-- foreign key constraints.
--
-- IMPORTANT: Tables must be created in topological order:
--   1. Tables with no foreign keys (root/parent tables)
--   2. Tables that reference only root tables
--   3. Tables that reference tables from step 2, etc.
--
-- This ensures all referenced tables exist before FK constraints are added.
--
-- PLACEHOLDERS:
--   {{TARGET_DATABASE}}      - Name of the encrypted target database
--   {{TARGET_SCHEMA}}        - Schema name in the target database
--   {{SOURCE_DATABASE}}      - Name of the source database (for reference)
--   {{SOURCE_SCHEMA}}        - Schema name in the source database (for reference)
-- =============================================================================

-- Create the target database and schema
CREATE DATABASE IF NOT EXISTS {{TARGET_DATABASE}};
CREATE SCHEMA IF NOT EXISTS {{TARGET_DATABASE}}.{{TARGET_SCHEMA}};

-- -----------------------------------------------------------------------------
-- TIER 1: Root tables (no foreign key dependencies)
-- Create these first as other tables reference them.
-- -----------------------------------------------------------------------------

-- Example: A root table with a primary key
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS (
--   DEPARTMENT_ID NUMBER PRIMARY KEY,
--   DEPARTMENT_NAME VARCHAR,
--   LOCATION VARCHAR
-- );

-- Example: Another root table
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.COUNTRIES (
--   COUNTRY_CODE VARCHAR(3) PRIMARY KEY,
--   COUNTRY_NAME VARCHAR
-- );

-- -----------------------------------------------------------------------------
-- TIER 2: Tables that reference TIER 1 tables
-- -----------------------------------------------------------------------------

-- Example: Table with FK to a TIER 1 table
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES (
--   EMPLOYEE_ID NUMBER PRIMARY KEY,
--   FIRST_NAME VARCHAR,
--   LAST_NAME VARCHAR,
--   EMAIL VARCHAR,           -- sensitive: will be encrypted
--   SSN VARCHAR,             -- sensitive: will be encrypted
--   DEPARTMENT_ID NUMBER,
--   COUNTRY_CODE VARCHAR(3),
--   CONSTRAINT FK_DEPT FOREIGN KEY (DEPARTMENT_ID)
--     REFERENCES {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS(DEPARTMENT_ID),
--   CONSTRAINT FK_COUNTRY FOREIGN KEY (COUNTRY_CODE)
--     REFERENCES {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.COUNTRIES(COUNTRY_CODE)
-- );

-- -----------------------------------------------------------------------------
-- TIER 3: Tables that reference TIER 2 tables
-- -----------------------------------------------------------------------------

-- Example: Table with FK to a TIER 2 table
-- CREATE OR REPLACE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS (
--   ORDER_ID NUMBER PRIMARY KEY,
--   EMPLOYEE_ID NUMBER,
--   ORDER_DATE DATE,
--   CC_NUMBER VARCHAR,       -- sensitive: will be encrypted
--   CONSTRAINT FK_EMP FOREIGN KEY (EMPLOYEE_ID)
--     REFERENCES {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES(EMPLOYEE_ID)
-- );

-- =============================================================================
-- NOTE: Replicate your actual source schema here with all PK/FK constraints.
-- Use SHOW PRIMARY KEYS IN SCHEMA and SHOW IMPORTED KEYS IN SCHEMA on your
-- source database to discover the constraint graph.
--
-- Helper queries to discover your source schema:
--   SHOW PRIMARY KEYS IN SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}};
--   SHOW IMPORTED KEYS IN SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}};
--   SHOW TABLES IN SCHEMA {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}};
-- =============================================================================
