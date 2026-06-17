-- =============================================================================
-- Step 4: Verify
-- =============================================================================

-- Row per masked file; confirm NFA_ tokens are present
SELECT FILE_NAME, FILE_FORMAT,
       CASE WHEN MASKED_CONTENT ILIKE '%NFA_%' THEN 'YES' ELSE 'NO' END AS HAS_NFA_TOKENS,
       LEFT(MASKED_CONTENT, 200) AS PREVIEW,
       LOADED_AT
FROM POS.PUBLIC.NULLAFI_MASKED_FILES
ORDER BY LOADED_AT DESC;

-- Example: query masked JSON content as structured data
-- SELECT FILE_NAME, TRY_PARSE_JSON(MASKED_CONTENT) AS j
-- FROM POS.PUBLIC.NULLAFI_MASKED_FILES
-- WHERE FILE_FORMAT = 'json';
