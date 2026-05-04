Param(
    [string]$DatabaseUrl = "",
    [string]$MediaDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $root "server-go"

Push-Location $serverDir
try {
    if ($DatabaseUrl -ne "") {
        $env:DATABASE_URL = $DatabaseUrl
    }
    if ($MediaDir -ne "") {
        $env:MEDIA_DIR = $MediaDir
    }
    go run ./cmd/demo-reset
}
finally {
    Pop-Location
}

