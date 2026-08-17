// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayResolution.swift
//
// What the device-local "Default for new chats" actually IS right now, as a
// value with eight distinguishable answers.
//
// One ref cannot say eight things. A bare `RemoteAgentRef` answers "which
// gateway" and nothing else, so every caller that received one had to guess the
// situation behind it — and the picker-less lanes (Action Button, menu bar,
// CarPlay, the wrist, the share target) guessed the worst reading available:
// they took a pointer at a gateway that is not set up on THIS device, while five
// others work fine, and reported it as `remoteAgentNotConfigured` — "No personal
// AI gateway is configured". On a device with five verified gateways that is
// simply false, and the user has no way to tell which sentence is the lie.
//
// So the resolver returns the SITUATION, and each surface decides what to say
// about it. Three of the cases exist for reasons a later reader will otherwise
// try to simplify away:
//
//   - `.brokenDefault` guesses NOTHING. Silently moving a voice capture from the
//     work agent to a scratch model is a trust break, not a kindness;
//     `GatewayGate.swift` argues the blind-fallback case out at length and asks
//     that it not be re-proposed. The projection therefore keeps the BROKEN ref,
//     so a send fails closed on the gateway the user actually chose and the
//     failure can be explained honestly.
//
//   - `.selectionRequired` persists NOTHING. A pointer the device invented is
//     indistinguishable, one launch later, from one the user chose — and only
//     the user can tell them apart. An unannounced guess among five working
//     gateways, decided by whichever backend `RemoteAgentBackend.allCases`
//     happens to declare first, becomes permanent because nothing ever revisits
//     it. Asking is one tap; guessing is forever.
//
//   - `.readingUnreliable` and `.setupUnfinished` are SEPARATE cases because
//     "you cannot trust what you just read" and "you can trust it, the user
//     simply never finished" are opposite facts. Collapsed into one word, every
//     downstream silence rule keyed on it is either too loud (a Keychain
//     blackout accusing a healthy device of a broken default) or too quiet
//     (deleting a correct "finish this one" row for every half-set-up first-run
//     user). Split, each rule is sayable.
//
// Pure Foundation, no storage access, and a sibling of `GatewayGate.swift` and
// `NewChatGatewaySeed.swift` for the same reason those are pure: the surfaces
// that consume this include `#if os(macOS)` views the iOS-Simulator suite never
// compiles, so logic written inline there is never exercised by a test. Logic
// the views cannot reach lives here, where it can be locked down.
//
// No user-facing strings live here. Every consuming surface owns its own copy,
// because the same verdict is worded differently in a Settings footer, a
// Diagnostics row and a headless failure notification.

import Foundation

/// The eight situations this device's "Default for new chats" can be in.
enum DefaultGatewayResolution: Sendable, Equatable {
    /// The stored pointer is a member of the configured set. The common case:
    /// say nothing, do nothing.
    case usable(RemoteAgentRef)

    /// A stored pointer could not send, exactly one gateway could, the Keychain
    /// was PROVEN readable, and no other gateway was one token away from
    /// working. That one was adopted and PERSISTED, and a one-shot notice was
    /// written. Carries the ref it replaced so a surface can name both.
    case adopted(ref: RemoteAgentRef, replacing: RemoteAgentRef)

    /// There was NO stored pointer, exactly one gateway could send, and the same
    /// two safety gates passed — so a pointer was filled in and PERSISTED.
    /// Nothing the user chose was overridden, so nothing is announced and no
    /// notice is written.
    case bootstrapped(RemoteAgentRef)

    /// A pointer is stored, it cannot send, and the roster genuinely offers
    /// alternatives. Nothing is guessed and nothing is persisted: surface it,
    /// name `broken`, offer `candidates`.
    ///
    /// `pointerIsParked` travels INSIDE the verdict rather than beside it. It is
    /// the difference between "the gateway you chose stopped working" and "the
    /// app wrote a placeholder here one step after you forgot a different
    /// gateway", and every surface that names the default has to make that
    /// distinction — the chat banner, the Settings selector, Diagnostics,
    /// CarPlay, the wrist and the headless lanes. Carried as a second value
    /// beside the verdict it was two facts a consumer could receive one of;
    /// carried inside it, a consumer that has the verdict cannot fail to have
    /// the flag.
    case brokenDefault(broken: RemoteAgentRef, candidates: [RemoteAgentRef], pointerIsParked: Bool)

    /// There is NO stored pointer and the device cannot honestly infer one:
    /// either two or more gateways can send, or exactly one can but another is
    /// still one token away from working. Nothing is persisted, nothing is
    /// guessed, nothing is announced as a repair — the user is asked to choose.
    case selectionRequired(candidates: [RemoteAgentRef])

    /// Nothing can send, nothing anywhere holds partial setup, and nothing is
    /// waiting on a token. The honest first-run state, where the existing
    /// empty-state copy and `remoteAgentNotConfigured` are exactly right.
    case nothingConfigured(pointer: RemoteAgentRef)

    /// Nothing can send AND the reading cannot be trusted: at least one gateway
    /// meets every non-Keychain requirement and is waiting only on a token that
    /// does not read back — a `kSecAttrAccessibleAfterFirstUnlock` blackout, or
    /// a half-arrived iCloud Keychain sync.
    ///
    /// NOBODY may refuse a capture, show a broken-default banner, emit an
    /// accusatory Diagnostics finding, or repair or persist anything on this
    /// verdict. Fall through and let the send fail closed on its own, which is
    /// the one outcome that costs the user nothing if the reading was wrong.
    case readingUnreliable(pointer: RemoteAgentRef)

    /// Nothing can send and nothing is waiting on a token, but half-finished
    /// setup residue exists — a stored URL, model, scheme or cert pin somewhere.
    /// The ordinary abandoned-setup state, and the reading IS trustworthy, so
    /// this is the case that must NOT be suppressed: Diagnostics' "finish this
    /// one" rows belong here.
    case setupUnfinished(pointer: RemoteAgentRef)

    /// The COMPATIBILITY PROJECTION — a ref for display, and for the legacy
    /// holders that need a non-optional value.
    ///
    /// For `.brokenDefault` this is the BROKEN ref, deliberately: a send then
    /// fails closed on the gateway the user actually chose, which is the only
    /// outcome that can be explained honestly. For `.selectionRequired` it is
    /// the documented built-in fallback, purely so those holders have something
    /// to hold.
    ///
    /// NEVER a licence to route. Anything that MINTS switches on the resolution
    /// itself, or reads `canSend`.
    var ref: RemoteAgentRef {
        switch self {
        case .usable(let ref): return ref
        case .adopted(let ref, _): return ref
        case .bootstrapped(let ref): return ref
        case .brokenDefault(let broken, _, _): return broken
        case .selectionRequired: return .builtin(Constants.remoteAgentDefaultBackendDefault)
        case .nothingConfigured(let pointer): return pointer
        case .readingUnreliable(let pointer): return pointer
        case .setupUnfinished(let pointer): return pointer
        }
    }

    /// Whether `ref` can actually take a turn. True ONLY for `.usable`,
    /// `.adopted` and `.bootstrapped` — the three cases where the pointer is a
    /// member of the configured set by construction.
    var canSend: Bool {
        switch self {
        case .usable, .adopted, .bootstrapped: return true
        case .brokenDefault, .selectionRequired, .nothingConfigured,
             .readingUnreliable, .setupUnfinished: return false
        }
    }

    /// Whether the stored pointer is a placeholder the APP parked after a
    /// Forget, rather than a gateway the user chose.
    ///
    /// Only `.brokenDefault` can report it, and that is the whole set that
    /// matters: a park writes a BUILT-IN pointer, so the pointer exists (never
    /// `.selectionRequired`), and the marker retires the moment that pointer
    /// becomes able to send (never `.usable` / `.adopted` / `.bootstrapped`).
    /// What is left is the verdicts where nothing can send at all, and those
    /// name no gateway in the first place.
    var pointerIsParked: Bool {
        switch self {
        case .brokenDefault(_, _, let parked): return parked
        case .usable, .adopted, .bootstrapped, .selectionRequired,
             .nothingConfigured, .readingUnreliable, .setupUnfinished: return false
        }
    }

    /// The gateway that let the user down: `.brokenDefault`'s `broken`,
    /// `.adopted`'s `replacing`. Nil for every case a surface should stay quiet
    /// about — including `.readingUnreliable`, where naming a gateway would be
    /// an accusation made by a locked device, and a PARKED `.brokenDefault`,
    /// where the pointer is a placeholder the user never chose and so cannot
    /// have let them down.
    var brokenRef: RemoteAgentRef? {
        switch self {
        case .brokenDefault(let broken, _, let parked): return parked ? nil : broken
        case .adopted(_, let replacing): return replacing
        case .usable, .bootstrapped, .selectionRequired, .nothingConfigured,
             .readingUnreliable, .setupUnfinished: return nil
        }
    }

    /// The gateways a surface may offer as the choice — `.brokenDefault`'s and
    /// `.selectionRequired`'s candidates, empty elsewhere.
    var candidates: [RemoteAgentRef] {
        switch self {
        case .brokenDefault(_, let candidates, _): return candidates
        case .selectionRequired(let candidates): return candidates
        case .usable, .adopted, .bootstrapped, .nothingConfigured,
             .readingUnreliable, .setupUnfinished: return []
        }
    }

    /// True for `.brokenDefault` and `.selectionRequired` — the two states whose
    /// only exit is the user picking a gateway. Everything else either works, is
    /// already repaired, or is waiting on setup the app cannot do for them.
    var needsUserChoice: Bool {
        switch self {
        case .brokenDefault, .selectionRequired: return true
        case .usable, .adopted, .bootstrapped, .nothingConfigured,
             .readingUnreliable, .setupUnfinished: return false
        }
    }
}

/// A device-local record that THIS device repaired its own default.
///
/// Names are captured AT WRITE TIME, not resolved on read: the replaced gateway
/// may be a custom that is gone by the time anyone reads this, and "…is no
/// longer set up" beside a raw UUID is worse than no notice at all.
///
/// Names ONLY — never a URL, never anything token-shaped. `Codable` so it
/// persists as JSON in the App Group; decode with `try?` so a ref that stops
/// parsing drops the notice rather than trapping.
struct DefaultGatewayAdoptionNotice: Codable, Sendable, Equatable {
    let adoptedRef: RemoteAgentRef
    let adoptedName: String
    let previousRef: RemoteAgentRef
    let previousName: String
}
