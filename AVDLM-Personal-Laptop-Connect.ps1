[CmdletBinding()]
param(
    [string]$VmIp = "20.198.74.107",
    [string]$VmUser = "azureuser",
    [string]$KeyPath = "$HOME\.ssh\avdlm-dev-01-key-v2",
    [string]$PortalUrl = "http://localhost:4173/#/integrations/azure",
    [switch]$StopExistingTunnel,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Stop-WithError([string]$Text) {
    Write-Host "`nERROR: $Text" -ForegroundColor Red
    exit 1
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Test-ListeningPort([int]$Port) {
    return $null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

Write-Host "AVD Lifecycle Manager - Personal Laptop Connector" -ForegroundColor Green
Write-Host "VM: $VmUser@$VmIp"
Write-Host "Portal: $PortalUrl"

Write-Step "Checking OpenSSH"
$sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshCommand) {
    Stop-WithError "OpenSSH Client is not installed. Install OpenSSH Client from Windows Settings > System > Optional features."
}
$sshVersion = Invoke-Native -FilePath $sshCommand.Source -Arguments @("-V")
Write-Host ($sshVersion.Output -join "`n")
if ($sshVersion.ExitCode -ne 0) {
    Stop-WithError "ssh.exe exists but returned exit code $($sshVersion.ExitCode)."
}

Write-Step "Checking SSH private key"
if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    Write-Host "Expected replacement key: $KeyPath" -ForegroundColor Yellow
    Write-Host "The old avdlm-dev-01-key.pem was exposed in Git and must not be used." -ForegroundColor Yellow
    Stop-WithError "Replacement SSH private key not found. Rotate the VM key first, then copy the new private key to the expected path."
}

try {
    & icacls.exe $KeyPath /inheritance:r | Out-Null
    & icacls.exe $KeyPath /grant:r "$($env:USERNAME):(R)" | Out-Null
}
catch {
    Write-Warning "The key ACL could not be changed automatically: $($_.Exception.Message)"
}
Write-Host "Replacement SSH key found: $KeyPath"

if ($StopExistingTunnel) {
    Write-Step "Stopping stale AVDLM SSH tunnels"
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -match [regex]::Escape($VmIp) -and
            $_.CommandLine -match "4173:127\.0\.0\.1:4173"
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped SSH process $($_.ProcessId)"
        }
    Start-Sleep -Seconds 1
}

Write-Step "Testing SSH access"
$testArguments = @(
    "-o", "ConnectTimeout=20",
    "-o", "ConnectionAttempts=1",
    "-o", "StrictHostKeyChecking=accept-new",
    "-i", $KeyPath,
    "$VmUser@$VmIp",
    "hostname"
)
$test = Invoke-Native -FilePath $sshCommand.Source -Arguments $testArguments
Write-Host ($test.Output -join "`n")
if ($test.ExitCode -ne 0) {
    Stop-WithError "SSH failed. Verify that the Azure VM is running, the public IP is $VmIp, TCP 22 allows this laptop's public IP, and the replacement key is installed for user $VmUser."
}
if (($test.Output -join " ") -notmatch "avdlm-dev-01") {
    Stop-WithError "SSH connected but the expected VM hostname was not returned."
}

Write-Step "Starting and validating services on the Linux VM"
$remoteCommand = "cd ~/avdlm-saas-platform && docker compose up -d && sleep 5 && docker compose ps && curl -fsS --max-time 20 http://127.0.0.1:8080/health"
$remoteArguments = @(
    "-o", "ConnectTimeout=20",
    "-o", "StrictHostKeyChecking=accept-new",
    "-i", $KeyPath,
    "$VmUser@$VmIp",
    $remoteCommand
)
$remote = Invoke-Native -FilePath $sshCommand.Source -Arguments $remoteArguments
Write-Host ($remote.Output -join "`n")
if ($remote.ExitCode -ne 0 -or ($remote.Output -join " ") -notmatch '"status":"ok"') {
    Stop-WithError "The VM is reachable, but the API did not become healthy."
}

if ((Test-ListeningPort 4173) -or (Test-ListeningPort 8080)) {
    if (-not ((Test-ListeningPort 4173) -and (Test-ListeningPort 8080))) {
        Stop-WithError "Only one local tunnel port is in use. Rerun with -StopExistingTunnel."
    }

    Write-Step "Existing local tunnel detected"
    try {
        $existingHealth = Invoke-RestMethod -Uri "http://localhost:8080/health" -TimeoutSec 5
        $existingWeb = Invoke-WebRequest -Uri "http://localhost:4173" -TimeoutSec 5
        if ($existingHealth.status -ne "ok" -or $existingWeb.StatusCode -ne 200) {
            Stop-WithError "Ports 4173 and 8080 are in use but are not a healthy AVDLM tunnel. Rerun with -StopExistingTunnel."
        }
        Write-Host "Existing tunnel is healthy."
    }
    catch {
        Stop-WithError "Ports 4173 and 8080 are occupied but health checks failed. Rerun with -StopExistingTunnel."
    }
}
else {
    Write-Step "Starting SSH tunnel"
    $tunnelArguments = @(
        "-N",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=6",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-i", $KeyPath,
        "-L", "4173:127.0.0.1:4173",
        "-L", "8080:127.0.0.1:8080",
        "$VmUser@$VmIp"
    )
    $tunnel = Start-Process -FilePath $sshCommand.Source -ArgumentList $tunnelArguments -PassThru
    Start-Sleep -Seconds 3
    if ($tunnel.HasExited) {
        Stop-WithError "The SSH tunnel exited immediately. Rerun with -StopExistingTunnel and check local port usage."
    }
    Write-Host "Tunnel process started: PID $($tunnel.Id)"
}

Write-Step "Validating the portal through the tunnel"
$healthy = $false
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:8080/health" -TimeoutSec 5
        $web = Invoke-WebRequest -Uri "http://localhost:4173" -TimeoutSec 5
        if ($health.status -eq "ok" -and $web.StatusCode -eq 200) {
            $healthy = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $healthy) {
    Stop-WithError "The tunnel started, but the API or portal did not pass health checks."
}

Write-Host "API status: $($health.status), version: $($health.version)" -ForegroundColor Green
Write-Host "Portal HTTP status: $($web.StatusCode)" -ForegroundColor Green

if (-not $NoBrowser) {
    Start-Process $PortalUrl
}

Write-Host "`nREADY" -ForegroundColor Green
Write-Host "Portal: $PortalUrl"
Write-Host "API health: http://localhost:8080/health"
Write-Host "Use a Microsoft Entra work or school account associated with the personal Azure tenant."
Write-Host "Keep the SSH tunnel process running while using the portal."
