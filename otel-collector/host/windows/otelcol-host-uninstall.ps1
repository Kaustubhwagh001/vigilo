# ------------------------------------------------------------
# vigilo — OTel Collector host agent (Windows) — uninstall
# Purpose: back up the running config, stop the service, and remove the
#          files installed by otelcol-host-install.ps1.
# Requires env: (none)
# Optional env: INSTALL_DIR, BACKUP_DIR
# Usage: Run from an elevated PowerShell prompt:
#          .\otelcol-host-uninstall.ps1
# ------------------------------------------------------------

$ErrorActionPreference = "Stop"

$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { "C:\observability-agent" }
$BackupDir = if ($env:BACKUP_DIR) { $env:BACKUP_DIR } else { "C:\observability-agent-backup" }
$ServiceName = "ObservabilityCollector"

$configPath = Join-Path $InstallDir "config.yaml"
if (Test-Path $configPath) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $backupPath = Join-Path $BackupDir "config.yaml.$stamp"
    Copy-Item $configPath $backupPath
    Write-Host "Backed up running config to $backupPath"
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Write-Host "Removed service $ServiceName"
}

if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host "otelcol-contrib removed. Config backup (if any) is in $BackupDir"
