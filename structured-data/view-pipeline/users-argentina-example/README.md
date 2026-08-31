# Nullafi Encryption View (On-the-fly PII Masking)

A Snowflake view that encrypts PII via the Nullafi Shield API **at query time** using a vectorized Python UDF — no table migration needed.

## Prerequisites

This view reuses the infrastructure from the stream-pipeline example:
- Secret: `POS.PUBLIC.NULLAFI_API_KEY_SECRET`
- Network rule + External access integration: `NULLAFI_API_ACCESS`

If not already created, run steps 0 and 1 from `../stream-pipeline/users-argentina-example/scripts-by-step/`.

## How It Works

- **UDF:** `NULLAFI_ENCRYPT_ROW_BATCHED(VARIANT)` — vectorized Python UDF
- **Behavior:** Snowflake sends rows in engine-determined batches (typically 1,000–5,000). Within each batch, the UDF sub-batches API calls at 100 rows. Result: far fewer HTTP calls than one-per-row.
- **Deploy:** Run `0_create_vectorized_udf.sql` then `1_create_batched_view.sql`

## Usage

```sql
SELECT * FROM POS.PUBLIC.USERS_ARGENTINA_ENCRYPTED_BATCHED LIMIT 100;
```

## Limitations

| Concern | Detail |
|---------|--------|
| No caching | Every SELECT re-calls the API. Repeated queries multiply cost and latency. |
| Batch size is engine-controlled | You cannot force all rows into one API call. The vectorized UDF reduces calls but doesn't eliminate the issue. |
| Timeout risk | Large result sets (10k+ rows) may hit UDF or API timeouts. Use WHERE/LIMIT. |
| Non-determinism | Snowflake may retry partitions on transient failures, potentially creating duplicate tokens. |
| Cost | API calls on every query. For high-frequency access, prefer the stream-pipeline (materialize once). |

## When to Use Views vs. Stream Pipeline

| Scenario | Recommendation |
|----------|----------------|
| Ad-hoc queries, dev/test | View (this approach) |
| Dashboard / repeated access | Stream pipeline (materialize to table) |
| Regulatory audit (stable tokens) | Stream pipeline |
| Real-time encryption of live inserts | Stream pipeline with task |
