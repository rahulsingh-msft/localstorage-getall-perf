<#
.SYNOPSIS
    Warm-DB benchmark: measures localStorage read with DB already open.

.DESCRIPTION
    Populates localStorage on two origins (localhost on two ports), then
    restarts the browser and reads origin A (cold DB) followed by origin B
    (warm DB, cold cache). Compares the delta to isolate DB opening overhead
    from data retrieval cost. Runs for both LevelDB and SQLite backends.

.PARAMETER Runs
    Number of measurement cycles per backend (default: 10).

.PARAMETER Entries
    Number of localStorage entries per origin (default: 10000).

.PARAMETER ValueSize
    Size of each value in characters (default: 100).

.PARAMETER Delay
    Milliseconds to wait after page load before measuring (default: 5000).

.PARAMETER EdgePath
    Path to msedge.exe. Defaults to Edge SxS (Canary).

.PARAMETER CdpPort
    Port for Chrome DevTools Protocol (default: 9222).

.PARAMETER PortA
    HTTP server port for origin A (default: 8080).

.PARAMETER PortB
    HTTP server port for origin B (default: 8081).

.PARAMETER PythonCmd
    Python executable name (default: python).

.EXAMPLE
    .\benchmark-warm-db.ps1 -Runs 10 -Entries 10000 -Delay 5000
#>
param(
    [int]$Runs = 20,
    [int]$Entries = 10000,
    [int]$ValueSize = 100,
    [int]$Delay = 5000,
    [string]$EdgePath = "$env:LOCALAPPDATA\Microsoft\Edge SxS\Application\msedge.exe",
    [int]$CdpPort = 9222,
    [int]$PortA = 9090,
    [int]$PortB = 9091,
    [string]$PythonCmd = "python"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
$script:EdgePid = $null
$script:ServerA = $null
$script:ServerB = $null

function Stop-EdgeTree {
    try {
        Invoke-RestMethod -Uri "http://localhost:$CdpPort/json/close" -TimeoutSec 3 -ErrorAction SilentlyContinue 2>$null | Out-Null
    } catch { }

    if ($script:EdgePid) {
        try {
            $proc = Get-Process -Id $script:EdgePid -ErrorAction SilentlyContinue
            if ($proc) {
                $proc.CloseMainWindow() | Out-Null
                $proc.WaitForExit(10000) | Out-Null
            }
        } catch { }

        $stillRunning = Get-Process -Id $script:EdgePid -ErrorAction SilentlyContinue
        if ($stillRunning) {
            taskkill /T /F /PID $script:EdgePid 2>$null | Out-Null
        }
        $script:EdgePid = $null
    }

    Get-Process msedge -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith((Split-Path $EdgePath)) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Launch-Edge {
    param(
        [string]$Url,
        [string]$UserDataDir,
        [string[]]$ExtraFlags = @()
    )

    $edgeArgs = @(
        "--user-data-dir=`"$UserDataDir`"",
        "--remote-debugging-port=$CdpPort",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-sync"
    ) + $ExtraFlags + @("`"$Url`"")

    $argString = $edgeArgs -join " "
    $proc = Start-Process -FilePath $EdgePath -ArgumentList $argString -PassThru
    $script:EdgePid = $proc.Id
}

function Get-CdpResult {
    param(
        [string]$UrlPattern,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    # Wait for CDP to be available.
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri "http://localhost:$CdpPort/json" -TimeoutSec 3 | Out-Null
            break
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    # Poll for result marker on the matching tab.
    while ((Get-Date) -lt $deadline) {
        try {
            $tabs = Invoke-RestMethod -Uri "http://localhost:$CdpPort/json" -TimeoutSec 3
            $page = $tabs | Where-Object {
                $_.type -eq "page" -and $_.url -like $UrlPattern
            } | Select-Object -First 1
            if ($page -and $page.title -match "^(RESULT|POPULATED):") {
                return $page.title
            }
        } catch { }
        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for result on $UrlPattern"
}

function Open-NewTab {
    param([string]$Url)

    # Use CDP to open a new tab.
    $encodedUrl = [System.Uri]::EscapeDataString($Url)
    Invoke-RestMethod -Method Put -Uri "http://localhost:$CdpPort/json/new?$encodedUrl" -TimeoutSec 5 | Out-Null
}

function Start-HttpServers {
    $siteDir = $PSScriptRoot

    $script:ServerA = Start-Process -FilePath $PythonCmd `
        -ArgumentList "-m http.server $PortA" `
        -WorkingDirectory $siteDir -WindowStyle Hidden -PassThru

    $script:ServerB = Start-Process -FilePath $PythonCmd `
        -ArgumentList "-m http.server $PortB" `
        -WorkingDirectory $siteDir -WindowStyle Hidden -PassThru

    # Wait for servers to be ready.
    Start-Sleep -Seconds 2
    Write-Host "  HTTP servers started on ports $PortA and $PortB" -ForegroundColor Green
}

function Stop-HttpServers {
    if ($script:ServerA) {
        $stillRunning = Get-Process -Id $script:ServerA.Id -ErrorAction SilentlyContinue
        if ($stillRunning) { Stop-Process -Id $script:ServerA.Id -Force -ErrorAction SilentlyContinue }
        $script:ServerA = $null
    }
    if ($script:ServerB) {
        $stillRunning = Get-Process -Id $script:ServerB.Id -ErrorAction SilentlyContinue
        if ($stillRunning) { Stop-Process -Id $script:ServerB.Id -Force -ErrorAction SilentlyContinue }
        $script:ServerB = $null
    }
}

function Remove-UserDataDir {
    param([string]$Path)
    if (Test-Path $Path) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Remove-Item -Recurse -Force $Path -ErrorAction Stop
                break
            } catch {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Compute-Stats {
    param([double[]]$Values)

    if ($Values.Count -eq 0) { return $null }

    $sorted = $Values | Sort-Object
    $mean   = ($Values | Measure-Object -Average).Average
    $min    = $sorted[0]
    $max    = $sorted[-1]
    $median = if ($sorted.Count % 2 -eq 0) {
        ($sorted[$sorted.Count/2 - 1] + $sorted[$sorted.Count/2]) / 2
    } else {
        $sorted[[math]::Floor($sorted.Count/2)]
    }
    $variance = ($Values | ForEach-Object { ($_ - $mean) * ($_ - $mean) } |
        Measure-Object -Sum).Sum / $Values.Count
    $stddev = [math]::Sqrt($variance)
    $ciMargin = 1.96 * $stddev / [math]::Sqrt($Values.Count)

    return @{
        Min      = $min
        Max      = $max
        Mean     = $mean
        Median   = $median
        StdDev   = $stddev
        CiMargin = $ciMargin
    }
}

function Run-WarmDbBackend {
    param(
        [string]$Name,
        [string]$UserDataDir,
        [string[]]$FeatureFlags = @()
    )

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " Backend: $Name" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan

    Remove-UserDataDir -Path $UserDataDir

    $urlA = "http://[::1]:$PortA/"
    $urlB = "http://[::1]:$PortB/"

    # --- Populate both origins ---
    Write-Host "Populating origin A (port $PortA)..." -ForegroundColor Yellow
    $populateUrlA = "${urlA}?populate=${Entries}&valueSize=${ValueSize}"
    Launch-Edge -Url $populateUrlA -UserDataDir $UserDataDir -ExtraFlags $FeatureFlags

    try {
        $title = Get-CdpResult -UrlPattern "*:$PortA/*" -TimeoutSec 60
        if ($title -match "^POPULATED:(\d+)") {
            Write-Host "  Origin A: $($Matches[1]) entries." -ForegroundColor Green
        }
    } catch {
        Write-Host "  ERROR populating origin A: $_" -ForegroundColor Red
        Stop-EdgeTree
        return @{ Tab1 = @(); Tab2 = @(); Delta = @() }
    }

    Write-Host "Populating origin B (port $PortB)..." -ForegroundColor Yellow
    $populateUrlB = "${urlB}?populate=${Entries}&valueSize=${ValueSize}"
    Open-NewTab -Url $populateUrlB

    try {
        $title = Get-CdpResult -UrlPattern "*:$PortB/*" -TimeoutSec 60
        if ($title -match "^POPULATED:(\d+)") {
            Write-Host "  Origin B: $($Matches[1]) entries." -ForegroundColor Green
        }
    } catch {
        Write-Host "  ERROR populating origin B: $_" -ForegroundColor Red
        Stop-EdgeTree
        return @{ Tab1 = @(); Tab2 = @(); Delta = @() }
    }

    Stop-EdgeTree

    # --- Measure: cold DB (tab 1) then warm DB (tab 2) ---
    $tab1Results = @()
    $tab2Results = @()
    $deltaResults = @()

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "Run $i/$Runs ... " -NoNewline

        # Tab 1: origin A (cold DB open)
        $measureUrlA = "${urlA}?auto&delay=${Delay}"
        Launch-Edge -Url $measureUrlA -UserDataDir $UserDataDir -ExtraFlags $FeatureFlags

        $tab1Duration = $null
        $tab2Duration = $null

        try {
            $timeout = [math]::Max(60, ($Delay / 1000) + 30)
            $title = Get-CdpResult -UrlPattern "*:$PortA/*" -TimeoutSec $timeout
            if ($title -match "^RESULT:([\d.]+):(\d+)") {
                $tab1Duration = [double]$Matches[1]
            }
        } catch {
            Write-Host "Tab1 ERROR: $_" -ForegroundColor Red
            Stop-EdgeTree
            continue
        }

        # Tab 2: origin B (DB already open, cache cold)
        $measureUrlB = "${urlB}?auto&delay=${Delay}"
        Open-NewTab -Url $measureUrlB

        try {
            $timeout = [math]::Max(60, ($Delay / 1000) + 30)
            $title = Get-CdpResult -UrlPattern "*:$PortB/*" -TimeoutSec $timeout
            if ($title -match "^RESULT:([\d.]+):(\d+)") {
                $tab2Duration = [double]$Matches[1]
            }
        } catch {
            Write-Host "Tab2 ERROR: $_" -ForegroundColor Red
            Stop-EdgeTree
            continue
        }

        if ($null -ne $tab1Duration -and $null -ne $tab2Duration) {
            $delta = $tab1Duration - $tab2Duration
            $tab1Results += $tab1Duration
            $tab2Results += $tab2Duration
            $deltaResults += $delta
            Write-Host ("Tab1: {0:F3} ms  Tab2: {1:F3} ms  Delta: {2:F3} ms" -f $tab1Duration, $tab2Duration, $delta) -ForegroundColor Green
        }

        Stop-EdgeTree
    }

    return @{
        Tab1  = $tab1Results
        Tab2  = $tab2Results
        Delta = $deltaResults
    }
}

function Format-Table {
    param(
        [string]$Name,
        [double[]]$Tab1,
        [double[]]$Tab2,
        [double[]]$Delta
    )

    $lines = @()
    $lines += "$Name Results"
    $lines += ("-" * 60)
    $lines += "{0,-6} {1,12} {2,12} {3,12}" -f "Run", "Tab1 (ms)", "Tab2 (ms)", "Delta (ms)"
    $lines += ("-" * 60)

    for ($i = 0; $i -lt $Tab1.Count; $i++) {
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f ($i + 1), $Tab1[$i], $Tab2[$i], $Delta[$i]
    }

    $lines += ("-" * 60)

    $stats1 = Compute-Stats -Values $Tab1
    $stats2 = Compute-Stats -Values $Tab2
    $statsD = Compute-Stats -Values $Delta

    if ($stats1) {
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f "Mean", $stats1.Mean, $stats2.Mean, $statsD.Mean
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f "Median", $stats1.Median, $stats2.Median, $statsD.Median
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f "Min", $stats1.Min, $stats2.Min, $statsD.Min
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f "Max", $stats1.Max, $stats2.Max, $statsD.Max
        $lines += "{0,-6} {1,12:F3} {2,12:F3} {3,12:F3}" -f "StdDev", $stats1.StdDev, $stats2.StdDev, $statsD.StdDev
        $lines += "{0,-6} {1,12} {2,12} {3,12}" -f "95% CI", `
            ("+/- " + $stats1.CiMargin.ToString('F3')), `
            ("+/- " + $stats2.CiMargin.ToString('F3')), `
            ("+/- " + $statsD.CiMargin.ToString('F3'))
    }

    return $lines -join "`n"
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
Write-Host "LocalStorage Warm-DB Benchmark" -ForegroundColor White
Write-Host "  Runs:      $Runs"
Write-Host "  Entries:   $Entries per origin"
Write-Host "  ValueSize: $ValueSize chars"
Write-Host "  Delay:     $Delay ms"
Write-Host "  Delay:     $Delay ms"
Write-Host "  Ports:     $PortA (origin A), $PortB (origin B)"
Write-Host "  Edge:      $EdgePath"
Write-Host ""

if (-not (Test-Path $EdgePath)) {
    Write-Host "ERROR: Edge not found at $EdgePath" -ForegroundColor Red
    exit 1
}

# Start HTTP servers.
Start-HttpServers

try {
    Stop-EdgeTree

    $leveldbData = Run-WarmDbBackend -Name "LevelDB" `
        -UserDataDir "$env:TEMP\bench-warmdb-leveldb" `
        -FeatureFlags @("--disable-features=DomStorageSqlite")

    $sqliteData = Run-WarmDbBackend -Name "SQLite" `
        -UserDataDir "$env:TEMP\bench-warmdb-sqlite" `
        -FeatureFlags @("--enable-features=DomStorageSqlite")

    # --- Summary ---
    $leveldbTable = Format-Table -Name "LevelDB" `
        -Tab1 $leveldbData.Tab1 -Tab2 $leveldbData.Tab2 -Delta $leveldbData.Delta

    $sqliteTable = Format-Table -Name "SQLite" `
        -Tab1 $sqliteData.Tab1 -Tab2 $sqliteData.Tab2 -Delta $sqliteData.Delta

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor White
    Write-Host " SUMMARY" -ForegroundColor White
    Write-Host "=============================================" -ForegroundColor White
    Write-Host ""
    Write-Host $leveldbTable -ForegroundColor Cyan
    Write-Host ""
    Write-Host $sqliteTable -ForegroundColor Cyan
    Write-Host ""

    # --- Write results to file ---
    $resultsPath = Join-Path $PSScriptRoot "results-warm-db.txt"
    $separator = "=" * 60
    $output = @(
        "LocalStorage Warm-DB Benchmark",
        "Date:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Runs:      $Runs",
        "Entries:   $Entries per origin",
        "ValueSize: $ValueSize chars",
        "Delay:     $Delay ms",
        "Ports:     $PortA (origin A), $PortB (origin B)",
        "Edge:      $EdgePath",
        "",
        "Tab1 = Origin A (cold DB open)",
        "Tab2 = Origin B (DB already open, data not cached)",
        "Delta = Tab1 - Tab2 (DB opening overhead)",
        "",
        $separator,
        "",
        $leveldbTable,
        "",
        $sqliteTable,
        ""
    )
    $output -join "`n" | Set-Content -Path $resultsPath
    Write-Host "Results written to $resultsPath" -ForegroundColor Green
} finally {
    Stop-HttpServers
}
