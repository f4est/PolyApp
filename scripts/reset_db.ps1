param(
  [ValidateSet("api", "hard")]
  [string]$Mode = "api",
  [string]$ApiUrl = "http://localhost:8000",
  [string]$AdminEmail = "admin@demo.local",
  [string]$AdminPassword = "Demo1234",
  [string]$ComposeFile = "docker-compose.yml",
  [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

function Confirm-Action([string]$Message) {
  if ($NoConfirm) { return $true }
  $answer = Read-Host "$Message [y/N]"
  return $answer -match "^(y|yes|д|да)$"
}

function Wait-Api([string]$BaseUrl, [int]$TimeoutSec = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method GET -TimeoutSec 5
      if ($health -ne $null) {
        return
      }
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  throw "API did not become healthy within $TimeoutSec seconds."
}

function Reset-ViaApi {
  Write-Host "Reset mode: API (/db/demo/reset)"
  $loginBody = @{
    email    = $AdminEmail
    password = $AdminPassword
  } | ConvertTo-Json

  $login = Invoke-RestMethod `
    -Uri "$ApiUrl/auth/login" `
    -Method POST `
    -ContentType "application/json" `
    -Body $loginBody `
    -TimeoutSec 30

  $token = [string]$login.access_token
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Login failed: access_token is empty."
  }

  Invoke-RestMethod `
    -Uri "$ApiUrl/db/demo/reset" `
    -Method POST `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -Body "{}" `
    -TimeoutSec 30 | Out-Null

  Write-Host "Database reset completed via API."
  Write-Host "Protected admin preserved: $AdminEmail / Demo1234"
}

function Reset-HardDocker {
  Write-Host "Reset mode: HARD (remove Postgres docker volume)"
  $root = Resolve-Path (Join-Path $PSScriptRoot "..")
  Push-Location $root
  try {
    docker compose -f $ComposeFile down | Out-Null

    $volumes = docker volume ls --format "{{.Name}}" | Where-Object {
      $_ -match "polyapp_postgres_data$"
    }
    if (-not $volumes -or $volumes.Count -eq 0) {
      throw "Postgres volume not found (expected *polyapp_postgres_data)."
    }
    foreach ($v in $volumes) {
      docker volume rm $v | Out-Null
      Write-Host "Removed volume: $v"
    }

    docker compose -f $ComposeFile up -d db redis api | Out-Null
    Wait-Api -BaseUrl $ApiUrl -TimeoutSec 120

    Write-Host "Hard reset completed. Services are up."
    Write-Host "If SEED_DEMO=true in compose, demo users will be recreated."
  } finally {
    Pop-Location
  }
}

Write-Host "PolyApp DB reset script"
Write-Host "Mode: $Mode"
Write-Host "API:  $ApiUrl"

if (-not (Confirm-Action "This will reset database data. Continue?")) {
  Write-Host "Cancelled."
  exit 0
}

switch ($Mode) {
  "api"  { Reset-ViaApi }
  "hard" { Reset-HardDocker }
  default { throw "Unknown mode: $Mode" }
}
