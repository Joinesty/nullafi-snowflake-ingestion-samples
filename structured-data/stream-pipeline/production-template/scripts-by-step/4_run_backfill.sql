-- =============================================================================
-- Step 4: Run Backfill for All Tables
-- =============================================================================
-- Truncates target tables and re-encrypts all existing rows from each source table.
--
-- IMPORTANT: Tables must be processed in reverse dependency order for TRUNCATE
-- (children first, parents last) to avoid FK constraint violations.
-- Then INSERT in forward dependency order (parents first, children last).
--
-- Strategy:
--   1. Disable FK constraints OR truncate in reverse order
--   2. Call the procedure in 'backfill' mode for each table in dependency order
--
-- PLACEHOLDERS:
--   {{PROCEDURE_DATABASE}}   - Database where the procedure lives
--   {{PROCEDURE_SCHEMA}}     - Schema where the procedure lives
--   {{PROCEDURE_NAME}}       - Name of the encryption procedure
--   {{SOURCE_DATABASE}}      - Source database name
--   {{SOURCE_SCHEMA}}        - Source schema name
--   {{TARGET_DATABASE}}      - Target (encrypted) database name
--   {{TARGET_SCHEMA}}        - Target schema name
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TRUNCATE in reverse dependency order (leaf tables first)
-- -----------------------------------------------------------------------------

-- TIER 3 (leaf tables - no other table references them)
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS;

-- TIER 2
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES;

-- TIER 1 (root tables)
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS;
-- TRUNCATE TABLE {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.COUNTRIES;

-- -----------------------------------------------------------------------------
-- BACKFILL in forward dependency order (parent tables first)
-- This ensures FK references are satisfied as data is inserted.
-- -----------------------------------------------------------------------------

-- TIER 1: Root tables
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS',
--   ''  -- stream not used in backfill mode
-- );

-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.COUNTRIES',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.COUNTRIES',
--   ''
-- );

-- TIER 2: Tables referencing TIER 1
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES',
--   ''
-- );

-- TIER 3: Leaf tables
-- CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
--   'backfill',
--   '{{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS',
--   '{{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS',
--   ''
-- );
