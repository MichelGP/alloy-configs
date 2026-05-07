# Define Paths
$InstallerPath = "alloy-installer-windows-amd64.exe"
$InstallDir = "C:\Program Files\GrafanaLabs\Alloy"
$ConfDir = Join-Path $InstallDir "conf.d"
$ConfigFile = Join-Path $ConfDir "config.alloy"
$ConfigFileExtra = Join-Path $ConfDir "eventlog-powershell.alloy"
$OldConfigFile = Join-Path $InstallDir "config.alloy" # Default file in root
$Executable = Join-Path $InstallDir "alloy-windows-amd64.exe"

# Install Alloy from Share
if (Test-Path $InstallerPath) {
    Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait
} else {
    Write-Error "Installer not found at $InstallerPath"
    exit
}

# Remove the old/default config file from the root directory
if (Test-Path $OldConfigFile) {
    Remove-Item -Path $OldConfigFile -Force
}

# Create the conf.d directory and write the new configuration
if (-not (Test-Path $ConfDir)) {
    New-Item -ItemType Directory -Path $ConfDir -Force
}

$AlloyConfig = @'
// ==============================================================================
// LOGS PIPELINE
// ==============================================================================
loki.source.windowsevent "application" {
  eventlog_name          = "Application"
  use_incoming_timestamp = true
  forward_to             = [loki.process.logs.receiver]
}
loki.source.windowsevent "system" {
  eventlog_name          = "System"
  use_incoming_timestamp = true
  forward_to             = [loki.process.logs.receiver]
}
loki.source.windowsevent "security" {
  eventlog_name          = "Security"
  use_incoming_timestamp = true
  forward_to             = [loki.process.logs.receiver]
}
// NOTE: Put any complimentary logging as a separate conf file in the conf.d directory.

loki.process "logs" {
  forward_to = [otelcol.receiver.loki.logs.receiver]
  stage.json {
    expressions = {
      win_level = "level", 
    }
  }
  stage.template {
    source = "level_label" 
    template = "{{ if or (eq .win_level \"4\") (eq .win_level \"0\") }}info{{ else if eq .win_level \"2\" }}error{{ else if eq .win_level \"3\" }}warn{{ else if eq .win_level \"1\" }}critical{{ else }}unknown{{ end }}"
  }
  stage.labels {
    values = {
      level = "level_label",
    }
  }
  stage.label_drop {
    values = ["win_level", "level_label"]
  }
}

otelcol.receiver.loki "logs" {
  output { 
    logs = [otelcol.processor.resourcedetection.logs.input] 
  }
}

otelcol.processor.resourcedetection "logs" {
  detectors = ["system"]
  output { 
    logs = [otelcol.processor.transform.logs.input] 
  }
}

otelcol.processor.transform "logs" {
  log_statements {
    context = "resource"
    statements = [
      `set(attributes["service.name"], "windows-host")`,
      `set(attributes["service.instance.id"], attributes["host.name"])`,
    ]
  }
  log_statements {
    context = "log"
    statements = [
      `set(severity_text, "critical") where attributes["level"] == "critical"`,
      `set(severity_number, 21)       where attributes["level"] == "critical"`,
      `set(severity_text, "error")    where attributes["level"] == "error"`,
      `set(severity_number, 17)       where attributes["level"] == "error"`,
      `set(severity_text, "warn")     where attributes["level"] == "warn"`,
      `set(severity_number, 13)       where attributes["level"] == "warn"`,
      `set(severity_text, "info")     where attributes["level"] == "info" or attributes["level"] == "unknown"`,
      `set(severity_number, 9)        where attributes["level"] == "info" or attributes["level"] == "unknown"`,
    ]
  }
  output { 
    logs = [otelcol.processor.batch.default.input] 
  }
}

otelcol.processor.memory_limiter "default" {
  check_interval = "1s"
  limit          = "512MiB"
  spike_limit    = "128MiB"
  output {
      metrics = [otelcol.processor.batch.default.input]
      logs    = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  timeout             = "1s"
  send_batch_size     = 2000
  send_batch_max_size = 3000
  output {
    metrics = [otelcol.exporter.otlphttp.default.input]
    logs    = [otelcol.exporter.otlphttp.default.input]
  }
}

otelcol.auth.basic "loki_auth" {
  username = "user"
  password = "pass"
}

otelcol.exporter.otlphttp "default" {
  client {
    endpoint = "https://host.example.com/otlp"
    auth = otelcol.auth.basic.loki_auth.handler
    tls {
      insecure_skip_verify = false
    }
  }
}
'@ | Out-File -FilePath $ConfigFile -Encoding utf8

$AlloyConfigExtra = @'
loki.source.windowsevent "powershell" {
  eventlog_name          = "Microsoft-Windows-PowerShell/Operational"
  use_incoming_timestamp = true
  forward_to             = [loki.process.logs.receiver]
}
'@ | Out-File -FilePath $ConfigFileExtra -Encoding utf8

# Adjust Registry Settings
$RegPath = "HKLM:\SOFTWARE\GrafanaLabs\Alloy"
$Arguments = @(
    "run",
    "$ConfDir\",
    "--storage.path=C:\ProgramData\GrafanaLabs\Alloy\data",
	"--disable-reporting"
)

if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force
}

Set-ItemProperty -Path $RegPath -Name "(Default)" -Value $Executable
New-ItemProperty -Path $RegPath -Name "Arguments" -Value $Arguments -PropertyType MultiString -Force
New-ItemProperty -Path $RegPath -Name "Environment" -Value @("") -PropertyType MultiString -Force

# Restart the Alloy service to apply changes
Restart-Service -Name "Alloy" -Force
Get-Service -Name "Alloy"