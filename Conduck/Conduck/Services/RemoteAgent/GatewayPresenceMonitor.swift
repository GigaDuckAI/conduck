// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPresenceMonitor.swift
//
// "Is the gateway named in this chat's title bar actually reachable from this
// device, right now?" — answered BEFORE the user types, instead of by a send
// that fails. Feeds the toolbar presence dot and nothing else.
//
// REUSES THE SETTINGS PROBE, never a hand-rolled ping. The verdict comes from
// `RemoteAgentClient.testConnection` via `DiagnosticsRunner.makeGatewayProbeContext`
// — the SINGLE construction site for a gateway probe input. `Why:` the probe
// path, the body envelope, fail-closed auth and the cert pin are a matched set
// (OpenClaw serves control-panel HTML at 200 on `/v1/models`; OpenRouter's key
// verdict lives at `/v1/key`), and a second construction site would drift from
// the one the user sees in Settings — two spellings of "is it up", disagreeing.
//
// ONE ENTRY POINT: `observe(_:)`. There is deliberately NO invalidation API.
// The freshness of a verdict is decided by the CONFIGURATION IT WAS BUILT FROM,
// not by an external "something may have changed" signal: every landed verdict
// is stored beside the signature of the exact URL / token / scheme / pin that
// produced it, and a verdict whose signature no longer matches the live
// configuration is not fresh, however young it is. `Why:` an external
// invalidation signal is either blunt or racy. Blunt, because the hosts' only
// signal is a roster refresh, which fires on ANY settings write — a voice
// toggle would wipe the gateway verdict and buy the user's server a probe. Racy,
// because "clear, then observe" bounces off the in-flight latch and lets the
// in-flight verdict discard itself on landing, leaving a configured gateway
// with no verdict and nothing scheduled. A signature carried with the verdict
// has neither problem by construction.
//
// A DOT ONLY EXISTS FOR A GATEWAY CONFIGURED ON THIS DEVICE. A ref with no
// snapshot gets its key REMOVED, never `.unreachable`: red means "configured,
// and the probe failed", and using it for "not set up" would turn an offer the
// user has not taken up into an unfinished task shouting at them from a chat
// window. This is the one invariant every early-return below is protecting.
// "Configured" here is `SettingsManager.configuredRemoteAgentRefs()` — the
// STRICT send-able predicate every chooser uses (resolvable URL, required model
// where the kind demands one, readable token unless explicitly keyless) — not
// the URL-gated snapshot the probe input is built from. So a `.bearer` gateway
// with no token on this device, or a hosted-model gateway with no model, gets
// no dot and no doomed request. The model is NOT part of the verdict
// signature, so clearing it retires a standing verdict only at the next probe
// (freshness expiry or a signature move), not instantly — accepted, because
// the strict gate then withholds the dot rather than greening it.
//
// `.checking` IS WRITTEN AFTER THE SNAPSHOT READ, NOT SYNCHRONOUSLY IN
// `observe`. Whether a ref is configured is an actor read, so a synchronous
// write would put a (muted green) dot on an unconfigured gateway for the
// duration of that hop — the exact claim the paragraph above forbids. The
// freshness test moved behind that same read for the same reason: reuse depends
// on the live signature, which `observe` cannot know without hopping. What IS
// synchronous is the in-flight latch, so a burst of `observe` calls in one turn
// still dispatches one probe. A reused verdict never writes `.checking`, so
// re-entering a chat inside the freshness window shows no flicker.
//
// A VERDICT THAT LANDS AFTER ITS CONFIGURATION MOVED IS DROPPED, AND THE REF
// RE-ARMS ONCE. Dropping alone would leave the ref dark until some unrelated
// event triggered another `observe`; re-dispatching after the drop probes what
// is configured NOW. Bounded by construction: each re-arm re-reads the live
// configuration, so the loop ends the moment the edits stop.
//
// NO POLLING, AND NO PERSISTENCE. Verdicts live in this process only (a green
// carried across launches would be a claim nobody checked), and a verdict
// younger than `Constants.gatewayPresenceFreshness` whose signature still
// matches is reused rather than re-probed, so thread switching and scene flaps
// cannot hammer the user's server.
//
// A VERDICT STOPS BEING SAID OUT LOUD LONG BEFORE ANYTHING RE-MEASURES IT.
// Freshness above governs REQUESTS; the display lifetimes govern CLAIMS, and
// they are not the same number or even the same idea. A window left frontmost
// for hours fires no trigger, so without a second clock the dot would still be
// asserting an hours-old check in the present tense — and the failure mode is
// not symmetric. A stale green costs nothing this app did not already cost
// before the dot existed; a stale red says "do not bother" about a gateway the
// user may have repaired a minute ago, and nothing polls, so nothing would ever
// take it back. Hence `gatewayPresenceFailedDisplayLifetime` (30 s) against
// `gatewayPresenceReachableDisplayLifetime` (5 min), enforced by a per-ref
// countdown that forgets the verdict — the only way a claim can leave a screen
// nobody is touching, since time passing re-renders nothing.
//
// THE CLAIM IS REFRESHED WHERE THE DECISION IS MADE. Expiry alone would turn a
// status light into a status flash, so the hosts add one trigger to the
// lifecycle ones: engaging the composer (a real tap, focus on iOS, or the first
// sendable content) calls `observe`. That is the instant the answer matters, it
// is intent rather than ambience, and the freshness window makes a fast typist
// free. It is deliberately NOT a timer — see the rejected designs above.
//
// A gateway that dies mid-session is still reported by the send itself.
//
// ISOLATED FROM THE DIAGNOSTICS SURFACE. This writes no `DiagnosticsRunner`
// row, moves no "last checked" stamp and clears no file-lane backoff — those
// are tied to a test the USER asked for, and a passive background ping is not
// that.
//
// LOGS NOTHING. The URL, token and fingerprint exist only inside the probe
// input on their way to the request; the observable surface carries the enum
// and nothing else.

import Foundation

/// What the toolbar dot renders. Deliberately three states and no payload — an
/// error code or a host on this enum would put credential-adjacent detail on an
/// observable surface a chat window reads.
enum GatewayPresence: Equatable, Sendable {
    /// A probe is in flight for this ref.
    case checking
    /// The probe proved a usable route (`.ok` or `.okNoModels`).
    case reachable
    /// The check did not come back a pass: a refused certificate, or any thrown
    /// `AppError` (rejected token, timeout, server error, device offline).
    ///
    /// NAMED FOR THE MEASUREMENT, not for a diagnosis. The probe collapses every
    /// one of those to "did not pass", and most of them are not the server being
    /// unreachable — a rejected key is a machine answering promptly and refusing.
    /// The word the user reads is "Connection check failed" for the same reason:
    /// it is the only sentence this evidence supports.
    case failed
}

@MainActor
@Observable
final class GatewayPresenceMonitor {

    static let shared = GatewayPresenceMonitor()

    /// The injected probe: input in, "did the check pass" out. Swapping this is
    /// what makes the state machine testable without a live GET.
    typealias Probe = @MainActor @Sendable (DiagnosticsRunner.GatewayProbeInput) async -> Bool

    /// The injected wait behind display expiry — the same seam, spelled the same
    /// way, as `KeyArrivalMonitor`'s. Swapping it lets a test drive a five-minute
    /// lifetime in microseconds instead of parking a suite for five minutes.
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Read by the dot. An ABSENT key means "no verdict, and none coming" and
    /// renders nothing — the unconfigured case and the fresh-launch case share
    /// that spelling on purpose.
    private(set) var presence: [RemoteAgentRef: GatewayPresence] = [:]

    private let manager: SettingsManager
    private let probe: Probe
    private let now: @MainActor () -> Date
    private let sleeper: Sleeper

    /// When each surviving verdict landed — the freshness clock. Written and
    /// cleared in lockstep with `presence`, and never surfaced: the dot states a
    /// verdict, not its age.
    private var checkedAt: [RemoteAgentRef: Date] = [:]

    /// The configuration signature each surviving verdict was built from — what
    /// makes freshness mean "still about THIS gateway" rather than merely
    /// "recent". Written and cleared in lockstep with `presence`, so a verdict
    /// can never outlive the configuration it describes. Opaque by construction
    /// (`DiagnosticsRunner.gatewaySignature` hashes; it is compared, never
    /// shown), and private, so no credential-derived value reaches the
    /// observable surface.
    private var verdictSignature: [RemoteAgentRef: String] = [:]

    /// The probe task in flight per ref. Doubles as the coalescing latch (a key
    /// present = a probe running) so a second `observe` in the same turn is a
    /// no-op without waiting for an actor hop to tell it so.
    private var inFlight: [RemoteAgentRef: Task<Void, Never>] = [:]

    /// The countdown that takes a verdict off screen, per ref. This is what
    /// actually makes expiry visible: a view body re-runs when something it read
    /// changes, and time passing is not a change — so nothing but a write to
    /// `presence` can retire a claim from a window nobody is touching.
    private var displayExpiry: [RemoteAgentRef: Task<Void, Never>] = [:]

    /// Which scheduled expiry is still the live one, per ref. A generation token
    /// rather than a re-read of `checkedAt`, because two verdicts can land at the
    /// same instant on an injected clock — comparing stamps would let a
    /// superseded countdown clear the verdict that replaced it.
    private var displayExpiryToken: [RemoteAgentRef: UUID] = [:]

    init(
        manager: SettingsManager = .shared,
        probe: @escaping Probe = { await GatewayPresenceMonitor.liveProbe($0) },
        now: @escaping @MainActor () -> Date = Date.init,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.manager = manager
        self.probe = probe
        self.now = now
        self.sleeper = sleeper
    }

    // MARK: - API

    /// Ask for `ref`'s presence: reuse the standing verdict if it is still about
    /// this configuration and still young, otherwise probe.
    ///
    /// Synchronous by design: the callers are `.task(id:)` / scene-phase / roster
    /// refresh hooks that must not be made to await a network probe, and the
    /// coalescing latch has to close before the caller's next line runs. The
    /// only decision made here is that latch — reuse-vs-probe needs the live
    /// configuration, which is an actor read, so it happens inside the task.
    /// Cheap to call on every trigger: a reused verdict costs one actor hop and
    /// touches nothing.
    func observe(_ ref: RemoteAgentRef) {
        // BEFORE the latch and before the actor hop: a trigger that arrives on a
        // process which was suspended past a deadline must not render one more
        // frame of the overdue claim while the settings read is in flight.
        // `Task.sleep` does not advance while iOS holds the process, so the
        // countdown below cannot be the only thing that retires a verdict.
        pruneExpiredVisibleAssertion(ref)

        guard inFlight[ref] == nil else { return }

        inFlight[ref] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runProbe(for: ref)
            // `runProbe`'s `defer` has already cleared this ref's latch, so this
            // re-entry dispatches instead of coalescing into the task it is
            // running inside.
            if outcome == .droppedConfigMoved {
                self.observe(ref)
            }
        }
    }

    /// What a surface may render for `ref` RIGHT NOW — the read every view uses,
    /// never `presence` directly.
    ///
    /// A settled verdict is an assertion in the present tense, and this is where
    /// it stops being one: past its lifetime it answers nil, which renders
    /// nothing. Nothing is the app declining to make a claim — NOT "reachable",
    /// and not "not configured" either, though those three share a spelling.
    /// That collision is accepted: every one of them is a state in which the
    /// honest thing to draw is nothing at all.
    ///
    /// `.checking` never expires; the probe behind it is already bounded by
    /// `Constants.remoteAgentTestConnectionTimeout`. A settled verdict with no
    /// stamp cannot be dated, so it is withheld rather than trusted — the pair is
    /// written in lockstep, so this is a guard against a future edit, not a state
    /// that occurs today.
    func visiblePresence(for ref: RemoteAgentRef) -> GatewayPresence? {
        guard let verdict = presence[ref] else { return nil }
        guard let lifetime = Self.displayLifetime(for: verdict) else { return verdict }
        guard let stamp = checkedAt[ref] else { return nil }
        return now().timeIntervalSince(stamp) < lifetime ? verdict : nil
    }

    /// How long each settled verdict may be asserted; nil for `.checking`, which
    /// is not a claim about the gateway at all. The asymmetry is the point — see
    /// `Constants.gatewayPresenceFailedDisplayLifetime`.
    private static func displayLifetime(for presence: GatewayPresence) -> TimeInterval? {
        switch presence {
        case .checking: return nil
        case .reachable: return Constants.gatewayPresenceReachableDisplayLifetime
        case .failed: return Constants.gatewayPresenceFailedDisplayLifetime
        }
    }

    // MARK: - Probe run

    /// Why a probe run ended — the only distinction a caller acts on.
    private enum ProbeOutcome {
        /// A verdict was written, reused, or deliberately withheld. Nothing left
        /// to do until the next trigger.
        case settled
        /// The configuration moved (or went away) while the probe was in flight,
        /// so its answer was discarded. The ref needs one more dispatch to say
        /// anything about the configuration that is live NOW.
        case droppedConfigMoved
    }

    private func runProbe(for ref: RemoteAgentRef) async -> ProbeOutcome {
        defer { inFlight.removeValue(forKey: ref) }

        // ONE read for the input AND the signature it was built from — see
        // `DiagnosticsRunner.makeGatewayProbeContext`. Nil = this ref has no
        // snapshot (never configured, forgotten, or inadmissible): the key goes
        // away, and NOTHING is claimed about it.
        guard let context = await DiagnosticsRunner.makeGatewayProbeContext(for: ref, manager: manager) else {
            forget(ref)
            return .settled
        }

        // The STRICT send-able predicate — the same one the picker, the menu-bar
        // lane and CarPlay consult — not the URL-gated snapshot above. It also
        // rejects a `.bearer` gateway with no token here (fail-closed auth: that
        // pair is not-configured, never an unauthenticated send) and a
        // hosted-model gateway with no model. Probing either anyway would spend
        // a request on a gateway a send will refuse, and for the model case
        // `/v1/key` would even come back GREEN beside it.
        let sendable = await manager.configuredRemoteAgentRefs().contains(ref)
        guard sendable else {
            forget(ref)
            return .settled
        }

        // REUSE, scoped to the configuration the standing verdict is about. Both
        // halves are load-bearing: age alone would let a stale green survive an
        // edit, and signature alone would freeze a verdict about a gateway that
        // has since gone down. Returning here writes nothing at all — no
        // `.checking`, so re-entering a chat inside the window cannot flicker.
        if let verdict = presence[ref],
           verdict == .reachable || verdict == .failed,
           verdictSignature[ref] == context.signature,
           let stamp = checkedAt[ref],
           now().timeIntervalSince(stamp) < Constants.gatewayPresenceFreshness {
            return .settled
        }

        // Only now is the ref known to be configured AND due, so only now may a
        // dot exist. The stamp and signature go with the verdict they described.
        presence[ref] = .checking
        checkedAt.removeValue(forKey: ref)
        verdictSignature.removeValue(forKey: ref)
        cancelDisplayExpiry(ref)

        let reachable = await probe(context.input)

        // Compare against the LIVE persisted configuration, not against a
        // remembered one: an edit in another window (or an inbound KVS update)
        // can move the URL / token / scheme while the probe is in flight, and
        // the old credentials' verdict must not green the new configuration.
        // A dropped verdict removes the key rather than guessing, and the caller
        // re-arms so the new configuration gets an answer of its own.
        let liveSignature = await DiagnosticsRunner.liveGatewaySignature(for: ref, manager: manager)
        guard let liveSignature, liveSignature == context.signature else {
            forget(ref)
            return .droppedConfigMoved
        }

        let verdict: GatewayPresence = reachable ? .reachable : .failed
        presence[ref] = verdict
        checkedAt[ref] = now()
        verdictSignature[ref] = context.signature
        scheduleDisplayExpiry(ref, for: verdict)
        return .settled
    }

    /// Drop everything this monitor claims about `ref`. The single spelling of
    /// "say nothing", so no path can leave a verdict without its freshness
    /// stamp or its signature (or either without the verdict).
    private func forget(_ ref: RemoteAgentRef) {
        presence.removeValue(forKey: ref)
        checkedAt.removeValue(forKey: ref)
        verdictSignature.removeValue(forKey: ref)
        cancelDisplayExpiry(ref)
    }

    // MARK: - Display expiry

    /// Arm the countdown that will retire `verdict` from every surface reading
    /// this monitor.
    ///
    /// ONE TASK PER REF, and it does no network work — it sleeps and then
    /// forgets, so the "no polling" rule is untouched: this costs the user's
    /// server nothing and buys back the ability to stop talking. Retiring the
    /// verdict WHOLE (`forget`) rather than blanking only the visible half is
    /// deliberate while nothing reads a history: an unread stamp on an
    /// `@Observable` object is dead state, and dropping the bookkeeping changes
    /// no reuse decision — the failed lifetime IS the reuse window, and the
    /// reachable one is ten times past it.
    private func scheduleDisplayExpiry(_ ref: RemoteAgentRef, for verdict: GatewayPresence) {
        guard let lifetime = Self.displayLifetime(for: verdict) else { return }
        let token = UUID()
        displayExpiryToken[ref] = token
        displayExpiry.removeValue(forKey: ref)?.cancel()
        displayExpiry[ref] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper(.seconds(lifetime))
            } catch {
                return  // cancelled by a newer verdict, or by `forget`
            }
            // BOTH guards: cancellation is not guaranteed to have been observed
            // by a sleeper a test releases by hand, and the token is what proves
            // this countdown still belongs to the verdict on screen.
            guard !Task.isCancelled, self.displayExpiryToken[ref] == token else { return }
            self.forget(ref)
        }
    }

    /// Drop `ref`'s verdict if it has outlived what it may assert. Silent when
    /// there is nothing to retire, so every trigger can call it unconditionally.
    private func pruneExpiredVisibleAssertion(_ ref: RemoteAgentRef) {
        guard presence[ref] != nil, visiblePresence(for: ref) == nil else { return }
        forget(ref)
    }

    private func cancelDisplayExpiry(_ ref: RemoteAgentRef) {
        displayExpiry.removeValue(forKey: ref)?.cancel()
        displayExpiryToken.removeValue(forKey: ref)
    }

    // MARK: - Live probe

    /// The real probe. `.ok` / `.okNoModels` are both reachable — "connection
    /// established" is the whole claim the dot makes, and a gateway advertising
    /// zero models is a Settings/Diagnostics concern, not a broken route.
    /// `.untrustedCert` and every throw (auth, timeout, server error, offline)
    /// are `.failed` — the honest common denominator, and the reason the state
    /// is not called "unreachable": a rejected token is a gateway this device
    /// reached perfectly well.
    static func liveProbe(_ input: DiagnosticsRunner.GatewayProbeInput) async -> Bool {
        do {
            let outcome = try await RemoteAgentClient.shared.testConnection(
                backend: input.backend,
                url: input.url,
                token: input.token,
                authScheme: input.authScheme,
                fingerprint: input.fingerprint,
                probePath: input.probePath,
                bodyShape: input.bodyShape
            )
            return outcome.isSuccess
        } catch {
            return false
        }
    }

    // MARK: - Test seam

    #if DEBUG
    /// Await every probe currently in flight, INCLUDING the ones that appear
    /// while draining. Test-only: it exists so a test can observe a LANDING
    /// without polling the observable surface. Loops rather than snapshotting
    /// once because a dropped verdict re-arms — a snapshot would return with the
    /// re-armed probe still running and hand the test a half-finished state. No
    /// production caller — the UI never waits for a presence verdict.
    func drainForTesting() async {
        while true {
            let running = Array(inFlight.values)
            if running.isEmpty { return }
            for task in running { await task.value }
        }
    }

    /// Await armed display countdowns — one ref's, or every one. Separate from
    /// `drainForTesting` on purpose: that one waits for NETWORK work to settle,
    /// this one waits for a deadline the test itself fired, and a suite that
    /// conflated them would park for a real five minutes.
    ///
    /// TAKE THE REF whenever the test deliberately leaves another countdown
    /// parked — awaiting one that has not been released simply hangs, which is a
    /// test timeout rather than a failure and reads as a crash in the log.
    func drainDisplayExpiryForTesting(_ ref: RemoteAgentRef? = nil) async {
        let tasks = ref.map { displayExpiry[$0].map { [$0] } ?? [] } ?? Array(displayExpiry.values)
        for task in tasks { await task.value }
    }
    #endif
}
