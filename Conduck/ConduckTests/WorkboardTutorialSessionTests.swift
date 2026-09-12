// SPDX-License-Identifier: Apache-2.0

// Work is introduced only after the person's first Chats-to-Work selection.
// Real section routes and memory-backed claims exercise delayed and interrupted
// presentation without a real desk write, recording, gateway or App-Group file.

import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class WorkboardTutorialSessionTests: XCTestCase {
    private var available: WorkboardTutorialAvailability {
        .init(isActive: true, isReady: true, isBlocked: false)
    }

    private func makeRouter(
        claim: @escaping @MainActor () async -> Bool = { true }
    ) -> (PersonalWorkbenchRouter, WorkboardTutorialSession) {
        let router = PersonalWorkbenchRouter()
        let session = WorkboardTutorialSession(claimIntroduction: claim)
        router.tutorialSession = session
        return (router, session)
    }

    private func start(_ session: WorkboardTutorialSession) async {
        let task = session.beginChatToWorkTransition()
        session.setDestinationActive(true)
        await task?.value
    }

    func testLaunchAndDirectCaptureRoutesDoNotIntroduceWork() async {
        let claimed = expectation(description: "First deliberate selection claims the introduction")
        var claimCount = 0
        let (router, session) = makeRouter {
            claimCount += 1
            claimed.fulfill()
            return true
        }
        session.setDestinationActive(true)
        router.destination = .work
        XCTAssertFalse(session.isEligibleVisit)
        XCTAssertFalse(session.isRequested)
        XCTAssertEqual(claimCount, 0)

        router.destination = .chats
        session.deferAutomaticForVisit()
        router.destination = .work
        XCTAssertFalse(session.isRequested)
        XCTAssertEqual(claimCount, 0, "A directed capture cannot spend the first user selection")

        router.destination = .chats
        router.selectDestination(.work)
        await fulfillment(of: [claimed], timeout: 1)
        XCTAssertEqual(claimCount, 1)
        XCTAssertTrue(session.isPresented(available))
    }

    func testSectionBindingClaimsOnlyTheFirstChatsToWorkSelection() async {
        let claimed = expectation(description: "Section binding claims")
        var claimCount = 0
        let (router, session) = makeRouter {
            claimCount += 1
            claimed.fulfill()
            return true
        }
        let binding = WorkbenchSectionToolbarItem.selectionBinding(for: router)
        binding.wrappedValue = .chats
        XCTAssertFalse(session.isEligibleVisit)
        binding.wrappedValue = .work
        await fulfillment(of: [claimed], timeout: 1)
        XCTAssertEqual(router.destination, .work)
        XCTAssertTrue(session.isPresented(available))
        XCTAssertTrue(session.acknowledge(available))

        binding.wrappedValue = .work
        binding.wrappedValue = .chats
        binding.wrappedValue = .work
        XCTAssertNil(session.beginChatToWorkTransition())
        XCTAssertFalse(session.isRequested)
        XCTAssertEqual(claimCount, 1)
    }

    #if os(iOS)
    func testPhoneSectionMenuClaimsFromAVisibleUserSelectionOnly() async {
        let claimed = expectation(description: "Phone control claims")
        let (router, session) = makeRouter { claimed.fulfill(); return true }
        router.selectPhoneSection(.work)
        XCTAssertEqual(router.destination, .chats)
        XCTAssertFalse(session.isEligibleVisit)
        router.togglePhoneSection(for: .chats)
        router.selectPhoneSection(.chats)
        XCTAssertFalse(session.isEligibleVisit)

        router.togglePhoneSection(for: .chats)
        router.selectPhoneSection(.work)
        await fulfillment(of: [claimed], timeout: 1)
        XCTAssertEqual(router.destination, .work)
        XCTAssertNil(router.expandedPhoneSection)
        XCTAssertTrue(session.isPresented(available))

        router.togglePhoneSection(for: .work)
        router.selectPhoneSection(.chats)
        XCTAssertFalse(session.isRequested)
        router.togglePhoneSection(for: .chats)
        router.selectPhoneSection(.work)
        XCTAssertFalse(session.isEligibleVisit)
        XCTAssertNil(session.beginChatToWorkTransition())
    }
    #endif

    func testLateSuccessfulClaimCannotReopenAfterLeavingAndReturning() async {
        let started = expectation(description: "Claim started")
        let gate = ClaimGate(started: started)
        let session = WorkboardTutorialSession(claimIntroduction: { await gate.claim() })
        let task = session.beginChatToWorkTransition()
        session.setDestinationActive(true)
        await fulfillment(of: [started], timeout: 1)
        session.setDestinationActive(false)
        session.setDestinationActive(true)
        XCTAssertNil(session.beginChatToWorkTransition())
        gate.finish(true)
        await task?.value
        XCTAssertFalse(session.isRequested)
        XCTAssertFalse(session.isEligibleVisit)
    }

    func testDirectedCaptureCancelsBothAnOpenTourAndAPendingClaim() async {
        let session = WorkboardTutorialSession(claimIntroduction: { true })
        await start(session)
        session.didPresent()
        session.advance()
        session.deferAutomaticForVisit()
        XCTAssertFalse(session.isRequested)
        XCTAssertFalse(session.acknowledge(available))
        session.setDestinationActive(false)
        session.setDestinationActive(true)
        XCTAssertNil(session.beginChatToWorkTransition())
        XCTAssertFalse(session.isPresented(available))

        let started = expectation(description: "Claim pending while capture arrives")
        let gate = ClaimGate(started: started)
        let pending = WorkboardTutorialSession(claimIntroduction: { await gate.claim() })
        let task = pending.beginChatToWorkTransition()
        pending.setDestinationActive(true)
        await fulfillment(of: [started], timeout: 1)
        pending.deferAutomaticForVisit()
        gate.finish(true)
        await task?.value
        XCTAssertFalse(pending.isRequested)
        XCTAssertFalse(pending.isEligibleVisit)
    }

    func testFirstTransitionClaimsEvenWhenLoadingThenCannotRepeatOnThisDevice() async {
        let defaults = InMemoryDefaultsStore()
        let manager = SettingsManager(dependencies: .inMemory(defaults: defaults))
        let session = WorkboardTutorialSession(claimIntroduction: { await manager.claimWorkboardTutorial() })
        var loading = available
        loading.isReady = false
        await start(session)
        XCTAssertTrue(defaults.bool(forKey: Constants.workboardTutorialSeenKey))
        XCTAssertTrue(session.isRequested)
        XCTAssertFalse(session.isPresented(loading))

        session.setDestinationActive(false)
        session.setDestinationActive(true)
        XCTAssertNil(session.beginChatToWorkTransition())
        XCTAssertFalse(session.isRequested)
        let restoredManager = SettingsManager(dependencies: .inMemory(defaults: defaults))
        let restored = WorkboardTutorialSession(claimIntroduction: { await restoredManager.claimWorkboardTutorial() })
        await start(restored)
        XCTAssertFalse(restored.isRequested, "Closing before loading finishes still spends the device introduction")
    }

    func testClaimIsOneShotAcrossConcurrentWindowsAndAnotherManager() async {
        let defaults = InMemoryDefaultsStore()
        let manager = SettingsManager(dependencies: .inMemory(defaults: defaults))
        async let first = manager.claimWorkboardTutorial()
        async let second = manager.claimWorkboardTutorial()
        let firstResult = await first
        let secondResult = await second
        XCTAssertEqual([firstResult, secondResult].filter { $0 }.count, 1)
        XCTAssertTrue(defaults.bool(forKey: Constants.workboardTutorialSeenKey))
        let restored = SettingsManager(dependencies: .inMemory(defaults: defaults))
        let nextClaim = await restored.claimWorkboardTutorial()
        XCTAssertFalse(nextClaim)
    }

    func testSharedCloudAndSecretsDoNotCarryTheClaimToAnotherDevice() async {
        let ubiquitous = InMemoryUbiquitousStore()
        let secrets = InMemorySecretStore()
        let firstDefaults = InMemoryDefaultsStore()
        let secondDefaults = InMemoryDefaultsStore()
        let first = SettingsManager(dependencies: .inMemory(
            defaults: firstDefaults, ubiquitous: ubiquitous, secrets: secrets, cloudAvailable: true
        ))
        let firstClaim = await first.claimWorkboardTutorial()
        XCTAssertTrue(firstClaim)
        let second = SettingsManager(dependencies: .inMemory(
            defaults: secondDefaults, ubiquitous: ubiquitous, secrets: secrets, cloudAvailable: true
        ))
        XCTAssertFalse(secondDefaults.bool(forKey: Constants.workboardTutorialSeenKey))
        let secondClaim = await second.claimWorkboardTutorial()
        XCTAssertTrue(secondClaim, "A fresh device teaches its own capture route")
        XCTAssertNil(ubiquitous.object(forKey: Constants.workboardTutorialSeenKey))
    }

    func testOverlappingOwnersRetainAClaimUntilAllBlockersClear() async {
        let session = WorkboardTutorialSession(claimIntroduction: { true })
        let picker = UUID(), recorder = UUID()
        session.setInteraction(owner: picker, isBlocking: true, blocksAutomatic: false)
        session.setInteraction(owner: recorder, isBlocking: true, blocksAutomatic: false)
        await start(session)
        XCTAssertTrue(session.isRequested)
        session.removeInteraction(owner: picker)
        XCTAssertFalse(session.isPresented(available))
        XCTAssertFalse(session.acknowledge(available))
        session.removeInteraction(owner: recorder)
        XCTAssertTrue(session.isPresented(available))
    }

    func testLateClaimSurvivesLoadingAndDraftUntilTheFirstPresentationIsReady() async {
        let started = expectation(description: "Claim began before loading and drafting")
        let gate = ClaimGate(started: started)
        let session = WorkboardTutorialSession(claimIntroduction: { await gate.claim() })
        let task = session.beginChatToWorkTransition()
        session.setDestinationActive(true)
        await fulfillment(of: [started], timeout: 1)
        let composer = UUID()
        session.setInteraction(owner: composer, isBlocking: false, blocksAutomatic: true)
        gate.finish(true)
        await task?.value
        XCTAssertTrue(session.isRequested, "A successful claim must survive a temporary presentation delay")
        XCTAssertFalse(session.isPresented(available))
        session.removeInteraction(owner: composer)

        var loading = available
        loading.isReady = false
        var modal = available
        modal.isBlocked = true
        var draft = available
        draft.blocksAutomatic = true
        var inactive = available
        inactive.isActive = false
        for blocked in [loading, modal, draft, inactive] {
            XCTAssertFalse(session.isPresented(blocked))
            XCTAssertFalse(session.acknowledge(blocked))
        }
        XCTAssertTrue(session.isPresented(available))
        session.didPresent()
        XCTAssertTrue(session.isPresented(loading), "A normal background refresh must not flicker an open tour")
    }

    func testTemporaryModalPreservesTheCurrentPageWithoutConsumingDismissal() async {
        let session = WorkboardTutorialSession(claimIntroduction: { true })
        await start(session)
        session.didPresent()
        session.advance()
        let owner = UUID()
        session.setInteraction(owner: owner, isBlocking: true, blocksAutomatic: false)
        XCTAssertFalse(session.isPresented(available))
        XCTAssertFalse(session.acknowledge(available))
        session.removeInteraction(owner: owner)
        XCTAssertTrue(session.isPresented(available))
        XCTAssertEqual(session.currentStep, 1)
        XCTAssertTrue(session.acknowledge(available))
        XCTAssertFalse(session.isRequested)
    }

    func testGoToWorkPreservesCurrentProjectConversationAndDrafts() async {
        enum Unexpected: Error { case mutation }
        let workspace = WorkDeskWorkspaceState(organization: WorkDeskOrganization(
            fetch: { throw Unexpected.mutation }, apply: { _ in throw Unexpected.mutation }
        ))
        let model = WorkboardViewModel(dependencies: .init(
            loadDesk: { nil }, importMaterial: { _, _, _ in throw Unexpected.mutation },
            removeMaterial: { _, _ in throw Unexpected.mutation },
            replaceMaterial: { _, _, _, _ in throw Unexpected.mutation },
            openMaterial: { _ in XCTFail("The introduction must not open a material") }
        ), deskWorkspace: workspace)
        let project = WorkDeskScope.project(UUID()), conversation = UUID()
        model.setComposerDraft("Keep the Home draft")
        workspace.selectScope(project)
        model.setComposerDraft("Keep the project draft")
        workspace.selectedConversationID = conversation
        let conversationSession = workspace.conversationSession(for: conversation)
        conversationSession.draft = "Keep the conversation draft"

        let (router, session) = makeRouter()
        let claim = session.beginChatToWorkTransition()
        router.destination = .work
        await claim?.value
        session.didPresent()
        for _ in 0..<4 { session.advance() }
        XCTAssertTrue(session.acknowledge(available))
        XCTAssertEqual(router.destination, .work)
        XCTAssertEqual(workspace.scope, project)
        XCTAssertEqual(workspace.selectedConversationID, conversation)
        XCTAssertEqual(model.composerDraft(for: project), "Keep the project draft")
        XCTAssertEqual(model.composerDraft(for: .all), "Keep the Home draft")
        XCTAssertEqual(conversationSession.draft, "Keep the conversation draft")
        XCTAssertNil(model.desk, "The introduction must not create sample cards")
    }

    func testFourShortStepsStayWithinTheirNavigationBounds() {
        let session = WorkboardTutorialSession(claimIntroduction: { true })
        XCTAssertEqual(WorkboardTutorialSession.stepCount, 4)
        XCTAssertEqual(session.currentStep, 0)
        session.goBack()
        XCTAssertEqual(session.currentStep, 0)
        for expected in 1...3 {
            session.advance()
            XCTAssertEqual(session.currentStep, expected)
        }
        session.advance()
        XCTAssertEqual(session.currentStep, 3)
        for expected in stride(from: 2, through: 0, by: -1) {
            session.goBack()
            XCTAssertEqual(session.currentStep, expected)
        }
        session.goBack()
        XCTAssertEqual(session.currentStep, 0)
    }

    @MainActor
    private final class ClaimGate {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<Bool, Never>?
        init(started: XCTestExpectation) { self.started = started }
        func claim() async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        func finish(_ granted: Bool) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: granted)
        }
    }
}
