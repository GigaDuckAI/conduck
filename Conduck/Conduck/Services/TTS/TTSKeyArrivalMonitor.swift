// Conduck
// TTSKeyArrivalMonitor.swift
//
// iCloud Keychain delivers a synced key OPPORTUNISTICALLY (minutes to hours)
// and posts NO app-visible arrival notification — so a device whose active
// cloud TTS provider is still waiting on its key has no event to converge on.
// Chat silently speaks Apple in the meantime (the never-go-silent contract),
// and nothing would flip the device (or the Watch, fed second-hand from this
// phone) to the cloud voice until the user happens to touch Settings.
//
// This monitor is the bounded workaround: WHILE the app is active AND the
// active TTS provider's key probes `.missing`/`.unreadable`, re-read the
// Keychain on a short exponential backoff (~5 min window per activation).
// The moment a poll read finds the key, post `.settingsDidChangeRemotely`
// ONCE — that single notification already fans out everything downstream:
// `SettingsViewModel.loadSettings()` (clears the key-readiness banner) and
// `PhoneSessionManager`'s debounced Watch re-broadcast (ships the envelope
// the wrist has been missing).
//
// Bounds (locked by design review — NOT tunables to relax):
//   - Foreground-active only. `willResignActive` cancels the window (covers
//     Control Center pulls and interruptions, not just backgrounding).
//   - One finite backoff schedule per activation; when it exhausts, the
//     monitor stays quiet until the app re-activates or the requirement
//     fingerprint (provider + key slot) changes. Unrelated settings changes
//     NEVER restart the window — that would make it effectively indefinite.
//   - Posts only from a TIMER-DISCOVERED missing→present transition. A
//     notification-triggered re-evaluation never posts (a local key paste
//     already posted; re-posting would double the fan-out).
//   - Secret-free: only `ActiveTTSKeyProbe` (typed state, no key material)
//     ever leaves the actor read. Nothing is logged or persisted.

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Probe value type

/// Device-local key availability of the ACTIVE TTS provider — the SECRET-FREE
/// projection of `SettingsManager.activeTTSSnapshot()` that the key-readiness
/// banner and this monitor consume. `keyState` speaks ONLY to local credential
/// availability (`.present` does not claim the provider works).
struct ActiveTTSKeyProbe: Sendable, Equatable {
    let providerID: String
    /// The shared `stt.apiKey.<presetID>` slot the provider reads — nil when
    /// no key is required. Part of the monitor's requirement fingerprint.
    let keySlotID: String?
    let keyState: APIKeyState

    /// The two states bounded polling can actually repair: a key that hasn't
    /// arrived yet, or one the Keychain couldn't return (locked
    /// pre-first-unlock is a legitimate transient per the
    /// `kSecAttrAccessibleAfterFirstUnlock` contract).
    var isDegraded: Bool { keyState == .missing || keyState == .unreadable }
}

// MARK: - Monitor

@MainActor
final class TTSKeyArrivalMonitor {
    static let shared = TTSKeyArrivalMonitor()

    /// The requirement identity a poll window is bound to. A window survives
    /// only as long as the SAME provider needs the SAME key slot — any change
    /// re-evaluates from scratch; anything else (unrelated settings churn)
    /// leaves the window untouched.
    struct Fingerprint: Equatable, Sendable {
        let providerID: String
        let keySlotID: String?

        init(_ probe: ActiveTTSKeyProbe) {
            providerID = probe.providerID
            keySlotID = probe.keySlotID
        }
    }

    /// Coarse run state — exposed for tests; never persisted.
    enum RunState: Equatable {
        case idle
        case polling(Fingerprint)
        /// The schedule ran dry for this fingerprint. Stays exhausted until
        /// the app re-activates or the fingerprint changes.
        case exhausted(Fingerprint)
    }

    /// Why an evaluation is happening — decides whether an existing window
    /// may be restarted (activation / manual re-arm) or must be left alone
    /// (settings churn with an unchanged fingerprint).
    enum EvaluateReason {
        case activation
        case settingsChange
        case manual
    }

    /// Exponential backoff, ~5.25 min total. Six Keychain reads per
    /// activation window is the whole battery cost.
    static let backoffSchedule: [Duration] = [
        .seconds(5), .seconds(10), .seconds(20),
        .seconds(40), .seconds(80), .seconds(160)
    ]

    private(set) var state: RunState = .idle

    // Test seams — production defaults; tests inject via init.
    private let probeProvider: @Sendable () async -> ActiveTTSKeyProbe
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let onKeyArrival: @MainActor () -> Void

    private var pollTask: Task<Void, Never>?
    /// Generation stamp per poll window. Cancellation alone is insufficient:
    /// a cancelled task can already be past its cancellation check and awaiting
    /// the actor's Keychain read — the stale generation makes its late resume
    /// a no-op instead of a wrong-window post.
    private var generation = 0
    private var started = false
    private var appIsActive = false

    init(
        probeProvider: @escaping @Sendable () async -> ActiveTTSKeyProbe = {
            await SettingsManager.shared.activeTTSKeyProbe()
        },
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
    /// Called once from app wiring (`ConduckApp.init`); the first
    /// `didBecomeActive` after launch performs the initial evaluation, so
    /// there is no separate "evaluate now" at start (a launch directly into
    /// the background must not poll).
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
    /// NEVER posts — posting is exclusively the poll loop's transition
    /// discovery, so notification-triggered evaluations can't echo a local
    /// key paste's own fan-out back into a second one.
    func evaluate(reason: EvaluateReason) async {
        guard appIsActive else { return }
        let probe = await probeProvider()
        guard appIsActive else { return }   // resigned while probing

        guard probe.isDegraded else {
            // Healthy (or keyless) — whatever window existed is obsolete.
            cancelWindow()
            state = .idle
            return
        }

        let fingerprint = Fingerprint(probe)
        switch reason {
        case .activation, .manual:
            // A genuine re-activation (or the user's explicit Check Again)
            // re-arms a fresh window even for the same fingerprint.
            beginWindow(fingerprint)
        case .settingsChange:
            switch state {
            case .polling(let current) where current == fingerprint,
                 .exhausted(let current) where current == fingerprint:
                // Unrelated settings churn — leave the window (or its
                // exhaustion) alone, else churn makes polling indefinite.
                return
            default:
                beginWindow(fingerprint)
            }
        }
    }

    // MARK: - Poll window

    private func cancelWindow() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
    }

    private func beginWindow(_ fingerprint: Fingerprint) {
        cancelWindow()
        let gen = generation
        state = .polling(fingerprint)

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
                // Re-check AFTER the await: a provider switch or resign-active
                // may have retired this window while the read was in flight.
                guard !Task.isCancelled, self.generation == gen else { return }
                guard Fingerprint(probe) == fingerprint else {
                    // Requirement changed under the window; the settings
                    // change that caused it owns the restart decision.
                    return
                }

                switch probe.keyState {
                case .present:
                    // THE transition this whole file exists for: the synced
                    // key arrived with no OS event. One post fans out banner
                    // refresh + Watch re-broadcast.
                    self.state = .idle
                    self.pollTask = nil
                    self.onKeyArrival()
                    return
                case .notRequired:
                    self.state = .idle
                    self.pollTask = nil
                    return
                case .missing, .unreadable:
                    continue
                }
            }
            guard self.generation == gen else { return }
            self.state = .exhausted(fingerprint)
            self.pollTask = nil
        }
    }
}
