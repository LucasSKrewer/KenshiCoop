#ifndef KENSHICOOP_SEQ_GUARD_H
#define KENSHICOOP_SEQ_GUARD_H

// SeqGuard.h - the stale-row guard, keyed PER SENDER.
//
// Wire.h documents every change-gated channel's `seq` as "per-sender monotonic",
// and ChangeGate.h's gateSeqAccept() says the same. But the rows stored a single
// scalar seqSeen, so the guard was really per-ROW: with two senders holding
// INDEPENDENT counters, whichever sender ran a lower seq had its rows rejected as
// "stale" - permanently, since seqSeen only ever moves up. Symptom: one player's
// faction/door/building/production/research changes silently stop crossing while
// the other player's keep working. Harmless with a single join (one counter), a
// silent desync as soon as a second one exists.
//
// This keeps ONE row per key (these are shared world-state rows - two senders
// describe the SAME logical door, not two doors) and tracks the last accepted seq
// separately per sender, which is what the wire contract always meant.
//
// Pure + header-only (no engine/game/Windows deps, C++03/v100-safe) so prototest
// can assert the semantics directly, same as ChangeGate.h / Inbound.h.

#include "../../netproto/Wire.h"

namespace coop {
namespace sync {

class SeqGuard {
public:
    // ENet is created with 8 peer slots (NetLink), so 8 distinct senders is the
    // transport's own ceiling - the table can never legitimately overflow.
    enum { MAX_SENDERS = 8 };

    SeqGuard() : n_(0) {
        for (unsigned i = 0; i < MAX_SENDERS; ++i) { owner_[i] = 0; seq_[i] = 0; }
    }

    // Accept iff this is the first row ever seen from ownerId, or the seq is
    // strictly newer than the last accepted FROM THAT SENDER. Stamps on accept,
    // so a caller cannot forget to (the old two-step
    // "gateSeqAccept(...) then row.seqSeen = p.seq" invited exactly that).
    //
    // Same predicate as ChangeGate.h's gateSeqAccept, just scoped per sender:
    //   accept iff seen == 0 || incoming > seen
    //
    // Table full (never reachable below 8 senders): fail OPEN. A duplicate row is
    // self-correcting - the channels are idempotent snapshots - whereas failing
    // closed would silently freeze a player's world state, the very bug this fixes.
    bool accept(u32 ownerId, u32 incomingSeq) {
        for (unsigned i = 0; i < n_; ++i) {
            if (owner_[i] != ownerId) continue;
            if (seq_[i] != 0 && incomingSeq <= seq_[i]) return false;
            seq_[i] = incomingSeq;
            return true;
        }
        if (n_ < (unsigned)MAX_SENDERS) {
            owner_[n_] = ownerId;
            seq_[n_]   = incomingSeq;
            ++n_;
        }
        return true; // first sight from this sender (or fail-open when full)
    }

    // Peer left: drop its slot so a reconnect (which restarts its counter low)
    // is not judged against the old session's high-water mark. Without this a
    // rejoining player's rows would be rejected until its seq climbed back past
    // where it left off.
    void forget(u32 ownerId) {
        for (unsigned i = 0; i < n_; ++i) {
            if (owner_[i] != ownerId) continue;
            owner_[i] = owner_[n_ - 1];
            seq_[i]   = seq_[n_ - 1];
            --n_;
            return;
        }
    }

    void reset() { n_ = 0; }

    // Diagnostics / tests.
    unsigned senders() const { return n_; }
    u32 seqFor(u32 ownerId) const {
        for (unsigned i = 0; i < n_; ++i)
            if (owner_[i] == ownerId) return seq_[i];
        return 0;
    }

private:
    u32      owner_[MAX_SENDERS];
    u32      seq_[MAX_SENDERS];
    unsigned n_;
};

} // namespace sync
} // namespace coop

#endif // KENSHICOOP_SEQ_GUARD_H
