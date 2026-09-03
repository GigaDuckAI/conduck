// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPresenceMonitorTests.swift
//
// The chat toolbar's gateway presence dot makes exactly one claim — "this
// device could reach the gateway named beside it" — and every way that claim
// can go wrong is a way to lie to the user. This suite pins the state machine
// that decides when the claim may be made at all:
//
//   * An UNCONFIGURED ref never gets a key, not even a transient one. Red means
//     "configured, and the probe failed"; using it for "not set up" would turn
//     an offer the user has not taken up into an unfinished task. This is the
//     spec rule the monitor exists to honour, so it is asserted BOTH
//     synchronously after `observe` and after the dispatch has fully drained.
//     A `.bearer` gateway with no token on this device is unconfigured too —
//     fail-closed auth forbids the unauthenticated send that probing it would
//     be, so the dot says nothing and no request leaves the device.
//   * A verdict that lands after its configuration moved is DROPPED, never
//     applied — the old credentials' answer greening the new configuration is a
//     false green, and a false green is the whole failure mode a passive
//     indicator can produce. Dropping alone would leave the gateway dark, so the
//     ref RE-ARMS once and answers about the configuration that is live now.
//   * Freshness is scoped to the CONFIGURATION, not just to the clock: a verdict
//     is reused only while it is both young and still about the same URL / token
//     / scheme / pin. Both halves are tested, in both directions — a stale-by-age
//     verdict re-probes, and so does a young verdict whose gateway was edited.
//   * A verdict STOPS being asserted long before anything re-measures it, and
//     the two lifetimes are deliberately unequal: a stale green costs nothing
//     this app did not cost before the dot existed, while a stale red tells the
//     user not to bother with a gateway they may have just repaired — and since
//     nothing polls, nothing would ever take it back. The countdown is tested
//     from both ends: that it fires and withdraws the claim, that a superseded
//     one cannot retire its successor, and that the read a view uses withholds
//     an overdue verdict even when the countdown never fired at all (the iOS
//     suspension case, where `Task.sleep` does not advance).
//   * Reuse and in-flight coalescing are load-bearing, not tuning: the probe hits
//     the USER'S server, and thread switching / scene flaps must not turn into
//     traffic they never asked for. Reuse must also be INVISIBLE — a `.checking`
//     write on a verdict that was never re-probed is a flicker with no event
//     behind it, so the observable surface is asserted to go untouched.
//
// NO NETWORK, EVER. The probe is injected (`ProbeGate` below) and the clock is
// injected, so every case is deterministic: the gate can HOLD a probe inside
// the monitor's `await` for as long as the test needs, which is what lets
// "mid-flight" be a real, non-racy state rather than a sleep. `DiagnosticsRunnerTests`
// documents the same limit from the other side — a unit test may not fire a
// live `GET /v1/models`, so the injected probe is what makes this testable.

import Observation
import XCTest
@testable import Conduck

final class GatewayPresenceMonitorTests: XCTestCase {

    // MARK: - Doubles

    /// Injected probe with a valve. Records every input it was handed, and in
    /// `.held` mode parks inside the monitor's `await` until the test calls
    /// `release()` — so the test can assert on the monitor's MID-FLIGHT state
    /// with no polling and no timing assumptions.
    ///
    /// MainActor-isolated (like the monitor and the tests themselves), so its
    /// bookkeeping needs no lock: every mutation happens on the same actor, and
    /// the suspensions are what hand control back to the test.
    @MainActor
    private final class ProbeGate {
        enum Mode { case immediate, held }

        var mode: Mode = .immediate
        /// What the probe reports: true = reachable.
        var result = true
        /// Per-input verdict override. Lets a test give two configurations
        /// DIFFERENT answers, so "which call's verdict landed" is provable from
        /// the presence enum alone rather than inferred from a call count.
        var resultForInput: ((DiagnosticsRunner.GatewayProbeInput) -> Bool)?
        private(set) var inputs: [DiagnosticsRunner.GatewayProbeInput] = []

        var callCount: Int { inputs.count }

        /// Signals banked because no one was waiting yet — makes `awaitStart()`
        /// and `release()` order-independent.
        private var startSignals = 0
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseTickets = 0
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func makeProbe() -> GatewayPresenceMonitor.Probe {
            { [self] input in
                inputs.append(input)
                signalStart()
                if mode == .held { await waitForRelease() }
                return resultForInput?(input) ?? result
            }
        }

        /// Suspend until a probe has entered the stub (consumes one signal).
        func awaitStart() async {
            if startSignals > 0 {
                startSignals -= 1
                return
            }
            await withCheckedContinuation { startWaiter = $0 }
        }

        /// Let one held probe return.
        func release() {
            if let waiter = releaseWaiter {
                releaseWaiter = nil
                waiter.resume()
            } else {
                releaseTickets += 1
            }
        }

        private func signalStart() {
            if let waiter = startWaiter {
                startWaiter = nil
                waiter.resume()
            } else {
                startSignals += 1
            }
        }

        private func waitForRelease() async {
            if releaseTickets > 0 {
                releaseTickets -= 1
                return
            }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    /// Injected wait behind display expiry, with a valve. Every countdown parks
    /// here instead of sleeping, so a five-minute lifetime is asserted in
    /// microseconds and "the deadline arrived" is an event the test fires rather
    /// than a duration it waits out.
    ///
    /// `fireOldest()` exists because the token guard cannot be tested any other
    /// way: a superseded countdown is CANCELLED but still parked (cancellation
    /// resumes nothing here), so the only way to prove it cannot clear the
    /// verdict that replaced it is to release exactly that one and leave its
    /// successor parked.
    @MainActor
    private final class SleeperGate {
        /// Every lifetime the monitor asked to wait out, in order.
        private(set) var durations: [Duration] = []

        var callCount: Int { durations.count }
        var parkedCount: Int { parked.count }

        private var parked: [CheckedContinuation<Void, Never>] = []
        /// Releases banked because nothing was parked yet — keeps `fire*` and
        /// `awaitPark()` order-independent.
        private var pendingReleases = 0
        private var parkSignals = 0
        private var parkWaiter: CheckedContinuation<Void, Never>?

        func makeSleeper() -> GatewayPresenceMonitor.Sleeper {
            { [self] duration in await park(duration) }
        }

        /// Suspend until a countdown has entered the stub (consumes one signal).
        func awaitPark() async {
            if parkSignals > 0 {
                parkSignals -= 1
                return
            }
            await withCheckedContinuation { parkWaiter = $0 }
        }

        /// Fire every parked countdown's deadline.
        func fireAll() {
            let waiting = parked
            parked = []
            if waiting.isEmpty {
                pendingReleases += 1
                return
            }
            for waiter in waiting { waiter.resume() }
        }

        /// Fire ONLY the countdown that parked first.
        func fireOldest() {
            guard !parked.isEmpty else {
                pendingReleases += 1
                return
            }
            parked.removeFirst().resume()
        }

        private func park(_ duration: Duration) async {
            durations.append(duration)
            signalPark()
            if pendingReleases > 0 {
                pendingReleases -= 1
                return
            }
            await withCheckedContinuation { parked.append($0) }
        }

        private func signalPark() {
            if let waiter = parkWaiter {
                parkWaiter = nil
                waiter.resume()
            } else {
                parkSignals += 1
            }
        }
    }

    /// Injectable clock. A box rather than a captured local so a test can move
    /// time forward after the monitor has already taken the closure.
    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Records whether the monitor's observable `presence` was written at all.
    /// Reference type, not a captured `var`: `withObservationTracking`'s
    /// `onChange` is `@Sendable`, so it cannot capture a mutable local — and the
    /// mutation it is watching for always happens on the main actor, which is
    /// what makes `assumeIsolated` at the call site sound.
    @MainActor
    private final class SurfaceWriteFlag {
        private(set) var didWrite = false
        func record() { didWrite = true }
    }

    // MARK: - Rig

    private struct Rig {
        let monitor: GatewayPresenceMonitor
        let manager: SettingsManager
        let gate: ProbeGate
        let sleeper: SleeperGate
        let clock: Clock
    }

    private let seededURL = URL(string: "https://presence-probe-host.example.com")!
    private let movedURL = URL(string: "https://presence-moved-host.example.com")!

    /// Isolated `SettingsManager` — nothing this suite writes may reach the App
    /// Group defaults, iCloud KVS or the real Keychain.
    @MainActor
    private func makeRig() -> Rig {
        let manager = SettingsManager(dependencies: .inMemory())
        let gate = ProbeGate()
        let sleeper = SleeperGate()
        let clock = Clock()
        let monitor = GatewayPresenceMonitor(
            manager: manager,
            probe: gate.makeProbe(),
            now: { clock.now },
            sleeper: sleeper.makeSleeper()
        )
        return Rig(monitor: monitor, manager: manager, gate: gate, sleeper: sleeper, clock: clock)
    }

    /// Seed a send-able gateway. Only the URL is required for a snapshot to
    /// resolve; the auth scheme is pinned to `.none` so the fixture is a
    /// keyless gateway and no test depends on a Keychain write.
    private func seedGateway(_ rig: Rig, ref: RemoteAgentRef, url: URL? = nil) async {
        await rig.manager.setRemoteAgentAuthScheme(.none, for: ref)
        let stored = await rig.manager.setRemoteAgentURL(url ?? seededURL, for: ref)
        XCTAssertTrue(stored, "the fixture URL must be admissible or every case below is vacuous")
    }

    /// Run `body`, reporting whether the monitor wrote to `presence` while it
    /// ran. Used to prove a NEGATIVE the enum cannot show: that a reused verdict
    /// never passed through `.checking` on its way to staying exactly what it
    /// was.
    @MainActor
    private func recordingSurfaceWrites(
        of monitor: GatewayPresenceMonitor,
        during body: () async -> Void
    ) async -> Bool {
        let flag = SurfaceWriteFlag()
        withObservationTracking {
            _ = monitor.presence
        } onChange: {
            MainActor.assumeIsolated { flag.record() }
        }
        await body()
        return flag.didWrite
    }

    // MARK: - 1. Happy path

    /// The full arc a user sees on a working gateway: muted green while the
    /// probe runs, full green when it answers.
    func testConfiguredRefReportsCheckingThenReachable() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.mode = .held
        rig.gate.result = true

        rig.monitor.observe(ref)
        await rig.gate.awaitStart()
        XCTAssertEqual(rig.monitor.presence[ref], .checking,
                       "the dot must say a probe is running before it says anything about the gateway")

        rig.gate.release()
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
        XCTAssertEqual(rig.gate.callCount, 1)
    }

    // MARK: - 2. Failed probe

    /// Every failure shape the live probe collapses into `false` — refused
    /// certificate, bad token, timeout, offline — lands as one honest claim:
    /// this device cannot reach it right now.
    func testFailedProbeReportsFailed() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.result = false

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .failed)
    }

    // MARK: - 3. Unconfigured ref — the spec rule

    /// A gateway that is not configured on this device is an OFFER, not an
    /// unfinished task: the chat window must say nothing about it. No key is
    /// written at any point in the dispatch — not `.failed`, and not even a
    /// transient `.checking` — and the probe is never fired.
    func testUnconfiguredRefNeverGetsAKey() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.custom(UUID())   // no roster entry, no URL

        rig.monitor.observe(ref)
        XCTAssertNil(rig.monitor.presence[ref],
                     "a dot must never appear synchronously for a ref nobody has configured")

        await rig.monitor.drainForTesting()
        XCTAssertNil(rig.monitor.presence[ref],
                     "an unconfigured ref must resolve to silence, never to red")
        XCTAssertTrue(rig.monitor.presence.isEmpty)
        XCTAssertEqual(rig.gate.callCount, 0,
                       "there is nothing to probe: no snapshot means no request may leave the device")
    }

    /// Fail-closed auth, seen from the dot: a `.bearer` gateway whose token this
    /// device does not hold is NOT configured here, however complete it looks
    /// elsewhere. Probing it would be an unauthenticated send (the exact thing
    /// the scheme forbids) spent on a guaranteed rejection, and painting the
    /// result red would blame the gateway for a token that simply has not
    /// reached this device.
    func testBearerGatewayWithNoTokenIsUnconfiguredAndNeverProbed() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await rig.manager.setRemoteAgentAuthScheme(.bearer, for: ref)
        let stored = await rig.manager.setRemoteAgentURL(seededURL, for: ref)
        XCTAssertTrue(stored, "the fixture URL must be admissible or this case is vacuous")

        rig.monitor.observe(ref)
        XCTAssertNil(rig.monitor.presence[ref])

        await rig.monitor.drainForTesting()
        XCTAssertNil(rig.monitor.presence[ref],
                     "a bearer gateway with no token here is not-configured — silence, not red")
        XCTAssertEqual(rig.gate.callCount, 0,
                       "no unauthenticated request may leave the device on a bearer gateway")
    }

    /// The same rule from the other direction: a gateway the user FORGETS while
    /// its probe is in flight must lose its dot, not inherit a red one — and
    /// must not spin, because there is no configuration left to re-probe.
    func testGatewayForgottenMidFlightLosesItsDotAndDoesNotReprobe() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.mode = .held

        rig.monitor.observe(ref)
        await rig.gate.awaitStart()
        await rig.manager.setRemoteAgentURL(nil, for: ref)

        rig.gate.release()
        await rig.monitor.drainForTesting()
        XCTAssertNil(rig.monitor.presence[ref],
                     "the live signature is gone, so there is no configuration the verdict could be about")
        XCTAssertEqual(rig.gate.callCount, 1,
                       "a forgotten gateway has nothing to re-probe: the re-arm must die on the missing snapshot")
    }

    // MARK: - 4. Coalescing

    /// A second `observe` while a probe is in flight is a no-op. The dot's
    /// triggers fire in bursts (surface appears, ref changes, window activates
    /// in the same turn) and each one must not become a request to the user's
    /// server.
    func testSecondObserveWhileInFlightDoesNotProbeTwice() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.mode = .held

        rig.monitor.observe(ref)
        await rig.gate.awaitStart()
        rig.monitor.observe(ref)
        rig.monitor.observe(ref)
        XCTAssertEqual(rig.gate.callCount, 1, "the in-flight latch must close synchronously")

        rig.gate.release()
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 1)
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
    }

    // MARK: - 5. Freshness, scoped to the configuration

    /// A young verdict about the SAME configuration is reused, and the reuse is
    /// invisible: the surface is not written at all, so a chat re-entry inside
    /// the window cannot flash the muted-green `.checking` dot at a gateway
    /// nobody re-checked.
    func testFreshVerdictForUnchangedConfigIsReusedWithoutTouchingTheSurface() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
        XCTAssertEqual(rig.gate.callCount, 1)

        rig.clock.advance(Constants.gatewayPresenceFreshness - 1)
        let wrote = await recordingSurfaceWrites(of: rig.monitor) {
            rig.monitor.observe(ref)
            XCTAssertEqual(rig.monitor.presence[ref], .reachable,
                           "dispatching must not blank the standing verdict")
            await rig.monitor.drainForTesting()
        }

        XCTAssertFalse(wrote, "a reused verdict must not write `.checking` — that is a flicker with no event behind it")
        XCTAssertEqual(rig.gate.callCount, 1, "a verdict inside the freshness window must be reused, not re-probed")
        XCTAssertEqual(rig.monitor.presence[ref], .reachable, "reuse must leave the dot exactly as it was")
    }

    /// Past the window, the same configuration is re-probed: the freshness
    /// constant is what bounds how long the dot may keep asserting a route it
    /// last saw a while ago.
    ///
    /// Doubles as the POSITIVE CONTROL for the case above: a real re-probe DOES
    /// write the surface (`.checking`, then the verdict), so the write detector
    /// is proven to fire — without this, the "no write on reuse" assertion could
    /// pass because the detector never fires at all.
    func testStaleVerdictIsReprobed() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 1)

        rig.clock.advance(Constants.gatewayPresenceFreshness + 1)
        let wrote = await recordingSurfaceWrites(of: rig.monitor) {
            rig.monitor.observe(ref)
            await rig.monitor.drainForTesting()
        }

        XCTAssertTrue(wrote, "a genuine re-probe writes the surface — if this fails, the reuse case's negative is vacuous")
        XCTAssertEqual(rig.gate.callCount, 2, "past the window, the next trigger must actually re-probe")
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
    }

    /// Freshness is about a CONFIGURATION, not a clock reading. A verdict that
    /// is seconds old but was built from the previous URL says nothing about the
    /// gateway now on screen, so the next trigger re-probes despite the age —
    /// this is what replaces the blanket invalidation the monitor deliberately
    /// does not offer.
    func testEditedConfigIsReprobedEvenInsideTheFreshnessWindow() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 1)
        XCTAssertEqual(rig.gate.inputs.last?.url, seededURL)

        // No clock movement at all: the verdict is as young as it can be.
        await seedGateway(rig, ref: ref, url: movedURL)
        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()

        XCTAssertEqual(rig.gate.callCount, 2,
                       "a verdict about the old URL may not be reused for the new one, however young it is")
        XCTAssertEqual(rig.gate.inputs.last?.url, movedURL)
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
    }

    /// An UNRELATED settings write must cost the gateway nothing. Re-observing
    /// after one reuses the verdict, because the gateway's own configuration —
    /// the only thing the signature is derived from — has not moved.
    func testUnrelatedSettingsWriteDoesNotCostTheGatewayAProbe() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 1)

        // A different gateway is configured — the shape a roster refresh used to
        // treat as "everything may have moved".
        await seedGateway(rig, ref: .builtin(.hermes), url: movedURL)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 1,
                       "another gateway's write is not this gateway's business — the verdict stands")
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)
    }

    // MARK: - 6. Config moved mid-flight

    /// The false-green guard, plus the re-arm that keeps it from turning into a
    /// dark dot: the URL changes while the probe is in flight, so the answer is
    /// about credentials that are no longer configured and must be discarded —
    /// and the ref immediately probes what IS configured, without waiting for
    /// another trigger from the UI.
    ///
    /// The two configurations are given OPPOSITE verdicts, so the landed
    /// presence proves which call produced it rather than merely that something
    /// landed.
    func testConfigEditedMidFlightDropsTheVerdictAndReArmsOnce() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.mode = .held
        let moved = movedURL
        rig.gate.resultForInput = { $0.url != moved }   // old URL → reachable, new URL → not

        rig.monitor.observe(ref)
        await rig.gate.awaitStart()
        XCTAssertEqual(rig.monitor.presence[ref], .checking)

        // The edit lands while the first probe is parked inside the monitor's
        // `await`; the re-armed probe must not park too, or the drain would
        // deadlock waiting for a release nobody sends.
        await seedGateway(rig, ref: ref, url: movedURL)
        rig.gate.mode = .immediate
        rig.gate.release()

        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.gate.callCount, 2,
                       "the dropped verdict must re-arm exactly once — no dark dot, and no spin")
        XCTAssertEqual(rig.gate.inputs.last?.url, movedURL,
                       "the re-probe must use the edited URL, not the one the dropped verdict was about")
        XCTAssertEqual(rig.monitor.presence[ref], .failed,
                       "the surviving verdict is the NEW configuration's, so the old green was truly discarded")
    }

    // MARK: - 7. Privacy

    /// The URL, token and fingerprint travel INTO the probe and stop there. The
    /// monitor's observable surface — the thing a chat window reads and an
    /// accessibility dump can render — carries the enum and the ref, nothing
    /// credential-shaped.
    func testObservableSurfaceCarriesNoCredentialMaterial() async throws {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        let secret = "presence-secret-token"
        await rig.manager.setRemoteAgentAuthScheme(.bearer, for: ref)
        await rig.manager.setRemoteAgentURL(seededURL, for: ref)
        try await rig.manager.setRemoteAgentToken(secret, for: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)

        // The probe DID receive them — otherwise this test would pass vacuously.
        let input = try XCTUnwrap(rig.gate.inputs.last)
        XCTAssertEqual(input.url, seededURL)
        XCTAssertEqual(input.token, secret)

        let rendered = String(describing: rig.monitor.presence)
        for needle in [secret, "presence-probe-host", "http", "://", "Bearer"] {
            XCTAssertFalse(rendered.contains(needle),
                           "the presence surface leaked '\(needle)': \(rendered)")
        }
    }

    // MARK: - 8. Display expiry — a verdict stops being said out loud

    /// A failed check may be asserted for 30 s and then goes silent. This is the
    /// state whose staleness actually costs the user something: red says "do not
    /// bother" about a gateway they may have repaired a minute ago, and nothing
    /// polls, so without this countdown nothing would ever take the word back.
    func testFailedVerdictExpiresAndTheDotGoesSilent() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.result = false

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .failed)

        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.sleeper.durations.last,
                       .seconds(Constants.gatewayPresenceFailedDisplayLifetime),
                       "red must be armed with the FAILED lifetime, not the reachable one")

        rig.sleeper.fireAll()
        await rig.monitor.drainDisplayExpiryForTesting()
        XCTAssertNil(rig.monitor.presence[ref],
                     "past its lifetime the verdict is withdrawn — no dot means no claim, not 'reachable'")
        XCTAssertEqual(rig.gate.callCount, 1,
                       "expiry is a local retraction: it may not cost the user's server a request")
    }

    /// A successful check is asserted for ten times as long. The asymmetry is the
    /// design: a stale green costs nothing this app did not cost before the dot
    /// existed, so expiring it as fast as red would trade a real status light for
    /// a flash and buy nothing.
    func testReachableVerdictIsArmedWithTheLongerLifetime() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)

        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.sleeper.durations.last,
                       .seconds(Constants.gatewayPresenceReachableDisplayLifetime))
        XCTAssertGreaterThan(Constants.gatewayPresenceReachableDisplayLifetime,
                             Constants.gatewayPresenceFailedDisplayLifetime,
                             "if these ever equalise, the asymmetry this suite is pinning is gone")

        rig.sleeper.fireAll()
        await rig.monitor.drainDisplayExpiryForTesting()
        XCTAssertNil(rig.monitor.presence[ref])
    }

    /// A SUPERSEDED countdown may not clear the verdict that replaced it. Both
    /// verdicts land at the same injected instant, which is exactly the case a
    /// timestamp comparison would get wrong — hence the generation token.
    func testSupersededCountdownCannotClearTheNewerVerdict() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        // Verdict per configuration, so which one survives is provable from the
        // enum rather than inferred.
        let originalURL = seededURL
        rig.gate.resultForInput = { $0.url != originalURL }

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.monitor.presence[ref], .failed)

        // No clock movement: the second verdict is written at the same instant.
        await seedGateway(rig, ref: ref, url: movedURL)
        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)

        // Release ONLY the first, cancelled countdown.
        rig.sleeper.fireOldest()
        await Task.yield()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable,
                       "the first countdown belongs to a verdict that is gone; it may not retire its successor")

        rig.sleeper.fireAll()
    }

    /// Countdowns are per ref. One gateway going silent says nothing about
    /// another, which shares nothing with it but this monitor.
    func testExpiryIsIndependentPerRef() async {
        let rig = makeRig()
        let first = RemoteAgentRef.builtin(.openclaw)
        let second = RemoteAgentRef.builtin(.hermes)
        await seedGateway(rig, ref: first)
        await seedGateway(rig, ref: second, url: movedURL)

        rig.monitor.observe(first)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        rig.monitor.observe(second)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.monitor.presence[first], .reachable)
        XCTAssertEqual(rig.monitor.presence[second], .reachable)

        // Scoped drain: the second ref's countdown is still parked on purpose,
        // and awaiting it would hang the suite rather than fail it.
        rig.sleeper.fireOldest()   // the first ref's countdown parked first
        await rig.monitor.drainDisplayExpiryForTesting(first)
        XCTAssertNil(rig.monitor.presence[first])
        XCTAssertEqual(rig.monitor.presence[second], .reachable,
                       "the second gateway's claim is its own and nothing has retired it")

        rig.sleeper.fireAll()   // release the survivor so no countdown outlives the test
    }

    /// THE SUSPENSION CASE. `Task.sleep` does not advance while iOS holds the
    /// process, so a countdown armed before a long background can be hours
    /// overdue when the app comes back with the verdict still in the dictionary.
    /// The read every view uses must not repeat it.
    func testVisiblePresenceWithholdsAnOverdueVerdictTheCountdownNeverFired() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.result = false

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()

        // Time passes with the process suspended: the clock moves, the countdown
        // does not fire.
        rig.clock.advance(Constants.gatewayPresenceFailedDisplayLifetime + 1)
        XCTAssertEqual(rig.monitor.presence[ref], .failed,
                       "the stored verdict is untouched — this test is about what may be RENDERED")
        XCTAssertNil(rig.monitor.visiblePresence(for: ref),
                     "an overdue verdict may not reach a surface even when its countdown is still parked")

        rig.sleeper.fireAll()
    }

    /// The same read, in the direction that proves it is not simply always nil:
    /// a green verdict is still visible well past the FAILED lifetime, because
    /// the two clocks are genuinely different.
    func testVisiblePresenceKeepsGreenPastTheFailedLifetime() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()

        rig.clock.advance(Constants.gatewayPresenceFailedDisplayLifetime + 1)
        XCTAssertEqual(rig.monitor.visiblePresence(for: ref), .reachable)

        rig.clock.advance(Constants.gatewayPresenceReachableDisplayLifetime)
        XCTAssertNil(rig.monitor.visiblePresence(for: ref))

        rig.sleeper.fireAll()
    }

    /// `observe` retires an overdue claim SYNCHRONOUSLY, before it decides
    /// anything else. A foreground trigger arrives on a process that may have
    /// been suspended for hours; making the user watch one more frame of a stale
    /// red while an actor read completes is the exact failure this guards.
    func testObserveSynchronouslyPrunesAnOverdueClaim() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)
        rig.gate.result = false

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        rig.clock.advance(Constants.gatewayPresenceFailedDisplayLifetime + 1)

        rig.monitor.observe(ref)
        XCTAssertNil(rig.monitor.presence[ref],
                     "the prune must happen before the first await, not after the probe returns")

        await rig.monitor.drainForTesting()
        XCTAssertEqual(rig.monitor.presence[ref], .failed,
                       "and the re-probe still answers — pruning is not a refusal to look again")

        rig.sleeper.fireAll()
    }

    /// Forgetting a gateway takes its countdown with it: no orphan task, and
    /// releasing one afterwards changes nothing.
    func testForgettingAGatewayCancelsItsCountdown() async {
        let rig = makeRig()
        let ref = RemoteAgentRef.builtin(.openclaw)
        await seedGateway(rig, ref: ref)

        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        await rig.sleeper.awaitPark()
        XCTAssertEqual(rig.monitor.presence[ref], .reachable)

        await rig.manager.setRemoteAgentURL(nil, for: ref)
        rig.monitor.observe(ref)
        await rig.monitor.drainForTesting()
        XCTAssertNil(rig.monitor.presence[ref])

        rig.sleeper.fireAll()
        await rig.monitor.drainDisplayExpiryForTesting()
        XCTAssertNil(rig.monitor.presence[ref],
                     "a released orphan countdown must not resurrect or disturb anything")
    }
}
