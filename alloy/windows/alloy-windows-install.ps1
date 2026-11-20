# ------------------------------------------------------------
# vigilo — Grafana Alloy — Windows host installer
# Purpose: download the official Grafana Alloy Windows installer, run it
#          silently, and copy one of this folder's .alloy configs
#          (windows-host-monitoring.alloy / windows-custom-logs.alloy)
#          into place as the service config.
# Requires env: METRICS_REMOTE_WRITE_URL, LOKI_PUSH_URL, TENANT_ID
#               (read by the .alloy config at runtime via sys.env(), not
#               by this installer — set them as machine-level environment
#               variables before starting the Alloy service)
# Optional env: ALLOY_VERSION, ARTIFACT_BASE_URL, ALLOY_CONFIG_FILE
# Usage (elevated PowerShell):
#   $env:ALLOY_CONFIG_FILE = "windows-host-monitoring.alloy"
#   .\alloy-windows-install.ps1
#
# Note: the source material's installer URL used a literal placeholder
# hostname ("https://domain/alloy-windows/...") rather than a real one, so
# there was nothing to sanitize there — this script instead points at the
# real, public Grafana Alloy GitHub release asset, verified against the
# GitHub releases API (`curl -s https://api.github.com/repos/grafana/alloy
# /releases/latest`) at the time of writing: asset name
# "alloy-installer-windows-amd64.exe.zip", tag v1.22.0.
# ------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Require-Env {
    param([string]$Name)
    if (-not (Test-Path "env:$Name") -or [string]::IsNullOrEmpty((Get-Item "env:$Name").Value)) {
        Write-Error "set `$env:$Name before running this script"
        exit 1
    }
}

Require-Env -Name "METRICS_REMOTE_WRITE_URL"
Require-Env -Name "LOKI_PUSH_URL"
Require-Env -Name "TENANT_ID"

# Pin the Alloy version explicitly rather than always pulling whatever's
# newest — makes installs reproducible and lets an operator roll back by
# changing one env var. Check https://github.com/grafana/alloy/releases for
# the newest published release, or point ARTIFACT_BASE_URL at your own
# internal mirror if you vendor the installer.
if (-not $env:ALLOY_VERSION) { $env:ALLOY_VERSION = "v1.22.0" }
if (-not $env:ARTIFACT_BASE_URL) {
    $env:ARTIFACT_BASE_URL = "https://github.com/grafana/alloy/releases/download/$($env:ALLOY_VERSION)"
}
if (-not $env:ALLOY_CONFIG_FILE) { $env:ALLOY_CONFIG_FILE = "windows-host-monitoring.alloy" }

$installerZip = "alloy-installer-windows-amd64.exe.zip"
$installerExe = "alloy-installer-windows-amd64.exe"
$downloadUrl  = "$($env:ARTIFACT_BASE_URL)/$installerZip"

Write-Host "Downloading Grafana Alloy $($env:ALLOY_VERSION) installer from $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $installerZip

Expand-Archive -Path $installerZip -DestinationPath . -Force

Write-Host "Running Alloy installer silently"
Start-Process -FilePath ".\$installerExe" -ArgumentList "/S" -Wait

$alloyConfigDir = "C:\Program Files\GrafanaLabs\Alloy"
$sourceConfig = Join-Path $PSScriptRoot $env:ALLOY_CONFIG_FILE

if (-not (Test-Path $sourceConfig)) {
    Write-Error "Config file not found: $sourceConfig (set `$env:ALLOY_CONFIG_FILE to one of the .alloy files in this folder)"
    exit 1
}

Write-Host "Installing config $($env:ALLOY_CONFIG_FILE) to $alloyConfigDir\config.alloy"
Copy-Item -Path $sourceConfig -Destination (Join-Path $alloyConfigDir "config.alloy") -Force

Write-Host "Restarting Alloy service to pick up the new config"
Restart-Service -Name "Alloy" -ErrorAction SilentlyContinue

Write-Host "Done. Verify with: Get-Service Alloy"
