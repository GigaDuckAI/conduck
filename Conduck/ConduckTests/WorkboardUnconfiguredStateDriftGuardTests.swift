// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardUnconfiguredStateDriftGuardTests.swift
//
// Work with no usable gateway shows the same connect-your-AI state Chats shows,
// and its button opens the same guided setup. The behavioral half — the shared
// availability object — runs as a unit test. The wiring half is a source guard:
// the macOS window is `#if os(macOS)` and never compiles in the authoritative
// iOS-Simulator suite, which is exactly how Chats' flag and the Mac's once
// drifted apart, so each of the three shells is checked by text for injecting
// the ONE environment key the desk column branches on.

import XCTest
@testable import Conduck

final class WorkboardUnconfiguredStateDriftGuardTests: XCTestCase {

    private static let columnPath = "Conduck/Views/Workboard/WorkboardView.swift"
    private static let shellPath = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
    private static let macPath = "Conduck/Views/Conversation/MainWindowView.swift"
    private static let chatsPath = "Conduck/ContentView.swift"

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The shared availability object (iOS-only type)

    #if os(iOS)
    private actor FakeRoster {
        private(set) var refs: [RemoteAgentRef] = []
        func set(_ refs: [RemoteAgentRef]) { self.refs = refs }
    }

    @MainActor
    func testRefreshAsksTheSamePredicateAsChats() async {
        let roster = FakeRoster()
        let availability = WorkbenchGatewayAvailability(configuredRefs: { await roster.refs })

        XCTAssertFalse(availability.canSendAnywhere,
                       "Starts unconfigured like Chats' flag — never a desk a send would refuse.")

        await availability.refresh()
        XCTAssertFalse(availability.canSendAnywhere)

        await roster.set([.builtin(.hermes)])
        await availability.refresh()
        XCTAssertTrue(availability.canSendAnywhere)

        await roster.set([])
        await availability.refresh()
        XCTAssertFalse(availability.canSendAnywhere, "Forgetting the last gateway locks Work again.")
    }

    @MainActor
    func testUpdateMirrorsChatsFlag() {
        let availability = WorkbenchGatewayAvailability(configuredRefs: { [] })
        availability.update(canSendAnywhere: true)
        XCTAssertTrue(availability.canSendAnywhere)
        availability.update(canSendAnywhere: false)
        XCTAssertFalse(availability.canSendAnywhere)
    }
    #endif

    // MARK: - The tour stays off the prompt and resumes after setup

    @MainActor
    func testTourHidesBehindThePromptAndResumesOnceAGatewayLands() async {
        let session = WorkboardTutorialSession(claimIntroduction: { true })
        session.setDestinationActive(true)
        await session.beginChatToWorkTransition()?.value

        let locked = WorkboardTutorialAvailability(isActive: true, isReady: true, isBlocked: true)
        let open = WorkboardTutorialAvailability(isActive: true, isReady: true, isBlocked: false)

        XCTAssertFalse(session.isPresented(locked), "The first visit on an unconfigured device shows the prompt, not the tour.")
        XCTAssertFalse(session.acknowledge(locked), "A dismissal echo from the hidden sheet must not spend the request.")
        XCTAssertTrue(session.isPresented(open), "Once a gateway lands, the armed request still tours.")

        session.didPresent()
        XCTAssertFalse(session.isPresented(locked),
                       "A tour already on screen leaves when the last gateway goes — which `blocksAutomatic` could not do.")
        XCTAssertTrue(session.isPresented(open), "…and comes back, same page, when configuration returns.")
    }

    // MARK: - The desk column branches on the one key

    func testDeskColumnDrawsTheSharedUnconfiguredStateAheadOfEveryDeskArm() throws {
        let source = try RefusalLaneSource.source(at: Self.columnPath)
        let column = try RefusalLaneSource.trailingClosure(
            after: "struct WorkboardDetailColumn: View",
            in: source,
            path: Self.columnPath
        )
        XCTAssertTrue(column.contains("@Environment(\\.workDeskCanSendAnywhere) private var canSendAnywhere"))
        XCTAssertTrue(column.contains("@Environment(\\.workDeskConnectAI) private var connectAI"))

        let body = try RefusalLaneSource.trailingClosure(after: "var body: some View", in: column, path: Self.columnPath)
        XCTAssertTrue(body.contains("if !canSendAnywhere"))
        XCTAssertTrue(body.contains("UnconfiguredEmptyState(mascot: hostMascot) { connectAI?() }"),
                      "Same view, same copy source as Chats — no Work-specific phrasing of one screen.")
        XCTAssertFalse(body.contains("switch viewModel.deskPresentation"),
                       "The gateway branch sits ABOVE the desk's load/fail/desk arms, not inside one of them.")
    }

    func testTourHoldsOffWhileTheConnectPromptIsUp() throws {
        let source = try RefusalLaneSource.source(at: Self.columnPath)
        let availability = try RefusalLaneSource.trailingClosure(
            after: "private var tutorialAvailability: WorkboardTutorialAvailability",
            in: source,
            path: Self.columnPath
        )
        XCTAssertTrue(availability.contains("|| !canSendAnywhere"))
        // A PRESENTATION blocker: `isPresented` bypasses automatic blockers once
        // the tour has shown, so only `isBlocked` pulls a tour already on screen.
        let blocksAutomatic = try XCTUnwrap(availability.range(of: "blocksAutomatic:"))
        let isBlocked = try XCTUnwrap(availability.range(of: "isBlocked:"))
        let gate = try XCTUnwrap(availability.range(of: "|| !canSendAnywhere"))
        XCTAssertTrue(gate.lowerBound > isBlocked.lowerBound && gate.lowerBound < blocksAutomatic.lowerBound,
                      "`!canSendAnywhere` belongs to `isBlocked`, not `blocksAutomatic`.")
    }

    // MARK: - Every shell injects the key from its own truth source

    func testIOSShellInjectsTheKeyOnBothWorkMountsAndTheWriteHandleOnBothChatsMounts() throws {
        let source = try RefusalLaneSource.source(at: Self.shellPath)
        XCTAssertEqual(
            occurrences(of: ".environment(\\.workDeskCanSendAnywhere, model.gatewayAvailability.canSendAnywhere)", in: source),
            2,
            "Compact TabView and wide ZStack each mount Work once; both must lock it."
        )
        XCTAssertEqual(
            occurrences(of: ".environment(\\.workbenchGatewayAvailability, model.gatewayAvailability)", in: source),
            2,
            "Chats writes the flag from both layouts."
        )
        let presenter = try RefusalLaneSource.trailingClosure(
            after: "private struct WorkSettingsPresentationModifier: ViewModifier",
            in: source,
            path: Self.shellPath
        )
        XCTAssertTrue(presenter.contains(".environment(\\.workDeskConnectAI, { openSettings(autoOpenGuidedSetup: true) })"))
        XCTAssertTrue(presenter.contains("autoOpenGuidedSetup: route.autoOpenGuidedSetup"),
                      "The Work door reaches guided setup through the Settings containers' own consume-once latch.")
        XCTAssertTrue(presenter.contains("Task { await gatewayAvailability.refresh() }"),
                      "A gateway saved through Work's own Settings never passes Chats' dismiss refresh.")
    }

    func testChatsWritesItsFlagIntoTheSharedObject() throws {
        let source = try RefusalLaneSource.source(at: Self.chatsPath)
        let refresh = try RefusalLaneSource.body(ofFunction: "refreshConfiguredFlag", in: source, path: Self.chatsPath)
        XCTAssertTrue(refresh.contains("workbenchGatewayAvailability?.update(canSendAnywhere: isRemoteAgentConfigured)"))
        XCTAssertEqual(occurrences(of: ".onChange(of: workbenchGatewayAvailability?.canSendAnywhere)", in: source), 2,
                       "Both iOS layouts read the flag back so Chats unlocks after setup from Work.")
    }

    func testMacWindowLocksWorkOnTheSameFlagAndOpensTheSameDoor() throws {
        let source = try RefusalLaneSource.source(at: Self.macPath)
        XCTAssertEqual(
            occurrences(of: ".environment(\\.workDeskCanSendAnywhere, coordinator.hasAnyConfiguredGateway)", in: source),
            2,
            "The detail mount and the presentation-chain mount both read `hasAnyConfiguredGateway` — the flag Chats' detail column reads."
        )
        // Environment reaches descendants only: the injection that feeds the tour
        // blocker must wrap the presentation modifier, not sit inside it.
        let split = try RefusalLaneSource.trailingClosure(after: "private var splitView: some View", in: source, path: Self.macPath)
        let modifier = try XCTUnwrap(split.range(of: ".modifier(workboardExperience(for: personalWorkbenchModel).presentationModifier)"))
        let injection = try XCTUnwrap(split.range(of: ".environment(\\.workDeskCanSendAnywhere, coordinator.hasAnyConfiguredGateway)"))
        XCTAssertTrue(injection.lowerBound > modifier.upperBound,
                      "`.environment` must come AFTER `.modifier(presentationModifier)` or the tour blocker reads the default `true`.")
        XCTAssertTrue(source.contains(".environment(\\.workDeskConnectAI, openGuidedSetupFromEmptyState)"))
        XCTAssertTrue(source.contains("UnconfiguredEmptyState(mascot: hostMascot, mascotHeight: 140, action: openGuidedSetupFromEmptyState)"),
                      "Chats' empty state and Work's button share one function, so the two doors cannot diverge.")
    }
}
