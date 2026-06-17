-- =============================================================================
-- Step 5: Create Streams on All Source Tables
-- =============================================================================
-- Creates an append-only stream on each source table to capture new inserts.
-- Must be run AFTER the backfill so streams only track new data going forward.
--
-- NAMING CONVENTION: {{TABLE_NAME}}_STREAM
--
-- PLACEHOLDERS:
--   {{SOURCE_DATABASE}}      - Source database name
--   {{SOURCE_SCHEMA}}        - Source schema name
--   {{STREAM_DATABASE}}      - Database for streams (can be same as source or separate)
--   {{STREAM_SCHEMA}}        - Schema for streams
-- =============================================================================

-- Create one stream per source table

-- TIER 1
-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.DEPARTMENTS_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS
--   APPEND_ONLY = TRUE;

-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.COUNTRIES_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.COUNTRIES
--   APPEND_ONLY = TRUE;

-- TIER 2
-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.EMPLOYEES_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES
--   APPEND_ONLY = TRUE;

-- TIER 3
-- CREATE OR REPLACE STREAM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.ORDERS_STREAM
--   ON TABLE {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS
--   APPEND_ONLY = TRUE;
