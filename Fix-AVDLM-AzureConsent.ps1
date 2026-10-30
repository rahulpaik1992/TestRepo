[CmdletBinding()]
param(
    [string]$VmIp = "20.198.74.107",
    [string]$VmUser = "azureuser",
    [string]$KeyPath = "$HOME\.ssh\avdlm-dev-01-key-v2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "Replacement SSH key not found: $KeyPath"
}

$Remote = @'
set -Eeuo pipefail

ROOT="$HOME/avdlm-saas-platform"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/tmp/azure-consent-fix-$STAMP"

cd "$ROOT"
mkdir -p "$BACKUP"
cp apps/api/src/azure-connect.ts "$BACKUP/azure-connect.ts"
cp apps/api/src/server.ts "$BACKUP/server.ts"

echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path

path = Path("apps/api/src/azure-connect.ts")
text = path.read_text(encoding="utf-8")

start = text.find('consentUrl.searchParams.set(\n        "scope",')
if start == -1:
    start = text.find('consentUrl.searchParams.set(\n      "scope",')
if start == -1:
    raise SystemExit("Could not locate the consent scope block")

end = text.find('\n      );', start)
if end == -1:
    end = text.find('\n    );', start)
if end == -1:
    raise SystemExit("Could not locate the end of the consent scope block")

end = text.find(');', end) + 2
replacement = '''consentUrl.searchParams.set(
        "scope",
        "https://management.azure.com/.default",
      );'''

text = text[:start] + replacement + text[end:]
path.write_text(text, encoding="utf-8")
print("Azure admin-consent scope corrected")
PY

echo "===== VERIFY SOURCE ====="
grep -n -A4 -B2 'management.azure.com/.default' apps/api/src/azure-connect.ts

if grep -q 'management.azure.com/user_impersonation' apps/api/src/azure-connect.ts; then
    echo "ERROR: Invalid mixed scope remains. Restoring backup."
    cp "$BACKUP/azure-connect.ts" apps/api/src/azure-connect.ts
    exit 1
fi

echo "===== COMPILE API ====="
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$ROOT/apps/api:/workspace" \
    -w /workspace \
    node:22-alpine \
    npm run build

git diff --check

echo "===== REBUILD API ====="
docker compose build api
docker compose up -d --force-recreate api
sleep 12

echo "===== HEALTH CHECK ====="
docker compose ps
curl -fsS --max-time 20 http://127.0.0.1:8080/health
echo

STATUS="$(curl -sS -o /tmp/auth-check.json -w '%{http_code}' --max-time 20 http://127.0.0.1:8080/api/v1/me)"
echo "Unauthenticated protected API status: HTTP $STATUS"
if [ "$STATUS" != "401" ]; then
    cat /tmp/auth-check.json
    exit 1
fi

echo "SUCCESS: Azure consent request corrected"
echo "Backup: $BACKUP"
'@

Write-Host "Applying Azure consent fix to $VmUser@$VmIp..." -ForegroundColor Cyan
$Remote | ssh.exe -T `
    -o ConnectTimeout=20 `
    -o ServerAliveInterval=30 `
    -o ServerAliveCountMax=6 `
    -o StrictHostKeyChecking=accept-new `
    -i $KeyPath `
    "$VmUser@$VmIp" `
    "tr -d '\r' | bash -s"

if ($LASTEXITCODE -ne 0) {
    throw "Azure consent fix failed with exit code $LASTEXITCODE"
}

Write-Host "Azure consent fix completed successfully." -ForegroundColor Green
Write-Host "Close the old Microsoft error tab, refresh the portal, and select Connect Azure again."
