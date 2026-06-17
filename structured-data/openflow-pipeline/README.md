# Nullafi Encryption Pipeline - Openflow Approach

Automated data encryption pipeline using Snowflake Openflow (managed NiFi) to read from source tables, encrypt sensitive fields via the Nullafi API, and write to target tables.

---

## How This Differs from the Stream Pipeline

| Aspect | Stream Pipeline | Openflow Pipeline |
|--------|----------------|-------------------|
| **Trigger** | Task polls every 1 min | Continuous polling (configurable, can be seconds) |
| **Latency** | ~1 minute minimum | Near real-time (seconds) |
| **Parallelism** | Single-threaded procedure | Multi-threaded, configurable concurrent tasks |
| **Error handling** | Try/catch in Python code | Built-in retry, back-pressure, dead-letter routing |
| **Observability** | Task history logs | Full NiFi UI: provenance, queue depths, throughput graphs |
| **Deployment** | Run SQL scripts | Import flow JSON + configure parameters |
| **Cost model** | Warehouse runs only when stream has data | Openflow runtime runs continuously |
| **Reproducibility** | 100% scriptable (SQL) | Flow JSON + SQL setup + UI import |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OPENFLOW RUNTIME                              │
│                                                                     │
│  ┌──────────────────┐     ┌──────────────┐     ┌────────────────┐  │
│  │ Consume Snowflake │────▶│ Merge Records│────▶│  InvokeHTTP    │  │
│  │ Stream            │     │ (batch=100)  │     │  (Nullafi API) │  │
│  └──────────────────┘     └──────────────┘     └───────┬────────┘  │
│                                                         │           │
│                                                         ▼           │
│                                                ┌────────────────┐   │
│                                                │ PutSnowpipe    │   │
│                                                │ Streaming      │   │
│                                                │ (target table) │   │
│                                                └────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │                        │                        │
         ▼                        ▼                        ▼
  SOURCE TABLE              NULLAFI API            TARGET TABLE
  (Snowflake)          (test2.broknus.com)        (Snowflake)
```

### Flow Processors

| # | Processor | Purpose |
|---|-----------|---------|
| 1 | **ConsumeSnowflakeStream** | Polls a Snowflake stream for new rows, emits them as JSON FlowFiles |
| 2 | **MergeRecord** | Batches records together (up to 100 per batch) for efficient API calls |
| 3 | **InvokeHTTP** | Sends the batch to Nullafi `/api/scan-dynamic` with configured data types and mask formats |
| 4 | **PutSnowpipeStreaming** | Writes encrypted records to the target table via Snowpipe Streaming |
| 5 | **LogAttribute** | Logs any failures for debugging |

### Built-in Resilience

- **Back-pressure**: If the API is slow, queues fill up and upstream processors slow down automatically
- **Retry loop**: HTTP 429/5xx responses route back to InvokeHTTP with exponential backoff
- **Dead-letter**: Permanent failures (4xx) route to LogAttribute for investigation
- **Exactly-once delivery**: Snowpipe Streaming provides deduplication guarantees

---

## Folder Structure

```
openflow-pipeline/
├── README.md                          ← You are here
├── flow-definition/
│   └── nullafi_encryption_flow.json   ← NiFi flow definition (import into Openflow)
└── snowflake-setup/
    └── setup_snowflake_objects.sql    ← SQL to run BEFORE importing the flow
```

---

## Setup Instructions

### Prerequisites

1. An Openflow runtime (Snowflake Deployment or BYOC)
2. Nullafi API key with Data Scanning permission
3. Snowflake ACCOUNTADMIN role (for initial setup)

### Step 1: Run the Snowflake Setup SQL

Execute `snowflake-setup/setup_snowflake_objects.sql` after replacing placeholders. This creates:
- Service user and role for Openflow
- Warehouse
- Target database/schema/tables
- Grants for read (source) and write (target) access
- Network access for the Nullafi hostname

### Step 2: Import the Flow Definition

**Option A: Direct Import (simplest)**
1. Open the Openflow canvas for your runtime
2. Drag the "Import" icon from the top toolbar onto the canvas
3. Upload `flow-definition/nullafi_encryption_flow.json`
4. The flow appears as a Process Group

**Option B: Via GitHub Registry (recommended for teams)**
1. Push the `flow-definition/` folder to a Git repository
2. In Openflow, configure a GitHub Registry Client (Controller Settings > Registry Clients)
3. Import the flow from the registry
4. Benefit: version control, pull requests, Flow Diff for reviewing changes

### Step 3: Configure Parameters

After import, right-click the Process Group and select "Parameters". Fill in:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `source_database` | Source database | `POS` |
| `source_schema` | Source schema | `PUBLIC` |
| `source_stream_name` | Stream to consume | `USERS_ARGENTINA_STREAM` |
| `target_database` | Encrypted target database | `POS_ENCRYPTED` |
| `target_schema` | Target schema | `PUBLIC` |
| `target_table` | Target table name | `USERS_ARGENTINA_ENCRYPTED` |
| `nullafi_hostname` | Nullafi API host | `test2.broknus.com` |
| `nullafi_api_key` | API key (sensitive) | `8o5zUI...` |
| `data_types` | Data types to detect | `CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS` |
| `mask_formats` | Mask format per type | `CYPHER,CYPHER,CYPHER,CYPHER` |
| `batch_size` | Records per API call | `100` |
| `polling_interval` | Stream poll frequency | `30 sec` |
| `concurrent_api_calls` | Parallel API threads | `2` |

### Step 4: Configure Network Access

**For Snowflake Deployments:**
- Go to Runtime Settings > Network > Allowed Domains
- Add your Nullafi hostname (e.g., `test2.broknus.com`)

**For BYOC:**
- Outbound internet is available by default

### Step 5: Start the Flow

1. Right-click the canvas > "Enable all Controller Services"
2. Right-click the Process Group > "Start"
3. Monitor throughput in the NiFi UI

---

## Multi-Table Setup

For multiple tables, you have two options:

**Option A: One Process Group per table**
- Duplicate the flow for each table
- Change the stream name and target table parameters per group
- Simple, isolated, easy to monitor per-table

**Option B: Single parameterized flow with dynamic routing**
- Use `ListDatabaseTables` to discover tables dynamically
- Route FlowFiles by table name using `RouteOnAttribute`
- More complex but handles schema changes automatically

For FK-ordered processing across tables, use NiFi's **Process Group priorities** or chain groups with `Wait`/`Notify` processors to ensure parents are processed before children.

---

## Parameters Reference

All configurable values are stored in the Parameter Context (`nullafi-pipeline-params`), making it easy to:
- Change environments (dev/staging/prod) by swapping Parameter Contexts
- Store sensitive values (API keys, private keys) securely
- Integrate with external secrets managers (AWS Secrets Manager, HashiCorp Vault)

---

## Scaling

| Knob | Effect |
|------|--------|
| `batch_size` | Rows per API call. Higher = fewer HTTP calls but larger payloads |
| `concurrent_api_calls` | Parallel InvokeHTTP threads. Higher = more throughput but more API load |
| `polling_interval` | How often to check for new data. Lower = less latency but more compute |
| Runtime size (Medium/Large) | More CPU/memory for the Openflow runtime |
| Back-pressure thresholds | Control queue sizes before slowing down upstream |

---

## When to Choose This Over Stream Pipeline

Choose Openflow when:
- You need **sub-minute latency** (seconds, not minutes)
- You have **many tables** and want a visual overview of all pipelines
- You need **sophisticated error handling** (retry policies, dead-letter queues, alerting)
- Your team already uses Openflow for other integrations
- You want **built-in observability** (data provenance, throughput graphs)

Choose Stream Pipeline when:
- You want **everything as code** (SQL scripts, git-friendly)
- **Cost matters** — only pay for compute when there's data to process
- The 1-minute latency is acceptable
- You want a **simpler operational model** (no always-on runtime)
- You need a **fully reproducible template** that anyone can deploy with placeholders

---

## Limitations

1. **Flow JSON is a starting point** — The JSON file in this template represents the logical flow structure. When imported, you may need to adjust processor-specific settings (e.g., exact controller service references) in the UI.

2. **Backfill requires separate handling** — Openflow streams are incremental. For initial backfill of existing data, either:
   - Temporarily modify the flow to read from the full table instead of the stream
   - Use the stream-pipeline's backfill procedure for the initial load, then switch to Openflow for ongoing sync

3. **Always-on cost** — The Openflow runtime runs continuously. For low-volume, infrequent data, the stream pipeline's event-driven model may be more cost-effective.
