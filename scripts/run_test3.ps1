<#
.SYNOPSIS
  THREE-client smoke run: host + two joins on one machine, direct UDP loopback.

.DESCRIPTION
  N-player experiment rig. Deliberately a SEPARATE script from run_test.ps1 so the
  validated two-client regression runner is not touched - this one is additive and
  can be deleted without affecting the 100-scenario suite.

  It answers the one question the unit layer cannot: with THREE clients connected,
  does each client actually observe the OTHER TWO peers' state (i.e. does the
  host's peer relay deliver), and does nobody crash?

  Why direct UDP: the Steam P2P tunnel is single-peer BY CONSTRUCTION on the host
  side (SteamP2P.cpp drops datagrams from any SteamId other than the one
  registered peer), so N players is only reachable over UDP. The regression suite
  already runs UDP on 127.0.0.1, so this is the same transport it validates.

  Three INDEPENDENT installs are required - Kenshi writes config/saves/logs into
  its own folder, so two instances of one install would fight over them. Create
  them with:
    scripts\setup_join_install.cmd "<source Kenshi>" "<dest>"

  Load is strictly SERIALIZED: run_test.ps1 learned the hard way that concurrent
  zone loads starve each other (a 12 s host load measured at 2.4 min). With three
  clients that is worse, so each one waits for the previous to reach gameplay.

.NOTES
  Reads nothing from scenarios.psd1 - this is a smoke rig, not a scenario run.
  Verdict lives in scripts\oracles\ThreePlayer.ps1.
#>
param(
    [string]$Save = "",
    [int]$Seconds = 90,
    [int]$Port = 27800,
    [string]$Ip = "127.0.0.1",
    [string]$HostDir  = "G:\steam\steamapps\common\Kenshi",
    [string]$Join1Dir = "G:\KenshiCoop-test\Kenshi-Join",
    [string]$Join2Dir = "G:\KenshiCoop-test\Kenshi-Join2",
    [string]$OutDir = "",
    [int]$StartTimeoutSec = 180,
    [int]$SettleSec = 10,
    [switch]$NoKill,
    [switch]$KeepOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "CoopHarness.psm1") -Force

# ---- Preflight ---------------------------------------------------------------
# Ordered so the FIRST failure reported is the most fundamental one. Getting this
# order wrong is not cosmetic: a still-copying install reported as "no plugin"
# sends you deploying into a folder that is not finished yet.
$installs = [ordered]@{ host = $HostDir; join1 = $Join1Dir; join2 = $Join2Dir }

# 1. The install exists at all.
foreach ($name in $installs.Keys) {
    if (-not (Test-Path (Join-Path $installs[$name] "kenshi_x64.exe"))) {
        throw "$name install has no kenshi_x64.exe at '$($installs[$name])'. Create it with scripts\setup_join_install.cmd"
    }
}

# 2. Distinct folders, or the instances would share config/saves/logs.
$paths = @($HostDir, $Join1Dir, $Join2Dir | ForEach-Object { (Resolve-Path $_).Path.TrimEnd('\').ToLower() })
if (($paths | Select-Object -Unique).Count -ne 3) {
    throw "host/join1/join2 must be three DISTINCT installs (they share config, saves and logs otherwise)."
}

# 3. COMPLETENESS, not just presence. robocopy writes kenshi_x64.exe early
# (roughly alphabetical), so an install still being copied passes an exe-exists
# check and then fails at runtime in a way that looks like a sync bug. Measured:
# a copy 1.4 GB into a 15 GB install already had the exe.
function Get-InstallSize {
    param([string]$Dir)
    return (Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
}
$srcSize = Get-InstallSize $HostDir
foreach ($name in @('join1', 'join2')) {
    $sz  = Get-InstallSize $installs[$name]
    $pct = if ($srcSize -gt 0) { 100.0 * $sz / $srcSize } else { 0 }
    # 90%: the copy deliberately excludes save/ and the mutable cfg/log files, so
    # an exact match is not expected - but a partial copy is nowhere near this.
    if ($pct -lt 90.0) {
        throw ("$name install looks INCOMPLETE: {0:N1} GB vs source {1:N1} GB ({2:N0}%). " -f `
               ($sz/1GB), ($srcSize/1GB), $pct) +
              "Still copying? Let scripts\setup_join_install.cmd finish, then re-run."
    }
    Write-Host ("  {0}: {1:N1} GB ({2:N0}% of source)" -f $name, ($sz/1GB), $pct)
}

# 4. Only now the mod bits: RE_Kenshi loads the plugin, and without either the
# run is a silent no-op that reads as "the relay does not work".
foreach ($name in $installs.Keys) {
    if (-not (Test-Path (Join-Path $installs[$name] "RE_Kenshi.dll"))) {
        throw "$name install is missing RE_Kenshi.dll ('$($installs[$name])'). The plugin would never load."
    }
    if (-not (Test-Path (Join-Path $installs[$name] "mods\KenshiCoop\KenshiCoop.dll"))) {
        throw "$name install has no mods\KenshiCoop\KenshiCoop.dll. Deploy with scripts\deploy.cmd `"$($installs[$name])`""
    }
}

if ($OutDir -eq "") {
    $OutDir = Join-Path $scriptDir ("..\out\three_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$logs = [ordered]@{
    host  = Join-Path $OutDir "host.log"
    join1 = Join-Path $OutDir "join1.log"
    join2 = Join-Path $OutDir "join2.log"
}

Write-Host "=== KenshiCoop THREE-client smoke run ==="
Write-Host "  transport: udp $Ip`:$Port (loopback)"
Write-Host "  save:      $(if ($Save -eq '') { '(none - client picks up its own)' } else { $Save })"
Write-Host "  seconds:   $Seconds"
Write-Host "  out:       $OutDir"
Write-Host ""

if (-not $NoKill) {
    $killed = Stop-CoopKenshi -SettleSec 2
    if ($killed -gt 0) { Write-Host "Killed $killed stale Kenshi process(es)." }
}

# ---- Helpers (mirroring run_test.ps1's, kept local so this file stands alone) --
function Wait-ForLogLine {
    param([string]$File, [string]$Pattern, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $File) {
            $hit = Select-String -Path $File -Pattern $Pattern -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($null -ne $hit) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-PastLauncher {
    param([string]$Exe, [string]$WorkDir)
    $out = & (Join-Path $scriptDir "start_kenshi.ps1") -ExePath $Exe -WorkDir $WorkDir `
             -TimeoutSec $StartTimeoutSec 6>&1
    $out | ForEach-Object { Write-Host "    $_" }
    $line = $out | Where-Object { "$_" -match "GAMEPID=(\d+)" } | Select-Object -First 1
    if ($line -and ("$line" -match "GAMEPID=(\d+)")) { return [int]$Matches[1] }
    return 0
}

# Every client gets the same channel defaults (hermetic clear, no scenario deltas)
# so a divergence cannot be blamed on a stray knob from an earlier run.
Set-CoopDiagEnv $null | Out-Null

function Set-ClientEnv {
    param([string]$Mode, [string]$Log)
    $env:KENSHICOOP_MODE         = $Mode
    $env:KENSHICOOP_TRANSPORT    = "udp"
    $env:KENSHICOOP_STEAM_PEER   = "0"
    $env:KENSHICOOP_IP           = $Ip
    $env:KENSHICOOP_PORT         = "$Port"
    $env:KENSHICOOP_LOG          = $Log
    $env:KENSHICOOP_SAVE         = $Save
    $env:KENSHICOOP_TEST_SECONDS = "$Seconds"
    # No compiled scenario: this is a plain "three clients coexist" smoke run.
    $env:KENSHICOOP_SCENARIO     = ""
    $env:KENSHICOOP_SETUP        = ""
}

# ---- Launch, strictly serialized -------------------------------------------
$pids = [ordered]@{}

Write-Host "Launching HOST ..."
Set-ClientEnv -Mode "host" -Log $logs.host
$pids.host = Start-PastLauncher -Exe (Join-Path $HostDir "kenshi_x64.exe") -WorkDir $HostDir
if ($pids.host -eq 0) { throw "Host never got past the launcher." }

foreach ($j in @(@{ n = "join1"; d = $Join1Dir }, @{ n = "join2"; d = $Join2Dir })) {
    $prev = if ($j.n -eq "join1") { "host" } else { "join1" }
    Write-Host "Waiting for $prev to reach gameplay before launching $($j.n) (timeout ${StartTimeoutSec}s) ..."
    if (-not (Wait-ForLogLine -File $logs[$prev] -Pattern "gameplay started" -TimeoutSec $StartTimeoutSec)) {
        Write-Warning "$prev never reported gameplay; launching $($j.n) anyway (the verdict will flag it)."
    }
    Start-Sleep -Seconds $SettleSec
    Write-Host "Launching $($j.n) ..."
    Set-ClientEnv -Mode "join" -Log $logs[$j.n]
    $pids[$j.n] = Start-PastLauncher -Exe (Join-Path $j.d "kenshi_x64.exe") -WorkDir $j.d
    if ($pids[$j.n] -eq 0) { Write-Warning "$($j.n) failed to get past the launcher; continuing." }
}

Write-Host ""
Write-Host "PIDs: host=$($pids.host) join1=$($pids.join1) join2=$($pids.join2)"
Write-Host "Running for ~${Seconds}s (each client self-exits via KENSHICOOP_TEST_SECONDS) ..."

# ---- Wait for the clients to self-exit --------------------------------------
$deadline = (Get-Date).AddSeconds($Seconds + $StartTimeoutSec + 120)
while ((Get-Date) -lt $deadline) {
    $alive = @(Get-Process -Id ($pids.Values | Where-Object { $_ -ne 0 }) -ErrorAction SilentlyContinue)
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 5
}
$stillUp = @(Get-Process -Id ($pids.Values | Where-Object { $_ -ne 0 }) -ErrorAction SilentlyContinue)
if ($stillUp.Count -gt 0) {
    if ($KeepOpen) {
        Write-Host "$($stillUp.Count) client(s) still up; -KeepOpen set, leaving them running."
    } else {
        Write-Warning "$($stillUp.Count) client(s) did not self-exit; killing."
        $stillUp | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# ---- Verdict ----------------------------------------------------------------
foreach ($k in $logs.Keys) {
    $n = if (Test-Path $logs[$k]) { (Get-Content $logs[$k] -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Host ("  {0,-6} {1,7} lines  {2}" -f $k, $n, $logs[$k])
}
Write-Host ""

$oracle = Join-Path $scriptDir "oracles\ThreePlayer.ps1"
if (Test-Path $oracle) {
    . $oracle
    $verdict = Test-ThreePlayer -HostFile $logs.host -Join1File $logs.join1 -Join2File $logs.join2
    $verdict | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir "verdict.json") -Encoding utf8
    Write-Host "== THREE-PLAYER VERDICT: $($verdict.verdict) =="
    foreach ($g in $verdict.gates) { Write-Host ("  {0,-22} {1}" -f $g.name, $g.result) }
    if ($verdict.why.Count -gt 0) {
        Write-Host "  reasons:"
        foreach ($w in $verdict.why) { Write-Host "    - $w" }
    }
    if ($verdict.verdict -ne "PASS") { exit 1 }
} else {
    Write-Warning "oracle not found at $oracle - logs are in $OutDir for manual reading."
}
