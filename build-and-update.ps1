# build-and-update.ps1
# Builds BooxTabletDriver to a staging folder, swaps the running exe, restarts with --autostart.
# The tablet's auto-reconnect picks up the new connection within ~2s.

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$proj    = "$root\windows\BooxTabletDriver\BooxTabletDriver.csproj"
$staging = "$root\bin_staging"
$bin     = "$root\bin"
$exe     = "$bin\BooxTabletDriver.exe"

Write-Host "[1/4] Building to $staging ..." -ForegroundColor Cyan
dotnet publish $proj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $staging --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed." -ForegroundColor Red; exit 1 }
Write-Host "      Build OK" -ForegroundColor Green

Write-Host "[2/4] Stopping running exe (if any)..." -ForegroundColor Cyan
$proc = Get-Process BooxTabletDriver -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process $proc -Force
    Start-Sleep -Milliseconds 600
    Write-Host "      Stopped PID $($proc.Id)" -ForegroundColor Green
} else {
    Write-Host "      Not running" -ForegroundColor Yellow
}

Write-Host "[3/4] Copying new exe..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item "$staging\BooxTabletDriver.exe" $exe -Force
Write-Host "      Copied" -ForegroundColor Green

Write-Host "[4/4] Starting with --autostart..." -ForegroundColor Cyan
Start-Process $exe -ArgumentList "--autostart"
Write-Host "      Started. Tablet will reconnect automatically." -ForegroundColor Green
