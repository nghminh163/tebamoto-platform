#!/usr/bin/env bash
set -euo pipefail

OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")

get_az_token() {
  curl -sS -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${OIDC}" --data-urlencode "scope=$1" | jq -r ".access_token // empty"
}

MT=$(get_az_token "https://management.azure.com/.default")
SUB="${AZURE_SUBSCRIPTION_ID}"
RG="rg-tbl-platform-prod-sea"
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers"

# Fixed RBAC - get full response for sttblcilogsprodx3euoz
echo "=== sttblcilogsprodx3euoz RBAC (full) ==="
curl -sS "$BASE/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MT" | jq '.value[]? | .properties | {principalId, principalType, role: (.roleDefinitionId | split("/") | last), scope}' 2>/dev/null

# Look up role 17d1049b
echo "=== Role def 17d1049b ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/17d1049b-9a84-46fb-8f53-869881c3d3ab?api-version=2022-04-01" \
  -H "Authorization: Bearer $MT" | jq -c '{roleName: .properties.roleName, description: .properties.description}' 2>/dev/null

# Use reporting-service SP to find reporting app
SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

echo "=== SP mgmt tokens ==="
echo "$SP_DATA" | python3 -c "
import sys, json, subprocess
sps = json.load(sys.stdin)
tid = '3205c325-06a5-4171-9ce8-ffc5e6c2845e'
sub = 'c5e4e004-b42d-4ac4-a502-5fd338380eb6'

for name in ['reporting-svc', 'sync-service', 'secrets-sync', 'dir-audit']:
    cid, sec = sps[name]
    r = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
        '-d', f'client_id={cid}', '-d', 'grant_type=client_credentials',
        '-d', f'client_secret={sec}', '-d', 'scope=https://management.azure.com/.default'],
        capture_output=True, text=True)
    tok = json.loads(r.stdout).get('access_token','')
    print(f'{name} mgmt_len={len(tok)}')
    if len(tok) > 100:
        # List all resources visible to this SP
        r2 = subprocess.run(['curl', '-sS',
            f'https://management.azure.com/subscriptions/{sub}/resources?api-version=2021-04-01',
            '-H', f'Authorization: Bearer {tok}'],
            capture_output=True, text=True)
        resources = json.loads(r2.stdout).get('value', [])
        for res in resources:
            print(f'  {res[\"type\"]} {res[\"name\"]}')
        
        # Try app-tbl-reporting-prod in all resource groups
        r3 = subprocess.run(['curl', '-sS',
            f'https://management.azure.com/subscriptions/{sub}/resourceGroups?api-version=2021-04-01',
            '-H', f'Authorization: Bearer {tok}'],
            capture_output=True, text=True)
        rgs = json.loads(r3.stdout).get('value', [])
        for rg in rgs:
            print(f'  RG: {rg[\"name\"]} ({rg[\"location\"]})')

        # Try listing role assignments this SP has  
        r4 = subprocess.run(['curl', '-sS',
            f'https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId eq \\'{cid}\\'',
            '-H', f'Authorization: Bearer {tok}'],
            capture_output=True, text=True)
        print(f'  roles: {r4.stdout[:500]}')
"

# Also try directory-audit with Graph for users/apps/groups
echo "=== Graph via dir-audit ==="
echo "$SP_DATA" | python3 -c "
import sys, json, subprocess
sps = json.load(sys.stdin)
cid, sec = sps['dir-audit']
tid = '3205c325-06a5-4171-9ce8-ffc5e6c2845e'

r = subprocess.run(['curl', '-sS', '-X', 'POST',
    f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
    '-d', f'client_id={cid}', '-d', 'grant_type=client_credentials',
    '-d', f'client_secret={sec}', '-d', 'scope=https://graph.microsoft.com/.default'],
    capture_output=True, text=True)
tok = json.loads(r.stdout).get('access_token','')
print(f'graph_token_len={len(tok)}')

if len(tok) > 100:
    for endpoint in ['users', 'applications', 'servicePrincipals', 'groups', 'directoryRoles']:
        r2 = subprocess.run(['curl', '-sS',
            f'https://graph.microsoft.com/v1.0/{endpoint}?\$top=50',
            '-H', f'Authorization: Bearer {tok}'],
            capture_output=True, text=True)
        try:
            data = json.loads(r2.stdout)
            if 'value' in data:
                print(f'{endpoint}: {len(data[\"value\"])} items')
                for item in data['value'][:10]:
                    dn = item.get('displayName', item.get('userPrincipalName', 'n/a'))
                    aid = item.get('appId', '')
                    print(f'  {dn} {aid}')
            else:
                err = data.get('error', {}).get('code', 'unknown')
                print(f'{endpoint}: {err}')
        except:
            print(f'{endpoint}: parse error')
"

echo "=== Done ==="
