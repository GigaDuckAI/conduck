// SPDX-License-Identifier: Apache-2.0

// Conduck
// ParkedDefaultCollapseTests.swift
//
// ONE fact, asserted at every surface that can speak it: a pointer the APP
// parked after a Forget is a placeholder, not a gateway the user chose, so no
// surface may name it.
//
// Why a whole file. The collapse used to be a Bool travelling BESIDE the verdict
// — a snapshot field one call path published and another did not — so surfaces
// reading the verdict through `resolveDefaultGateway()` computed "broken, named
// OpenClaw" while surfaces reading it through `newChatPickerSnapshot()` computed
// "nothing chosen". The two disagreed on the same screen: the honest banner
// deep-linked the user into Settings → Personal AI, where three controls then
// named a gateway they never picked. The flag now rides INSIDE
// `.brokenDefault`, which is what makes "hold the verdict without the flag"
// unrepresentable rather than merely discouraged — and these tests are what stop
// it being lifted back out.
//
// Everything here is either a pure function or a `SettingsManager` over an
// in-memory dependency bundle, so nothing touches the App Group, the Keychain or
// the shared singleton. Gateways are seeded KEYLESS (a URL plus an explicit
// `.none` scheme is send-able on its own), so the file runs unsigned.

import XCTest
@testable import Conduck

final class ParkedDefaultCollapseTests: XCTestCase {

    // Key literals pinned independently of `Constants`, mirroring
    // `GigaActionPreflightTests`: a rename that would orphan real user data
    // breaks a test rather than silently re-homing keys.
    private let openclawURLKey = "remoteAgent.url.openclaw"
    private let openclawAuthKey = "remoteAgent.authScheme.openclaw"
    private let hermesURLKey = "remoteAgent.url.hermes"
    private let hermesAuthKey = "remoteAgent.authScheme.hermes"
    private let defaultBackendKey = "remoteAgent.defaultBackend"
    private let parkedDefaultKey = "remoteAgent.parkedDefaultRef"
    private let gatewayRosterKey = "remoteAgent.customGateways"

    private let openclaw = RemoteAgentRef.builtin(.openclaw)
    private let hermes = RemoteAgentRef.builtin(.hermes)

    // MARK: - Fixtures

    private func makeManager(defaults: InMemoryDefaultsStore) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: InMemoryUbiquitousStore(),
            cloudAvailable: true
        ))
    }

    private func seedKeyless(_ defaults: InMemoryDefaultsStore, urlKey: String, authKey: String) {
        defaults.set("https://gateway.example.test", forKey: urlKey)
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: authKey)
    }

    private func seedKeylessCustom(_ defaults: InMemoryDefaultsStore, roster: inout [CustomGateway],
                                   name: String) throws {
        let gateway = CustomGateway(id: UUID(), name: name)
        roster.append(gateway)
        defaults.set(try JSONEncoder().encode(roster), forKey: gatewayRosterKey)
        let ref = RemoteAgentRef.custom(gateway.id)
        seedKeyless(defaults,
                    urlKey: Constants.remoteAgentURLKey(for: ref),
                    authKey: Constants.remoteAgentAuthSchemeKey(for: ref))
    }

    /// The real state users reach: forget a custom while two other CUSTOMS
    /// survive. No built-in is among the survivors, so the re-point parks on the
    /// compiled-in built-in default — a gateway nobody chose and nobody set up.
    private func managerWithParkedPointer() async throws -> SettingsManager {
        let defaults = InMemoryDefaultsStore()
        var roster: [CustomGateway] = []
        try seedKeylessCustom(defaults, roster: &roster, name: "Work Box")
        try seedKeylessCustom(defaults, roster: &roster, name: "Home Box")
        let goneID = UUID()
        defaults.set(RemoteAgentRef.custom(goneID).rawString, forKey: defaultBackendKey)

        let manager = makeManager(defaults: defaults)
        await manager.repointDefaultAfterForget(of: .custom(goneID))
        XCTAssertEqual(defaults.string(forKey: parkedDefaultKey), "openclaw",
                       "Fixture precondition: the re-point must genuinely have parked the pointer.")
        return manager
    }

    /// The control twin: the SAME shape of broken default, chosen by the user.
    private func managerWithUserChosenBrokenPointer() async throws -> SettingsManager {
        let defaults = InMemoryDefaultsStore()
        var roster: [CustomGateway] = []
        try seedKeylessCustom(defaults, roster: &roster, name: "Work Box")
        seedKeyless(defaults, urlKey: hermesURLKey, authKey: hermesAuthKey)
        // OpenClaw has a scheme but no URL, so it cannot send — and the user
        // pointed at it themselves.
        defaults.set(RemoteAgentAuthScheme.none.rawValue, forKey: openclawAuthKey)
        let manager = makeManager(defaults: defaults)
        await manager.applyUserChosenDefault(openclaw)
        return manager
    }

    // MARK: - 1. The verdict carries the fact

    /// The structural half of the fix. Every surface below reads the flag off
    /// the verdict, so this is the one place it can be wrong.
    func testTheVerdictItselfReportsTheParkAndTheProjectionRefusesToBlame() async throws {
        let manager = try await managerWithParkedPointer()

        let resolution = await manager.resolveDefaultGateway()
        guard case .brokenDefault(let broken, let candidates, let pointerIsParked) = resolution else {
            return XCTFail("Precondition: the parked built-in is not configured here, got \(resolution).")
        }
        XCTAssertEqual(broken, openclaw)
        XCTAssertEqual(candidates.count, 2, "Both surviving customs remain choosable.")
        XCTAssertTrue(pointerIsParked,
                      "`resolveDefaultGateway()` is the path the Settings view model reads. A verdict that "
                      + "cannot say the pointer is a placeholder is exactly how three controls came to name "
                      + "a gateway the user never chose.")
        XCTAssertNil(resolution.brokenRef,
                     "Nobody let the user down — a placeholder cannot have broken a promise it never made.")

        // …and the snapshot path agrees, because it derives rather than stores.
        let snap = await manager.newChatPickerSnapshot()
        XCTAssertTrue(snap.defaultPointerIsParked,
                      "The two call paths must be one fact; a stored twin is what let them disagree.")
    }

    /// The control that keeps every assertion in this file from passing
    /// vacuously: a default the USER chose still reports unparked and is still
    /// nameable.
    func testAUserChosenBrokenDefaultIsNotParkedAndIsStillNamed() async throws {
        let manager = try await managerWithUserChosenBrokenPointer()

        let resolution = await manager.resolveDefaultGateway()
        guard case .brokenDefault(_, _, let pointerIsParked) = resolution else {
            return XCTFail("Precondition: expected .brokenDefault, got \(resolution).")
        }
        XCTAssertFalse(pointerIsParked, "The user picked this one themselves.")
        XCTAssertEqual(resolution.brokenRef, openclaw,
                       "A gateway the user chose and that stopped working IS the thing that let them down.")
    }

    // MARK: - 2. Settings → Personal AI, the screen the banner deep-links into

    /// The four controls on that screen — the selector row, its footer, the
    /// picker callout and the gateway list's chosen check — all hang off this one
    /// predicate. Under a park it has to read the same way the banner that sent
    /// the user here already did.
    func testTheSettingsSelectorCollapsesToNothingChosenUnderAPark() {
        let parked = DefaultGatewayResolution.brokenDefault(
            broken: openclaw, candidates: [hermes], pointerIsParked: true)
        XCTAssertTrue(SettingsViewModel.selectorNeedsChoice(for: parked),
                      "The banner and Diagnostics both deep-link here calling it 'nothing chosen'. A screen "
                      + "that then flags and names a broken default contradicts the sentence that "
                      + "brought the user to it.")

        let chosen = DefaultGatewayResolution.brokenDefault(
            broken: openclaw, candidates: [hermes], pointerIsParked: false)
        XCTAssertFalse(SettingsViewModel.selectorNeedsChoice(for: chosen),
                       "Control: a default the user picked and that broke is still flagged and named.")

        XCTAssertTrue(SettingsViewModel.selectorNeedsChoice(for: .selectionRequired(candidates: [hermes])),
                      "Control: the original nothing-chosen state must still answer true.")
        XCTAssertFalse(SettingsViewModel.selectorNeedsChoice(for: .usable(hermes)),
                       "Control: a working default is not a question.")
    }

    /// The chat banner's own mapper. Already collapsed before this round, and
    /// asserted here too so all four surfaces are pinned in one place — if a
    /// future reader lifts the flag back out of the verdict, this fails beside
    /// the others rather than alone in another file.
    func testTheChatBannerSpeaksAsNoDefaultChosenUnderAPark() {
        let candidates = [hermes]
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: candidates, pointerIsParked: true),
            roster: [],
            pendingAdoption: nil
        )
        XCTAssertEqual(notice, .noDefaultChosen(candidates: candidates))
    }

    /// Diagnostics' standing row, the third surface, from the same verdict.
    func testDiagnosticsStandsDownToNotChosenUnderAPark() {
        let order = [GatewayDisplayEntry(ref: hermes, displayName: "Hermes", connectionCheckID: "gw.hermes")]
        let standing = DiagnosticsRunner.makeDefaultGatewayStanding(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: true),
            notice: nil,
            displayOrder: order,
            customGateways: [],
            customOrdinals: [:]
        )
        XCTAssertEqual(standing?.kind, .notChosen)
        XCTAssertEqual(standing?.defaultName, "", "A placeholder carries no name.")

        let named = DiagnosticsRunner.makeDefaultGatewayStanding(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
            notice: nil,
            displayOrder: order,
            customGateways: [],
            customOrdinals: [:]
        )
        XCTAssertEqual(named?.kind, .broken, "Control: a chosen default that broke is still called broken.")
    }

    /// The copy block the user pastes into a support message has to agree with
    /// the row printed directly above it.
    func testTheDiagnosticsReportTokenAgreesWithTheStandingRow() {
        XCTAssertEqual(
            DiagnosticsRunner.defaultGatewayVerdict(
                resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: true),
                notice: nil),
            "not-chosen(candidates=1)")
        XCTAssertEqual(
            DiagnosticsRunner.defaultGatewayVerdict(
                resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
                notice: nil),
            "broken(candidates=1)")
    }

    // MARK: - 3. The wrist

    /// The Watch has no picker and speaks the refusal aloud. Its whole
    /// distinction rides one Bool in the broadcast envelope, so a parked pointer
    /// that broadcasts as chosen makes the wrist name a gateway nobody picked —
    /// the one surface where the sentence is heard rather than read.
    func testTheWristBroadcastsAParkedPointerAsNotChosen() async throws {
        let manager = try await managerWithParkedPointer()
        let effective = await manager.watchEffectiveDefault()
        XCTAssertEqual(effective.ref, openclaw,
                       "The ref is unchanged — leaving it is what keeps the wrist from being rerouted (I1).")
        XCTAssertFalse(effective.chosen,
                       "`chosen: false` is what routes the wrist to its unnamed sentence, the same one the "
                       + "phone, CarPlay and the headless lanes use.")
    }

    func testTheWristStillReportsAUserChosenDefaultAsChosen() async throws {
        let manager = try await managerWithUserChosenBrokenPointer()
        let effective = await manager.watchEffectiveDefault()
        XCTAssertTrue(effective.chosen,
                      "Control: a broken default the user picked keeps its name on the wrist too.")
    }

    // MARK: - 4. CarPlay

    /// `newChatPlan`'s `broken` is what the car SPEAKS before it shows the
    /// chooser, and its own doc says the slot is non-nil "only when a stored
    /// pointer can be honestly named". A placeholder cannot be.
    func testCarPlayRefusesWithoutNamingAParkedPointer() {
        let configured = [hermes]
        let plan = CarPlaySceneDelegate.newChatPlan(
            resolution: .brokenDefault(broken: openclaw, candidates: configured, pointerIsParked: true),
            configured: configured,
            override: nil,
            effectiveRef: openclaw
        )
        guard case .chooseInstead(let broken, let candidates, let current) = plan else {
            return XCTFail("A broken default beside a working gateway must still push the chooser, got \(plan).")
        }
        XCTAssertNil(broken, "The driver never chose this gateway; naming it aloud blames them for it.")
        XCTAssertEqual(candidates, configured, "The exit is unchanged — only the attribution is.")
        XCTAssertEqual(current, openclaw,
                       "The chooser still needs a row to check, even when nothing may be blamed.")
    }

    func testCarPlayStillNamesAUserChosenBrokenDefault() {
        let configured = [hermes]
        let plan = CarPlaySceneDelegate.newChatPlan(
            resolution: .brokenDefault(broken: openclaw, candidates: configured, pointerIsParked: false),
            configured: configured,
            override: nil,
            effectiveRef: openclaw
        )
        guard case .chooseInstead(let broken, _, _) = plan else {
            return XCTFail("Control: expected .chooseInstead, got \(plan).")
        }
        XCTAssertEqual(broken, openclaw, "Control: a default the driver chose is named when it breaks.")
    }

    /// A driver's in-car pick outranks the phone's verdict entirely, park or no
    /// park — otherwise the only exit the refusal offers leads back to it.
    func testADriversOwnPickIsUnaffectedByAParkedPhonePointer() {
        let configured = [hermes]
        let plan = CarPlaySceneDelegate.newChatPlan(
            resolution: .brokenDefault(broken: openclaw, candidates: configured, pointerIsParked: true),
            configured: configured,
            override: hermes,
            effectiveRef: openclaw
        )
        XCTAssertEqual(plan, .proceed(ref: hermes, adoptAsSessionOverride: false))
    }
}
