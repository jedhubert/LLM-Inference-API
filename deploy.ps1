<#
.SYNOPSIS
    Production LLM API Deployment & Health Verification Script for Windows PowerShell
.DESCRIPTION
    Pulls latest git commits, rebuilds Docker images, starts multi-container stack, and probes /health.

$ErrorActionPreference = "Stop"

$Port = if ($env:PORT) { $env:PORT } else { "8000" }
$HealthUrl = "http://localhost:$Port/health"
$MaxAttempts = if ($env:MAX_ATTEMPTS) { [int]$env:MAX_ATTEMPTS } else { 100 }
$SleepIntervalSec = if ($env:SLEEP_INTERVAL) { [int]$env:SLEEP_INTERVAL } else { 3 }

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "🚀 Starting Production Deployment: LLM Inference API  " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

Write-Host "`n▶ Step 1: Checking for repository updates..." -ForegroundColor Yellow
if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path ".git")) {
    Write-Host "Pulling latest code changes..."
    git pull
} else {
    Write-Host "Git repository not present or git CLI not found. Using local directory code."
}

Write-Host "`n▶ Step 2: Building container images..." -ForegroundColor Yellow
docker compose build --pull

Write-Host "`n▶ Step 3: Orchestrating multi-container startup..." -ForegroundColor Yellow
docker compose up -d --remove-orphans

Write-Host "`n▶ Step 4: Polling /health endpoint for readiness ($HealthUrl)..." -ForegroundColor Yellow
$healthy = $false

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host -NoNewline "Probe attempt $attempt/$MaxAttempts : "
    try {
        $response = Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
        if ($response.status -eq "healthy" -or $response.status -eq "degraded") {
            Write-Host "HTTP 200 OK (Status: $($response.status))" -ForegroundColor Green
            $healthy = $true
            $finalResponse = $response
            break
        } else {
            Write-Host "Status returned: $($response.status)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Connection waiting / initializing..." -ForegroundColor DarkYellow
    }
    Start-Sleep -Seconds $SleepIntervalSec
}

Write-Host "`n======================================================" -ForegroundColor Cyan
if ($healthy) {
    Write-Host "✅ DEPLOYMENT SUCCESSFUL! All services healthy." -ForegroundColor Green
    Write-Host "Active Containers:" -ForegroundColor Green
    docker compose ps
    exit 0
} else {
    Write-Host "❌ DEPLOYMENT FAILED: Service did not become healthy within $($MaxAttempts * $SleepIntervalSec) seconds." -ForegroundColor Red
    Write-Host "`nAPI Container Logs:" -ForegroundColor Red
    docker compose logs --tail=40 api
    exit 1
}
