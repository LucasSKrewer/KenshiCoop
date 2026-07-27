# ThreePlayer.ps1 - verdict for the THREE-client smoke run (scripts\run_test3.ps1).
#
# Purpose-built and deliberately NARROW. The existing oracles are all pairwise
# host-vs-join comparisons (~386 $JoinFile references across 8 files); making that
# suite three-way is a rewrite, and this rig does not need it. It answers only the
# question the unit layer cannot:
#
#   With three clients connected, does each client OBSERVE THE OTHER TWO peers'
#   state - i.e. does the host's peer relay actually deliver - and does nobody
#   crash?
#
# Evidence it reads:
#   * "[owners] driven total=N distinct=M byOwner: a=x b=y"
#       the per-authoring-peer driven-body tally (KENSHICOOP_DEBUG_OWNERS=1,
#       emitted ~3 s in Replicator::logDriveTelemetry). This is the ONLY line
#       that attributes driven bodies to a peer - the [drive] lines carry the
#       hand but not the owner.
#   * "handshake: peer present id=N (local id=L)"  - who each client sees, and
#       its own id.
#   * "3+ players experimental"                    - the NetLink step-6 guard.
#   * "=== Kenshi-Online"/"gameplay started"/crash markers - liveness.
#
# NOT judged here (needs the real suite / a real session): positional
# convergence, combat, inventory, save streaming.

Set-StrictMode -Version Latest

function Get-TpLines {
    param([string]$File)
    if (-not (Test-Path $File)) { return @() }
    return @(Get-Content $File -ErrorAction SilentlyContinue)
}

# Parse the LAST [owners] tally in a log: which owner ids this client was driving
# bodies for, and how many each. Returns @{ owners = @{id=count}; total = N }.
function Get-TpOwnerTally {
    param([string[]]$Lines)
    $res = @{ owners = @{}; total = 0; samples = 0 }
    foreach ($l in $Lines) {
        if ($l -notmatch '\[owners\] driven total=(\d+) distinct=(\d+) byOwner:(.*)$') { continue }
        $res.samples++
        $total = [int]$Matches[1]
        $tail  = $Matches[3]
        $o = @{}
        foreach ($m in [regex]::Matches($tail, '(\d+)=(\d+)')) {
            $o[[int]$m.Groups[1].Value] = [int]$m.Groups[2].Value
        }
        # keep the LAST sample (steady state, after mint/settle)
        $res.owners = $o
        $res.total  = $total
    }
    return $res
}

function Get-TpLocalId {
    param([string[]]$Lines)
    foreach ($l in $Lines) {
        if ($l -match 'handshake: peer present id=\d+ \(local id=(\d+)\)') { return [int]$Matches[1] }
    }
    return -1
}

function Get-TpSeenPeers {
    param([string[]]$Lines)
    $seen = @{}
    foreach ($l in $Lines) {
        if ($l -match 'handshake: peer present id=(\d+)') { $seen[[int]$Matches[1]] = $true }
    }
    return @($seen.Keys | Sort-Object)
}

function Test-ThreePlayer {
    param(
        [string]$HostFile,
        [string]$Join1File,
        [string]$Join2File
    )

    $why   = New-Object System.Collections.ArrayList
    $gates = New-Object System.Collections.ArrayList
    function AddGate($name, $ok, $detail) {
        $null = $gates.Add([pscustomobject]@{
            name = $name; result = $(if ($ok) { "PASS" } else { "FAIL" }); detail = $detail })
        if (-not $ok) { $null = $why.Add("$name - $detail") }
        return $ok
    }

    $clients = [ordered]@{
        host  = Get-TpLines $HostFile
        join1 = Get-TpLines $Join1File
        join2 = Get-TpLines $Join2File
    }

    # ---- 1. Liveness: every client produced a log and reached gameplay --------
    foreach ($n in $clients.Keys) {
        $L = $clients[$n]
        AddGate "log_$n" ($L.Count -gt 0) "$($L.Count) lines" | Out-Null
        $gp = @($L | Where-Object { $_ -match 'gameplay started' }).Count -gt 0
        AddGate "gameplay_$n" $gp $(if ($gp) { "reached gameplay" } else { "never reported 'gameplay started'" }) | Out-Null
    }

    # ---- 2. No crash on any client -------------------------------------------
    # The plugin's own crash breadcrumb + the engine's. A three-client run that
    # crashes is a FAIL even if the relay demonstrably worked before the crash.
    foreach ($n in $clients.Keys) {
        $crash = @($clients[$n] | Where-Object {
            $_ -match 'VEH CRASH|ExceptionCode=0xC0000005|EXCEPTION_ACCESS_VIOLATION'
        })
        AddGate "nocrash_$n" ($crash.Count -eq 0) `
            $(if ($crash.Count -eq 0) { "clean" } else { "$($crash.Count) crash marker(s): $($crash[0])" }) | Out-Null
    }

    # ---- 3. The host admitted a third player and said so loudly ---------------
    # The step-6 guard is intentionally still there: it warns rather than blocks.
    # Seeing it is the proof the run really had three clients, not two.
    $guard = @($clients.host | Where-Object { $_ -match '3\+ players' }).Count
    AddGate "third_admitted" ($guard -ge 1) `
        "host logged the 3+ guard $guard time(s) (expected >= 1)" | Out-Null

    # Host should have seen TWO distinct peers connect.
    $hostSeen = Get-TpSeenPeers $clients.host
    AddGate "host_saw_two_peers" ($hostSeen.Count -ge 2) `
        "host saw peer ids: $($hostSeen -join ',')" | Out-Null

    # ---- 4. THE RELAY GATE ---------------------------------------------------
    # Each JOIN must be driving bodies authored by TWO distinct owners: the host
    # AND the other join. One distinct owner means it only ever heard from the
    # host - exactly the pre-relay behavior this experiment set out to change.
    $tally = @{}
    foreach ($n in $clients.Keys) { $tally[$n] = Get-TpOwnerTally $clients[$n] }

    foreach ($n in @('join1', 'join2')) {
        $t = $tally[$n]
        if ($t.samples -eq 0) {
            AddGate "relay_$n" $false ("no '[owners]' samples - was KENSHICOOP_DEBUG_OWNERS=1 set, " +
                                       "and did this client ever drive a body?") | Out-Null
            continue
        }
        $ids = @($t.owners.Keys | Sort-Object)
        AddGate "relay_$n" ($ids.Count -ge 2) `
            ("drove bodies from owner(s) [$($ids -join ',')], total=$($t.total), " +
             "$($t.samples) sample(s) - need >= 2 distinct owners (host + the other join)") | Out-Null
    }

    # The host drives both joins' bodies natively (no relay involved) - a sanity
    # check that the run had real motion at all, so a relay FAIL cannot be blamed
    # on "nothing was moving anywhere".
    $ht = $tally['host']
    $hostIds = @($ht.owners.Keys | Sort-Object)
    AddGate "host_drove_both" ($hostIds.Count -ge 2) `
        ("host drove bodies from owner(s) [$($hostIds -join ',')], total=$($ht.total), " +
         "$($ht.samples) sample(s)") | Out-Null

    $failed  = @($gates | Where-Object { $_.result -eq "FAIL" })
    $verdict = if ($failed.Count -eq 0) { "PASS" } else { "FAIL" }

    return [pscustomobject]@{
        verdict = $verdict
        gates   = @($gates)
        why     = @($why)
        tally   = $tally
    }
}
