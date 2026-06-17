# Nullafi Encryption Pipeline - Unstructured Data

Encrypt sensitive data inside files **before they are ingested** into Snowflake. Files are sent to the Nullafi API first, which masks sensitive content in place and returns the file in its original format. Only the encrypted version is ingested — raw PII never lands in a consumable Snowflake object.

---

## Why Encrypt Unstructured Data?

When files on Snowflake stages are used by:
- **Cortex Agents / Snowflake Intelligence** (RAG pipelines, document Q&A)
- **AI_PARSE_DOCUMENT** (OCR, layout extraction)
- **AI_COMPLETE** (document-aware LLM prompts)
- **Cortex Search** (semantic search over documents)

...any PII or sensitive data in those files gets exposed to the model. Encrypting sensitive values before AI consumption ensures compliance while still allowing meaningful analysis.

---

## Two Approaches

This folder is split into two approaches based on whether Nullafi's engine supports the file format natively:

### `native-masking/` — Formats Nullafi supports directly

For PDF, OpenXML (DOCX, XLSX, PPTX), HTML, TXT, CSV, JSON, XML. The file is sent to the Nullafi API as-is and returned in the **same format** with sensitive content masked. No AI model ever sees the raw PII — Nullafi's engine does the masking deterministically. This is the recommended approach for any supported format.

### `parse-extract/` — Formats Nullafi does NOT support natively

For images (JPEG, PNG, TIFF) and other formats where content must be extracted before it can be masked. Uses Snowflake's `AI_PARSE_DOCUMENT` to OCR/extract text, then sends the extracted text to Nullafi for masking. Output is encrypted **text** (the original image format cannot be preserved).

> **IMPORTANT CAVEAT:** `AI_PARSE_DOCUMENT` uses AI models to extract content, which means the **raw PII is processed by a model during extraction** — before it can be masked. This processing happens inside Snowflake's Cortex boundary (not sent to an external third-party LLM, and not used for training per Snowflake's AI terms). However, if your compliance requirement is "no AI model should ever see raw PII, even internally," this approach does not satisfy it. For images there is no way around this: something must perform OCR/vision on the raw pixels to locate the PII before masking. Use this approach only when Cortex-internal processing is acceptable under your governance policy.

---

## Supported File Types

### Native Masking (`native-masking/`) — format preserved

| Format | Extension | Use Case |
|--------|-----------|----------|
| PDF | `.pdf` | Contracts, invoices, reports |
| Word (OpenXML) | `.docx` | Letters, HR documents |
| Excel (OpenXML) | `.xlsx` | Spreadsheets with PII |
| PowerPoint (OpenXML) | `.pptx` | Presentations with PII |
| HTML | `.html` | Web content, exports |
| Plain text | `.txt` | Logs, transcripts |
| CSV | `.csv` | Tabular exports, data feeds |
| JSON | `.json` | API responses, event data |
| XML | `.xml` | Legacy system exports |

### Parse + Extract (`parse-extract/`) — text extracted, original format not preserved

| Format | Extension | Use Case |
|--------|-----------|----------|
| Image | `.jpeg`, `.jpg`, `.png`, `.tiff`, `.tif` | Scanned documents, photos of forms, ID cards |

---

## Core Principle: Encrypt Before Ingest

The defining characteristic of these workflows is that **the Nullafi API is called before the data is ingested** into its final destination. Raw files land in a temporary landing stage, get encrypted by Nullafi, and only the encrypted output is ingested. This guarantees unencrypted PII is never stored in a queryable or AI-consumable Snowflake object.

**Production separation:** in production the landing area and the encrypted output live in **separate databases** — a clear-text database (locked down, only the masking role can read it) and an encrypted database (the only one AI agents/Cortex are granted access to). The examples here use one schema (`POS.PUBLIC`) for convenience. For stricter isolation the two can be in separate accounts, with the encrypted database shared read-only to the agent account (Snowflake has no cross-account write — masking runs producer-side and the result is shared). See the [root README security boundary](../README.md#the-security-boundary-clear-text-vs-encrypted-separate-databases).

```
┌──────────────┐    ┌──────────────────┐    ┌──────────────────────┐
│ Landing Stage │──▶│ Nullafi API      │──▶│ Ingest Encrypted     │
│ (raw files,   │    │ (mask in place,  │    │ Output               │
│  transient)   │    │  same format)    │    │ (stage or table)     │
└──────────────┘    └──────────────────┘    └──────────────────────┘
```

---

## Two Workflows

### 1. Stage to Encrypted Stage (`stage-to-encrypted-stage/`)

```
Landing Stage → Nullafi API (mask, same format) → Encrypted Target Stage
```

**Best for:**
- Documents that must stay as files (for AI_PARSE_DOCUMENT, Cortex Search, RAG)
- Any format where you want to preserve the original file type (PDF stays PDF, DOCX stays DOCX)
- Preparing files for safe AI agent / LLM consumption

**How it works:**
1. Raw files land in a landing stage
2. A task (or Snowpipe event notification) detects new files
3. A stored procedure:
   - Reads each file (binary or text)
   - Sends it to Nullafi's `/api/scan-dynamic` — the engine masks content natively for OpenXML, PDF, and all text formats
   - Receives the encrypted file in the same format
   - Writes it to the target (encrypted) stage
4. The raw file is removed from the landing stage
5. AI agents read only from the encrypted target stage

**Components:**
- Landing stage + target (encrypted) stage
- Task triggered by new files
- Python stored procedure (read → encrypt → write)
- External Access Integration (for Nullafi API)

### 2. Stage to Table (`stage-to-table/`)

```
Landing Stage → Nullafi API (mask) → Ingest encrypted content into Table
```

**Best for:**
- CSV/JSON/XML files that should become queryable rows
- Loading structured file data where the encrypted output is parsed into columns

**How it works:**
1. Raw files land in a landing stage
2. A task detects new files
3. A stored procedure:
   - Reads each file
   - Sends it to Nullafi's `/api/scan-dynamic` for masking
   - Loads the encrypted content into the target table (via COPY INTO or direct insert)
4. The raw file is removed from the landing stage

**Components:**
- Landing stage + target table
- Task triggered by new files
- Python stored procedure (read → encrypt → load)
- External Access Integration (for Nullafi API)

---

## Architecture Comparison

```
WORKFLOW 1: Stage → Encrypted Stage (format preserved)
┌────────────┐    ┌──────────────────┐    ┌──────────────┐    ┌─────────────┐
│ Landing     │───▶│ Task             │───▶│ Nullafi API  │───▶│ Encrypted   │
│ Stage       │    │ (read + send)    │    │ (mask, same  │    │ Target      │
│ (raw files) │    └──────────────────┘    │  format)     │    │ Stage       │
└────────────┘                             └──────────────┘    └─────────────┘
                                                                       │
                                                                       ▼
                                                            ┌─────────────────┐
                                                            │ AI Agents /     │
                                                            │ Cortex Search / │
                                                            │ RAG Pipelines   │
                                                            └─────────────────┘

WORKFLOW 2: Stage → Table (structured rows)
┌────────────┐    ┌──────────────────┐    ┌──────────────┐    ┌─────────────┐
│ Landing     │───▶│ Task             │───▶│ Nullafi API  │───▶│ Target      │
│ Stage       │    │ (read + send)    │    │ (mask)       │    │ Table       │
│ (raw files) │    └──────────────────┘    └──────────────┘    │ (rows)      │
└────────────┘                                                  └─────────────┘
```

---

## Folder Structure

```
unstructured-data/
├── README.md                              ← You are here
├── WORKFLOW-DESIGN.md                     ← Design reference (reconciled with as-built system)
├── native-masking/                        ← Formats Nullafi masks natively (format preserved)
│   ├── stage-to-encrypted-stage/          ← File in → encrypted file out (same format)
│   │   ├── README.md
│   │   ├── users-argentina-example/       ← deployed + tested
│   │   └── production-template/           ← placeholders
│   └── stage-to-table/                    ← File in → encrypted rows in a table
│       ├── README.md
│       ├── users-argentina-example/
│       └── production-template/
└── parse-extract/                         ← Images → AI_PARSE_DOCUMENT → mask text
    ├── README.md
    ├── users-argentina-example/
    └── production-template/
```

All three pipelines are built, tested live against `POS.PUBLIC`, and documented. See [WORKFLOW-DESIGN.md](WORKFLOW-DESIGN.md) for design decisions and test findings, and each pipeline's own README for use case, architecture, and test results.

---

## Key Differences from Structured Data Pipeline

| Aspect | Structured (table-to-table) | Unstructured (file-based) |
|--------|---------------------------|--------------------------|
| **Source** | Snowflake table + stream | Stage + file event notification |
| **Trigger** | Stream has data | New file arrives on stage |
| **Input format** | Rows/columns | File contents (text, binary) |
| **Parsing needed** | No (already structured) | No — Nullafi masks files natively, format preserved |
| **Output** | Encrypted table rows | Encrypted files (same format) OR encrypted table rows |
| **AI-ready** | Query via SQL | Consume via AI_PARSE_DOCUMENT, Cortex Search, RAG |

---

## Placeholders (shared across both workflows)

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{SECRET_DATABASE}}` | Database for API key secret | `ADMIN` |
| `{{SECRET_SCHEMA}}` | Schema for secret | `SECURITY` |
| `{{SECRET_NAME}}` | Secret name | `NULLAFI_API_KEY` |
| `{{NULLAFI_API_KEY}}` | Nullafi API key value | `abc123...` |
| `{{NULLAFI_HOSTNAME}}` | Nullafi API host | `test2.broknus.com` |
| `{{INTEGRATION_NAME}}` | External access integration | `NULLAFI_API_ACCESS` |
| `{{LANDING_STAGE}}` | Landing stage (raw files, transient) | `@RAW_FILES` |
| `{{TARGET_STAGE}}` | Target stage (encrypted files) | `@ENCRYPTED_FILES` |
| `{{TARGET_TABLE}}` | Target table (for stage-to-table) | `DOCUMENTS_ENCRYPTED` |
| `{{DATA_TYPES}}` | Nullafi data type identifiers | `CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS` |
| `{{MASK_FORMATS}}` | Mask formats per type | `CYPHER,CYPHER,CYPHER,CYPHER` |
| `{{BATCH_SIZE}}` | Files per batch | `10` |
| `{{WAREHOUSE}}` | Warehouse for tasks | `COMPUTE_WH` |

---

## Important Considerations

### Native Format Masking

Nullafi's engine masks content directly within OpenXML (DOCX, XLSX, PPTX), PDF, and all text-based formats. You send the file as-is and receive it back in the same format with sensitive values encrypted. There is no need to:
- Extract text with AI_PARSE_DOCUMENT before encrypting
- Reconstruct the document afterward
- Convert binary formats to text

This means a PDF stays a valid PDF, a DOCX stays a valid DOCX — fully consumable by AI agents and Cortex functions, but with PII encrypted.

### Encrypt Before Ingest

The API call happens at the landing stage, before the file reaches its final destination. This is a deliberate security boundary: raw, unencrypted PII never lands in a queryable table or an AI-consumable stage. Treat the landing stage as transient — remove raw files once encrypted.

### Binary vs Text Transport

- **Document files (PDF, OpenXML)**: read as binary, sent to the API as the request body, returned as binary
- **Text files (CSV, JSON, XML, TXT, HTML)**: read as text, sent as the request body, returned as text

In both cases the response is the same format as the request, per the Nullafi `/api/scan-dynamic` contract.

### Event Notifications vs Polling

- **Internal stages**: Use `SYSTEM$PIPE_STATUS` or directory table polling
- **External stages (S3/GCS/Azure)**: Use cloud event notifications (SNS, EventGrid, Pub/Sub) with Snowpipe auto-ingest
- **Simplest option**: A task that periodically checks the directory table for new files
