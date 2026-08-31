-- Step 2: Create a vectorized Python UDF that processes rows in batches.
-- Snowflake sends rows as pandas DataFrames (batch size controlled by the engine,
-- typically 1,000-5,000 rows). Each batch = one API call to Nullafi.
-- Much more efficient than per-row for large result sets.
-- Requires: NULLAFI_API_KEY_SECRET, NULLAFI_API_ACCESS (from stream-pipeline setup).

CREATE OR REPLACE FUNCTION POS.PUBLIC.NULLAFI_ENCRYPT_ROW_BATCHED(ROW_JSON VARIANT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests', 'pandas')
HANDLER = 'encrypt_batch'
EXTERNAL_ACCESS_INTEGRATIONS = (NULLAFI_API_ACCESS)
SECRETS = ('nullafi_key' = POS.PUBLIC.NULLAFI_API_KEY_SECRET)
AS
$$
import _snowflake
import requests
import json
import pandas as pd
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

API_URL = "https://test2.broknus.com/api/scan-dynamic"
PARAMS = {
    "namespace": "snowflake_view_batch",
    "obfuscatedDataTypes": "CREDIT_CARD,US_SSN,IBAN,EMAIL_ADDRESS",
    "maskFormats": "CYPHER,CYPHER,CYPHER,CYPHER",
    "storeOriginalValues": "true"
}

# Internal batch size for API calls within a single Snowflake-provided partition.
# Even though Snowflake may send thousands of rows, we chunk API calls to avoid
# exceeding payload limits or timeouts.
API_BATCH_SIZE = 100


def encrypt_batch(df: pd.DataFrame) -> pd.Series:
    """Vectorized UDF handler. Receives a DataFrame of VARIANT column, returns Series of VARIANT."""
    api_key = _snowflake.get_generic_secret_string('nullafi_key')
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    # Each element in the input Series is a dict (from VARIANT)
    input_rows = df.iloc[:, 0]  # single VARIANT column
    results = []

    # Collect all row dicts
    all_rows = []
    for row_json in input_rows:
        if row_json is None:
            all_rows.append({})
        else:
            row_data = {k: str(v) if v is not None else None for k, v in row_json.items()}
            all_rows.append(row_data)

    # Process in sub-batches to respect API payload limits
    encrypted_all = [None] * len(all_rows)
    for batch_start in range(0, len(all_rows), API_BATCH_SIZE):
        batch = all_rows[batch_start:batch_start + API_BATCH_SIZE]
        try:
            response = requests.post(
                API_URL,
                headers=headers,
                params=PARAMS,
                json=batch,
                timeout=120,
                verify=False
            )
            response.raise_for_status()
            encrypted_batch = response.json()
            for i, encrypted_row in enumerate(encrypted_batch):
                encrypted_all[batch_start + i] = encrypted_row
        except Exception as e:
            # On error, return original rows with error marker
            for i, row in enumerate(batch):
                row["_NULLAFI_ERROR"] = str(e)
                encrypted_all[batch_start + i] = row

    return pd.Series(encrypted_all)


# Register as vectorized
encrypt_batch._sf_vectorized_input = pd.DataFrame
$$;
