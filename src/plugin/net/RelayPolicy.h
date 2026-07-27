#ifndef KENSHICOOP_RELAY_POLICY_H
#define KENSHICOOP_RELAY_POLICY_H

// RelayPolicy.h - which packet types the HOST forwards to its OTHER peers.
//
// N-player experiment. The topology is a STAR: every join holds exactly ONE
// connection (to the host), so a join never reaches another join directly - the
// host forwards on its behalf. Every relayable packet already carries ownerId, so
// a receiver attributes it correctly without caring whether the host authored it
// or merely relayed it. That is why the relay can forward the RAW datagram and
// leave all 40+ local packet handlers untouched.
//
// Pure + header-only (Wire.h only, no engine/game/Windows deps, C++03/v100-safe)
// so prototest can assert the classification without linking the net layer - the
// same shape as Inbound.h's world-state vs session-preserving split.
//
// SAFETY: with two players the relay is a NO-OP, because the only connected peer
// is the sender and the sender is always skipped. It cannot regress the validated
// two-player path; it only adds behavior once a third peer exists.

#include "../../netproto/Wire.h"

namespace coop {

// True for state a peer AUTHORS that every other peer must observe.
//
// Excluded on purpose:
//   - handshake / per-peer control (HELLO/WELCOME/LEAVE)
//   - pairwise clock sync (TIME_PING/PONG must stay host <-> that one peer, or the
//     relayed echo would corrupt a third party's offset estimate)
//   - join->host REQUESTS the host answers itself (SPEED_REQ, SPAWN_REQ, SAVE_REQ,
//     LOAD_REQ, LOAD_NACK): relaying would ask the wrong party
//   - host-AUTHORED channels (SPEED_SET, STEALTH, SPAWN_INFO, TIME, PROD,
//     NPC_CENSUS, RESEARCH): the host already broadcasts these and a join does not
//     author them, so a relayed copy could only be spoof or noise
//   - the save/load bulk transfer (SAVE_BEGIN/FILE/DONE/ACK, LOAD_GO): host <-> ONE
//     peer by construction, and SaveXfer is still one global state machine
//   - CAM_HINT: join->host only, and the HOST is its only consumer - it decides
//     what to stream for everyone. A join drives peer SQUAD bodies, which the
//     tab-leader spheres already anchor, so a peer's viewpoint tells it nothing
//     it acts on. Relaying it was tried and reverted: the receiving side never
//     drains the queue (the drain lives in the host branch), so it was pure dead
//     weight on the wire. Making joins consume it would change what each client
//     streams - a gameplay-visible change with no evidence it is wanted.
//   - COMBAT_HIT: join->host BY DESIGN. The host applies the damage
//     authoritatively and the result mirrors back over the vitals channel.
//     Relaying would let a second peer apply the same damage again (double-count).
inline bool relayToPeers(u8 type) {
    switch (type) {
        case PKT_ENTITY_BATCH:      // owner-tagged state stream, explicitly bidirectional
        case PKT_EVENT:             // KO/death/revive/furniture/recruit transitions
        case PKT_INV_SNAPSHOT:      // owner-authoritative container contents
        case PKT_WORLD_ITEM:        // world-item snapshot (netId space is per-sender)
        case PKT_WORLD_ITEM_REMOVE:
        case PKT_WORLD_DROP:        // conservation intents (relocate, never fabricate)
        case PKT_WORLD_PICKUP:
        case PKT_MEDICAL:           // owner-authoritative vitals
        case PKT_TREATMENT:         // healer -> owner delta (raise-only, idempotent)
        case PKT_STATS:             // owner-authoritative CharStats
        case PKT_MONEY:             // owner-of-tab wallet
        case PKT_FACTION:           // symmetric channel
        case PKT_DOOR:              // symmetric channel
        case PKT_BUILD_PLACE:       // placer-authoritative building lifecycle
        case PKT_BUILD_STATE:
        case PKT_BUILD_DOOR:
        case PKT_BUILD_REMOVE:
        case PKT_INV_XFER:          // cross-owner transfer intent
            return true;
        default:
            return false;
    }
}

} // namespace coop

#endif // KENSHICOOP_RELAY_POLICY_H
