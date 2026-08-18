// SPDX-License-Identifier: Apache-2.0

// Conduck
// KeyArrivalMonitor.swift
//
// iCloud Keychain delivers a synced secret OPPORTUNISTICALLY (minutes to hours)
// and posts NO app-visible arrival notification — so a device still waiting on
// one has no event to converge on. Whatever depends on that secret stays quietly
// degraded until the user happens to touch Settings.
//
// This is the bounded workaround, shared by every subject that can be waiting:
// WHILE the app is active AND the subject reads as degraded, re-read on a short exponential
// backoff (~5 min window per activation). The moment a poll finds the secret,
// post `.settingsDidChangeRemotely` ONCE — that single notification already fans
// out everything downstream (`SettingsViewModel.loadSettings()` and, on iPhone,
// `PhoneSessionManager`'s debounced Watch re-broadcast).
//
// TWO subjects share this one mechanism (see `KeyArrivalMonitors`), and sharing
// is the point: the bounds below were settled by design review, and a second
// hand-rolled poller would be a second place for them to be got wrong. Each
// subject gets its OWN instance, never a merged probe — one subject's window
// exhausting must not silence the other's.
//
// Bounds (locked by design review — NOT tunables to relax):
//   - Foreground-active only. `willResignActive` cancels the window (covers
//     Control Center pulls and interruptions, not just backgrounding).
//   - One finite backoff schedule per activation; when it exhausts, the
//     monitor stays quiet until the app re-activates or the requirement
//     fingerprint changes. Unrelated settings changes NEVER restart the window
//     — that would make it effectively indefinite.
//   - Posts only from a TIMER-DISCOVERED degraded→arrived transition. A
//     notification-triggered re-evaluation never posts (a local key paste
//     already posted; re-posting would double the fan-out).
//   - Secret-free: only the typed reading (no key material) ever leaves the
//     actor read. Nothing is logged or persisted.

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Probe contract

/// What one poll read found. Deliberately three-valued: "nothing to wait for"
/// and "it arrived" both END a window, but only the second is a transition worth
/// telling the rest of the app about.
enum KeyArrivalReading: Sendable, Equatable {
    /// The secret is readable now — the transition this whole file exists for.
    case arrived
    /// Nothing is waiting on a secret (keyless provider, nothing configured).
    case notRequired
    /// Missing, or the Keychain would not return it. Both are repairable by
    /// waiting: a `kSecAttrAccessibleAfterFirstUnlock` blackout is a legitimate
    /// transient, and an unsynced item is exactly what this polls for.
    case degraded
}

/// One poll read: what is outstanding, and whether it has landed.
///
/// `requirementKey` is an opaque STRING rather than a generic `Equatable`
/// associated type, and the monitor below is a plain class rather than one
/// generic over a probe protocol. Two reasons, in order:
///
///   - The module compiles under MainActor default isolation, so a synthesized
///     `Equatable` is itself MainActor-isolated and cannot satisfy the `Sendable`
///     bound a generic probe parameter would carry. Every workaround (marking
///     subject types `nonisolated`, hand-writing conformances) spreads isolation
///     annotations through value types that have no other reason for them.
///   - The monitor only ever asks ONE question of a requirement: is it still the
///     same one? A string answers that exactly. Nothing here inspects, orders or
///     decodes it, so the extra type machinery bought no safety.
///
/// The key must be stable for one outstanding requirement and different for any
/// other — it decides when a poll window survives and when it is retired.
///
/// A composed key therefore owes what the typed pair it replaced gave for free:
/// no two distinct requirements may render the same string. Both composers meet
/// that by building from REGISTRY-ISSUED identifiers only — a backend id, a
/// `stt.apiKey.<presetID>` slot, a `custom_<uuid>` ref — none of which can
/// contain the `|` separator or be empty. Compose a key from user-entered text
/// and that guarantee is gone.
struct KeyArrivalProbeReading: Sendable, Equatable {
    let requirementKey: String
    let reading: KeyArrivalReading
}

// MARK: - Monitor

@MainActor
final class KeyArrivalMonitor {
    /// Coarse run state — exposed for tests; never persisted.
    enum RunState: Equatable {
        case idle
        case polling(requirementKey: String)
        /// The schedule ran dry for this requirement. Stays exhausted until the
        /// app re-activates or the requirement changes.
        case exhausted(requirementKey: String)
    }

    /// Why an evaluation is happening — decides whether an existing window may be
    /// restarted (activation / manual re-arm) or must be left alone (settings
    /// churn with an unchanged requirement).
    enum EvaluateReason {
        case activation
        case settingsChange
        case manual
    }

    /// Exponential backoff, ~5.25 min total. Six Keychain reads per activation
    /// window is the whole battery cost.
    static var backoffSchedule: [Duration] {
        [.seconds(5), .seconds(10), .seconds(20),
         .seconds(40), .seconds(80), .seconds(160)]
    }

    private(set) var state: RunState = .idle

    // Test seams — production values are supplied by `KeyArrivalMonitors`.
    private let probeProvider: @Sendable () async -> KeyArrivalProbeReading
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let onKeyArrival: @MainActor () -> Void

    private var pollTask: Task<Void, Never>?
    /// Generation stamp per poll window. Cancellation alone is insufficient: a
    /// cancelled task can already be past its cancellation check and awaiting the
    /// actor's Keychain read — the stale generation makes its late resume a no-op
    /// instead of a wrong-window post.
    private var generation = 0
    private var started = false
    private var appIsActive = false

    init(
        probeProvider: @escaping @Sendable () async -> KeyArrivalProbeReading,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onKeyArrival: @escaping @MainActor () -> Void = {
            SettingsManager.shared.postSettingsDidChangeRemotely()
        }
    ) {
        self.probeProvider = probeProvider
        self.sleeper = sleeper
        self.onKeyArrival = onKeyArrival
    }

    /// Register lifecycle observers. Idempotent — a second call is a no-op.
    /// Called once per instance from app wiring (`ConduckApp.init`); the first
    /// `didBecomeActive` after launch performs the initial evaluation, so there is
    /// no separate "evaluate now" at start (a launch directly into the background
    /// must not poll).
    func start() {
        guard !started else { return }
        started = true

        #if canImport(UIKit)
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        let willResignActive = UIApplication.willResignActiveNotification
        #elseif canImport(AppKit)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        let willResignActive = NSApplication.willResignActiveNotification
        #endif

        NotificationCenter.default.addObserver(
            forName: didBecomeActive, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidBecomeActive() }
        }
        NotificationCenter.default.addObserver(
            forName: willResignActive, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillResignActive() }
        }
        NotificationCenter.default.addObserver(
            forName: .settingsDidChangeRemotely, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSettingsChanged() }
        }
    }

    // MARK: - Lifecycle handlers (internal for tests — notifications are the
    // production entry points)

    func handleDidBecomeActive() {
        appIsActive = true
        Task { await evaluate(reason: .activation) }
    }

    func handleWillResignActive() {
        // `willResignActive`, not `didEnterBackground` — Control Center,
        // interruptions, and an inactive window must all stop the window.
        appIsActive = false
        cancelWindow()
        state = .idle
    }

    func handleSettingsChanged() {
        Task { await evaluate(reason: .settingsChange) }
    }

    // MARK: - Evaluation

    /// Re-derive the degraded predicate and reconcile the poll window.
    /// NEVER posts — posting is exclusively the poll loop's transition discovery,
    /// so notification-triggered evaluations can't echo a local key paste's own
    /// fan-out back into a second one.
    func evaluate(reason: EvaluateReason) async {
        guard appIsActive else { return }
        let probe = await probeProvider()
        guard appIsActive else { return }   // resigned while probing

        guard probe.reading == .degraded else {
            // Healthy (or nothing to wait for) — whatever window existed is obsolete.
            cancelWindow()
            state = .idle
            return
        }

        let key = probe.requirementKey
        switch reason {
        case .activation, .manual:
            // A genuine re-activation (or the user's explicit Check again) re-arms
            // a fresh window even for the same requirement.
            beginWindow(key)
        case .settingsChange:
            switch state {
            case .polling(let current) where current == key,
                 .exhausted(let current) where current == key:
                // Unrelated settings churn — leave the window (or its exhaustion)
                // alone, else churn makes polling indefinite.
                return
            default:
                beginWindow(key)
            }
        }
    }

    // MARK: - Poll window

    private func cancelWindow() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
    }

    private func beginWindow(_ requirementKey: String) {
        cancelWindow()
        let gen = generation
        state = .polling(requirementKey: requirementKey)

        pollTask = Task { [weak self] in
            guard let self else { return }
            for delay in Self.backoffSchedule {
                do {
                    try await self.sleeper(delay)
                } catch {
                    return  // cancelled mid-sleep — window owner moved on
                }
                guard !Task.isCancelled, self.generation == gen else { return }

                let probe = await self.probeProvider()
                // Re-check AFTER the await: a requirement switch or resign-active
                // may have retired this window while the read was in flight.
                guard !Task.isCancelled, self.generation == gen else { return }
                guard probe.requirementKey == requirementKey else {
                    // Requirement changed under the window; the settings change
                    // that caused it owns the restart decision.
                    return
                }

                switch probe.reading {
                case .arrived:
                    // THE transition this whole file exists for: the synced secret
                    // arrived with no OS event. One post fans out everything.
                    self.state = .idle
                    self.pollTask = nil
                    self.onKeyArrival()
                    return
                case .notRequired:
                    self.state = .idle
                    self.pollTask = nil
                    return
                case .degraded:
                    continue
                }
            }
            guard self.generation == gen else { return }
            self.state = .exhausted(requirementKey: requirementKey)
            self.pollTask = nil
        }
    }
}

// MARK: - The production instances

/// The app's key-arrival monitors, one per subject.
///
/// SEPARATE INSTANCES, never one merged probe: the active TTS voice and the
/// default gateway wait on different secrets for different reasons, and a single
/// window would let one subject's exhaustion silence the other's — or let one
/// subject's change restart the other's window, which is exactly the indefinite
/// polling the bounds forbid.
@MainActor
enum KeyArrivalMonitors {
    /// The active cloud TTS provider's key. Until it lands, chat silently speaks
    /// Apple (the never-go-silent contract) and the Watch, fed second-hand from
    /// this phone, does the same.
    static let tts = KeyArrivalMonitor(
        probeProvider: { await SettingsManager.shared.activeTTSKeyProbe().arrivalReading }
    )

    /// The default gateway's token. Until it lands, the picker-less lanes (Action
    /// Button, menu bar, CarPlay, the wrist, the share target) have nowhere to
    /// send, and the Personal AI screen shows a default it cannot use.
    static let defaultGateway = KeyArrivalMonitor(
        probeProvider: { await SettingsManager.shared.defaultGatewayTokenProbe().arrivalReading }
    )

    /// Start both. One call site (`ConduckApp`), so neither can be forgotten.
    static func startAll() {
        tts.start()
        defaultGateway.start()
    }

    /// Re-arm both after an explicit user action that could have changed either.
    static func evaluateAll(reason: KeyArrivalMonitor.EvaluateReason) async {
        await tts.evaluate(reason: reason)
        await defaultGateway.evaluate(reason: reason)
    }
}
