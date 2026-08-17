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
}
