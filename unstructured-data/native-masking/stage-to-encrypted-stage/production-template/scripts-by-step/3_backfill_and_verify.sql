-- =============================================================================
-- Step 3: (Optional) Backfill existing files + verification
-- =============================================================================
-- PLACEHOLDERS as in previous steps.

-- Backfill: encrypt all files already present in the landing stage
CALL {{PROCEDURE_DATABASE}}.{{PROCEDURE_SCHEMA}}.{{PROCEDURE_NAME}}(
  'all',
  '{{LANDING_DATABASE}}.{{LANDING_SCHEMA}}.{{LANDING_STAGE}}',
  '{{ENCRYPTED_DATABASE}}.{{ENCRYPTED_SCHEMA}}.{{ENCRYPTED_STAGE}}',
  ''
);

-- Verify: list encrypted outputs
LIST @{{ENCRYPTED_DATABASE}}.{{ENCRYPTED_SCHEMA}}.{{ENCRYPTED_STAGE}};

-- Verify masking inside a PDF (requires SSE stage)
-- SELECT SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
--   '@{{ENCRYPTED_DATABASE}}.{{ENCRYPTED_SCHEMA}}.{{ENCRYPTED_STAGE}}',
--   'enc_<your_file>.pdf', {'mode': 'OCR'}):content::STRING;
