<#
.SYNOPSIS
    Automated cold-read benchmark for localStorage first access.

.DESCRIPTION
    Launches Edge, populates localStorage, then restarts the browser multiple
    times to measure the cold first-read duration. Runs for both LevelDB
    (default) and SQLite backends, then prints a comparison summary.

.PARAMETER Runs
    Number of cold-read measurements per backend (default: 10).

.PARAMETER Entries
    Number of localStorage entries to populate (default: 10000).

.PARAMETER ValueSize
    Size of each value in characters (default: 100).

.PARAMETER Delay
    Milliseconds to wait after page load before measuring (default: 5000).

.PARAMETER EdgePath
    Path to msedge.exe. Defaults to Edge SxS (Canary).

.PARAMETER PageUrl
    URL of the benchmark page. Defaults to the GitHub Pages deployment.

.PARAMETER CdpPort
    Port for Chrome DevTools Protocol (default: 9222).

.EXAMPLE
    .\benchmark.ps1 -Runs 10 -Entries 10000 -ValueSize 100 -Delay 5000
#>
param(
    [int]$Runs = 10,
    [int]$Entries = 10000,
    [int]$ValueSize = 100,
    [int]$Delay = 5000,
    [string]$EdgePath = "$env:LOCALAPPDATA\Microsoft\Edge SxS\Application\msedge.exe",
    [string]$PageUrl = "https://rahulsingh-msft.github.io/localstorage-getall-perf/",
    [int]$CdpPort = 9222
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
function Kill-Edge {
    # Wait a moment, then kill all Edge processes from our user-data-dir.
    Start-Sleep -Seconds 2
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Launch-Edge {
    param(
        [string]$Url,
        [string]$UserDataDir,
        [string[]]$ExtraFlags = @()
    )

    $args = @(
        "--user-data-dir=$UserDataDir",
        "--remote-debugging-port=$CdpPort",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-sync"
    ) + $ExtraFlags + @($Url)

    Start-Process -FilePath $EdgePath -ArgumentList $args
}

function Get-CdpTitle {
    param([int]$TimeoutSec = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    # Wait for CDP to be available.
    while ((Get-Date) -lt $deadline) {
        try {
            $tabs = Invoke-RestMethod -Uri "http://localhost:$CdpPort/json" -TimeoutSec 3
            break
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    # Poll document.title via CDP until it has our result marker.
    while ((Get-Date) -lt $deadline) {
        try {
            $tabs = Invoke-RestMethod -Uri "http://localhost:$CdpPort/json" -TimeoutSec 3
            $page = $tabs | Where-Object { $_.type -eq "page" -and $_.url -like "*localstorage*" } | Select-Object -First 1
            if ($page -and $page.title -match "^(RESULT|POPULATED):") {
                return $page.title
            }
        } catch { }
        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for page result"
}

function Run-Backend {
    param(
        [string]$Name,
        [string]$UserDataDir,
        [string[]]$FeatureFlags = @()
    )

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " Backend: $Name" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan

    # Clean user data dir for a fresh start.
    if (Test-Path $UserDataDir) {
        Remove-Item -Recurse -Force $UserDataDir
    }

    # --- Populate ---
    Write-Host "Populating $Entries entries ($ValueSize chars each)..." -ForegroundColor Yellow
    $populateUrl = "${PageUrl}?populate=${Entries}&valueSize=${ValueSize}"
    Launch-Edge -Url $populateUrl -UserDataDir $UserDataDir -ExtraFlags $FeatureFlags

    try {
        $title = Get-CdpTitle -TimeoutSec 60
        if ($title -match "^POPULATED:(\d+)") {
            Write-Host "  Populated $($Matches[1]) entries." -ForegroundColor Green
        } else {
            Write-Host "  Unexpected populate result: $title" -ForegroundColor Red
        }
    } catch {
        Write-Host "  ERROR during populate: $_" -ForegroundColor Red
        Kill-Edge
        return @()
    }

    Kill-Edge

    # --- Measure cold reads ---
    $results = @()
    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "Run $i/$Runs ... " -NoNewline
        $measureUrl = "${PageUrl}?auto&delay=${Delay}"
        Launch-Edge -Url $measureUrl -UserDataDir $UserDataDir -ExtraFlags $FeatureFlags

        try {
            # Wait for delay + some extra time for page load and CDP.
            $timeout = [math]::Max(60, ($Delay / 1000) + 30)
            $title = Get-CdpTitle -TimeoutSec $timeout
            if ($title -match "^RESULT:([\d.]+):(\d+)") {
                $duration = [double]$Matches[1]
                $entries  = [int]$Matches[2]
                $results += $duration
                Write-Host "$($duration.ToString('F3')) ms ($entries entries)" -ForegroundColor Green
            } else {
                Write-Host "Unexpected result: $title" -ForegroundColor Red
            }
        } catch {
            Write-Host "ERROR: $_" -ForegroundColor Red
        }

        Kill-Edge
    }

    return $results
}

function Show-Stats {
    param(
        [string]$Name,
        [double[]]$Values
    )

    if ($Values.Count -eq 0) {
        Write-Host "$Name : no results" -ForegroundColor Red
        return
    }

    $sorted = $Values | Sort-Object
    $mean   = ($Values | Measure-Object -Average).Average
    $min    = $sorted[0]
    $max    = $sorted[-1]
    $median = if ($sorted.Count % 2 -eq 0) {
        ($sorted[$sorted.Count/2 - 1] + $sorted[$sorted.Count/2]) / 2
    } else {
        $sorted[[math]::Floor($sorted.Count/2)]
    }
    $variance = ($Values | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum / $Values.Count
    $stddev   = [math]::Sqrt($variance)

    Write-Host ""
    Write-Host "$Name Results ($($Values.Count) runs):" -ForegroundColor Cyan
    Write-Host "  Min:    $($min.ToString('F3')) ms"
    Write-Host "  Max:    $($max.ToString('F3')) ms"
    Write-Host "  Mean:   $($mean.ToString('F3')) ms"
    Write-Host "  Median: $($median.ToString('F3')) ms"
    Write-Host "  StdDev: $($stddev.ToString('F3')) ms"
    Write-Host "  All:    $($Values | ForEach-Object { $_.ToString('F3') })" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
Write-Host "LocalStorage First Read Benchmark - Automated" -ForegroundColor White
Write-Host "  Runs:      $Runs"
Write-Host "  Entries:   $Entries"
Write-Host "  ValueSize: $ValueSize chars"
Write-Host "  Delay:     $Delay ms"
Write-Host "  Edge:      $EdgePath"
Write-Host ""

# Make sure Edge exists.
if (-not (Test-Path $EdgePath)) {
    Write-Host "ERROR: Edge not found at $EdgePath" -ForegroundColor Red
    Write-Host "Set -EdgePath to your msedge.exe location." -ForegroundColor Yellow
    exit 1
}

# Kill any existing Edge instances.
Kill-Edge

# Run LevelDB (default backend).
$leveldbResults = Run-Backend -Name "LevelDB" `
    -UserDataDir "$env:TEMP\bench-leveldb" `
    -FeatureFlags @("--disable-features=DomStorageSqlite")

# Run SQLite backend.
$sqliteResults = Run-Backend -Name "SQLite" `
    -UserDataDir "$env:TEMP\bench-sqlite" `
    -FeatureFlags @("--enable-features=DomStorageSqlite")

# --- Summary ---
Write-Host ""
Write-Host "=============================================" -ForegroundColor White
Write-Host " SUMMARY" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White

Show-Stats -Name "LevelDB" -Values $leveldbResults
Show-Stats -Name "SQLite"  -Values $sqliteResults

Write-Host ""
Write-Host "Done." -ForegroundColor Green
