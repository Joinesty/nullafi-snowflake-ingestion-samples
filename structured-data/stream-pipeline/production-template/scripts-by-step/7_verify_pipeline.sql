-- =============================================================================
-- Step 7: Verify the Pipeline
-- =============================================================================
-- Queries to validate that the pipeline is working correctly.
--
-- PLACEHOLDERS:
--   {{SOURCE_DATABASE}}      - Source database name
--   {{SOURCE_SCHEMA}}        - Source schema name
--   {{TARGET_DATABASE}}      - Target database name
--   {{TARGET_SCHEMA}}        - Target schema name
--   {{TASK_DATABASE}}        - Database where tasks live
--   {{TASK_SCHEMA}}          - Schema where tasks live
--   {{STREAM_DATABASE}}      - Database where streams live
--   {{STREAM_SCHEMA}}        - Schema where streams live
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Verify row counts match between source and target
-- -----------------------------------------------------------------------------

-- SELECT
--   '{{SOURCE_SCHEMA}}.DEPARTMENTS' AS table_name,
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS) AS source_rows,
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS) AS target_rows
-- UNION ALL
-- SELECT
--   '{{SOURCE_SCHEMA}}.EMPLOYEES',
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.EMPLOYEES),
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES)
-- UNION ALL
-- SELECT
--   '{{SOURCE_SCHEMA}}.ORDERS',
--   (SELECT COUNT(*) FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.ORDERS),
--   (SELECT COUNT(*) FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS);

-- -----------------------------------------------------------------------------
-- 2. Verify streams are empty (all data has been consumed)
-- -----------------------------------------------------------------------------

-- SELECT * FROM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.DEPARTMENTS_STREAM;
-- SELECT * FROM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.EMPLOYEES_STREAM;
-- SELECT * FROM {{STREAM_DATABASE}}.{{STREAM_SCHEMA}}.ORDERS_STREAM;

-- -----------------------------------------------------------------------------
-- 3. Verify tasks are running and scheduled
-- -----------------------------------------------------------------------------

-- SHOW TASKS IN SCHEMA {{TASK_DATABASE}}.{{TASK_SCHEMA}};

-- -----------------------------------------------------------------------------
-- 4. Check task execution history for errors
-- -----------------------------------------------------------------------------

-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--   SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -24, CURRENT_TIMESTAMP()),
--   RESULT_LIMIT => 50
-- ))
-- WHERE DATABASE_NAME = '{{TASK_DATABASE}}'
--   AND SCHEMA_NAME = '{{TASK_SCHEMA}}'
-- ORDER BY SCHEDULED_TIME DESC;

-- -----------------------------------------------------------------------------
-- 5. Spot-check encrypted values (sensitive columns should have NFA_ prefix)
-- -----------------------------------------------------------------------------

-- SELECT * FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.EMPLOYEES LIMIT 5;
-- SELECT * FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.ORDERS LIMIT 5;

-- -----------------------------------------------------------------------------
-- 6. End-to-end test: insert a row and wait for encryption
-- -----------------------------------------------------------------------------

-- INSERT INTO {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS (DEPARTMENT_ID, DEPARTMENT_NAME)
--   VALUES (9999, 'Test Department');
--
-- -- Wait ~1 minute for the task to fire, then check:
-- SELECT * FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS WHERE DEPARTMENT_ID = 9999;
--
-- -- Clean up test data:
-- DELETE FROM {{SOURCE_DATABASE}}.{{SOURCE_SCHEMA}}.DEPARTMENTS WHERE DEPARTMENT_ID = 9999;
-- DELETE FROM {{TARGET_DATABASE}}.{{TARGET_SCHEMA}}.DEPARTMENTS WHERE DEPARTMENT_ID = 9999;
