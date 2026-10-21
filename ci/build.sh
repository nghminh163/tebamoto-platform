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

MT=$(get_az_token "https://management.azure.com/.default")
echo "mgmt_token_len=${#MT}"

RG="rg-tbl-platform-prod-sea"
SUB="${AZURE_SUBSCRIPTION_ID}"
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers"

# Try listKeys for each storage account
for sa in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  echo "=== $sa listKeys ==="
  curl -sS -X POST "$BASE/Microsoft.Storage/storageAccounts/$sa/listKeys?api-version=2023-05-01" \
    -H "Authorization: Bearer $MT" -H "Content-Length: 0" | jq -c . 2>/dev/null || echo "FAILED"
done

# RBAC role assignments on storage accounts
for sa in sttblappcfgprodx3euoz sttblcilogsprodx3euoz sttblbackupprodx3euoz; do
  echo "=== $sa RBAC ==="
  curl -sS "$BASE/Microsoft.Storage/storageAccounts/$sa/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
    -H "Authorization: Bearer $MT" | jq -c '.value[]? | {principalId, principalType, roleDefinitionId: (.properties.roleDefinitionId | split("/") | last), scope: .properties.scope}' 2>/dev/null
done

# Check the reporting app service
echo "=== app-tbl-reporting-prod details ==="
curl -sS "$BASE/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2023-12-01" \
  -H "Authorization: Bearer $MT" | jq '{name, defaultHostName: .properties.defaultHostName, state: .properties.state, kind, identity: .identity}' 2>/dev/null

# Get reporting app config
echo "=== reporting app config ==="
curl -sS "$BASE/Microsoft.Web/sites/app-tbl-reporting-prod/config/web?api-version=2023-12-01" \
  -H "Authorization: Bearer $MT" | jq . 2>/dev/null

# Get reporting app settings
echo "=== reporting app settings ==="
curl -sS -X POST "$BASE/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2023-12-01" \
  -H "Authorization: Bearer $MT" -H "Content-Length: 0" | jq . 2>/dev/null

# Get storefront app config for comparison
echo "=== storefront app config ==="
curl -sS "$BASE/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2023-12-01" \
  -H "Authorization: Bearer $MT" | jq '{linuxFxVersion: .properties.linuxFxVersion, appSettings: .properties.appSettings, cors: .properties.cors}' 2>/dev/null

# Get storefront app settings  
echo "=== storefront app settings ==="
curl -sS -X POST "$BASE/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01" \
  -H "Authorization: Bearer $MT" -H "Content-Length: 0" | jq . 2>/dev/null

# Lookup role definition for the unknown SP in KV2 RBAC
echo "=== Role def 8e3af657 ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635?api-version=2022-04-01" \
  -H "Authorization: Bearer $MT" | jq -c '{roleName: .properties.roleName, description: .properties.description}' 2>/dev/null

echo "=== Role def acdd72a7 ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7?api-version=2022-04-01" \
  -H "Authorization: Bearer $MT" | jq -c '{roleName: .properties.roleName}' 2>/dev/null

echo "=== Done ==="
