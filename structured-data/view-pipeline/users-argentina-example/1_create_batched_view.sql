-- Step 3: Create a view that encrypts rows in batches using the vectorized UDF.
-- Snowflake automatically groups rows into batches (1,000-5,000) for processing.
-- Within each batch, the UDF sub-batches API calls at 100 rows each.
-- Best for: larger result sets where per-row HTTP calls would be too slow.
--
-- LIMITATIONS:
--   - Batch size is engine-controlled; you cannot force all rows into one API call.
--   - Every query re-encrypts (no caching); repeated SELECTs multiply API usage.
--   - For very large tables (100k+ rows), consider the stream-pipeline approach instead.

CREATE OR REPLACE VIEW POS.PUBLIC.USERS_ARGENTINA_ENCRYPTED_BATCHED AS
SELECT
    encrypted:FIRST_NAME::VARCHAR       AS FIRST_NAME,
    encrypted:LAST_NAME::VARCHAR        AS LAST_NAME,
    encrypted:EMAIL::VARCHAR            AS EMAIL,
    encrypted:HOME_ADDRESS::VARCHAR     AS HOME_ADDRESS,
    encrypted:CC_NUMBER::VARCHAR        AS CC_NUMBER,
    encrypted:PHONE_NUMBER::VARCHAR     AS PHONE_NUMBER,
    encrypted:DATE_OF_BIRTH::VARCHAR    AS DATE_OF_BIRTH,
    encrypted:IBAN::VARCHAR             AS IBAN,
    encrypted:SWIFT_CODE::VARCHAR       AS SWIFT_CODE,
    encrypted:DRIVERS_LICENSE::VARCHAR  AS DRIVERS_LICENSE,
    encrypted:ID::NUMBER                AS ID,
    encrypted:URL::VARCHAR              AS URL,
    encrypted:US_ITIN::VARCHAR          AS US_ITIN,
    encrypted:US_ATIN::VARCHAR          AS US_ATIN,
    encrypted:US_EIN::VARCHAR           AS US_EIN,
    encrypted:US_SSN::VARCHAR           AS US_SSN,
    encrypted:PASSPORT::VARCHAR         AS PASSPORT,
    encrypted:VIN::VARCHAR              AS VIN,
    encrypted:USERNAME::VARCHAR         AS USERNAME,
    encrypted:PASSWORD::VARCHAR         AS PASSWORD,
    encrypted:DOMAIN::VARCHAR           AS DOMAIN,
    encrypted:IP::VARCHAR               AS IP,
    encrypted:MAC_ADDRESS::VARCHAR      AS MAC_ADDRESS,
    encrypted:BADGE::VARCHAR            AS BADGE,
    encrypted:NOTES::VARCHAR            AS NOTES
FROM (
    SELECT NULLAFI_ENCRYPT_ROW_BATCHED(OBJECT_CONSTRUCT(*)) AS encrypted
    FROM POS.PUBLIC.USERS_ARGENTINA
);
