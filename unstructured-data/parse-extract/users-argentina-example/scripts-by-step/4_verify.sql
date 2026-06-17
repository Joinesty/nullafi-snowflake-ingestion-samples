-- =============================================================================
-- Step 4: Verify
-- =============================================================================

SELECT FILE_NAME,
       CASE WHEN EXTRACTED_TEXT_MASKED ILIKE '%NFA_%' THEN 'YES' ELSE 'NO' END AS HAS_NFA_TOKENS,
       LEFT(EXTRACTED_TEXT_MASKED, 400) AS PREVIEW,
       LOADED_AT
FROM POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED
ORDER BY LOADED_AT DESC;
