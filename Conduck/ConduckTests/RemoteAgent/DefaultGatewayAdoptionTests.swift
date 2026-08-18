// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayAdoptionTests.swift
//
// The two arms of `resolveDefaultGateway()` that WRITE, driven end to end
// against the real resolver rather than asserted on hand-built enum values.
//
// Everywhere else the resolver is asked to stay silent, and the suite asserts
// that nothing was persisted. These are the opposite cases — the only two where
// the app is allowed to write a default pointer on the user's behalf — so what
// has to be pinned is that the write HAPPENS, that it happens exactly once, and
// that the safety gates guarding it are load-bearing:
//
//   - `.bootstrapped` fills in an absent pointer when exactly one gateway can
//     send. It persists, announces nothing (nothing the user chose was
//     overridden), and the next resolve takes the fast path.
//   - `.adopted` moves a pointer that cannot send onto the one that can, and
//     leaves a notice naming BOTH gateways so the user is told exactly once.
//   - RULE B — the pending-bearer-candidate gate — refuses both of those when
//     any OTHER gateway is one token away from working. A readable token proves
//     the Keychain is OPEN; it never proves iCloud has finished DELIVERING, and
//     a pointer written mid-delivery is indistinguishable one launch later from
//     one the user chose. Each refusal case is paired with a control that
//     removes the pending candidate and asserts the write DOES fire, so a
//     refusal can never pass because the fixture staged nothing.
//
// Fixture shape follows `DiagnosticsDefaultGatewayTests`: the live
// `SettingsManager` singleton over the process-global in-memory stores (whose
// secret store accepts token writes, which the adopt gate's Keychain proof
// requires), wiped on both edges.

import XCTest
@testable import Conduck

final class DefaultGatewayAdoptionTests: XCTestCase {

    private var defaults: InMemoryDefaultsStore { TestStores.defaults }

    override func setUp() async throws {
        try await super.setUp()
        await wipe()
    }

    override func tearDown() async throws {
        await wipe()
        try await super.tearDown()
    }

    private func wipe() async {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    // MARK: - Fixtures

    /// A gateway that CAN send AND proves the Keychain readable: URL, `.bearer`,
    /// and a token that reads back. Keyless gateways cannot prove readability, so
    /// neither write arm can ever fire on one — every case here needs this shape.
    private func makeBearerSendable(_ backend: RemoteAgentBackend, token: String) async throws {
        let ref = RemoteAgentRef.builtin(backend)
        let url = try XCTUnwrap(URL(string: "https://\(backend.rawValue).example.test"))
        await SettingsManager.shared.setRemoteAgentURL(url, for: backend)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: ref)
        try await SettingsManager.shared.setRemoteAgentToken(token, for: ref)
    }

    /// A PENDING BEARER CANDIDATE: every non-Keychain requirement met and only a
    /// token missing. This is the partial-iCloud-Keychain-sync shape — one
    /// gateway's URL arrived over KVS while only another's token arrived over the
    /// Keychain — and the single thing Rule B exists to notice.
    private func makePendingBearerCandidate(_ backend: RemoteAgentBackend) async throws {
        let ref = RemoteAgentRef.builtin(backend)
        let url = try XCTUnwrap(URL(string: "https://\(backend.rawValue).example.test"))
        await SettingsManager.shared.setRemoteAgentURL(url, for: backend)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: ref)
    }

    /// Undo the pending candidate by removing the slot Rule B short-circuits on.
    /// The control half of every refusal case below.
    private func dropPendingBearerCandidate(_ backend: RemoteAgentBackend) async {
        await SettingsManager.shared.setRemoteAgentURL(nil, for: backend)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: .builtin(backend))
    }

    /// A roster custom with membership and nothing else: evidence enough that the
    /// dangling-custom drop spares the pointer, but no URL — so it is not itself a
    /// pending bearer candidate and does not confound the gate under test.
    private func makeEvidenceOnlyCustom(named name: String) async -> RemoteAgentRef {
        let id = UUID()
        let accepted = await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: id, name: name)
        )
        XCTAssertTrue(accepted, "Fixture: the roster must accept the custom, or the pointer dangles and is dropped.")
        return .custom(id)
    }

    private func storedPointerRaw() -> String? {
        defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey)
    }

    // MARK: - 1. Bootstrap: the silent fill-in, and that it sticks

    func testBootstrapPersistsThePointerSilentlyAndIsIdempotent() async throws {
        try await makeBearerSendable(.openclaw, token: "tok-oc")
        XCTAssertNil(storedPointerRaw(), "Fixture precondition: nothing is stored yet.")

        let first = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(first, .bootstrapped(.builtin(.openclaw)))

        XCTAssertEqual(storedPointerRaw(), RemoteAgentRef.builtin(.openclaw).rawString,
                       "A bootstrap that does not persist re-fires on every window appear, conversation open, menu-bar arm and headless mint.")
        let notice = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNil(notice,
                     "Nothing the user chose was overridden, so a bootstrap announces nothing.")

        let second = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(second, .usable(.builtin(.openclaw)),
                       "The repair is idempotent — the second resolve takes the fast path, so at most one settings-changed post per repair.")
    }

    /// RULE B, bootstrap arm. The reinstall where OpenClaw's URL arrived over KVS
    /// but only Hermes's token arrived over the iCloud Keychain: Hermes is the
    /// only send-able gateway and the Keychain reads as open, yet writing Hermes
    /// down would make a mid-sync accident permanent.
    func testBootstrapIsRefusedWhileAnotherGatewayIsOneTokenAway() async throws {
        try await makeBearerSendable(.hermes, token: "tok-h")
        try await makePendingBearerCandidate(.openclaw)

        let refused = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(refused, .selectionRequired(candidates: [.builtin(.hermes)]),
                       "A roster with a gateway one token away is not yet a roster we may count.")
        XCTAssertNil(storedPointerRaw(),
                     "Refusing must persist NOTHING — a guessed pointer is indistinguishable one launch later from a chosen one.")

        // Control: with the pending candidate gone, the identical roster DOES
        // bootstrap — so the case above fails for the gate's reason, not because
        // the fixture could never have written anything.
        await dropPendingBearerCandidate(.openclaw)
        let allowed = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(allowed, .bootstrapped(.builtin(.hermes)))
        XCTAssertEqual(storedPointerRaw(), RemoteAgentRef.builtin(.hermes).rawString)
    }

    // MARK: - 2. Adoption: the pointer moves, and the user is told once

    func testAdoptionPersistsWritesANoticeAndAcknowledgesIdempotently() async throws {
        try await makeBearerSendable(.openclaw, token: "tok-oc")
        let custom = await makeEvidenceOnlyCustom(named: "Workshop")
        await SettingsManager.shared.setDefaultRemoteAgentRef(custom)

        let resolution = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(resolution, .adopted(ref: .builtin(.openclaw), replacing: custom))

        XCTAssertEqual(storedPointerRaw(), RemoteAgentRef.builtin(.openclaw).rawString,
                       "An adoption that does not stick re-fires forever, re-clearing the active-conversation pointer each time.")

        let written = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        let notice = try XCTUnwrap(written,
                                   "The repair is announced exactly once, and the record is what carries it to the screen that will say so.")
        XCTAssertEqual(notice.adoptedRef, .builtin(.openclaw))
        XCTAssertEqual(notice.previousRef, custom)
        XCTAssertEqual(notice.previousName, "Workshop",
                       "The replaced gateway's name is captured at WRITE time — a custom can be gone by the time anyone reads this.")
        XCTAssertFalse(notice.adoptedName.isEmpty)
        for text in [notice.adoptedName, notice.previousName] {
            XCTAssertFalse(text.contains("://"), "A gateway is named by its display name, never its URL (I5).")
            XCTAssertFalse(text.contains("tok-"), "No token text may ever reach a stored record (I5).")
        }

        let second = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(second, .usable(.builtin(.openclaw)))
        let stillPending = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNotNil(stillPending,
                        "Peek, never read-and-clear: several surfaces may describe the same repair, so whichever renders first must not swallow it.")

        await SettingsManager.shared.acknowledgeDefaultAdoptionNotice()
        let cleared = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNil(cleared)
        await SettingsManager.shared.acknowledgeDefaultAdoptionNotice()
        let stillCleared = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNil(stillCleared, "Each dismissal is idempotent.")
    }

    /// RULE B, adopt arm. Same partial-sync hazard, one difference: a pointer IS
    /// stored, so refusing surfaces the loud `.defaultUnavailable` the user fixes in
    /// one tap rather than a repair nobody asked for.
    func testAdoptionIsRefusedWhileAnotherGatewayIsOneTokenAway() async throws {
        try await makeBearerSendable(.hermes, token: "tok-h")
        try await makePendingBearerCandidate(.openclaw)
        let custom = await makeEvidenceOnlyCustom(named: "Workshop")
        await SettingsManager.shared.setDefaultRemoteAgentRef(custom)

        let refused = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(refused, .defaultUnavailable(pointer: custom, candidates: [.builtin(.hermes)], pointerIsParked: false))
        XCTAssertEqual(storedPointerRaw(), custom.rawString,
                       "The user's own pointer stays exactly where they left it.")
        let notice = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNil(notice, "Nothing was repaired, so there is nothing to announce.")

        // Control: the same roster minus the pending candidate DOES adopt.
        await dropPendingBearerCandidate(.openclaw)
        let adopted = await SettingsManager.shared.resolveDefaultGateway()
        XCTAssertEqual(adopted, .adopted(ref: .builtin(.hermes), replacing: custom))
        XCTAssertEqual(storedPointerRaw(), RemoteAgentRef.builtin(.hermes).rawString)
        let wrote = await SettingsManager.shared.pendingDefaultAdoptionNotice()
        XCTAssertNotNil(wrote)
    }
}
