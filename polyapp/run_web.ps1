param(
  [int]$Port = 5050,
  [string]$Device = "chrome"
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
  flutter run -d $Device --web-port $Port @args
} finally {
  Pop-Location
}
