<#
.SYNOPSIS
    Host Health Monitoring Script for Windows (Scheduled Task / Cron Equivalent)
.DESCRIPTION
    Pings the /health endpoint and appends any failures to logs/llm_health_failures.log
.EXAMPLE
    Register as Windows Scheduled Task (runs every 5 minutes):
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-File "C:\path\to\healthcheck_cron.ps1"'
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "LLM_Health_Monitor"
#>

$HealthUrl = if ($env:HEALTH_URL) { $env:HEALTH_URL } else { "http://localhost:8000/health" }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "llm_health_failures.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

try {
    $response = Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
    if ($response.status -eq "degraded") {
        $logMessage = "[$Timestamp] [WARNING] Service degraded (Redis cache unreachable): $($response | ConvertTo-Json -Compress)"
        Add-Content -Path $LogFile -Value $logMessage
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorDetails = $_.Exception.Message
    $logMessage = "[$Timestamp] [CRITICAL] Health check probe failed. Status: $statusCode. Error: $errorDetails"
    Add-Content -Path $LogFile -Value $logMessage
}
