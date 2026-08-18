// SPDX-License-Identifier: Apache-2.0

// Conduck
// GigaActionPreflightTests.swift
//
// The three rules that decide whether the bundled shortcut's pre-flight refuses
// a capture BEFORE the microphone, and what it says when it does:
//
//   1. The pre-flight asks the ROUTER's question. A capture that would have been
//      appended to a live conversation on a working gateway is not refused by
//      any verdict about the default — and one bound to a gateway that is not
//      set up here still is.
//   2. A pointer the APP parked after a Forget is never called "your default AI".
//   3. A fix route armed hours ago is dropped when the default can send again.
//
// Every test builds its own `SettingsManager` over an in-memory dependency
// bundle (no shared singleton, no App Group, no wipe choreography) and an
// in-memory `ConversationStore`. Gateways are seeded KEYLESS — a URL plus an
// explicit `.none` auth scheme is send-able on its own, so nothing here needs a
// Keychain write and the whole file runs on an unsigned build.

import XCTest
@testable import Conduck

final class GigaActionPreflightTests: XCTestCase {

    // Key literals pinned independently of `Constants` so a rename that would
    // orphan real user data breaks a test rather than silently re-homing keys.
    private let openclawURLKey = "remoteAgent.url.openclaw"
    private let openclawAuthKey = "remoteAgent.authScheme.openclaw"
    private let hermesURLKey = "remoteAgent.url.hermes"
    private let hermesAuthKey = "remoteAgent.authScheme.hermes"
    private let defaultBackendKey = "remoteAgent.defaultBackend"
    private let parkedDefaultKey = "remoteAgent.parkedDefaultRef"
    private let gatewayRosterKey = "remoteAgent.customGateways"

    /// `GatewayFixRoute`'s latch is process-wide by design, so every test starts
    /// by spending anything a previous one left armed.
    override func setUp() async throws {
        try await super.setUp()
        let manager = makeManager()
        _ = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
    }

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        cloudAvailable: Bool = true
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            cloudAvailable: cloudAvailable
        ))
    }

    private func seedKeylessGateway(_ defaults: InMemoryDefaultsStore, urlKey: String, authKey: String) {
        defaults.set("https://gateway.example.test", forKey: urlKey)
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: authKey)
    }

    /// A keyless CUSTOM gateway, roster entry included, ready to be counted as a
    /// survivor.
    private func seedKeylessCustom(_ defaults: InMemoryDefaultsStore, roster: inout [CustomGateway],
                                   id: UUID, name: String) throws {
        roster.append(CustomGateway(id: id, name: name))
        defaults.set(try JSONEncoder().encode(roster), forKey: gatewayRosterKey)
        let ref = RemoteAgentRef.custom(id)
        seedKeylessGateway(defaults,
                           urlKey: Constants.remoteAgentURLKey(for: ref),
                           authKey: Constants.remoteAgentAuthSchemeKey(for: ref))
    }

    /// Stamp the quick-capture pointer at `id` with a fresh activity, so the
    /// default `.minutes30` policy resolves "continue".
    private func stampPointer(_ manager: SettingsManager, _ id: UUID) async {
        await manager.recordActiveConversation(id)
    }

    // MARK: - 1. The pre-flight asks the router's question

    /// THE REGRESSION. Two gateways work, the user never picked a default
    /// (`.selectionRequired`), and Action-Button captures have been appending to
    /// one OpenClaw thread for weeks. `resolveOrMint` continues that thread and
    /// never looks at the default — so the pre-flight must not refuse the
    /// capture on the default's verdict.
    func testLivePointerOnConfiguredGatewaySurvivesSelectionRequired() async throws {
        let defaults = InMemoryDefaultsStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        // No stored pointer: two gateways can send, so the device asks rather
        // than guessing.
        let manager = makeManager(defaults: defaults)
        let store = ConversationStore(inMemory: true)

        let snap = await manager.newChatPickerSnapshot()
        guard case .selectionRequired = snap.resolution else {
            return XCTFail("Precondition: two configured gateways and no pointer is .selectionRequired, got \(snap.resolution).")
        }

        let row = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await stampPointer(manager, row.id)

        let canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertTrue(canContinue,
                      "A live pointer on a gateway that is set up here is what the router routes on — "
                      + "refusing this capture would refuse a chat that was never going to be minted.")

        // …and the router really does continue that thread, which is the fact
        // the pre-flight is claiming on its behalf.
        let resolved = try await SharedInboxRouting.resolveOrMint(settings: manager, store: store)
        XCTAssertEqual(resolved.conversationID, row.id)
    }

    /// THE TWIN (I1). The pointer's conversation is bound to a gateway that is
    /// NOT set up on this device. Nothing may reroute it, so the refusal stands
    /// exactly as it does with no pointer at all.
    func testLivePointerOnUnconfiguredBoundGatewayStillRefuses() async throws {
        let defaults = InMemoryDefaultsStore()
        // OpenClaw is the stored default and is NOT send-able: a scheme slot and
        // no URL. Keyless, so the reading is trustworthy (no blackout hazard).
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)
        let store = ConversationStore(inMemory: true)

        let snap = await manager.newChatPickerSnapshot()
        guard case .defaultUnavailable = snap.resolution else {
            return XCTFail("Precondition: a dead pointer beside a working gateway is .defaultUnavailable, got \(snap.resolution).")
        }

        let row = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await stampPointer(manager, row.id)

        let canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertFalse(canContinue,
                       "A conversation is BOUND to its gateway. With that gateway unconfigured the capture "
                       + "dead-ends, so the pre-flight must still refuse — cloning is the user's exit, not a reroute.")

        // The router agrees: it refuses too, and mints nothing.
        do {
            _ = try await SharedInboxRouting.resolveOrMint(settings: manager, store: store)
            XCTFail("The bound gateway is unconfigured — routing must throw.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, AppError.remoteAgentNotConfigured.errorCode)
        }
    }

    /// The pointer names a conversation on a gateway that WORKS but is not the
    /// default. The router treats that as "no pointer" and mints on the default,
    /// so the pre-flight must fall through to the default's verdict too — the
    /// two answering differently here is the drift this helper exists to stop.
    func testLivePointerOnNonDefaultGatewayFallsThroughToTheDefaultVerdict() async throws {
        let defaults = InMemoryDefaultsStore()
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)
        let store = ConversationStore(inMemory: true)

        let snap = await manager.newChatPickerSnapshot()
        let row = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)
        await stampPointer(manager, row.id)

        let canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertFalse(canContinue,
                       "A pointer bound to a non-default gateway is not continued, so the capture is a NEW "
                       + "chat and the default's verdict decides it.")
    }

    /// THE FOUR-STATE TABLE both headless lanes and BOTH PLATFORMS answer.
    /// `WatchRecordingService.liveCaptureCanContinue` is the wrist's sibling of
    /// this helper — a separate target cannot link `SharedInboxRouting` — and
    /// `WatchCaptureGuardTests.testTheWristAnswersThePhonesLiveCaptureTable`
    /// walks the identical four rows. Change one table and the other must change
    /// with it, or the two surfaces have silently drifted apart again.
    func testTheLiveCaptureTableAnswersFourWays() async throws {
        // Row 1 — pointer bound to a CONFIGURED gateway that is the default:
        //         continue (covered by the two named cases above too, kept here
        //         so the table is readable as one thing).
        // Row 2 — pointer bound to the default, which is NOT configured: refuse.
        // Row 3 — pointer bound to a configured NON-default gateway: fall through.
        // Row 4 — no live pointer at all: fall through.
        let defaults = InMemoryDefaultsStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)
        let store = ConversationStore(inMemory: true)
        let snap = await manager.newChatPickerSnapshot()

        // Row 4 first — nothing stamped yet.
        var canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertFalse(canContinue, "Row 4: no pointer, so the default's verdict decides.")

        // Row 1.
        let onDefault = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        await stampPointer(manager, onDefault.id)
        canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertTrue(canContinue, "Row 1: the thread is live and its gateway can send.")

        // Row 3.
        let offDefault = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)
        await stampPointer(manager, offDefault.id)
        canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: snap.defaultRef, settings: manager, store: store)
        XCTAssertFalse(canContinue, "Row 3: a non-default binding is not continued — this is a NEW chat.")

        // Row 2 — the default loses its URL, so the pointer's own gateway can no
        // longer send. The binding is untouched (I1); only the refusal changes.
        defaults.removeObject(forKey: openclawURLKey)
        await stampPointer(manager, onDefault.id)
        let brokenSnap = await manager.newChatPickerSnapshot()
        canContinue = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: brokenSnap.defaultRef, settings: manager, store: store)
        XCTAssertFalse(canContinue, "Row 2: a bound gateway that cannot send still refuses.")
    }

    // MARK: - 2. A parked pointer is never called "your default AI"

    /// Forget a gateway with two customs surviving: the pointer parks on a
    /// built-in the user never chose, and here never even set up. The verdict is
    /// `.defaultUnavailable`, and the snapshot says the pointer is parked so the
    /// sentence drops the name.
    func testForgetParkedPointerIsMarkedAndGoesUnnamed() async throws {
        let defaults = InMemoryDefaultsStore()
        var roster: [CustomGateway] = []
        let workID = UUID(), homeID = UUID(), goneID = UUID()
        try seedKeylessCustom(defaults, roster: &roster, id: workID, name: "Work Box")
        try seedKeylessCustom(defaults, roster: &roster, id: homeID, name: "Home Box")
        // The gateway being forgotten IS the stored default.
        defaults.set(RemoteAgentRef.custom(goneID).rawString, forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        await manager.repointDefaultAfterForget(of: .custom(goneID))

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), "openclaw",
                       "Two survivors and no built-in among them parks the pointer on the built-in default — "
                       + "the user chooses their next gateway rather than inheriting one.")
        XCTAssertEqual(defaults.string(forKey: parkedDefaultKey), "openclaw",
                       "…and the park is recorded, because the pointer alone cannot say who wrote it.")

        let snap = await manager.newChatPickerSnapshot()
        guard case .defaultUnavailable(let broken, _, _) = snap.resolution else {
            return XCTFail("Precondition: the parked built-in is not configured here, got \(snap.resolution).")
        }
        XCTAssertEqual(broken, .builtin(.openclaw))
        XCTAssertTrue(snap.defaultPointerIsParked,
                      "The app parked this pointer one step after a Forget — naming it 'your default AI' "
                      + "would blame the user for a choice they never made.")

        // The refusal the headless lanes actually throw carries NO name.
        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(settings: manager, store: store)
            XCTFail("A broken default must refuse.")
        } catch AppError.remoteAgentDefaultNeedsSetup(let gatewayName) {
            XCTAssertNil(gatewayName,
                         "A parked pointer takes the unnamed sentence: Conduck doesn't know which AI to use.")
        }
    }

    /// The other half of the same rule: a pointer the USER chose is still named
    /// when it breaks. Nothing about the honest case changes.
    func testUserChosenBrokenDefaultIsStillNamed() async throws {
        let defaults = InMemoryDefaultsStore()
        var roster: [CustomGateway] = []
        try seedKeylessCustom(defaults, roster: &roster, id: UUID(), name: "Work Box")
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        // OpenClaw is unconfigured, and the user picked it themselves.
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: openclawAuthKey)
        let manager = makeManager(defaults: defaults)
        await manager.applyUserChosenDefault(.builtin(.openclaw))

        let snap = await manager.newChatPickerSnapshot()
        XCTAssertFalse(snap.defaultPointerIsParked,
                       "The user picked this one — the sentence may name it.")

        let store = ConversationStore(inMemory: true)
        do {
            _ = try await SharedInboxRouting.resolveOrMint(settings: manager, store: store)
            XCTFail("A broken default must refuse.")
        } catch AppError.remoteAgentDefaultNeedsSetup(let gatewayName) {
            XCTAssertEqual(gatewayName, "OpenClaw",
                           "A default the user chose is named, so they fix the right gateway.")
        }
    }

    /// Choosing the very gateway that was parked makes it the user's own. The
    /// marker is cleared outright, because a by-value comparison alone would
    /// still match.
    func testChoosingTheParkedGatewayClearsTheMarker() async throws {
        let defaults = InMemoryDefaultsStore()
        var roster: [CustomGateway] = []
        try seedKeylessCustom(defaults, roster: &roster, id: UUID(), name: "Work Box")
        try seedKeylessCustom(defaults, roster: &roster, id: UUID(), name: "Home Box")
        let goneID = UUID()
        defaults.set(RemoteAgentRef.custom(goneID).rawString, forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        await manager.repointDefaultAfterForget(of: .custom(goneID))
        XCTAssertEqual(defaults.string(forKey: parkedDefaultKey), "openclaw")

        await manager.applyUserChosenDefault(.builtin(.openclaw))
        let snap = await manager.newChatPickerSnapshot()
        XCTAssertFalse(snap.defaultPointerIsParked,
                       "Re-picking the parked gateway is a choice; the pointer stops being a placeholder.")
    }

    /// A pointer with no marker at all — every install that predates the key,
    /// and every ordinary user choice — reads as the user's own.
    func testPointerWithNoMarkerReadsAsUserChosen() async {
        let defaults = InMemoryDefaultsStore()
        seedKeylessGateway(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)

        let snap = await manager.newChatPickerSnapshot()
        XCTAssertFalse(snap.defaultPointerIsParked,
                       "Absent means chosen — anything else would silence the named sentence for everyone.")
    }

    // MARK: - 3. A fix route drops when the problem is already fixed

    @MainActor
    func testArmedRouteStandsWhileTheDefaultStillCannotSend() async {
        // A device with nothing configured: the route is exactly as true as when
        // it was armed.
        let manager = makeManager()
        GatewayFixRoute.request()

        let landed = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
        XCTAssertTrue(landed, "The default still cannot send — the user belongs on the fix.")

        let again = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
        XCTAssertFalse(again, "One-shot: a second root must not navigate on the same request.")
    }

    @MainActor
    func testArmedRouteIsDroppedOnceTheDefaultCanSendAgain() async {
        // Armed at 09:00 against a broken default; by the time the app opens the
        // user has fixed it on another device and the setting has synced.
        let defaults = InMemoryDefaultsStore()
        seedKeylessGateway(defaults, urlKey: openclawURLKey, authKey: openclawAuthKey)
        defaults.set("openclaw", forKey: defaultBackendKey)
        let manager = makeManager(defaults: defaults)
        GatewayFixRoute.request()

        let landed = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
        XCTAssertFalse(landed,
                       "Dropping into Settings for a problem solved hours ago is worse than saying nothing.")

        // …and the request is spent either way, so a later root doesn't inherit it.
        GatewayFixRoute.request()
        _ = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
    }

    @MainActor
    func testUnarmedRouteNeverNavigates() async {
        let manager = makeManager()
        let landed = await GatewayFixRoute.consumeIfStillBroken(settings: manager)
        XCTAssertFalse(landed, "Nothing armed the route — an app launch must not land in Settings.")
    }
}
