# build-and-update.ps1
# Builds BooxTabletDriver to a staging folder, swaps the running exe, restarts with --autostart.
# The tablet's auto-reconnect picks up the new connection within ~2s.

# Auto-elevate: re-launch as Administrator if not already elevated.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$proj    = "$root\windows\BooxTabletDriver\BooxTabletDriver.csproj"
$staging = "$root\bin_staging"
$bin     = "$root\bin"
$exe     = "$bin\BooxTabletDriver.exe"

# Kill first — dotnet publish writes intermediate files to the project's bin\Release\
# folder which is locked if the exe is running.
Write-Host "[1/4] Stopping running exe (if any)..." -ForegroundColor Cyan
$proc = Get-Process BooxTabletDriver -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process $proc -Force
    Start-Sleep -Milliseconds 600
    Write-Host "      Stopped PID $($proc.Id)" -ForegroundColor Green
} else {
    Write-Host "      Not running" -ForegroundColor Yellow
}

Write-Host "[2/4] Building to $staging ..." -ForegroundColor Cyan
dotnet publish $proj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $staging --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed." -ForegroundColor Red; exit 1 }
Write-Host "      Build OK" -ForegroundColor Green

Write-Host "[3/4] Copying new exe to $bin ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item "$staging\BooxTabletDriver.exe" $exe -Force
Write-Host "      Copied" -ForegroundColor Green

Write-Host "[4/4] Starting Main with --autostart..." -ForegroundColor Cyan
Start-Process $exe -ArgumentList "--name Main --autostart"
Write-Host "      Started. Tablet will reconnect automatically." -ForegroundColor Green
