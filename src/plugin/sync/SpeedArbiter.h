#ifndef KENSHICOOP_SPEED_ARBITER_H
#define KENSHICOOP_SPEED_ARBITER_H

// SpeedArbiter.h - the consensus game-speed rule, as pure logic.
//
// Requests use ONE number: the multiplier, with 0 meaning paused and -1 meaning
// "no vote yet". min() over the votes is what gives the intended asymmetry:
//   ANY player can pause or slow down; ALL must agree to raise.
// Combat caps the result at 1x, and the cap can never force an UNPAUSE, because
// pause (0) is already below 1 and min-semantics keep it.
//
// Extracted so the rule the players actually FEEL ("why is the game slow?") is
// asserted in prototest instead of only being reachable through a live two-client
// scenario. Upstream computed it inline over a single speedPeerReq_ scalar, which
// with two joins degraded into "whoever spoke last" - the accumulator below is the
// N-player form, and is byte-identical for a single peer (asserted).
//
// Pure + header-only, C++03/v100-safe.

namespace coop {
namespace sync {

class SpeedArbiter {
public:
    // myReq: this client's vote (-1 = none yet, treated as 1x - upstream's
    // default when a client has not voted). myCombat: own squad fighting.
    SpeedArbiter(float myReq, bool myCombat)
        : eff_(myReq >= 0.0f ? myReq : 1.0f),
          minPeer_(-1.0f),
          combat_(myCombat) {}

    void addPeer(float req, bool combat) {
        if (req >= 0.0f) {
            if (req < eff_) eff_ = req;
            if (minPeer_ < 0.0f || req < minPeer_) minPeer_ = req;
        }
        if (combat) combat_ = true;   // a peer's flag counts even with no vote yet
    }

    // The arbitrated multiplier: min of every vote, then capped at 1x while
    // anyone fights. Never unpauses (0 stays 0).
    float effective() const {
        float e = eff_;
        if (combat_ && e > 1.0f) e = 1.0f;
        return e;
    }

    bool  combat() const  { return combat_; }
    // Lowest peer vote, or -1 when no peer has voted (diagnostics/logging).
    float minPeer() const { return minPeer_; }

private:
    float eff_;
    float minPeer_;
    bool  combat_;
};

} // namespace sync
} // namespace coop

#endif // KENSHICOOP_SPEED_ARBITER_H
