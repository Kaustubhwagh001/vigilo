# ------------------------------------------------------------
# vigilo — OTel Collector host agent (Windows)
# Purpose: download the official otelcol-contrib release archive, render
#          a hostmetrics + Windows Event Log config from env vars, and
#          register it as a Windows service (via sc.exe), exporting OTLP
#          to a central backend. This is the host-level tier — a
#          different deployment from otel-collector/agent/, which is a
#          per-application collector run as a Kubernetes
#          Deployment/DaemonSet.
# Requires env: OTLP_BACKEND_ENDPOINT
# Optional env: COLLECTOR_VERSION, TENANT_ID, DEPLOYMENT_ENVIRONMENT,
#               SERVICE_NAME, RESOURCE_DETECTORS, PROCESS_NAME_FILTER,
#               EVENTLOG_CHANNELS, INSTALL_DIR
# Usage: Run from an elevated PowerShell prompt:
#          .\otelcol-host-install.ps1
# ------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Require-EnvVar($name, $example) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrEmpty($value)) {
        throw "set `$env:$name, e.g. $example"
    }
    return $value
}

$OtlpBackendEndpoint = Require-EnvVar "OTLP_BACKEND_ENDPOINT" "otel-gateway.example.internal:4317"

# Pin the collector version explicitly — see otel-collector/host/linux's
# install script for why v0.138.0 is the default here too (verified via
# the GitHub releases API against the real asset name below).
$CollectorVersion = if ($env:COLLECTOR_VERSION) { $env:COLLECTOR_VERSION } else { "0.138.0" }

# tenant.id / deployment.environment / service.name resource attributes —
# TENANT_ID is shared with grafana-agent/linux's X-Scope-OrgID convention
# (see root .env.example).
$TenantId = if ($env:TENANT_ID) { $env:TENANT_ID } else { "default" }
$DeploymentEnvironment = if ($env:DEPLOYMENT_ENVIRONMENT) { $env:DEPLOYMENT_ENVIRONMENT } else { "prod" }
$ServiceNameAttr = if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { "windows-host" }

# resourcedetection detectors — "env,system" always; append "azure" on
# Azure VMs, "ec2" on EC2, etc.
$ResourceDetectors = if ($env:RESOURCE_DETECTORS) { $env:RESOURCE_DETECTORS } else { "env,system" }

# Comma-separated regexes for the hostmetrics `process` scraper's include list.
$ProcessNameFilter = if ($env:PROCESS_NAME_FILTER) { $env:PROCESS_NAME_FILTER } else { "node.*,otelcol.*,svchost.*,explorer.*" }

# Windows Event Log channels to collect via the windowseventlog receiver.
$EventLogChannels = if ($env:EVENTLOG_CHANNELS) { $env:EVENTLOG_CHANNELS } else { "Application,System" }

$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { "C:\observability-agent" }

$Package = "otelcol-contrib_${CollectorVersion}_windows_amd64.tar.gz"
$DownloadUrl = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${CollectorVersion}/${Package}"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

Write-Host "Downloading $DownloadUrl"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $Package
tar -xvzf $Package

# --- Build YAML fragments from the comma-separated env vars above ---

$ProcessNamesYaml = ($ProcessNameFilter -split ",") | ForEach-Object { "            - `"$_`"" } | Out-String

$EventLogReceiversYaml = ""
$EventLogPipelineReceivers = @()
foreach ($channel in ($EventLogChannels -split ",")) {
    $channel = $channel.Trim()
    $receiverName = if ($channel -eq "Application") { "windowseventlog" } else { "windowseventlog/$($channel.ToLower())" }
    $EventLogReceiversYaml += "  ${receiverName}:`n    channel: ${channel}`n    start_at: end`n"
    $EventLogPipelineReceivers += $receiverName
}
$EventLogPipelineReceiversYaml = ($EventLogPipelineReceivers -join ", ")

$ConfigYaml = @"
# Rendered by vigilo otel-collector/host/windows/otelcol-host-install.ps1.
# Re-run the installer with updated env vars rather than hand-editing
# receivers/processors below.

receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
          system.cpu.logical.count:
            enabled: true
          system.cpu.physical.count:
            enabled: true
          system.cpu.frequency:
            enabled: true
      disk: {}
      filesystem: {}
      load: {}
      memory:
        metrics:
          system.memory.limit:
            enabled: true
      network: {}
      paging: {}
      process:
        mute_process_name_error: true
        mute_process_exe_error: true
        mute_process_io_error: true
        include:
          match_type: regexp
          names:
$ProcessNamesYaml      processes: {}
      system: {}

$EventLogReceiversYaml  ## Enable the block below to collect logs from a specific application's
  ## own log file instead of (or alongside) the Windows Event Log:
  # filelog:
  #   include: [ "C:\\app-logs\\*.log" ]
  #   start_at: beginning

processors:
  batch:
    send_batch_size: 1000
    timeout: 10s

  resourcedetection:
    detectors: [$ResourceDetectors]
    timeout: 2s
    system:
      hostname_sources: [os]
      resource_attributes:
        os.description:
          enabled: true
        os.type:
          enabled: true
        host.arch:
          enabled: true
        host.id:
          enabled: true
        host.ip:
          enabled: true
        host.cpu.family:
          enabled: true
        host.cpu.model.id:
          enabled: true
        host.cpu.model.name:
          enabled: true
        host.cpu.vendor.id:
          enabled: true
        host.cpu.cache.l2.size:
          enabled: true

  resource/env:
    attributes:
      - key: deployment.environment
        value: "$DeploymentEnvironment"
        action: upsert
      - key: tenant.id
        value: "$TenantId"
        action: upsert
      - key: service.name
        value: "$ServiceNameAttr"
        action: upsert

extensions:
  health_check: {}
  zpages: {}

exporters:
  otlp:
    endpoint: "$OtlpBackendEndpoint"
    tls:
      insecure: true
  debug:
    verbosity: basic

service:
  telemetry:
    metrics:
      level: basic

  extensions: [health_check, zpages]

  pipelines:
    metrics/internal:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource/env, batch]
      exporters: [otlp, debug]

    logs/windows:
      receivers: [$EventLogPipelineReceiversYaml]
      processors: [resourcedetection, resource/env, batch]
      exporters: [otlp, debug]
    ## If you enabled the filelog block above, add a matching pipeline:
    # logs/app:
    #   receivers: [filelog]
    #   processors: [resourcedetection, resource/env, batch]
    #   exporters: [otlp, debug]
"@

Set-Content -Path "$InstallDir\config.yaml" -Value $ConfigYaml -Encoding UTF8

# Quick one-shot sanity check before installing as a service — fails fast
# on a bad config instead of silently not starting.
& "$InstallDir\otelcol-contrib.exe" validate --config "$InstallDir\config.yaml"

$ServiceName = "ObservabilityCollector"
$BinPath = "`"$InstallDir\otelcol-contrib.exe`" --config `"$InstallDir\config.yaml`""

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Service $ServiceName already exists — stopping to update binPath"
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

sc.exe create $ServiceName binPath= $BinPath start= auto DisplayName= "Observability Collector"

Start-Service $ServiceName
Get-Service $ServiceName

Write-Host "otelcol-contrib $CollectorVersion installed and running as service '$ServiceName'."
Write-Host "Check status with: Get-Service $ServiceName"
Write-Host "Stop with:         Stop-Service $ServiceName"
