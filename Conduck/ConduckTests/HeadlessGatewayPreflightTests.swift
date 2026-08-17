// SPDX-License-Identifier: Apache-2.0

// Conduck
// HeadlessGatewayPreflightTests.swift
//
// The headless lane's verdict-to-error mapping, locked.
//
// This is the one place in the app where a wrong answer costs a user their
// words: the Action Button, the share target, CarPlay and the menu-bar hotkey
// all send WITHOUT a human looking at a gateway name first, so whatever
// `SharedInboxRouting.resolveOrMint` decides is what the user gets — and by then
// they have already spoken. Four rules have to hold exactly:
//
//   - a broken default beside working gateways throws code 74 and NAMES the
//     broken one, because code 12's "No personal AI gateway is configured" is
//     false there and leaves the user with no way to tell which sentence lied;
//   - no default chosen at all throws 74 UNNAMED and persists nothing, because a
//     pointer the device invented is indistinguishable one launch later from one
//     the user chose;
//   - a reading the Keychain cannot be trusted for throws code 12 and accuses
//     nobody — an after-first-unlock blackout reads every `.bearer` gateway as
//     gone, and a device that is perfectly well set up must not be told its
//     default is broken;
//   - a conversation that already has turns keeps code 12 forever. Routing is
//     per-conversation; 74 there would read as an offer to re-point a thread the
//     app is forbidden to re-point.
//
// Fixture shape follows `SharedInboxRoutingTests`: the live `SettingsManager`
// singleton over the in-memory stores, a full wipe each side, and a fresh
// in-memory `ConversationStore` per test. Cases that need no bearer token are
// written keyless on purpose so they exercise the same paths a locked Keychain
// would.

import XCTest
@testable import Conduck

final class HeadlessGatewayPreflightTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        await wipe()
    }

    override func tearDown() async throws {
        await wipe()
        try await super.tearDown()
    }

    /// Wipe all three stores, not a key list: the resolver reads URL, model,
    /// auth-scheme, cert-pin, roster and token slots, and a per-key teardown that
    /// misses one leaves `hasAnyRawSetupResidue()` answering for the previous
    /// test. Nothing here is persistent, so it cannot leak.
    private func wipe() async {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
    }

    // MARK: - Fixture helpers

    /// A KEYLESS gateway: URL plus an explicit `.none` auth scheme. Configured
    /// with no Keychain read at all, which is what lets the blackout-shaped tests
    /// run without writing a secret.
    private func configureKeyless(_ backend: RemoteAgentBackend, url: String) async throws {
        let u = try XCTUnwrap(URL(string: url))
        await SettingsManager.shared.setRemoteAgentURL(u, for: backend)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: .builtin(backend))
    }

    /// A BEARER gateway: URL plus a token. The token write goes through the
    /// storage seam's secret store; on a host where that write fails the test
    /// skips rather than reporting a false verdict.
    private func configureOrSkip(_ backend: RemoteAgentBackend, url: String, token: String) async throws {
        let u = try XCTUnwrap(URL(string: url))
        await SettingsManager.shared.setRemoteAgentURL(u, for: backend)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: .builtin(backend))
        do {
            try await SettingsManager.shared.setRemoteAgentToken(token, for: backend)
        } catch {
            throw XCTSkip("Secret-store write unavailable on this host (\(error)).")
        }
    }

    private func storedPointerRaw() -> String? {
        defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey)
    }

    // MARK: - 1. Broken default → 74, named, and never a URL

    func testBrokenDefaultMintThrows74WithDisplayNameNotURL() async throws {
        let store = ConversationStore(inMemory: true)
        // Two gateways fully set up, at least one of them `.bearer` with a
        // readable token — which is what PROVES the Keychain readable and takes
        // the resolver off its blackout arm.
        try await configureOrSkip(.openclaw, url: "https://openclaw.example.test:18789", token: "tok-oc")
        try await configureOrSkip(.hermes, url: "https://hermes.example.test:8642", token: "tok-h")
        // The default points at a THIRD gateway that has everything except a
        // token, so it cannot send while the other two can.
        await SettingsManager.shared.setRemoteAgentModel("some/model", for: .builtin(.openrouter))
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openrouter)

        let resolution = await SettingsManager.shared.resolveDefaultGateway()
        guard case .brokenDefault(let broken, let candidates, _) = resolution else {
            return XCTFail("Expected .brokenDefault, got \(resolution).")
        }
        XCTAssertEqual(broken, .builtin(.openrouter))
        XCTAssertEqual(candidates.count, 2, "Both working gateways must be offered as candidates.")

        do {
            _ = try await SharedInboxRouting.resolveOrMint(store: store)
            XCTFail("A broken default beside working gateways must throw code 74.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 74,
                           "Code 12 asserts nothing is configured, which is false with two working gateways.")
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("OpenRouter"),
                          "The refusal must NAME the broken default so the user fixes the right one: \(description)")
            XCTAssertFalse(description.contains("://"),
                           "A gateway is named by its DISPLAY NAME, never its URL.")
            XCTAssertFalse(description.contains("tok-"),
                           "No token text may ever reach user copy.")
        }

        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0,
                       "The broken-default refusal must not leave a stray empty thread.")
    }

    // MARK: - 2. No default chosen → 74, unnamed, nothing persisted

    func testSelectionRequiredMintThrows74Unnamed() async throws {
        let store = ConversationStore(inMemory: true)
        // Two keyless gateways: both can send, and neither needs a secret — so
        // this case runs everywhere.
        try await configureKeyless(.openclaw, url: "https://openclaw.example.test:18789")
        try await configureKeyless(.hermes, url: "https://hermes.example.test:8642")
        XCTAssertNil(storedPointerRaw(), "Fixture precondition: no default pointer is stored.")

        let resolution = await SettingsManager.shared.resolveDefaultGateway()
        guard case .selectionRequired(let candidates) = resolution else {
            return XCTFail("Expected .selectionRequired, got \(resolution).")
        }
        XCTAssertEqual(candidates.count, 2)

        do {
            _ = try await SharedInboxRouting.resolveOrMint(store: store)
            XCTFail("A device with no chosen default must throw code 74.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 74)
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertEqual(description, AppError.remoteAgentDefaultNeedsSetup(gatewayName: nil).errorDescription,
                           "There is no default to name, so the unnamed copy must carry it.")
            XCTAssertFalse(description.contains("OpenClaw"))
            XCTAssertFalse(description.contains("Hermes"))
        }

        XCTAssertNil(storedPointerRaw(),
                     "`.selectionRequired` must PERSIST NOTHING — a guessed pointer becomes permanent because nothing ever revisits it.")
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0, "Nothing may be minted when no destination was chosen.")
    }

    // MARK: - 3. Untrustworthy reading → 12, never 74 (the I3 regression lock)

    func testReadingUnreliableMintThrows12Not74() async throws {
        let store = ConversationStore(inMemory: true)
        // The blackout shape: a `.bearer` default with a URL and no readable
        // token, and the only gateway that CAN send is keyless — so nothing
        // anywhere proves the Keychain is open. Indistinguishable, from inside
        // the app, from a device booted and not yet unlocked.
        let u = try XCTUnwrap(URL(string: "https://openclaw.example.test:18789"))
        await SettingsManager.shared.setRemoteAgentURL(u, for: .openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: .builtin(.openclaw))
        try await configureKeyless(.hermes, url: "https://hermes.example.test:8642")
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let pointerBefore = storedPointerRaw()

        let resolution = await SettingsManager.shared.resolveDefaultGateway()
        guard case .readingUnreliable(let pointer) = resolution else {
            return XCTFail("Expected .readingUnreliable, got \(resolution).")
        }
        XCTAssertEqual(pointer, .builtin(.openclaw))

        do {
            _ = try await SharedInboxRouting.resolveOrMint(store: store)
            XCTFail("Nothing can send here, so the mint must still refuse.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 12,
                           "A reading we cannot trust must fail closed with the existing, non-accusatory verdict — never accuse a default that may be healthy behind a locked Keychain.")
            XCTAssertNotEqual(error.errorCode, 74)
        }

        XCTAssertEqual(storedPointerRaw(), pointerBefore,
                       "Nothing may be repaired or persisted on an untrustworthy reading.")
        let convos = try? await store.fetchConversations()
        XCTAssertEqual(convos?.count ?? 0, 0)
    }

    // MARK: - 4. Bound conversation → 12 forever (the I1 regression lock)

    func testBoundConversationStillThrows12() async throws {
        let store = ConversationStore(inMemory: true)
        // Gateway A works and is the default; the conversation is bound to B,
        // which has nothing stored at all.
        try await configureKeyless(.openclaw, url: "https://openclaw.example.test:18789")
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)
        let boundRow = try await store.createConversation(backend: RemoteAgentBackend.hermes.rawValue)

        do {
            _ = try await SharedInboxRouting.resolveOrMint(
                overrideConversationID: boundRow.id,
                store: store
            )
            XCTFail("A conversation bound to an unconfigured gateway must refuse.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 12,
                           "A thread with turns is BOUND to its gateway; 74 would read as an offer to re-point it, which routing forbids. Clone to switch.")
            XCTAssertNotEqual(error.errorCode, 74)
        }

        let reread = try await store.fetchConversation(id: boundRow.id)
        XCTAssertEqual(reread?.backend, RemoteAgentRef.builtin(.hermes).rawString,
                       "The refusal must not rebind the conversation onto the working default.")
    }

    // MARK: - 5. A reconstructed 74 never prints an empty name

    func testReconstructed74NeverPrintsAnEmptyName() throws {
        let reconstructed = AppError.from(errorCode: 74, message: nil)
        XCTAssertEqual(reconstructed.errorCode, 74,
                       "74 round-trips to itself — it must not collapse to .apiFailure and render a blank banner on the relay.")

        let unnamedCopy = try XCTUnwrap(AppError.remoteAgentDefaultNeedsSetup(gatewayName: nil).errorDescription)
        let rebuilt = try XCTUnwrap(reconstructed.errorDescription)
        XCTAssertEqual(rebuilt, unnamedCopy,
                       "A bare wire code carries no name, so it must use the copy written to be true without one.")
        XCTAssertFalse(rebuilt.contains(", ,"),
                       "An interpolated empty name would render \"Your default AI, , isn't set up\" — the defect the two-key split exists to prevent.")
        XCTAssertFalse(rebuilt.contains(",  "))

        let named = AppError.remoteAgentDefaultNeedsSetup(gatewayName: "OpenClaw")
        for kase in [named, reconstructed] {
            XCTAssertTrue(kase.shouldPreserveForRetry,
                          "The audio is bit-for-bit valid and the fix is one tap — the recording must survive so the SAME bytes can be sent after it.")
            XCTAssertFalse(kase.isRetryable,
                           "Retrying the same bytes against the same dead pointer reaches the same verdict.")
            let description = try XCTUnwrap(kase.errorDescription)
            XCTAssertFalse(description.contains("No personal AI"),
                           "74 exists precisely because code 12's copy is false when other gateways work.")
        }
    }

    // MARK: - 6. CarPlay adopts a session override on two verdicts, and no others

    #if os(iOS)
    func testCarPlayOverrideOnlyOnAdoptedOrBootstrapped() {
        let a = RemoteAgentRef.builtin(.openclaw)
        let b = RemoteAgentRef.builtin(.hermes)

        // The two verdicts where the resolver has ALREADY proven the Keychain
        // readable, cleared the pending-bearer-candidate gate, and persisted a
        // pointer. The car inherits that decision; it never makes its own.
        XCTAssertEqual(CarPlaySceneDelegate.sessionOverrideRef(for: .adopted(ref: a, replacing: b)), a)
        XCTAssertEqual(CarPlaySceneDelegate.sessionOverrideRef(for: .bootstrapped(a)), a)

        // Everything else: no override. `.usable` needs none; `.brokenDefault`
        // and `.selectionRequired` need the DRIVER to choose; the last three must
        // be left strictly alone.
        let noOverride: [DefaultGatewayResolution] = [
            .usable(a),
            .brokenDefault(broken: a, candidates: [b], pointerIsParked: false),
            .selectionRequired(candidates: [a, b]),
            .nothingConfigured(pointer: a),
            .setupUnfinished(pointer: a),
            .readingUnreliable(pointer: a)
        ]
        for resolution in noOverride {
            XCTAssertNil(CarPlaySceneDelegate.sessionOverrideRef(for: resolution),
                         "\(resolution) must not silently re-aim a drive's captures.")
        }
    }

    // MARK: - 7. A driver's in-car choice outranks the phone's verdict

    /// The dead-end this closes: both refusing verdicts push the CarPlay gateway
    /// chooser, and the chooser writes ONLY the session-local override — never
    /// the phone's default. A pre-flight that reads the phone's verdict alone
    /// therefore answers identically after the driver picks, so the only exit the
    /// refusal offers leads straight back to the refusal, for the whole drive.
    func testASessionOverrideRoutesPastBothRefusingVerdicts() {
        let broken = RemoteAgentRef.builtin(.openrouter)
        let picked = RemoteAgentRef.builtin(.hermes)
        let other = RemoteAgentRef.builtin(.openclaw)
        let configured = [other, picked]

        for resolution in [DefaultGatewayResolution.brokenDefault(broken: broken, candidates: configured, pointerIsParked: false),
                           .selectionRequired(candidates: configured)] {
            // Control: with no override, the refusal is exactly right — the
            // driver has not chosen anything yet.
            guard case .chooseInstead = CarPlaySceneDelegate.newChatPlan(
                resolution: resolution, configured: configured, override: nil, effectiveRef: resolution.ref
            ) else {
                return XCTFail("Control: \(resolution) with no driver choice must still refuse.")
            }
            // …and with one, the drive proceeds on the gateway they picked.
            XCTAssertEqual(
                CarPlaySceneDelegate.newChatPlan(
                    resolution: resolution, configured: configured,
                    override: picked, effectiveRef: picked
                ),
                .proceed(ref: picked, adoptAsSessionOverride: false),
                "The chooser only ever lists configured refs, so a pick from it is a decision the pre-flight has no business overruling: \(resolution)."
            )
        }
    }

    /// Fail-closed, in the one shape that matters: a gateway forgotten on the
    /// phone mid-drive drops out of `configuredRefs`, and the stale override must
    /// not carry the session onto it. Membership is the same test `.usable`
    /// applies, so the override inherits I2's proof rather than re-deriving it.
    func testAnOverrideThatLeftTheConfiguredSetIsRefusedNotHonoured() {
        let gone = RemoteAgentRef.builtin(.hermes)
        let alive = RemoteAgentRef.builtin(.openclaw)
        let resolution = DefaultGatewayResolution.selectionRequired(candidates: [alive])

        guard case .chooseInstead(let broken, let candidates, _) = CarPlaySceneDelegate.newChatPlan(
            resolution: resolution, configured: [alive], override: gone, effectiveRef: gone
        ) else {
            return XCTFail("A stale override must fall back to the device verdict, never route.")
        }
        XCTAssertNil(broken, "Nothing was chosen, so there is no stored pointer to name.")
        XCTAssertEqual(candidates, [alive])

        // And with nothing configured at all, no override can survive the
        // membership test — the refusal is the whole answer.
        XCTAssertEqual(
            CarPlaySceneDelegate.newChatPlan(
                resolution: .nothingConfigured(pointer: alive),
                configured: [], override: gone, effectiveRef: gone
            ),
            .setUpOnPhone
        )
    }

    /// A driver's live choice is not overwritten by a repair the resolver made in
    /// the background, and the two verdicts that DO carry a repair still reach
    /// the car when the driver has chosen nothing.
    func testAnInheritedAdoptionYieldsToADriversOwnChoice() {
        let adopted = RemoteAgentRef.builtin(.openclaw)
        let picked = RemoteAgentRef.builtin(.hermes)
        let previous = RemoteAgentRef.builtin(.openrouter)
        let resolution = DefaultGatewayResolution.adopted(ref: adopted, replacing: previous)

        XCTAssertEqual(
            CarPlaySceneDelegate.newChatPlan(
                resolution: resolution, configured: [adopted, picked],
                override: picked, effectiveRef: picked
            ),
            .proceed(ref: picked, adoptAsSessionOverride: false),
            "The driver picked this drive's gateway; a background repair is not a reason to re-aim it."
        )
        XCTAssertEqual(
            CarPlaySceneDelegate.newChatPlan(
                resolution: resolution, configured: [adopted, picked],
                override: nil, effectiveRef: previous
            ),
            .proceed(ref: adopted, adoptAsSessionOverride: true),
            "With no driver choice the car inherits the repair the device already proved and persisted."
        )
    }

    /// `.readingUnreliable` proceeds rather than refusing: a Keychain that has not
    /// opened yet reads every bearer gateway as gone, and stranding a driver on
    /// that reading is the exact I3 failure the split verdict exists to prevent.
    func testAnUntrustworthyReadingStillLetsTheDriveStart() {
        let pointer = RemoteAgentRef.builtin(.openclaw)
        XCTAssertEqual(
            CarPlaySceneDelegate.newChatPlan(
                resolution: .readingUnreliable(pointer: pointer),
                configured: [], override: nil, effectiveRef: pointer
            ),
            .proceed(ref: pointer, adoptAsSessionOverride: false)
        )
    }
    #endif
}
