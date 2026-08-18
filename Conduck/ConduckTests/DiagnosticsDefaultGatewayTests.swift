// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsDefaultGatewayTests.swift
//
// The Diagnostics screen's account of ONE question: which gateway does a new chat
// get, and can that gateway actually send? The screen held both halves of that
// answer — the configured set and the default pointer, read two lines apart — and
// joined neither, so the single condition that silently killed new chats,
// GigaAction, Control Center, CarPlay and the wrist was the one thing it could
// not report. Five green gateway rows sat above a completely dead lane.
//
// The other half of this file is the attention TRIAGE. "2 items need attention"
// counted a genuinely broken gateway and a leftover slot from an abandoned save
// that nothing pointed at, nothing was bound to, and nothing relied on. A
// built-in with residue nobody depends on is tidying, not a finding, so it is
// demoted OUT of `checks` — the only honest way to keep it out of a count that
// sums `checks`.
//
// Isolation: the runner reads the `SettingsManager.shared` singleton, so the
// process-global in-memory stores are wiped on both edges. Every fixture is then
// exact rather than ambient — no `XCTSkipIf` on whatever a sibling suite left
// behind, and no network (the auto-read tier is local by construction).
//
// A wipe settles only what a sibling suite has ALREADY written. It cannot settle
// what one is STILL writing: every `SettingsViewModel()` starts an unstructured
// load task and registers a `.settingsDidChangeRemotely` observer, both of which
// resolve the default gateway on `.shared`, and those suites return long before
// the task drains. So the one case here that needs no runner —
// `testAParkedPointerStopsBeingParkedOnceItsGatewayCanSend` — drives its own
// `SettingsManager` over its own store, which no other suite can reach.

import XCTest
@testable import Conduck

@MainActor
final class DiagnosticsDefaultGatewayTests: XCTestCase {

    private var defaults: InMemoryDefaultsStore { TestStores.defaults }

    override func setUp() async throws {
        try await super.setUp()
        TestStores.removeAll()
    }

    override func tearDown() async throws {
        TestStores.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures (all keyless or slot-only — the Keychain is in-memory here)

    /// A gateway that CAN send: a URL plus an explicit keyless auth scheme.
    private func makeSendable(_ backend: RemoteAgentBackend) {
        let ref = RemoteAgentRef.builtin(backend)
        defaults.set("https://\(backend.rawValue).example.test", forKey: Constants.remoteAgentURLKey(for: ref))
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: ref))
    }

    /// A gateway that is HALF set up and cannot send: an auth-scheme slot with no
    /// URL. Deliberately the KEYLESS scheme, so the resolver's blackout hazard
    /// (which fires only for a token-bearing pointer) stays out of the fixture and
    /// the verdict under test is the one being asserted.
    private func makeIncomplete(_ backend: RemoteAgentBackend) {
        let ref = RemoteAgentRef.builtin(backend)
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: ref))
    }

    private func storeDefaultPointer(_ ref: RemoteAgentRef) {
        defaults.set(ref.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
    }

    private func runner() async -> DiagnosticsRunner {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        return runner
    }

    private func defaultRow(_ runner: DiagnosticsRunner) -> DiagnosticCheck? {
        runner.checks.first { $0.id == DiagnosticsRunner.defaultGatewayCheckID }
    }

    // MARK: - The verdict map

    /// First run is not a failure. With nothing send-able the screen already has a
    /// better story — `connection.gateway.none`, or one named red row per
    /// half-configured gateway plus the footer — and the default pointer is not why
    /// the device is stuck. Emitting this row too would count one outage plus its
    /// cause as two findings.
    func testDefaultGatewayRowIsAbsentWhenNothingCanSend() async {
        let runner = await runner()
        XCTAssertNil(runner.defaultGatewayStanding,
                     "nothing can send — the default pointer is not the reason, so it says nothing")
        XCTAssertNil(defaultRow(runner),
                     "no standing ⇒ no row, and therefore nothing added to attentionCount")
    }

    /// The ordinary case: the stored pointer is a member of the configured set.
    func testDefaultGatewayRowIsGreenWhenTheDefaultCanSend() async {
        makeSendable(.openclaw)
        storeDefaultPointer(.builtin(.openclaw))

        let runner = await runner()
        XCTAssertEqual(runner.defaultGatewayStanding?.kind, .ready)
        XCTAssertEqual(defaultRow(runner)?.status, .passed,
                       "a pointer that names a send-able gateway is a pass, not a silence")
    }

    /// THE REPORTED BUG. A stored pointer that cannot send, beside gateways that
    /// can. Red, naming the broken default and offering the working ones — and the
    /// names live OUTSIDE `checks`, because `copyBlock()` reads `check.title` /
    /// `check.detail` and the allowlist forbids a user's own gateway label there.
    func testBrokenDefaultBesideWorkingGatewaysIsRedAndNamesTheCandidates() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.hermes))

        let runner = await runner()
        let standing = runner.defaultGatewayStanding
        XCTAssertEqual(standing?.kind, .broken)
        XCTAssertEqual(defaultRow(runner)?.status,
                       .failed(code: AppError.remoteAgentNotConfigured.errorCode),
                       "the whole lane is down with no picker in it — red, not amber")
        XCTAssertFalse(standing?.candidates.isEmpty ?? true,
                       "the roster offers alternatives; the row has to be able to offer them back")
        XCTAssertTrue(standing?.candidates.contains { $0.ref == .builtin(.openclaw) } ?? false)

        let name = standing?.defaultName ?? ""
        XCTAssertFalse(name.isEmpty, "the broken default has to be nameable on screen")
        XCTAssertFalse(defaultRow(runner)?.title.contains(name) ?? true,
                       "the row's own title is copy-safe and must not carry a gateway name")
        XCTAssertFalse(defaultRow(runner)?.detail?.contains(name) ?? true,
                       "the row's own detail is copy-safe and must not carry a gateway name")
    }

    /// No stored pointer and two gateways that can send — the device cannot
    /// honestly infer one, so it asks. Same red, same Fix action, but nothing is
    /// named "broken": nothing is broken, the question has simply never been
    /// answered.
    func testNoDefaultChosenIsRedAndOffersTheSameFix() async {
        makeSendable(.openclaw)
        makeSendable(.hermes)

        let runner = await runner()
        let standing = runner.defaultGatewayStanding
        XCTAssertEqual(standing?.kind, .notChosen)
        XCTAssertEqual(standing?.offersFix, true, "its only exit is the user picking a gateway")
        XCTAssertEqual(standing?.defaultName, "",
                       "the projected ref is the built-in compatibility fallback, not a user choice — naming it would invent a default")
        XCTAssertEqual(standing?.candidates.count, 2)
        XCTAssertEqual(defaultRow(runner)?.status,
                       .failed(code: AppError.remoteAgentNotConfigured.errorCode))
    }

    /// A pointer the APP parked after a Forget is a placeholder, not a default.
    /// Diagnostics said "<Name> is your default for new chats, but it can't
    /// send" — a sentence that blames the user for a pointer the app wrote one
    /// step after they forgot a different gateway. It takes the `.notChosen`
    /// standing instead: no name, same red, same Fix.
    ///
    /// STAGED ON `.shared`, so the contamination window described in the file
    /// header reaches THIS case: a sibling suite's still-draining resolve can
    /// delete the dangling-custom pointer before `repointDefaultAfterForget`
    /// sees it, and the re-point then returns without parking. What is left —
    /// no pointer, two keyless customs that can send — resolves
    /// `.selectionRequired`, which the runner maps to the SAME `.notChosen`
    /// kind, the same empty `defaultName`, the same `offersFix` and the same
    /// failed row. Every assertion below still passes; it has simply stopped
    /// proving a park. `testAParkedPointerStopsBeingParkedOnceItsGatewayCanSend`
    /// is where that proof is held, on a store no other suite can reach.
    func testParkedDefaultReadsAsNotChosenAndNamesNobody() async {
        await parkThePointerOnTheBuiltInDefault(in: defaults, on: .shared)

        let runner = await runner()
        let standing = runner.defaultGatewayStanding
        XCTAssertEqual(standing?.kind, .notChosen,
                       "the app put this pointer here — there is no default to call broken")
        XCTAssertEqual(standing?.defaultName, "",
                       "a placeholder must not be named; the copy for this case names none")
        XCTAssertEqual(standing?.offersFix, true, "its only exit is still the user picking a gateway")
        XCTAssertEqual(defaultRow(runner)?.status,
                       .failed(code: AppError.remoteAgentNotConfigured.errorCode),
                       "the lane is just as dead — only the attribution changes")
    }

    /// The exit finding 3 closes. The banner and this screen both tell the user
    /// the parked gateway is not set up here; a user who takes that advice writes
    /// no pointer, so the marker has to retire on its own when the gateway
    /// becomes send-able. Otherwise the pointer reads as app-parked forever.
    ///
    /// The only case here that reads its answer from `SettingsManager` without
    /// building a runner, so it is the only one free to hold its own store — and
    /// it has to. Its fixture stores a pointer at a custom with nothing left
    /// behind it, and any resolve landing on `.shared` inside that window deletes
    /// exactly that pointer (the dangling-custom drop, doing its job).
    /// `repointDefaultAfterForget` then finds a pointer that no longer names the
    /// forgotten gateway and returns without parking, which is what the control
    /// below catches.
    func testAParkedPointerStopsBeingParkedOnceItsGatewayCanSend() async {
        let store = InMemoryDefaultsStore()
        let manager = SettingsManager(dependencies: .inMemory(
            defaults: store,
            ubiquitous: InMemoryUbiquitousStore(),
            cloudAvailable: false
        ))
        await parkThePointerOnTheBuiltInDefault(in: store, on: manager)

        let parked = await manager.newChatPickerSnapshot()
        XCTAssertTrue(parked.defaultPointerIsParked, "Control: the fixture must genuinely park.")

        // The user follows the advice and finishes setting that gateway up. No
        // pointer is written — the pointer was already aimed at it.
        let builtInDefault = RemoteAgentRef.builtin(Constants.remoteAgentDefaultBackendDefault)
        store.set("https://\(Constants.remoteAgentDefaultBackendDefault.rawValue).example.test",
                  forKey: Constants.remoteAgentURLKey(for: builtInDefault))
        store.set(RemoteAgentAuthScheme.none.rawValue,
                  forKey: Constants.remoteAgentAuthSchemeKey(for: builtInDefault))

        let healed = await manager.newChatPickerSnapshot()
        XCTAssertFalse(healed.defaultPointerIsParked,
                       "The marker's only job is to stop a refusal naming a gateway nobody picked, and a "
                       + "pointer that can send raises no refusal to name anything in.")
        XCTAssertNil(store.string(forKey: Constants.remoteAgentParkedDefaultRefKey),
                     "Cleared outright, so a later breakage cannot resurrect the placeholder reading.")
    }

    /// Forget a custom while two other CUSTOMS survive: no built-in is among the
    /// survivors, so the re-point parks on `Constants.remoteAgentDefaultBackendDefault`
    /// — a gateway the user never chose and has not set up here. That is the state
    /// both parked cases above need, and it is the real one users reach.
    ///
    /// Store and manager are passed in rather than reached for, so the runner
    /// case can stage it on the singleton the runner reads while the case above
    /// stages the identical state somewhere no other suite can touch. Identical
    /// literally: the isolated bundle spells `cloudAvailable: false`, which is
    /// what `.processDefault` resolves to under `CONDUCK_TESTING`, so the two
    /// managers agree about the KVS read-fallback as well as about the slots.
    private func parkThePointerOnTheBuiltInDefault(
        in store: InMemoryDefaultsStore,
        on manager: SettingsManager
    ) async {
        var roster: [CustomGateway] = []
        for name in ["Work Box", "Home Box"] {
            let gateway = CustomGateway(id: UUID(), name: name)
            roster.append(gateway)
            let ref = RemoteAgentRef.custom(gateway.id)
            store.set("https://custom.example.test", forKey: Constants.remoteAgentURLKey(for: ref))
            store.set(RemoteAgentAuthScheme.none.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: ref))
        }
        // A custom counts as configured only when it is ALSO on the roster —
        // `configuredRemoteAgentRefs()` walks `customGateways()`, not the slots.
        store.set(try? JSONEncoder().encode(roster), forKey: Constants.customGatewaysRegistryKey)
        let goneID = UUID()
        store.set(RemoteAgentRef.custom(goneID).rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        await manager.repointDefaultAfterForget(of: .custom(goneID))
    }

    // MARK: - Diagnostics is silent about a gateway that is merely not connected

    /// THE rule this screen now enforces. A gateway holding stored state this
    /// device cannot send on earns NO row, no matter how it got that way — not a
    /// warning, not a red row, not a quiet "leftover" entry. It is a menu item the
    /// user declined, and Diagnostics reports faults.
    ///
    /// Asserted by prefix rather than against one id, because the point is that
    /// the whole category is gone: any future re-introduction under a new id fails
    /// here too.
    func testNoPerGatewayRowIsEmittedForAnUnavailableGateway() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.openclaw))

        let runner = await runner()
        XCTAssertFalse(
            runner.checks.contains { $0.id.hasPrefix("connection.gateway.incomplete.") },
            "an unconnected gateway is not a finding — the whole row category is retired"
        )
        XCTAssertFalse(
            runner.checks.contains { $0.title.localizedCaseInsensitiveContains("Hermes") },
            "…and it must not reappear under some other row's title either"
        )
    }

    /// The same silence when the unavailable gateway is the DEFAULT. Here the
    /// standing row speaks — it is about the LANE (new chats, GigaAction, CarPlay,
    /// the wrist), which really is down — but the gateway still gets no row of its
    /// own, so one outage is still one finding.
    func testAnUnavailableDefaultProducesTheStandingRowAndNothingElse() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.hermes))

        let runner = await runner()
        XCTAssertEqual(runner.defaultGatewayStanding?.kind, .broken)
        XCTAssertNotNil(defaultRow(runner))
        XCTAssertFalse(
            runner.checks.contains { $0.id.hasPrefix("connection.gateway.incomplete.") },
            "the standing row is the only thing said about a pointer that cannot send"
        )
    }

    /// The arithmetic the founder actually sees. Same device, same residue, one
    /// difference: where the stored pointer points. An unavailable default moves
    /// the count by EXACTLY one.
    func testAttentionCountCountsTheUnavailableDefaultExactlyOnce() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.openclaw))
        let healthy = await runner().attentionCount

        storeDefaultPointer(.builtin(.hermes))
        let unavailable = await runner()
        XCTAssertEqual(unavailable.defaultGatewayStanding?.kind, .broken)
        XCTAssertEqual(unavailable.attentionCount, healthy + 1,
                       "one outage, one finding")
    }

    /// Residue on a device where everything else works contributes NOTHING the
    /// user can see — no row, no count, and no named entry anywhere on screen.
    /// This is the screenshot the founder sent, inverted.
    func testResidueBesideWorkingGatewaysIsInvisible() async {
        makeSendable(.openclaw)
        storeDefaultPointer(.builtin(.openclaw))
        let clean = await runner().attentionCount

        makeIncomplete(.hermes)
        let withResidue = await runner()
        XCTAssertEqual(withResidue.attentionCount, clean,
                       "residue must not move the attention count by so much as one")
    }

    // MARK: - The device-level outage row

    /// The row that SURVIVES the purge, and the bug the purge exposed. It used to
    /// require `incompleteRefs.isEmpty` as well, because a per-gateway red row
    /// covered the rest — so with those rows gone, a device holding residue and
    /// nothing send-able would have shown nothing at all. It now keys on the one
    /// fact it is about: nothing here can send.
    func testTheDeviceLevelRowFiresEvenWhenResidueExists() async {
        makeIncomplete(.hermes)   // residue, and nothing send-able anywhere

        let runner = await runner()
        let row = runner.checks.first { $0.id == "connection.gateway.none" }
        XCTAssertNotNil(row, "with nothing send-able the device-level row is the whole story")
        XCTAssertFalse(
            runner.checks.contains { $0.id.hasPrefix("connection.gateway.incomplete.") },
            "…and it does not bring the per-gateway rows back with it"
        )
    }

    /// The two rows answer DIFFERENT questions and must both appear when both are
    /// true — the device-level row is not the `else` of the focused one.
    ///
    /// This is the worst case on the screen: the user arrived from a conversation
    /// that failed, on a device where nothing works at all. Emitted as an `else`,
    /// the focused row would be alone, telling them to "clone the conversation to
    /// a gateway that works" with no gateway that works and nothing saying so.
    func testTheDeviceLevelRowAccompaniesTheFocusedRowWhenNothingCanSend() async {
        makeIncomplete(.hermes)   // residue, and nothing send-able anywhere
        let focused = RemoteAgentRef.builtin(.openclaw)

        let runner = DiagnosticsRunner(focusedRef: focused)
        await runner.runAutoReads()

        XCTAssertTrue(runner.checks.contains { $0.id == "connection.gateway.focused.missing" },
                      "the conversation the user came from still earns its row")
        XCTAssertTrue(runner.checks.contains { $0.id == "connection.gateway.none" },
                      "…and so does the fact that nothing on the device can send")
    }

    /// The same focused arrival on a device that CAN send: one row, not two. The
    /// device-level row is about the device, and this device is fine.
    func testTheFocusedRowStandsAloneWhenSomethingElseCanSend() async {
        makeSendable(.hermes)
        storeDefaultPointer(.builtin(.hermes))

        let runner = DiagnosticsRunner(focusedRef: .builtin(.openclaw))
        await runner.runAutoReads()

        XCTAssertTrue(runner.checks.contains { $0.id == "connection.gateway.focused.missing" })
        XCTAssertFalse(runner.checks.contains { $0.id == "connection.gateway.none" },
                       "a device with a working gateway is not in an outage")
    }

    /// A device that can send says nothing device-level.
    func testTheDeviceLevelRowIsAbsentWhenSomethingCanSend() async {
        makeSendable(.openclaw)
        storeDefaultPointer(.builtin(.openclaw))

        let runner = await runner()
        XCTAssertNil(runner.checks.first { $0.id == "connection.gateway.none" })
    }

    // MARK: - The copy block's joined fact

    /// The verdict travels as an anonymous token plus a CLOSED vocabulary — never a
    /// display name, never a URL, never anything token-shaped (I5).
    func testCopyBlockReportsTheDefaultStandingAndStaysPasteSafe() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.hermes))

        let runner = await runner()
        let block = runner.copyBlock()
        let line = block.split(separator: "\n").first { $0.hasPrefix("Default: ") }
        XCTAssertNotNil(line, "the joined default-vs-reality fact must reach the report:\n\(block)")

        let verdicts = ["ok", "ok(auto-adopted)", "broken(candidates=", "not-chosen(candidates=",
                        "none-configured", "unreadable", "setup-unfinished"]
        XCTAssertTrue(verdicts.contains { line?.contains($0) ?? false },
                      "the verdict vocabulary is closed — '\(line ?? "")' is not in it")
        XCTAssertTrue(line?.contains("broken(candidates=1)") ?? false,
                      "this fixture is one unavailable default beside one working gateway: \(line ?? "")")
        XCTAssertTrue(line?.contains("hermes") ?? false,
                      "a built-in travels as its LOCKED raw value: \(line ?? "")")
        XCTAssertFalse(line?.contains("Hermes gateway") ?? true,
                       "…and never as its display name: \(line ?? "")")
        for needle in ["http", "://", "Bearer ", "custom_"] {
            XCTAssertFalse(block.contains(needle), "copy block leaked '\(needle)':\n\(block)")
        }
    }

    /// `partial=` is the ONE trace of unavailable gateways left anywhere, and it
    /// never reaches the screen. It is anonymous, so it costs the user nothing,
    /// and it is the only way a support conversation can see residue the UI now
    /// deliberately says nothing about.
    func testResidueIsInvisibleOnScreenButStillCountedForSupport() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.openclaw))

        let runner = await runner()
        let block = runner.copyBlock()
        XCTAssertTrue(block.contains("partial=1"),
                      "the support reader still sees what the screen is quiet about:\n\(block)")
        XCTAssertFalse(block.contains("leftover="),
                       "…but the demoted-list vocabulary is gone with the list:\n\(block)")
        XCTAssertFalse(block.contains("Hermes"),
                       "a gateway with residue contributes no checklist line at all:\n\(block)")
    }

    // MARK: - I3: an ambiguous read never accuses

    /// `.readingUnreliable` means the READING cannot be trusted — a gateway meets
    /// every non-Keychain requirement and is waiting only on a token that does not
    /// read back. I3 forbids an accusatory finding on that verdict.
    ///
    /// It used to be enforced by RE-WORDING each incomplete row, because deleting
    /// the last one would have emptied the section. With the rows gone the guard is
    /// simpler and stronger: nothing gateway-specific is said at all, and the
    /// device-level row carries the section on its own.
    func testUnreadableVerdictSaysNothingAboutAnyGateway() async {
        // A URL with no token under the fail-closed default (`.bearer`): nothing can
        // send, and OpenClaw is one Keychain delivery away from working.
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://openclaw.example.test", forKey: Constants.remoteAgentURLKey(for: openclaw))

        let runner = await runner()
        XCTAssertNil(runner.defaultGatewayStanding,
                     "an ambiguous read may never mint an accusatory finding (I3)")
        XCTAssertFalse(
            runner.checks.contains { $0.id.hasPrefix("connection.gateway.incomplete.") },
            "no gateway is named or accused on a reading that cannot be trusted"
        )
        XCTAssertNotNil(runner.checks.first { $0.id == "connection.gateway.none" },
                        "the section is carried by the device-level row, which claims nothing about why")
    }
}
