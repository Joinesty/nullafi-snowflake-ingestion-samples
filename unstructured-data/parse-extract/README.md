# Parse + Extract Approach (for unsupported formats)

Encrypt sensitive data in file formats that Nullafi's engine does **not** mask natively — primarily images (JPEG, PNG, TIFF). Since the content can't be masked in place, this approach extracts text with Snowflake's `AI_PARSE_DOCUMENT`, masks the extracted text via Nullafi, and stores the encrypted text.

---

## ⚠️ Read This First: Security Caveat

`AI_PARSE_DOCUMENT` uses **AI models** to extract content from files. This means the **raw PII is processed by a model during extraction — before it can be masked**.

| Consideration | Detail |
|---------------|--------|
| Where does extraction happen? | Inside Snowflake's Cortex boundary |
| Is data sent to an external third-party LLM? | No |
| Is data used for model training? | No (per Snowflake's AI terms) |
| Does a model see raw PII? | **Yes** — during the parse/OCR step |

**When this approach is acceptable:**
- Your policy allows PII to be processed by AI within Snowflake's governance boundary
- You need to handle formats (images) that have no other masking path

**When this approach is NOT acceptable:**
- Your policy is "no AI model may ever see raw PII, even internally"
- In that case, do not ingest these formats at all, or mask them with an external tool before they reach Snowflake

For images specifically, there is no way to avoid this: OCR/vision must run on the raw pixels to locate PII before it can be masked. This is a fundamental constraint, not a limitation of the implementation.

> If this approach does not fit your compliance posture, archive this folder. The `native-masking/` approach (for PDF, OpenXML, and text formats) does not have this limitation because Nullafi masks those formats deterministically without an AI model.

---

## Supported Formats

| Format | Extension |
|--------|-----------|
| JPEG | `.jpeg`, `.jpg` |
| PNG | `.png` |
| TIFF | `.tiff`, `.tif` |

(`AI_PARSE_DOCUMENT` also supports PDF/DOCX/PPTX, but for those prefer `native-masking/` since Nullafi handles them without exposing PII to a model.)

---

## How It Works

```
┌────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌──────────────┐   ┌─────────────┐
│ Landing     │──▶│ AI_PARSE_DOCUMENT│──▶│ Nullafi API  │──▶│ Encrypted    │──▶│ Target      │
│ Stage       │   │ (OCR/extract     │   │ (mask the    │   │ text         │   │ Table       │
│ (images)    │   │  text — sees PII)│   │  text)       │   │              │   │ (or .txt)   │
└────────────┘   └──────────────────┘   └──────────────┘   └──────────────┘   └─────────────┘
```

1. Image files land in a landing stage
2. A task detects new files
3. A stored procedure:
   - Calls `AI_PARSE_DOCUMENT` to extract text from each image (OCR)
   - Sends the extracted text to Nullafi's `/api/scan-dynamic` for masking
   - Stores the encrypted text in a target table (or writes it as a `.txt` file to a target stage)
4. The raw image is removed from the landing stage

Note: the **output is text, not the original image**. You cannot reconstruct a masked image — the encrypted result is the extracted, masked text content.

---

## Placeholders

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{SECRET_DATABASE}}` | Database for API key secret | `ADMIN` |
| `{{SECRET_SCHEMA}}` | Schema for secret | `SECURITY` |
| `{{SECRET_NAME}}` | Secret name | `NULLAFI_API_KEY` |
| `{{NULLAFI_API_KEY}}` | Nullafi API key value | `abc123...` |
| `{{NULLAFI_HOSTNAME}}` | Nullafi API host | `test2.broknus.com` |
| `{{INTEGRATION_NAME}}` | External access integration | `NULLAFI_API_ACCESS` |
| `{{LANDING_STAGE}}` | Landing stage (raw images, transient) | `@RAW_IMAGES` |
| `{{TARGET_TABLE}}` | Target table for extracted/encrypted text | `IMAGE_TEXT_ENCRYPTED` |
| `{{DATA_TYPES}}` | Nullafi data type identifiers | `CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS` |
| `{{MASK_FORMATS}}` | Mask formats per type | `CYPHER,CYPHER,CYPHER,CYPHER` |
| `{{WAREHOUSE}}` | Warehouse for tasks (MEDIUM or smaller for AI_PARSE_DOCUMENT) | `COMPUTE_WH` |

---

## Cost Note

`AI_PARSE_DOCUMENT` bills per page; each image file counts as one page. Run it on a warehouse no larger than MEDIUM — larger warehouses do not improve performance for this function.

---

## As-Built Implementation (live tested)

| Object | Name (example) |
|--------|----------------|
| Landing stage | `POS.PUBLIC.NULLAFI_LANDING_STAGE` (SSE) |
| Target table | `POS.PUBLIC.NULLAFI_IMAGE_TEXT_MASKED` |
| Procedure | `POS.PUBLIC.NULLAFI_PARSE_EXTRACT_IMAGES(mode, source, target_table, stream)` |
| Stream | `POS.PUBLIC.NULLAFI_LANDING_STREAM_IMG` |
| Task | `POS.PUBLIC.NULLAFI_PARSE_EXTRACT_TASK` |

The procedure: lists image files → runs `PARSE_DOCUMENT(..., {'mode':'OCR'})` to get text → POSTs the text to `/api/scan-dynamic` → inserts masked text into the table. Output is masked text (target table column `EXTRACTED_TEXT_MASKED`), not a reconstructed image.

### Folders

- `users-argentina-example/` — deployed and tested against `POS.PUBLIC` (scripts-by-step + single-script)
- `production-template/` — placeholder version (single-script; mirror the example's step files if you prefer numbered steps)

### Key requirement

- Stage MUST use `SNOWFLAKE_SSE`. `PARSE_DOCUMENT` errors on client-side-encrypted stages ("Input files from stages with Client Side Encryption is not supported").

### Test Results (users-argentina-example)

| File | Result |
|------|--------|
| users_sample.png (PII rendered as text) | OCR'd by AI_PARSE_DOCUMENT, extracted text masked (EMAIL, CC_NUMBER, US_SSN → `NFA_` tokens), stored in `NULLAFI_IMAGE_TEXT_MASKED` |

Confirmed `NFA_` tokens present in the stored text. The PII was visible to the OCR model during extraction — see the caveat above.
