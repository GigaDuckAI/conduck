// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayTokenProbe.swift
//
// The DEFAULT GATEWAY as a subject `KeyArrivalMonitor` can poll: the secret-free
// probe, plus its projection into the monitor's erased reading.
//
// The polling itself lives in `KeyArrivalMonitor.swift` and is shared with the
// TTS subject. Its bounds are locked by design review; do not re-implement them.
//
// WHY THIS SUBJECT NEEDS IT. When the stored pointer names a gateway this device
// cannot send on, the app deliberately keeps the pointer and changes nothing —
// so that if the token is merely still crossing iCloud Keychain, the default
// resumes working on its own, with the user's choice intact. "On its own" is the
// promise this file keeps: iCloud Keychain posts no arrival event, so without a
// poll the app would go on believing the gateway is unusable until something
// unrelated reloaded settings, and the user would be nudged into replacing a
// choice that was about to start working.
//
// It is deliberately a SEPARATE monitor instance from the TTS one rather than a
// merged probe. The two wait on different secrets, and sharing a window would let
// one subject's exhaustion silence the other, or one subject's change restart the
// other — the indefinite polling the bounds exist to prevent.

import Foundation

/// Whether this device's default-for-new-chats pointer is waiting on a secret,
/// derived from the resolver rather than from a raw Keychain read.
///
/// The resolver is the right source because it already encodes every distinction
/// that matters here — parked vs chosen, unreadable vs absent — and re-deriving
/// those from slots would be a second opinion that could disagree with the one
/// the whole app reads.
///
/// SECRET-FREE by construction: it carries a ref and a three-valued reading, no
/// token, no URL, no key material.
struct DefaultGatewayTokenProbe: Sendable, Equatable {
    /// The pointer the verdict is about. Also the requirement identity: choosing
    /// a different default retires any window open on the old one.
    let ref: RemoteAgentRef
    let reading: KeyArrivalReading

    init(resolution: DefaultGatewayResolution) {
        ref = resolution.ref
        switch resolution {
        case .usable, .adopted, .bootstrapped:
            // The pointer can send. Nothing to wait for — and if a window was open
            // on it, this is the arrival that closes it.
            reading = .arrived

        case .defaultUnavailable(_, _, let pointerIsParked):
            // A pointer the USER chose that cannot send here is the case this
            // monitor exists for: a token still crossing iCloud reads exactly like
            // one that is gone, and only time tells them apart.
            //
            // A PARKED pointer is not. The app wrote it as a placeholder after a
            // Forget, so there is no user choice waiting to be restored — the
            // screens already ask the user to pick, and polling for the return of
            // a secret nobody is waiting on would spend a window on nothing.
            reading = pointerIsParked ? .notRequired : .degraded

        case .readingUnreliable:
            // Some gateway meets every non-Keychain requirement and is waiting only
            // on a token that does not read back — a blackout or a half-arrived
            // sync. Exactly what a bounded poll repairs, and the one verdict on
            // which nothing else in the app is allowed to act.
            reading = .degraded

        case .selectionRequired, .nothingConfigured, .setupUnfinished:
            // Nothing is waiting on a secret: the user has a choice to make, has
            // configured nothing, or left a setup unfinished. No key is in flight.
            reading = .notRequired
        }
    }
}

extension DefaultGatewayTokenProbe {
    /// This probe as the erased reading `KeyArrivalMonitor` polls.
    ///
    /// The requirement key is the pointer itself: re-pointing the default retires
    /// any window open on the old one, which is correct — the user has answered
    /// the question the window was asking.
    var arrivalReading: KeyArrivalProbeReading {
        KeyArrivalProbeReading(requirementKey: "gateway:\(ref.rawString)", reading: reading)
    }
}
