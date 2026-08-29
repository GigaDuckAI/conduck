// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetsSnapshotObserver.swift
//
// Share-Extension "Send to" picker — the lightweight app-owned observer that
// keeps the appex's `share-targets.json` snapshot fresh. It subscribes to the
// two buses that change a picker target:
//   - `.conversationsDidChange` — a conversation was created / a turn appended /
//     a CloudKit remote change merged → the "recent conversations" rows shift.
//   - `.settingsDidChangeRemotely` — a gateway was added/removed/edited or the
//     default changed → the configured-gateways list shifts.
// On either, it asks `ShareTargetsSnapshotWriter` to regenerate. The writer is
// an actor, but actor isolation does NOT serialize overlapping triggers —
// actors are reentrant across `await` and `regenerate()` suspends — so the
// writer coalesces explicitly (one build in flight plus one trailing build).
// That bound lives there rather than here, so every caller inherits it.
//
// Both iOS (`ConduckApp`) and macOS (`AppDelegate.applicationDidFinishLaunching`)
// instantiate + `start()` one of these for the app's lifetime — each platform's
// share extension reads the snapshot the writer keeps fresh. On watchOS the
// writer's `regenerate()` is a NO-OP (no share sheet), so were it ever started
// there it would fire harmlessly; the Watch app does not instantiate it.

import Foundation

/// Owns the NotificationCenter subscriptions that trigger snapshot regeneration.
/// Held for the app's lifetime by `ConduckApp` (a stored property) so its
/// observer tokens aren't deallocated. `@MainActor` — it only adds observers +
/// hops into the writer actor; no shared mutable state crosses threads.
@MainActor
final class ShareTargetsSnapshotObserver {

    private var tokens: [NSObjectProtocol] = []

    /// Begin observing. Idempotent — a second call is a no-op (the tokens are
    /// already installed), so an accidental double-`start()` doesn't double-fire.
    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.conversationsDidChange, .settingsDidChangeRemotely]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                // Hop into the writer actor. Actor isolation does NOT serialize
                // overlapping triggers — actors are reentrant across `await`, and
                // `regenerate()` suspends — so the writer coalesces explicitly:
                // one build in flight plus one trailing build. A burst therefore
                // costs a bounded number of concurrent store reads, not one per
                // post. `regenerate()` is a no-op on watchOS.
                Task { await ShareTargetsSnapshotWriter.shared.regenerate() }
            }
            tokens.append(token)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
