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

    /// One outage, one finding. The default row names the CONSEQUENCE and carries
    /// the fix, so the broken gateway's own incomplete row would be the same
    /// outage counted twice.
    func testBrokenDefaultSuppressesItsOwnIncompleteRow() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.hermes))

        let runner = await runner()
        XCTAssertEqual(runner.defaultGatewayStanding?.kind, .broken)
        XCTAssertNotNil(defaultRow(runner))
        XCTAssertFalse(
            runner.checks.contains { $0.id == DiagnosticsRunner.incompleteCheckID(for: .builtin(.hermes)) },
            "the standing row is strictly more informative — running both double-counts one outage"
        )
    }

    /// The mirror, and why the suppression is `.broken`-only: under `.autoAdopted`
    /// `brokenRef` is the REPLACED gateway. The standing row explains the switch,
    /// the incomplete row offers the repair — different questions, and the standing
    /// row is `.passed`, so nothing double-counts.
    ///
    /// The replaced gateway is a CUSTOM because a custom is a reliance signal in
    /// its own right: a built-in nothing points at would (correctly) be demoted,
    /// which would make this assertion test the triage rather than the mirror.
    func testAutoAdoptedKeepsTheReplacedGatewaysIncompleteRow() async throws {
        // A token-bearing OpenClaw — the ONLY send-able gateway, and the thing that
        // proves the Keychain is readable (the resolver's adopt gate).
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://openclaw.example.test", forKey: Constants.remoteAgentURLKey(for: openclaw))
        defaults.set(RemoteAgentAuthScheme.bearer.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: openclaw))
        try await SettingsManager.shared.setRemoteAgentToken("token", for: openclaw)

        // A roster custom with no slots: evidence (roster membership) but nothing
        // to send with, and — with no URL — not a pending bearer candidate, so the
        // adopt gate is not refused.
        let customID = UUID()
        let accepted = await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: customID, name: "Workshop")
        )
        XCTAssertTrue(accepted)
        let custom = RemoteAgentRef.custom(customID)
        storeDefaultPointer(custom)

        let runner = await runner()
        XCTAssertEqual(runner.defaultGatewayStanding?.kind, .autoAdopted)
        XCTAssertEqual(defaultRow(runner)?.status, .passed,
                       "the repair already happened — it is informational, never a finding")
        XCTAssertTrue(
            runner.checks.contains { $0.id == DiagnosticsRunner.incompleteCheckID(for: custom) },
            "the replaced gateway keeps its own row: it still offers the repair the standing row does not"
        )
    }

    /// The arithmetic the founder actually sees. Same device, same leftover, one
    /// difference: where the stored pointer points. A broken default must move the
    /// count by EXACTLY one — it is one outage, and its cause must not be counted
    /// beside it.
    func testAttentionCountCountsTheBrokenDefaultExactlyOnce() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.openclaw))
        let healthy = await runner().attentionCount

        storeDefaultPointer(.builtin(.hermes))
        let broken = await runner()
        XCTAssertEqual(broken.defaultGatewayStanding?.kind, .broken)
        XCTAssertEqual(broken.attentionCount, healthy + 1,
                       "one outage, one finding — the broken default's own incomplete row is suppressed")
    }

    // MARK: - The triage rules (pure — no runner, no stores)

    /// A BUILT-IN with residue that nothing points at, nothing is bound to and
    /// nothing focused has not earned the word attention. Built-ins exist on every
    /// install whether anyone wants them, and their slots fill from a half-finished
    /// visit to the editor or from a peer's abandoned attempt arriving over KVS.
    func testTriageDemotesAnUnreliedBuiltinOutOfTheCount() {
        let result = DiagnosticsRunner.triageIncompleteGateways(
            incomplete: [.builtin(.hermes)],
            defaultRef: .builtin(.openclaw),
            boundBackendRawStrings: [],
            focusedRef: nil,
            anyConfigured: true
        )
        XCTAssertEqual(result.reliedOn, [])
        XCTAssertEqual(result.leftover, [.builtin(.hermes)])
    }

    /// The four reliance signals, one assertion each.
    func testTriageKeepsTheDefaultTheCustomTheBoundAndTheFocused() {
        let hermes = RemoteAgentRef.builtin(.hermes)
        let openrouter = RemoteAgentRef.builtin(.openrouter)
        let custom = RemoteAgentRef.custom(UUID())

        // The DEFAULT — every headless capture mints on it, so a broken one is a
        // live outage.
        XCTAssertEqual(
            DiagnosticsRunner.triageIncompleteGateways(
                incomplete: [hermes], defaultRef: hermes,
                boundBackendRawStrings: [], focusedRef: nil, anyConfigured: true
            ).reliedOn,
            [hermes]
        )
        // A CUSTOM — only ROSTER customs are enumerated, so an incomplete custom is
        // by construction one the user created, named and can still see.
        XCTAssertEqual(
            DiagnosticsRunner.triageIncompleteGateways(
                incomplete: [custom], defaultRef: .builtin(.openclaw),
                boundBackendRawStrings: [], focusedRef: nil, anyConfigured: true
            ).reliedOn,
            [custom]
        )
        // A BOUND conversation — bindings are permanent and never silently
        // rerouted, so that thread is dead until this gateway is fixed.
        XCTAssertEqual(
            DiagnosticsRunner.triageIncompleteGateways(
                incomplete: [openrouter], defaultRef: .builtin(.openclaw),
                boundBackendRawStrings: [openrouter.rawString], focusedRef: nil, anyConfigured: true
            ).reliedOn,
            [openrouter]
        )
        // The FOCUSED ref — the user arrived from that gateway's failure.
        XCTAssertEqual(
            DiagnosticsRunner.triageIncompleteGateways(
                incomplete: [hermes], defaultRef: .builtin(.openclaw),
                boundBackendRawStrings: [], focusedRef: hermes, anyConfigured: true
            ).reliedOn,
            [hermes]
        )
    }

    /// With no send-able gateway a half-finished one is the closest thing to a
    /// working setup, and "finish this one" is the best instruction the screen can
    /// give. Nothing is demoted at zero.
    func testTriageDemotesNothingWhenNoGatewayCanSend() {
        let incomplete: [RemoteAgentRef] = [.builtin(.hermes), .builtin(.openrouter)]
        let result = DiagnosticsRunner.triageIncompleteGateways(
            incomplete: incomplete,
            defaultRef: .builtin(.openclaw),
            boundBackendRawStrings: [],
            focusedRef: nil,
            anyConfigured: false
        )
        XCTAssertEqual(result.reliedOn, incomplete)
        XCTAssertEqual(result.leftover, [])
    }

    // MARK: - Leftovers on screen, never in the report

    /// A demoted gateway is nameable on screen (an anonymous "2 leftover gateways"
    /// sent the user to a list that marked none of them) and is absent from
    /// `checks` — which is what keeps it out of `attentionCount` AND out of the
    /// pasted checklist. `leftover=` carries what the row no longer does.
    func testLeftoverGatewaysAreNamedOnScreenButNeverInChecks() async {
        makeSendable(.openclaw)
        makeIncomplete(.hermes)
        storeDefaultPointer(.builtin(.openclaw))

        let runner = await runner()
        XCTAssertEqual(runner.leftoverGateways.map(\.ref), [.builtin(.hermes)])
        XCTAssertFalse(runner.leftoverGateways.first?.displayName.isEmpty ?? true,
                       "a named entry with no name defeats the purpose")
        XCTAssertFalse(
            runner.checks.contains { $0.id == DiagnosticsRunner.incompleteCheckID(for: .builtin(.hermes)) },
            "a demoted gateway has no check row — that is the only honest way to keep it out of the count"
        )

        let block = runner.copyBlock()
        let name = runner.leftoverGateways.first?.displayName ?? "«none»"
        XCTAssertFalse(block.contains(name),
                       "a demoted gateway contributes no checklist line at all:\n\(block)")
        XCTAssertTrue(block.contains("leftover=1"),
                      "…but the support reader still sees what the screen quieted down:\n\(block)")
        XCTAssertTrue(block.contains("partial="),
                      "`partial=` keeps counting ALL incomplete refs, demoted ones included")
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
                      "this fixture is one broken default beside one working gateway: \(line ?? "")")
        XCTAssertTrue(line?.contains("hermes") ?? false,
                      "a built-in travels as its LOCKED raw value: \(line ?? "")")
        XCTAssertFalse(line?.contains("Hermes gateway") ?? true,
                       "…and never as its display name: \(line ?? "")")
        for needle in ["http", "://", "Bearer ", "custom_"] {
            XCTAssertFalse(block.contains(needle), "copy block leaked '\(needle)':\n\(block)")
        }
    }

    // MARK: - I3: an ambiguous read never accuses

    /// `.readingUnreliable` means the READING cannot be trusted — a gateway meets
    /// every non-Keychain requirement and is waiting only on a token that does not
    /// read back. I3 forbids an accusatory finding on that verdict, so no standing
    /// row is emitted and every incomplete row keeps its id, status and colour
    /// while saying the non-accusatory thing instead.
    ///
    /// The rows are RE-WORDED rather than deleted on purpose: at zero-configured
    /// `connection.gateway.none` is already suppressed whenever any incomplete ref
    /// exists, so deleting the last incomplete row would leave the Connection
    /// section with a footer and nothing else.
    func testUnreadableVerdictUsesTheNonAccusatoryIncompleteCopy() async {
        // A URL with no token under the fail-closed default (`.bearer`): nothing can
        // send, and OpenClaw is one Keychain delivery away from working.
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://openclaw.example.test", forKey: Constants.remoteAgentURLKey(for: openclaw))

        let runner = await runner()
        XCTAssertNil(runner.defaultGatewayStanding,
                     "an ambiguous read may never mint an accusatory finding (I3)")

        let row = runner.checks.first { $0.id == DiagnosticsRunner.incompleteCheckID(for: openclaw) }
        XCTAssertNotNil(row, "the incomplete row stands — deleting it would empty the section")
        if case .failed = row?.status {} else {
            XCTFail("with nothing send-able the row is RED, exactly as it is on any other verdict: \(String(describing: row?.status))")
        }
        let detail = row?.detail ?? ""
        XCTAssertTrue(detail.contains("can't read this gateway's saved details"),
                      "the row states the readability problem, not a setup accusation: \(detail)")
        XCTAssertFalse(detail.contains("never finished"),
                       "…and must not tell the user to finish setup that may already be finished: \(detail)")
    }
}
