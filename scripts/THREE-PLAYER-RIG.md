# Three-player smoke rig (N-player experiment)

Additive to the upstream harness: nothing here is wired into `regress.ps1` or
`scenarios.psd1`, and `run_test.ps1` is untouched. The whole rig can be deleted
without affecting the validated 100-scenario two-client suite.

## The one question it answers

> With **three** clients connected, does each client actually OBSERVE the other
> two peers' state — i.e. does the host's peer relay deliver — and does nobody crash?

Everything in the N-player branch up to this point is verified only at the unit
level: it compiles, the policy tables are asserted, and two-player behavior is
byte-identical. None of that proves three clients actually work. This rig does.

## Why it is a separate rig instead of a new scenario

The existing oracles are **pairwise** by construction — roughly 386 `$JoinFile`
references across 8 oracle files, every one comparing host-vs-join. Making that
suite three-way is a rewrite, and this experiment does not need it. One narrow
purpose-built oracle answers the question; the suite keeps doing its job.

## Pieces

| File | Role |
|---|---|
| `run_test3.ps1` | launches host + join1 + join2, strictly serialized, direct UDP loopback |
| `oracles/ThreePlayer.ps1` | the narrow verdict (14 gates) |
| `KENSHICOOP_DEBUG_OWNERS=1` | the observation the verdict reads (see below) |

### The observation that had to be added

Nothing in the log answered *"am I observing peer X at all?"* — the `[drive]`
lines carry the hand but not the author. So a working relay and a silent one
looked identical. `Replicator::logDriveTelemetry` now emits, every ~3 s under
`KENSHICOOP_DEBUG_OWNERS=1`:

```
[owners] driven total=9 distinct=2 byOwner: 0=4 2=5
```

That is the relay gate: a JOIN must show **≥ 2 distinct owners** (the host *and*
the other join). One owner means it only ever heard from the host — exactly the
pre-relay behavior. Gates no behavior; pure diagnostic, cleared hermetically by
`CoopHarness` like every other trace knob.

## Prerequisites

**Three independent installs.** Kenshi writes config/saves/logs into its own
folder, so two instances of one install fight over them. Upstream already splits
host/join this way; a third needs one more copy.

```powershell
scripts\setup_join_install.cmd "G:\steam\steamapps\common\Kenshi" "G:\KenshiCoop-test\Kenshi-Join"
scripts\setup_join_install.cmd "G:\steam\steamapps\common\Kenshi" "G:\KenshiCoop-test\Kenshi-Join2"
```

⚠️ Do **not** use the upstream default `%USERPROFILE%\Kenshi-Join` on this machine:
Kenshi is ~15 GB and C: has ~11 GB free. Both extra installs live on G:.

Then deploy the Harness DLL into all three:

```powershell
scripts\deploy.cmd "G:\steam\steamapps\common\Kenshi" Harness
scripts\deploy.cmd "G:\KenshiCoop-test\Kenshi-Join" Harness
scripts\deploy.cmd "G:\KenshiCoop-test\Kenshi-Join2" Harness
```

`run_test3.ps1` preflights all of this (exe, `RE_Kenshi.dll`, the deployed plugin,
and that the three paths are genuinely distinct) and fails loudly rather than
producing a run that looks like "the relay does not work".

## Use a TEST save, not a real one

⚠️ Learned the hard way on the first live run. The upstream suite uses **purpose-built
test saves** — `sync` (52 scenarios), `squad1` (26), `bedcage1`, `camp`, `jailed`,
`duel1` — not real play saves. `squad1` ships in this repo at `dist\kit\save\squad1`.

The first attempt here pointed at a real, heavily-modded save (Genesis, Dark UI and
friends) and the HOST **crashed during world load**, ~19 s after reaching in-game:

```
17.842 RE_Kenshi: In-game.
36.709 RE_Kenshi: Unhandled Exception Filter called
Error 36.709 RE_Kenshi: Main crash handler did not pick up exception
42.926 RE_Kenshi: Attempting emergency save...
```

Note what that costs you: a crash on load looks exactly like "the N-player changes
broke something", when the variable that actually changed was the save. Keep the
save fixed and clean, or an infra failure will be misread as a code failure.

Install the fixture into all three:

```powershell
robocopy dist\kit\save\squad1 "<install>\save\squad1" /E
```

## Running

```powershell
$env:KENSHICOOP_DEBUG_OWNERS = "1"
powershell -ExecutionPolicy Bypass -File scripts\run_test3.ps1 -Save "squad1" -Seconds 120
```

Output lands in `out\three_<timestamp>\` (`host.log`, `join1.log`, `join2.log`,
`verdict.json`). Exit code is non-zero on FAIL.

## Why direct UDP, not Steam

The Steam P2P tunnel is single-peer **by construction on the host side**:
`SteamP2P.cpp` keeps one `g_peer` SteamId and drops datagrams from anyone else.
Joins only ever talk to the host, so the star topology is fine for them — it is
the host that cannot fan out. N players is therefore reachable over direct UDP
only. The upstream regression suite already runs UDP on 127.0.0.1, so this rig
uses the same transport it validates.

## Load must be serialized

`run_test.ps1` learned this the hard way: two instances loading the same save
concurrently starve each other (a 12 s host load measured at 2.4 minutes, only
finishing once the other client exited). With three clients it is worse, so each
one waits for the previous to log `gameplay started` before launching, plus a
settle delay. Expect the run to take several minutes before the useful window.

## What it does NOT judge

Positional convergence, combat, inventory, save streaming — all of that is the
real suite's job and is still two-client only. A PASS here means "three clients
coexist and the relay delivers", not "three-player co-op works".

## Oracle self-check

The verdict logic was validated against synthetic logs before spending live runs:

| Case | Expected | Got |
|---|---|---|
| relay working (joins see 2 owners) | PASS | PASS |
| pre-relay (joins see only the host) | FAIL | FAIL — `need >= 2 distinct owners` |
| crash marker on a client | FAIL | FAIL — `nocrash_join2` |
