// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayNoticeTests.swift
//
// The display mapper over the default-gateway verdict: which of three sentences
// — if any — the user is owed. Pure input → output, which is the whole point of
// the mapper living outside the three SwiftUI surfaces that consume it
// (`ContentView`, `ConversationLibraryView`'s detail column and `MainWindowView`,
// the last of which the iOS-Simulator suite never even compiles).
//
// SCOPE WARNING: these tests cover the MAPPING, not its three call sites. They
// cannot catch the mistakes the call sites actually risk — resolving the notice
// BELOW the picker-seed guard (where it would freeze at whatever it said when the
// user last stood on the empty state), rendering the macOS banner outside the
// pane's drop destination, or a second `GatewayFixRoute.consume()` under the same
// host racing the first. Those are guarded by comments at the call sites only.

import XCTest
@testable import Conduck

final class DefaultGatewayNoticeTests: XCTestCase {

    private let openclaw = RemoteAgentRef.builtin(.openclaw)
    private let hermes = RemoteAgentRef.builtin(.hermes)

    /// A custom that is still on the roster.
    private let liveCustomID = UUID()
    /// A custom the user forgot: present in the BADGE roster (which unions retired
    /// entries) and nowhere else.
    private let retiredCustomID = UUID()

    private var roster: [CustomGateway] {
        [
            CustomGateway(id: liveCustomID, name: "Work Box"),
            CustomGateway(id: retiredCustomID, name: "Old Box")
        ]
    }

    // MARK: - The silences

    func testNoNoticeWhenTheDefaultIsUsable() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .usable(openclaw),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice, "The pointer works — there is nothing to say.")
    }

    /// A bootstrap filled a pointer in where the user had chosen none and exactly
    /// one gateway could send. Nothing the user chose was overridden, so there is
    /// nothing to announce.
    func testNoNoticeWhenABootstrapFilledInTheOnlyGateway() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .bootstrapped(hermes),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice)
    }

    /// The honest first-run state, owned by `UnconfiguredEmptyState` and the
    /// locked composer. A banner on top of those says nothing new.
    func testNoNoticeWhenNothingIsConfigured() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .nothingConfigured(pointer: openclaw),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice)
    }

    /// Half-finished setup with nothing configured — the same empty state owns it,
    /// and a banner here would nag a user who is mid-setup.
    func testNoNoticeWhenSetupIsUnfinished() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .setupUnfinished(pointer: openclaw),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice)
    }

    /// THE I3 GUARD. Secrets are `kSecAttrAccessibleAfterFirstUnlock`, so a
    /// headless read after a reboot and before first unlock — or an iCloud
    /// Keychain sync that has delivered some tokens and not others — reads every
    /// gateway as gone while none of them is. A banner announcing a broken default
    /// there is a lie told by a locked device.
    func testNoNoticeWhenTheReadingIsUnreliable() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .readingUnreliable(pointer: openclaw),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice, "A locked device must never accuse a healthy default.")
    }

    // MARK: - The two things worth saying

    func testBrokenNoticeNamesTheStoredDefaultAndCarriesItsRef() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes, .custom(liveCustomID)], pointerIsParked: false),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertEqual(notice, .brokenDefault(ref: openclaw, name: "OpenClaw"),
                       "The user has to know WHICH gateway to fix.")
        XCTAssertEqual(notice?.dismissalKey, .broken(openclaw),
                       "A dismissal is scoped to this gateway, so a different broken default still speaks up.")
    }

    /// The founder's restored-iPad state: gateways work, no default was ever
    /// chosen, and the device may not guess one. If this stayed silent the user
    /// would never learn why every lane without a picker refuses.
    func testSelectionRequiredAsksTheUserToChoose() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .selectionRequired(candidates: [openclaw, hermes]),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertEqual(notice, .noDefaultChosen(candidates: [openclaw, hermes]))
        XCTAssertEqual(notice?.dismissalKey, .noDefaultChosen)
    }

    /// With nothing to pick, "pick one" is a lie — and the empty-state UI already
    /// owns that screen.
    func testSelectionRequiredWithNoCandidatesSaysNothing() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .selectionRequired(candidates: []),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice)
    }

    /// The badge roster unions RETIRED customs, so a default parked on a gateway
    /// the user forgot resolves to its real name instead of a raw UUID.
    func testBrokenDefaultOnARetiredCustomStillResolvesAName() {
        let retired = RemoteAgentRef.custom(retiredCustomID)
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: retired, candidates: [hermes], pointerIsParked: false),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertEqual(notice, .brokenDefault(ref: retired, name: "Old Box"))
    }

    // MARK: - A parked pointer is not a default

    /// The Forget re-point parks the pointer on a built-in so the user CHOOSES
    /// their next gateway. Calling that placeholder "your default for new chats"
    /// blames them for a pointer the app wrote one step after they forgot a
    /// different one — the same false attribution the headless lanes already
    /// drop. The banner says the true thing instead: nothing is chosen, pick one.
    func testParkedBrokenPointerSpeaksAsNoDefaultChosen() {
        let candidates = [hermes, RemoteAgentRef.custom(liveCustomID)]
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: candidates, pointerIsParked: true),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertEqual(notice, .noDefaultChosen(candidates: candidates),
                       "A placeholder is not a default — the user is owed the choice, not an accusation.")
        XCTAssertEqual(notice?.dismissalKey, .noDefaultChosen)
    }

    /// The control that keeps the case above from passing vacuously: the SAME
    /// verdict with the SAME roster, unparked, still names the gateway.
    func testUnparkedBrokenPointerIsStillNamed() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertEqual(notice, .brokenDefault(ref: openclaw, name: "OpenClaw"))
    }

    /// A parked pointer with nothing to offer says nothing at all, exactly as a
    /// candidate-less `.selectionRequired` does — "pick one" with nothing to pick
    /// is a worse sentence than silence.
    func testParkedPointerWithNoCandidatesSaysNothing() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: [], pointerIsParked: true),
            roster: roster,
            pendingAdoption: nil
        )

        XCTAssertNil(notice)
    }

    /// An unacknowledged repair still outranks the collapse — the user hears that
    /// their pointer moved before anything else.
    func testAdoptionOutranksAParkedPointer() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: true),
            roster: roster,
            pendingAdoption: adoptionRecord(previousRef: openclaw)
        )

        XCTAssertEqual(notice, .adopted(adoptedName: "Hermes", previousName: "OpenClaw"))
    }

    // MARK: - Adoption outranks everything

    private func adoptionRecord(
        previousRef: RemoteAgentRef,
        previousName: String = "OpenClaw"
    ) -> DefaultGatewayAdoptionNotice {
        DefaultGatewayAdoptionNotice(
            adoptedRef: hermes,
            adoptedName: "Hermes",
            previousRef: previousRef,
            previousName: previousName
        )
    }

    /// The user is owed the news that their pointer MOVED before they are told the
    /// new one is unhappy; the broken notice takes the slot over on the refresh
    /// after the acknowledgment.
    func testAdoptionOutranksABrokenDefaultAndNamesBothGateways() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
            roster: roster,
            pendingAdoption: adoptionRecord(previousRef: openclaw)
        )

        XCTAssertEqual(notice, .adopted(adoptedName: "Hermes", previousName: "OpenClaw"))
    }

    func testAdoptionOutranksASelectionRequest() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .selectionRequired(candidates: [openclaw, hermes]),
            roster: roster,
            pendingAdoption: adoptionRecord(previousRef: openclaw)
        )

        XCTAssertEqual(notice, .adopted(adoptedName: "Hermes", previousName: "OpenClaw"))
    }

    /// The replaced gateway may be a custom that is GONE by the time anyone reads
    /// the record — deleted on this device, or never synced here at all. The names
    /// are captured at write time for exactly that case, and a repair that names a
    /// UUID explains nothing.
    func testAdoptionUsesTheStoredNamesNotTheLiveRoster() {
        let vanished = RemoteAgentRef.custom(UUID())   // absent from `roster`
        let notice = DefaultGatewayNotice.resolve(
            resolution: .usable(hermes),
            roster: roster,
            pendingAdoption: adoptionRecord(previousRef: vanished, previousName: "Garage Box")
        )

        XCTAssertEqual(notice, .adopted(adoptedName: "Hermes", previousName: "Garage Box"))
        XCTAssertNotEqual(
            notice,
            .adopted(adoptedName: "Hermes", previousName: RemoteAgentRefMetadata.genericCustomName),
            "A live-roster lookup would have degraded the name to the generic label."
        )
    }

    /// Acknowledging the STORED record is what dismisses an adoption, and that
    /// survives a relaunch — so it must not also be waved off by a session flag,
    /// which would leave the record unacknowledged and the notice back tomorrow.
    func testAdoptionHasNoSessionDismissalKey() {
        let notice = DefaultGatewayNotice.resolve(
            resolution: .usable(hermes),
            roster: roster,
            pendingAdoption: adoptionRecord(previousRef: openclaw)
        )

        XCTAssertNil(notice?.dismissalKey)
    }

    // MARK: - The selector row's value

    /// Under `.selectionRequired` the compatibility shim projects to the built-in
    /// fallback, which may itself be configured — so a name in the row would claim
    /// a choice the user never made.
    func testSelectorValueReadsNotChosenOnlyWhenNoDefaultIsChosen() {
        let notChosen = String(localized: LocalizedStringResource(
            "settings.personalAI.default.notChosen",
            defaultValue: "Not chosen yet"
        ))

        XCTAssertEqual(
            DefaultGatewayNotice.selectorValue(needsChoice: true, displayName: "OpenClaw"),
            notChosen
        )
        XCTAssertEqual(
            DefaultGatewayNotice.selectorValue(needsChoice: false, displayName: "OpenClaw"),
            "OpenClaw"
        )
    }
}

/// The two selector flags the Personal AI screens read, asserted on a plain
/// `SettingsViewModel`. Mirrors `GuidedSetupPrimerTests.DefaultSelectorDisplayNameTests`:
/// the synchronous set + assert cannot race the VM's async load task, because both
/// are MainActor-isolated and no `await` yields the actor mid-test.
@MainActor
final class DefaultSelectorBrokenNameTests: XCTestCase {

    /// `defaultSelectorBrokenName` is DERIVED from `defaultSelectorNeedsSetup`, so
    /// the picker callout, the selector footer and the flagged row can never name
    /// a different gateway from the one the row itself flags.
    func testBrokenNameIsNilExactlyWhenTheSelectorIsNotFlagged() {
        let vm = SettingsViewModel()

        // The VM's initial `defaultRemoteAgentRef` is `.builtin(.openclaw)`, so a
        // configured set of exactly Hermes IS the broken case.
        vm.configuredRemoteAgentRefSet = [.builtin(.hermes)]
        XCTAssertTrue(vm.defaultSelectorNeedsSetup)
        XCTAssertEqual(vm.defaultSelectorBrokenName, vm.defaultRemoteAgentDisplayName,
                       "The callout names the gateway the row flags, never another one.")

        vm.configuredRemoteAgentRefSet = [.builtin(.openclaw)]
        XCTAssertFalse(vm.defaultSelectorNeedsSetup)
        XCTAssertNil(vm.defaultSelectorBrokenName)
    }

    /// A first-run device is not broken — "Not configured" already says everything
    /// true about it, and naming the never-chosen fallback pointer would advertise
    /// the phantom default the empty-set guard exists to kill.
    func testBrokenNameIsNilWhenNothingIsConfigured() {
        let vm = SettingsViewModel()
        vm.configuredRemoteAgentRefSet = []

        XCTAssertNil(vm.defaultSelectorBrokenName)
    }

    /// The restored-install shape, and the one the raw membership predicate gets
    /// wrong. With nothing stored, `defaultRemoteAgentRef` is the compatibility
    /// projection — the built-in fallback — so whenever that fallback is not
    /// itself configured, "is the default in the configured set?" answers "no"
    /// about a gateway the user never picked. Naming it would put "OpenClaw isn't
    /// set up here, finish setting it up" under a row that reads "Not chosen
    /// yet", and beside a chat banner saying no default is chosen at all.
    ///
    /// Driven through the REAL resolver rather than by setting the verdict by
    /// hand: the projection, the configured set and the verdict all have to come
    /// from one reading for the contradiction to be reproducible at all.
    func testNothingChosenIsNeverReportedAsABrokenDefault() async throws {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
        defer { TestStores.removeAll() }

        // Two keyless gateways, neither of them the built-in fallback the shim
        // projects to, and no stored pointer → `.selectionRequired`.
        let hermes = RemoteAgentRef.builtin(.hermes)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://hermes.example.test")), for: hermes
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: hermes)
        let customID = UUID()
        let accepted = await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: customID, name: "Workshop")
        )
        XCTAssertTrue(accepted)
        let custom = RemoteAgentRef.custom(customID)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://workshop.example.test")), for: custom
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: custom)

        let vm = SettingsViewModel()
        await vm.refreshRemoteAgentState()

        XCTAssertTrue(vm.defaultSelectorNeedsChoice,
                      "Control: this device must genuinely be in the nothing-chosen state.")
        XCTAssertEqual(vm.defaultRemoteAgentRef, .builtin(Constants.remoteAgentDefaultBackendDefault),
                       "Control: the projection is the built-in fallback, which is what the raw predicate trips over.")
        XCTAssertFalse(vm.configuredRemoteAgentRefSet.contains(vm.defaultRemoteAgentRef),
                       "Control: the fallback is NOT configured here, which is the sub-case that misfires.")

        XCTAssertTrue(vm.defaultSelectorNeedsSetup,
                      "The raw membership predicate is byte-identical and still answers its own question — it is asserted verbatim elsewhere.")
        XCTAssertFalse(vm.defaultSelectorFlagsBroken,
                       "…but nothing may be FLAGGED as broken, because nothing was chosen.")
        XCTAssertNil(vm.defaultSelectorBrokenName,
                     "…and above all nothing may be NAMED: the footer and the picker callout both key on this.")
        XCTAssertFalse(vm.personalAIRows.contains { $0.isDefault },
                       "No row carries the chosen check when nothing has been chosen.")
    }

    // MARK: - The Keychain blackout

    /// The rule itself, over every verdict. `.readingUnreliable` is the ONE the
    /// selector may not speak about; the other seven either say nothing anyway or
    /// are trustworthy readings the screen must keep reporting.
    func testOnlyAnUntrustworthyReadingSilencesTheSelector() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let hermes = RemoteAgentRef.builtin(.hermes)

        XCTAssertFalse(SettingsViewModel.selectorMaySpeak(for: .readingUnreliable(pointer: openclaw)),
                       "A locked Keychain reads a healthy gateway as gone; the selector may not accuse it.")

        for speakable: DefaultGatewayResolution in [
            .usable(openclaw),
            .adopted(ref: hermes, replacing: openclaw),
            .bootstrapped(hermes),
            .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
            .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: true),
            .selectionRequired(candidates: [openclaw, hermes]),
            .nothingConfigured(pointer: openclaw),
            .setupUnfinished(pointer: openclaw)
        ] {
            XCTAssertTrue(SettingsViewModel.selectorMaySpeak(for: speakable),
                          "\(speakable) is a reading the screen can trust — silencing it hides real trouble. "
                          + "Only the untrustworthy one is gated here; `selectorNeedsChoice` handles the rest.")
        }
    }

    /// The restore-from-backup window, and the shape the raw membership predicate
    /// gets wrong in the OPPOSITE direction to the test above: the pointer names a
    /// gateway that is perfectly well set up, on a device that cannot read its
    /// token back yet.
    ///
    /// `configuredRemoteAgentRefs()` fails CLOSED, so during a Keychain blackout
    /// it reports a `.bearer` gateway as "not a member" and the membership
    /// predicate answers "broken". `.readingUnreliable`'s own contract forbids
    /// every surface from acting on that reading, and the chat banner,
    /// Diagnostics, the headless lanes and CarPlay all keep the silence — this
    /// screen is the one the user actually opens during the window, so its
    /// accusation ("<name> isn't set up on this iPhone") is the one that lands,
    /// beside an invitation to re-type a token that is seconds from arriving.
    ///
    /// Driven through the REAL resolver, and it writes NO secret: the blackout
    /// shape is reproducible with keyless writes alone, which is the same reason
    /// `HeadlessGatewayPreflightTests` builds it that way.
    func testAnUnreadableKeychainIsNeverReportedAsABrokenDefault() async throws {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
        defer { TestStores.removeAll() }

        // The one gateway that CAN send is keyless, so nothing in the configured
        // set proves the Keychain open…
        let hermes = RemoteAgentRef.builtin(.hermes)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://hermes.example.test:8642")), for: .hermes
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: hermes)
        // …and the stored default is a `.bearer` gateway with a URL and no token
        // that reads back. Indistinguishable, from inside the app, from a device
        // whose iCloud Keychain has not finished delivering.
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://openclaw.example.test:18789")), for: .openclaw
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: openclaw)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)

        let vm = SettingsViewModel()
        await vm.refreshRemoteAgentState()

        XCTAssertEqual(vm.defaultGatewayResolution, .readingUnreliable(pointer: openclaw),
                       "Control: the device must genuinely be in the blackout state.")
        XCTAssertEqual(vm.defaultRemoteAgentRef, openclaw,
                       "Control: the projection is the stored pointer, so a name here would name it.")
        XCTAssertFalse(vm.configuredRemoteAgentRefSet.isEmpty,
                       "Control: something IS configured, which is what stops the empty-set guard covering this.")
        XCTAssertFalse(vm.defaultSelectorNeedsChoice,
                       "Control: a stored, unparked pointer is a CHOICE, so the nothing-chosen exclusion does not cover this.")

        XCTAssertTrue(vm.defaultSelectorNeedsSetup,
                      "The raw membership predicate is byte-identical and still answers its own question — it is asserted verbatim elsewhere.")
        XCTAssertFalse(vm.defaultSelectorFlagsBroken,
                       "A reading the resolver has declared untrustworthy may not draw the ⚠ + \"Needs setup\" line.")
        XCTAssertNil(vm.defaultSelectorBrokenName,
                     "…and above all may not NAME the gateway: the footer and the picker callout both key on this.")
    }

    /// THE CONTROL for the test above, differing in exactly one fact: a second
    /// gateway is configured with a token that DOES read back, which proves the
    /// Keychain open and takes the resolver off its blackout arm. The same broken
    /// pointer must then be flagged and named — the silence is scoped to the
    /// untrustworthy reading, not extended to every unconfigured default.
    ///
    /// Writes a secret, so it skips where the store is unavailable; the blackout
    /// test above deliberately does not, and never skips.
    func testAProvenReadableKeychainStillFlagsAndNamesABrokenDefault() async throws {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
        defer { TestStores.removeAll() }

        let hermes = RemoteAgentRef.builtin(.hermes)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://hermes.example.test:8642")), for: .hermes
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: hermes)
        do {
            try await SettingsManager.shared.setRemoteAgentToken("tok-h", for: .hermes)
        } catch {
            throw XCTSkip("Secret-store write unavailable on this host (\(error)).")
        }

        let openclaw = RemoteAgentRef.builtin(.openclaw)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://openclaw.example.test:18789")), for: .openclaw
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: openclaw)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)

        let vm = SettingsViewModel()
        await vm.refreshRemoteAgentState()

        XCTAssertEqual(vm.defaultGatewayResolution,
                       .brokenDefault(broken: openclaw, candidates: [hermes], pointerIsParked: false),
                       "Control: with the Keychain proven readable this is an ordinary broken default.")
        XCTAssertTrue(vm.defaultSelectorFlagsBroken,
                      "The gateway the user chose really cannot send here, and the row has to say so.")
        XCTAssertEqual(vm.defaultSelectorBrokenName, vm.defaultRemoteAgentDisplayName,
                       "…and the footer names it, exactly as before this silence rule existed.")

        let defaultNeedsSetup = String(localized: LocalizedStringResource(
            "settings.root.personalAI.defaultNeedsSetup",
            defaultValue: "Default needs setup"
        ))
        XCTAssertEqual(vm.personalAISummaryShort, defaultNeedsSetup,
                       "…and the Settings ROOT row says the same thing as the screen it opens. This is "
                       + "the control for the blackout case below: the silence is scoped to the "
                       + "untrustworthy reading, not extended to every unconfigured default.")
    }

    /// The Settings ROOT row is the FOURTH surface asking the same question, and
    /// it is the one the user meets first — a "Default needs setup" there sends
    /// them into a Personal AI screen that has just been silenced, where nothing
    /// explains the summary that brought them. Two surfaces disagreeing about one
    /// device is harder to act on than either answer alone.
    ///
    /// Same blackout rig as `testAnUnreadableKeychainIsNeverReportedAsABrokenDefault`,
    /// driven through the REAL resolver and writing no secret.
    func testTheRootSummaryKeepsTheSameSilenceAsTheScreenItOpens() async throws {
        TestStores.removeAll()
        await SettingsManager.shared.resetRemoteAgentMigrationLatchForTesting()
        defer { TestStores.removeAll() }

        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://hermes.example.test:8642")), for: .hermes
        )
        let hermes = RemoteAgentRef.builtin(.hermes)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: hermes)
        await SettingsManager.shared.setRemoteAgentURL(
            try XCTUnwrap(URL(string: "https://openclaw.example.test:18789")), for: .openclaw
        )
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.bearer, for: openclaw)
        await SettingsManager.shared.setDefaultRemoteAgentBackend(.openclaw)

        let vm = SettingsViewModel()
        await vm.refreshRemoteAgentState()

        XCTAssertEqual(vm.defaultGatewayResolution, .readingUnreliable(pointer: openclaw),
                       "Control: the device must genuinely be in the blackout state.")
        XCTAssertEqual(vm.configuredRemoteAgentRefSet, [hermes],
                       "Control: exactly one gateway can send, and it is NOT the default — which is what "
                       + "made the old count subtract a gateway that was never in the set.")

        let defaultNeedsSetup = String(localized: LocalizedStringResource(
            "settings.root.personalAI.defaultNeedsSetup",
            defaultValue: "Default needs setup"
        ))
        XCTAssertNotEqual(vm.personalAISummaryShort, defaultNeedsSetup,
                          "The root row may not accuse a default the screen below it has been silenced "
                          + "about. One device, one answer.")
        XCTAssertEqual(vm.personalAISummaryShort, "\(vm.defaultRemoteAgentDisplayName) +1",
                       "The silenced answer still has to be TRUE: the default keeps its name, and the "
                       + "one gateway that works is counted rather than subtracted away. A bare name "
                       + "here would hide it.")
    }

    /// The gateway LIST's default row derives the same accusation, so it has to
    /// read the same gated flag. Re-asking membership there is what let one screen
    /// carry a clean selector and a "Needs setup" row about the same gateway.
    ///
    /// A source guard because the expression lives inside a SwiftUI `body`: the
    /// macOS twin is `#if os(macOS)` and this suite never compiles it, and neither
    /// row is reachable without a mounted hierarchy.
    func testBothGatewayListsReadTheGatedFlagRatherThanReAskingMembership() throws {
        let rows = [
            "Conduck/Views/Settings/PersonalAISettingsView.swift",
            "Conduck/Views/Settings/MacPersonalAICategory.swift"
        ]
        for path in rows {
            let source = try RefusalLaneSource.source(at: path)
            XCTAssertTrue(source.contains("row.isDefault && viewModel.defaultSelectorFlagsBroken"),
                          "\(path): the default row no longer reads the gated flag, so it can reach a "
                          + "different verdict than the selector that sends the user to it.")
            XCTAssertFalse(source.contains("row.isDefault && !configured"),
                           "\(path): the membership question is re-asked here. It answers \"broken\" "
                           + "about a healthy gateway whenever the Keychain cannot be read, which is "
                           + "exactly what `selectorMaySpeak` exists to refuse.")
            XCTAssertTrue(source.contains("SettingsStatusMark("),
                          "Control: this really is the row that draws the mark, or the assertions above "
                          + "are checking a ghost.")
        }
    }
}
