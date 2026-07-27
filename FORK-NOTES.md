# About this fork

This is a personal, **experimental** fork of
[nhoral/KenshiCoop](https://github.com/nhoral/KenshiCoop). All credit for the mod
belongs to **nhoral** — the co-op design, the sync doctrine, the validation
harness and effectively all of the code are theirs. Licensed AGPL-3.0, same as
upstream.

**This is not an official build and not a replacement for upstream.** If you want
a working co-op mod for Kenshi, get the real thing from
[the upstream releases](https://github.com/nhoral/KenshiCoop/releases/latest).

## Why it exists

I wanted to see whether the sync architecture could carry **more than two
players** (a group of five, in my case). The upstream author was asked about
4-player support in
[issue #2](https://github.com/nhoral/KenshiCoop/issues/2) and declined for good
reasons: they don't want the reconciliation problem between joining clients, and
they want to avoid requiring a server — sensible calls, and they said they'd
revisit it once two-player is stable.

So this is not a request, a complaint, or a competing project. It's the normal way
to explore a direction the maintainer deliberately isn't taking, **without
pressuring them about it**. Two-player stability is their goal and it's the right
one.

## What diverges from upstream

Branch `experimento-3-jogadores`:

1. **Peer relay** (`src/plugin/net/RelayPolicy.h`, `NetLink.cpp`) — the host
   forwards peer-authored state to its *other* peers. Upstream deliberately does
   not: join-authored state reaches only the host, which is the reason for the
   two-player guard in `NetLink.cpp`. Implemented as raw-datagram forwarding at a
   single choke point (every packet already carries `ownerId`), with an explicit
   per-type policy and 42 unit assertions locking the table. No-op with two
   players — the only connected peer is the sender, which is always skipped.
2. **Interest-anchor ceiling** (`game/Engine.h`) — `interestCenters()` capped tab
   leader spheres at 2; now a named `MAX_INTEREST_LEADERS`. A player whose squad
   tab gets no anchor has no NPCs streamed around them at all.
3. **Per-sender stale-row guard** (`src/plugin/sync/SeqGuard.h`) — this one is
   arguably a **plain bug fix, not an N-player change**, and may be of interest
   upstream regardless of player count. `Wire.h` and `ChangeGate.h` both document
   every change-gated channel's `seq` as *"per-sender monotonic"*, but the rows
   stored a single scalar `seqSeen`, making the guard per-*row*. Two senders with
   independent counters starve each other: the lower-seq sender's faction / door /
   building / production / research rows are rejected as stale permanently. With
   one sender the new guard is byte-identical to the old predicate (asserted).

4. **Per-peer leave cleanup** (`ReplicatorCore.cpp`, `Plugin.cpp`) — any peer
   leaving used to run the whole-session `clearPeerReplicationState()`, which with
   three players wipes the *survivors'* proxies, interp buffers and drive maps too
   (upstream's own comment: *"Runs once per leave batch (we support a single
   peer)"*). Now each departed peer is swept individually and the full reset only
   fires when the last one leaves — identical to upstream at two players, where the
   departing peer always *is* the last one. Prerequisite fixed along the way:
   `ingest()` discarded the authoring `ownerId`, so the receiver could not answer
   "whose driven body is this?"; it is now stamped on `Driven::ownerId`.

   ⚠️ If a 3-player scenario is ever added to the harness, `scripts/oracles/World.ps1`
   needs to learn the new `[leave] per-peer sweep owner=` line — it currently
   requires `[leave] cleared proxies=` after a drop, which only the full-reset path
   emits. Unchanged for every existing (2-player) scenario.

Still not N-ready, and the guard in `NetLink.cpp` still fails loudly past two
players: `SaveXfer` is one global send/receive state machine, some peer fields are
still singular (`speedPeerReq_`/`speedPeerCombat_` let two joins overwrite each
other's speed vote, `peerCam_` is one camera-hint slot, `pinPeer_`/`ownerClassForHand`
are binary "mine vs THE peer"), and the Steam P2P tunnel is single-peer by
construction on the **host** side — so N players is only reachable over direct UDP,
not the Steam transport.

## Build note

Worth knowing if you clone this: the documented setup (`KenshiLib_Examples_deps`)
does **not** compile upstream as-is. The deps snapshot pins KenshiLib 0.4.0, where
`CraftingItem` is only forward-declared while used in a `std::deque` — VC10's STL
requires a complete type. The relevant header fixes exist only on KenshiLib's
master. Separately, `CombatClass.h` moved to `kenshi/combat/` in June while the
plugin still includes `<kenshi/CombatClass.h>`. I build against master's headers
plus a one-line forwarder. This looks like something any new contributor would
hit — it's a build-setup gap, not anyone's mistake.
