# Nullafi Encryption Pipeline for Snowflake

Automated data encryption pipeline that migrates data between Snowflake databases while encrypting sensitive fields through the [Nullafi Shield API](https://docs.nullafi.com/api/scanning/dynamic-scan/).

---

## What This Does

This pipeline takes data from a **source database** and replicates it into a **target database**, sending all data through Nullafi's tokenization API before insertion. The API automatically detects and encrypts values matching the configured data types (credit cards, SSNs, IBANs, emails, etc.) -- you don't need to specify which columns are sensitive. Once deployed, it keeps the target database automatically in sync with the source -- every new row inserted into any source table is encrypted and inserted into the corresponding target table within ~1 minute.

### Key Capabilities

- **Full database migration** -- not just one table, but an entire database with all its tables
- **Respects foreign key constraints** -- processes tables in dependency order
- **Initial backfill** -- encrypts all existing data in a single operation
- **Automatic incremental sync** -- new rows are detected and processed automatically
- **Configurable encryption** -- choose which columns to encrypt and which mask format to use
- **Single reusable procedure** -- one stored procedure handles all tables (parameterized)

---

## The Security Boundary (clear-text DB vs encrypted DB)

In production the **source database holds clear-text data and the target database holds only encrypted data** — they are deliberately separate databases, and that separation is the security boundary:

- The **clear-text (source) database** is locked down. Only the masking pipeline's service role reads it. AI agents, Cortex Search, and broad analyst roles get **no grants** on it.
- The **encrypted (target) database** is the only thing exposed to AI agents / Cortex / RAG — grant those roles `USAGE` here and nowhere near the clear-text data.
- The **procedure is the only bridge**: it runs with a role that has read on the source DB and write on the target DB.

For stricter isolation, the two databases can live in **separate accounts**: the masking runs in the clear-text account, writes the encrypted DB locally, and that encrypted DB is **shared read-only** to a separate agent-facing account (Snowflake has no cross-account write — see the [root README](../../README.md#the-security-boundary-clear-text-vs-encrypted-separate-databases)). The example in this folder uses one schema (`POS.PUBLIC`) for convenience; the `production-template` uses distinct source/target databases.

---

## Architecture

```
SOURCE DATABASE                          TARGET DATABASE (encrypted)
┌──────────────────────┐                 ┌──────────────────────┐
│  DEPARTMENTS (PK)    │──── stream ───▶ │  DEPARTMENTS (PK)    │
│  EMPLOYEES (FK→DEPT) │──── stream ───▶ │  EMPLOYEES (FK→DEPT) │
│  ORDERS (FK→EMP)     │──── stream ───▶ │  ORDERS (FK→EMP)     │
└──────────────────────┘                 └──────────────────────┘
         │                                         ▲
         │         ┌──────────────────┐            │
         └────────▶│  TASK DAG        │────────────┘
                   │  (1-min schedule) │
                   │                   │
                   │  For each table:  │
                   │  1. Read stream   │
                   │  2. Call Nullafi  │
                   │  3. Insert row    │
                   └──────────────────┘
                            │
                            ▼
                   ┌──────────────────┐
                   │  Nullafi API     │
                   │  /api/scan-dyn.  │
                   │  (encrypts PII)  │
                   └──────────────────┘
```

---

## How It Works

| Component | Purpose |
|-----------|---------|
| **Secret** | Securely stores the Nullafi API key |
| **Network Rule** | Allows outbound HTTPS to your Nullafi host |
| **External Access Integration** | Grants the procedure permission to call the API |
| **Stored Procedure** | Generic Python procedure that reads rows, calls API, inserts encrypted data |
| **Streams** (one per table) | Append-only CDC -- detects new rows automatically |
| **Tasks** (one per table, DAG) | Fires when stream has data; chains respect FK order |

### Processing Order (FK-aware)

Foreign key constraints require careful ordering:

| Operation | Order |
|-----------|-------|
| Create target tables | Parent first, children last |
| Truncate (for backfill) | Children first, parents last |
| Insert (backfill) | Parents first, children last |
| Task DAG | Parents fire first, children chained via `AFTER` |
| Resume tasks | Children first, parents last (Snowflake requirement) |

---

## Folder Structure

```
nullafi-encryption-pipeline/
├── README.md                          ← You are here
├── users-argentina-example/           ← Working example (single table)
│   ├── scripts-by-step/
│   │   ├── 0_create_secret.sql
│   │   ├── 1_create_network_rule_and_integration.sql
│   │   ├── 2_create_stored_procedure.sql
│   │   ├── 3_run_backfill.sql
│   │   ├── 4_create_stream.sql
│   │   └── 5_create_and_resume_task.sql
│   └── single-script/
│       └── deploy_encryption_pipeline.sql
└── production-template/               ← Multi-table, multi-database template
    ├── scripts-by-step/
    │   ├── 0_create_secret.sql
    │   ├── 1_create_network_and_integration.sql
    │   ├── 2_create_target_database.sql
    │   ├── 3_create_stored_procedure.sql
    │   ├── 4_run_backfill.sql
    │   ├── 5_create_streams.sql
    │   ├── 6_create_tasks.sql
    │   └── 7_verify_pipeline.sql
    └── single-script/
        └── deploy_encryption_pipeline.sql
```

---

## Quick Start

### Prerequisites

1. **Nullafi API key** with Data Scanning permission
2. **Snowflake roles**: ACCOUNTADMIN (for integration), SYSADMIN (for objects)
3. **A warehouse** for task execution

### Steps

1. **Fill in placeholders** -- Search for `{{...}}` in the template files and replace with your values
2. **Run scripts 0-3** -- Creates infrastructure and the stored procedure
3. **Map your schema** -- In script 2, define your target tables with all PK/FK constraints
4. **Run script 4** -- Backfills all existing data through the API
5. **Run scripts 5-6** -- Creates streams and tasks for automatic sync
6. **Run script 7** -- Validates everything is working

---

## Placeholder Reference

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{SECRET_DATABASE}}` | Database for the API key secret | `ADMIN` |
| `{{SECRET_SCHEMA}}` | Schema for the secret | `SECURITY` |
| `{{SECRET_NAME}}` | Name of the secret | `NULLAFI_API_KEY` |
| `{{NULLAFI_API_KEY}}` | Your actual API key | `abc123...` |
| `{{NETWORK_RULE_DB}}` | Database for network rule | `ADMIN` |
| `{{NETWORK_RULE_SCHEMA}}` | Schema for network rule | `SECURITY` |
| `{{NETWORK_RULE_NAME}}` | Name of the network rule | `NULLAFI_EGRESS_RULE` |
| `{{NULLAFI_HOSTNAME}}` | API hostname | `api.nullafi.com` |
| `{{INTEGRATION_NAME}}` | External access integration name | `NULLAFI_API_ACCESS` |
| `{{PROCEDURE_DATABASE}}` | Database for the procedure | `ADMIN` |
| `{{PROCEDURE_SCHEMA}}` | Schema for the procedure | `PIPELINES` |
| `{{PROCEDURE_NAME}}` | Name of the procedure | `ENCRYPT_AND_INSERT` |
| `{{NULLAFI_NAMESPACE}}` | Namespace for Nullafi logging | `production_migration` |
| `{{DATA_TYPES}}` | Nullafi data type IDs | `CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS` |
| `{{MASK_FORMATS}}` | Mask format per type | `CYPHER,CYPHER,CYPHER,CYPHER` |
| `{{BATCH_SIZE}}` | Rows per API call | `50` |
| `{{SOURCE_DATABASE}}` | Source database | `PRODUCTION` |
| `{{SOURCE_SCHEMA}}` | Source schema | `PUBLIC` |
| `{{TARGET_DATABASE}}` | Target encrypted database | `PRODUCTION_ENCRYPTED` |
| `{{TARGET_SCHEMA}}` | Target schema | `PUBLIC` |
| `{{STREAM_DATABASE}}` | Database for streams | `ADMIN` |
| `{{STREAM_SCHEMA}}` | Schema for streams | `PIPELINES` |
| `{{TASK_DATABASE}}` | Database for tasks | `ADMIN` |
| `{{TASK_SCHEMA}}` | Schema for tasks | `PIPELINES` |
| `{{WAREHOUSE}}` | Task warehouse | `COMPUTE_WH` |
| `{{SCHEDULE}}` | Task frequency | `1 MINUTE` |

---

## Important Notes

### Streams Only Capture New Rows

Snowflake streams do NOT include existing data -- they only track changes from the moment they are created. This is why the backfill (step 4) must run BEFORE streams are created (step 5).

### Append-Only Streams

The template uses `APPEND_ONLY = TRUE` streams, which means only INSERTs are captured. If you need to handle UPDATEs and DELETEs, remove the `APPEND_ONLY` flag and modify the procedure to handle `METADATA$ACTION` values.

### SSL Certificates

If your Nullafi instance uses a self-signed certificate, the procedure includes `verify=False` in the requests call. For production with a valid CA-signed certificate, remove this parameter.

### Task DAG and Foreign Keys

Tasks are structured as a DAG (Directed Acyclic Graph) using the `AFTER` clause. Parent table tasks fire first, ensuring FK-referenced rows exist before child rows are inserted. If you don't have FK constraints, you can use independent tasks (each with their own `SCHEDULE`) for parallel processing.

### Scaling Considerations

- Rows are batched into a single API call (default: 50 rows per batch). Adjust `BATCH_SIZE` based on your API rate limits and payload size constraints.
- The task schedule (`1 MINUTE`) means at most a 1-minute delay. Adjust based on your latency requirements.
- For very large backfills (millions of rows), consider running the procedure in chunks using `LIMIT/OFFSET` on the source query.

---

## Discovering Your Schema

Use these queries to understand your source database structure:

```sql
-- List all tables
SHOW TABLES IN SCHEMA SOURCE_DB.SOURCE_SCHEMA;

-- List primary keys
SHOW PRIMARY KEYS IN SCHEMA SOURCE_DB.SOURCE_SCHEMA;

-- List foreign keys (imported keys = FK constraints)
SHOW IMPORTED KEYS IN SCHEMA SOURCE_DB.SOURCE_SCHEMA;

-- Get full DDL for a table
SELECT GET_DDL('TABLE', 'SOURCE_DB.SOURCE_SCHEMA.TABLE_NAME');
```

---

## Teardown

To remove the pipeline completely:

```sql
-- Suspend and drop tasks (leaf first)
ALTER TASK TASK_DB.TASK_SCHEMA.ENCRYPT_ORDERS_TASK SUSPEND;
DROP TASK TASK_DB.TASK_SCHEMA.ENCRYPT_ORDERS_TASK;
-- ... repeat for all tasks

-- Drop streams
DROP STREAM STREAM_DB.STREAM_SCHEMA.ORDERS_STREAM;
-- ... repeat for all streams

-- Drop procedure
DROP PROCEDURE PROC_DB.PROC_SCHEMA.PROC_NAME(VARCHAR, VARCHAR, VARCHAR, VARCHAR);

-- Drop integration and network rule
DROP INTEGRATION NULLAFI_API_ACCESS;
DROP NETWORK RULE NETWORK_RULE_DB.NETWORK_RULE_SCHEMA.RULE_NAME;

-- Drop secret
DROP SECRET SECRET_DB.SECRET_SCHEMA.SECRET_NAME;

-- Optionally drop the target database
DROP DATABASE TARGET_DATABASE;
```
