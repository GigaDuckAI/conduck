// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarCoordinatorQuickTypedTests.swift
//
// The TEXT-input-mode quick lane (`sendQuickTypedDraft` → `handleQuickSend`):
//   - the SYNCHRONOUS press contract (gap-bridge claimed + draft cleared +
//     destination latched in one MainActor turn — the no-stale-frame rule),
//   - the empty-draft guards (no-op without a staged image; attachment-only
//     proceeds),
//   - the in-flight backstops (a racing Return never eats the draft),
//   - the handoff-error stash ladder (deleted explicit destination → visible
//     error + `.quickTyped` stash + snapshot kept latched; busy target →
//     stash; attachment-only failure degrades to a Dismiss-only error),
//   - `.quickTyped` Retry replaying through the QUICK lane (never the window
//     lane) by re-consuming the kept-latched snapshot,
//   - `popoverDidCloseHook` keeping compose state (staged image OR non-empty
//     draft) + the explicit pick across dismissals — and still dropping an
//     unconsumed pick when no compose state exists (incl. a voice-mode
//     stranded draft, which must NOT pin picks),
//   - text→voice flip reconciliation (staged image cleared, draft kept),
//   - the `.voice` wrapper's post-refactor parity on the shared path,
//   - the WORK screenshot slot: never picked up by a chat turn, parked by a
//     navigation, dropped by the bail that discards its composition, and
//     scoped so a bail aimed at the chat draft leaves it alone.
//
// Every coordinator injects an isolated `ConversationStore(inMemory: true)`
// via the store seam: the unsigned test host CRASHES (or hangs) on the shared
// CloudKit-backed container's first touch — no iCloud entitlement. Paths that
// would reach `vm.sendUserTurn` (whose optimistic append hits the SHARED
// store inside the VM) are deliberately not driven; the send tail is
// signed-run + QA territory. `@MainActor` because the coordinator requires it.

#if os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class MenuBarCoordinatorQuickTypedTests: XCTestCase {

    private let modeDefaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        modeDefaults.removeObject(forKey: Constants.menuBarInputModeKey)
    }

    override func tearDown() async throws {
        modeDefaults.removeObject(forKey: Constants.menuBarInputModeKey)
        try await super.tearDown()
    }

    /// Coordinator + its isolated in-memory store (kept so tests can seed
    /// conversations for the busy/retry paths). Mode mirror seeds VOICE (the
    /// wiped-key default).
    private func makeCoordinator() -> (MenuBarCoordinator, ConversationStore) {
        let store = ConversationStore(inMemory: true)
        return (MenuBarCoordinator(conversationStore: store), store)
    }

    /// Coordinator whose mode mirror seeds TEXT — the device-local key is
    /// written BEFORE construction (the mirror reads it synchronously in
    /// `init`), the same order a real text-mode machine launches in.
    private func makeTextModeCoordinator() -> (MenuBarCoordinator, ConversationStore) {
        modeDefaults.set(MenuBarInputMode.text.rawValue,
                         forKey: Constants.menuBarInputModeKey)
        return makeCoordinator()
    }

    /// Poll until `condition` holds (the send tail is a short store hop; no
    /// notification to await). Fails the test on timeout.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    /// Point the next quick capture at a nonexistent thread — the
    /// deleted-explicit-destination branch (read-only against the store).
    private func aimAtDeletedThread(_ coordinator: MenuBarCoordinator) {
        coordinator.selectQuickDestination(.explicitConversation(UUID()))
    }

    private func isError(_ coordinator: MenuBarCoordinator) -> Bool {
        if case .error = coordinator.dictationService.state { return true }
        return false
    }

    // MARK: - Synchronous press contract

    func testSendClaimsGapBridgeClearsDraftAndLatchesSynchronously() {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.quickDraft = "  hello there  "
        coordinator.sendQuickTypedDraft()
        // All three commit BEFORE any await — the popover must flip to the
        // working view in the same render that empties the field.
        XCTAssertTrue(coordinator.turnStarting,
                      "Gap-bridge must be claimed synchronously (no stale frame).")
        XCTAssertEqual(coordinator.quickDraft, "",
                       "Draft must clear synchronously with the claim.")
        XCTAssertTrue(coordinator.quickDestinationLatched,
                      "The Return press freezes the displayed destination (display==send).")
    }

    // MARK: - Empty-draft guards

    func testEmptyDraftWithoutImageIsTotalNoOp() {
        let (coordinator, _) = makeCoordinator()
        coordinator.quickDraft = "   \n  "
        coordinator.sendQuickTypedDraft()
        XCTAssertFalse(coordinator.turnStarting,
                       "Whitespace-only with nothing staged must not start a turn.")
        XCTAssertFalse(coordinator.quickDestinationLatched,
                       "A no-op must not latch (a held latch freezes background refreshes).")
    }

    func testEmptyDraftWithStagedImageProceeds() {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.setPendingCaptureImage(Data([0x89, 0x50]))
        coordinator.quickDraft = ""
        coordinator.sendQuickTypedDraft()
        XCTAssertTrue(coordinator.turnStarting,
                      "Attachment-only turns are allowed — parity with `handleTypedText`.")
    }

    // MARK: - In-flight backstops (a blocked send must not eat the words)

    func testReturnWhileQuickLaneAwaitsReplyKeepsDraft() {
        let (coordinator, _) = makeCoordinator()
        coordinator.bindQuickViewModel(to: UUID())
        coordinator.quickViewModel?.isAwaitingReply = true
        coordinator.quickDraft = "queued thought"
        coordinator.sendQuickTypedDraft()
        XCTAssertFalse(coordinator.turnStarting)
        XCTAssertEqual(coordinator.quickDraft, "queued thought",
                       "A backstopped send returns BEFORE the draft clears.")
    }

    func testRacingSecondReturnKeepsSecondDraft() {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.quickDraft = "first"
        coordinator.sendQuickTypedDraft()
        XCTAssertTrue(coordinator.turnStarting)
        // A second Return racing the first turn's hand-off gap: blocked by the
        // `turnStarting` backstop, and blocked BEFORE the draft clears.
        coordinator.quickDraft = "second thought"
        coordinator.sendQuickTypedDraft()
        XCTAssertEqual(coordinator.quickDraft, "second thought",
                       "A backstopped send returns BEFORE the draft clears.")
    }

    // MARK: - Handoff-error stash (deleted explicit destination)

    func testDeletedExplicitDestinationStashesQuickTypedAndKeepsLatch() async {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.quickDraft = "words worth keeping"
        coordinator.sendQuickTypedDraft()

        await waitUntil("handoff error to present") { isError(coordinator) }
        XCTAssertTrue(coordinator.hasPendingFailedTurn,
                      "The typed words must be stashed for the error footer's Retry.")
        XCTAssertTrue(coordinator.quickDestinationLatched,
                      "A stash-error keeps the snapshot latched so Retry replays the promised destination.")
        XCTAssertFalse(coordinator.turnStarting,
                       "The defer must release the gap-bridge on the stash exit.")
        if case .explicitNew = coordinator.quickDestination?.destination {
            // Repointed so the error copy's "Retry → new chat" promise is
            // literally what the replay does.
        } else {
            XCTFail("Deleted explicit destination must repoint the kept snapshot to .explicitNew.")
        }
    }

    func testAttachmentOnlyHandoffFailureDegradesToDismissOnly() async {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.setPendingCaptureImage(Data([0x89, 0x50]))
        coordinator.quickDraft = ""
        coordinator.sendQuickTypedDraft()

        await waitUntil("handoff error to present") { isError(coordinator) }
        XCTAssertFalse(coordinator.hasPendingFailedTurn,
                       "No words → nothing replayable; an empty stash would dead-end Retry.")
        XCTAssertNil(coordinator.pendingCaptureImage,
                     "The defer clears the staged image on every exit — same contract as voice.")
        XCTAssertFalse(coordinator.quickDestinationLatched,
                       "No stash → nothing will consume the snapshot; the latch must release.")
    }

    // MARK: - Busy target + `.quickTyped` Retry replays the QUICK lane

    func testBusyTargetStashesAndRetryReplaysQuickLane() async throws {
        let (coordinator, store) = makeCoordinator()
        let record = try await store.createConversation(backend: "openclaw")
        // Pre-mark the target VM busy (registry reuse returns this instance to
        // the send path), then aim the capture at it explicitly.
        coordinator.viewModel(for: record.id).isAwaitingReply = true
        coordinator.selectQuickDestination(.explicitConversation(record.id))
        coordinator.quickDraft = "typed into a busy thread"
        coordinator.sendQuickTypedDraft()

        await waitUntil("busy handoff error to present") { isError(coordinator) }
        XCTAssertTrue(coordinator.hasPendingFailedTurn)
        if case .explicitConversation(let id) = coordinator.quickDestination?.destination {
            XCTAssertEqual(id, record.id,
                           "A busy stash keeps the snapshot on the SAME thread — Retry replays there once it frees up.")
        } else {
            XCTFail("Busy stash must keep the explicit destination latched.")
        }

        // Retry while STILL busy: the `.quickTyped` arm must claim the
        // gap-bridge synchronously and replay through `handleQuickSend` —
        // re-consuming the kept snapshot and re-stashing on the same busy
        // target. A mis-route through the window lane (`handleTypedText`)
        // would mint a fresh conversation and bind `windowViewModel`.
        coordinator.retryPendingFailedTurn()
        XCTAssertTrue(coordinator.turnStarting,
                      "`.quickTyped` Retry claims the gap-bridge synchronously, like `.voice`.")
        XCTAssertFalse(coordinator.hasPendingFailedTurn,
                       "Retry consumes the stash before replaying.")
        await waitUntil("replay to re-stash on the still-busy target") {
            coordinator.hasPendingFailedTurn && !coordinator.turnStarting
        }
        XCTAssertTrue(isError(coordinator),
                      "The replay must re-present the busy error, not vanish the words.")
        XCTAssertNil(coordinator.windowViewModel,
                     "A `.quickTyped` replay must NEVER touch the window lane.")
        if case .explicitConversation(let id) = coordinator.quickDestination?.destination {
            XCTAssertEqual(id, record.id, "The replay consumed the kept-latched snapshot.")
        } else {
            XCTFail("The kept snapshot must survive the replay cycle.")
        }
    }

    // MARK: - New-chat gateway pick (the submenu → snapshot the mint consumes)

    /// The popover's "New chat · {gateway}" submenu calls
    /// `selectQuickDestination(.explicitNew(ref))`. The snapshot must carry that
    /// exact ref — `handleQuickSend` mints `createConversation(backend:)` on it
    /// (`mintRef ?? default`), so the carried ref IS the mint target — and the
    /// caption must show the picked gateway's display name. A built-in ref keeps
    /// the assertion deterministic (static `displayName`, no roster cache /
    /// Keychain needed; the full mint-and-send tail is the signed QA gate).
    func testPickExplicitNewGatewayCarriesRefAndCaption() {
        let (coordinator, _) = makeCoordinator()
        coordinator.selectQuickDestination(.explicitNew(.builtin(.hermes)))
        guard case .explicitNew(let ref) = coordinator.quickDestination?.destination else {
            return XCTFail("A gateway pick must set the destination to .explicitNew carrying that gateway.")
        }
        XCTAssertEqual(ref, .builtin(.hermes),
                       "The latched snapshot must carry the picked gateway — handleQuickSend mints on exactly this ref.")
        XCTAssertEqual(coordinator.quickDestination?.gatewayName,
                       RemoteAgentBackend.hermes.displayName,
                       "The 'New chat · {gateway}' caption shows the picked gateway's name.")
    }

    /// The single-gateway path (and the submenu's default row) pick
    /// `.explicitNew(nil)` — no carried gateway, so the mint resolves the
    /// persisted default at send time; the caption falls back to the cached
    /// default-gateway name.
    func testPickExplicitNewDefaultCarriesNoRef() {
        let (coordinator, _) = makeCoordinator()
        coordinator.selectQuickDestination(.explicitNew(nil))
        guard case .explicitNew(let ref) = coordinator.quickDestination?.destination else {
            return XCTFail("The default New-chat pick must still set .explicitNew.")
        }
        XCTAssertNil(ref,
                     "A default New-chat pick carries no gateway — the mint resolves the persisted default at send time.")
        XCTAssertEqual(coordinator.quickDestination?.gatewayName,
                       coordinator.quickDefaultGatewayName,
                       "Caption falls back to the cached default-gateway name.")
    }

    // MARK: - Voice-wrapper regression (post-refactor parity)

    func testVoiceTranscriptOnDeletedExplicitDestinationStillStashes() async {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        await coordinator.handleTranscript("spoken words")
        XCTAssertTrue(coordinator.hasPendingFailedTurn,
                      "The `.voice` path through the shared `handleQuickSend` must stash exactly as before the refactor.")
        XCTAssertTrue(isError(coordinator),
                      "Deleted explicit destination must present the handoff error for voice too.")
    }

    // MARK: - Dismissal keeps compose state (text-mode contract)

    func testPopoverCloseWithStagedImageKeepsImageAndExplicitPick() {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.setPendingCaptureImage(Data([0x89, 0x50]))
        coordinator.popoverDidCloseHook()
        XCTAssertNotNil(coordinator.pendingCaptureImage,
                        "An outside click must not strip a staged ⌘⇧2 screenshot (the reopened thumbnail + ✕ keep it visible and discardable).")
        if case .explicitConversation = coordinator.quickDestination?.destination {} else {
            XCTFail("With compose state staged, the explicit pick must survive the dismissal.")
        }
    }

    func testIdlePopoverCloseWithoutComposeStateDropsExplicitPick() async {
        let (coordinator, _) = makeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.popoverDidCloseHook()
        // One-shot semantics hold for text mode exactly as for voice: an
        // unconsumed pick dies with a bare idle dismissal.
        await waitUntil("explicit pick to reset") {
            if case .explicitConversation = coordinator.quickDestination?.destination { return false }
            return true
        }
    }

    func testPopoverCloseWithNonEmptyDraftKeepsExplicitPick() {
        let (coordinator, _) = makeTextModeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.quickDraft = "half a thought"
        coordinator.popoverDidCloseHook()
        if case .explicitConversation = coordinator.quickDestination?.destination {} else {
            XCTFail("""
                A non-empty draft is compose state exactly like a staged image — \
                the pick made for those words must survive the dismissal \
                (otherwise the surviving draft sends to the auto-resolved thread).
                """)
        }
    }

    func testDraftDoesNotPinExplicitPickInVoiceMode() async {
        // A draft stranded by a text→voice flip is inert (the compose surface
        // is its only sender) — it must NOT pin destination picks in voice mode.
        let (coordinator, _) = makeCoordinator()   // voice (wiped-key default)
        aimAtDeletedThread(coordinator)
        coordinator.quickDraft = "stranded by a mode flip"
        coordinator.popoverDidCloseHook()
        await waitUntil("explicit pick to reset despite the stranded draft") {
            if case .explicitConversation = coordinator.quickDestination?.destination { return false }
            return true
        }
    }

    // MARK: - Mode-flip reconciliation (text → voice)

    func testFlipToVoiceClearsStagedImageButKeepsDraft() async {
        let (coordinator, _) = makeTextModeCoordinator()
        XCTAssertEqual(coordinator.menuBarInputMode, .text)
        coordinator.setPendingCaptureImage(Data([0x89, 0x50]))
        coordinator.quickDraft = "typed before the flip"

        // The Settings write path: persist the new mode, then the same
        // notification `setMenuBarInputMode` posts.
        modeDefaults.set(MenuBarInputMode.voice.rawValue,
                         forKey: Constants.menuBarInputModeKey)
        NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)

        await waitUntil("mode mirror to refresh") {
            coordinator.menuBarInputMode == .voice
        }
        XCTAssertNil(coordinator.pendingCaptureImage,
                     "A text-staged screenshot must not linger into voice mode — it would silently ride the next ⌘⇧1 voice turn.")
        XCTAssertEqual(coordinator.quickDraft, "typed before the flip",
                       "The draft survives the flip: inert in voice mode, restored intact on flipping back.")
    }

    // MARK: - Explicit cancel clears compose state (Esc / cancel buttons)

    /// Esc and every on-screen Cancel/Dismiss/Discard route through
    /// `cancelActiveCapture` — the universal explicit-bail teardown. Unlike a
    /// click-away (`popoverDidCloseHook`, which PRESERVES compose state), this
    /// must wipe BOTH the staged ⌘⇧2 screenshot and the typed draft and release
    /// the armed destination, in every mode/state — a clean slate, so nothing
    /// spills into the next ⌘⇧1/⌘⇧2 summon.
    func testCancelActiveCaptureClearsStagedImageAndDraft() {
        let (coordinator, _) = makeTextModeCoordinator()
        aimAtDeletedThread(coordinator)
        coordinator.armQuickCapture()   // freeze the explicit pick (latched)
        coordinator.setPendingCaptureImage(Data([0x89, 0x50]))
        coordinator.quickDraft = "words to discard"

        coordinator.cancelActiveCapture()

        XCTAssertNil(coordinator.pendingCaptureImage,
                     "Esc / explicit cancel discards a staged ⌘⇧2 screenshot in every mode.")
        XCTAssertEqual(coordinator.quickDraft, "",
                       "Esc / explicit cancel discards the typed draft too — a clean slate.")
        XCTAssertFalse(coordinator.quickDestinationLatched,
                       "The teardown releases the armed destination latch.")
        if case .explicitConversation = coordinator.quickDestination?.destination {
            XCTFail("The one-shot explicit pick must be released by the teardown.")
        }
    }

    // MARK: - The Work screenshot lives in its own slot

    /// The leak this slot exists to prevent, caught at the only place it could
    /// happen: the attachments a real chat turn assembles.
    ///
    /// `pendingCaptureImage` rides the turn as a `PendingAttachment.image`. A
    /// ⌃⌘W screenshot sharing that ride would be uploaded to a gateway by an Ask
    /// made minutes later, and a picture of somebody's screen carries far more
    /// than the sentence they typed.
    ///
    /// Asserted AT the assembly, never after the turn. Every exit nils both
    /// image slots, so a check on the far side reads identically for an image
    /// that was copied onto the wire and one that was never touched — which is
    /// exactly the hole this test used to have. The turn runs against a real
    /// conversation whose VM is already busy, so it assembles its attachments
    /// and then stops one line later, short of the send tail the unsigned host
    /// cannot survive.
    func testAChatTurnCarriesTheChatScreenshotAndNeverTheWorkOne() async throws {
        let (coordinator, store) = makeCoordinator()
        let record = try await store.createConversation(backend: "openclaw")
        // Busy target: the turn reaches the assembly below and returns at the
        // in-flight claim, so `sendUserTurn` (and the SHARED store inside it) is
        // never touched. Same stop the busy-stash test above relies on.
        coordinator.viewModel(for: record.id).isAwaitingReply = true
        coordinator.selectQuickDestination(.explicitConversation(record.id))

        let chatScreenshot = Data([0x89, 0x50, 0x4E, 0x47])   // what ⌘⇧2 staged
        let workScreenshot = Data([0x57, 0x4F, 0x52, 0x4B])   // what ⌃⌘W parked
        coordinator.setPendingCaptureImage(chatScreenshot)
        coordinator.setPendingWorkCaptureImage(workScreenshot)

        var dispatched: [[PendingAttachment]] = []
        coordinator.onQuickTurnAttachments = { dispatched.append($0) }
        coordinator.quickDraft = "a question for the gateway"
        coordinator.sendQuickTypedDraft()

        await waitUntil("the turn to assemble its attachments") { !dispatched.isEmpty }
        let attachments = try XCTUnwrap(dispatched.first)
        XCTAssertEqual(
            attachments.count, 1,
            "The turn carries something other than the one ⌘⇧2 screenshot — a second attachment here "
            + "is the desk's picture riding along: \(attachments)"
        )
        guard case .image(let data) = try XCTUnwrap(attachments.first) else {
            return XCTFail("The ⌘⇧2 screenshot no longer rides as an inline image: \(attachments)")
        }
        XCTAssertEqual(data, chatScreenshot,
                       "The CHAT screenshot is what the turn was given.")
        XCTAssertNotEqual(
            data, workScreenshot,
            "The turn is uploading the desk's screenshot. Nothing captured by ⌃⌘W may ever reach a "
            + "gateway — that is the entire reason the Work lane holds its picture in its own slot."
        )
    }

    /// Control for the test above: with nothing staged for Chat, a turn made
    /// while a Work picture is parked carries NO attachment at all. Without
    /// this, an assembly that dropped every image would satisfy the assertion
    /// that the Work one is absent.
    func testAChatTurnWithOnlyAWorkPictureParkedCarriesNoAttachment() async throws {
        let (coordinator, store) = makeCoordinator()
        let record = try await store.createConversation(backend: "openclaw")
        coordinator.viewModel(for: record.id).isAwaitingReply = true
        coordinator.selectQuickDestination(.explicitConversation(record.id))
        coordinator.setPendingWorkCaptureImage(Data([0x57, 0x4F, 0x52, 0x4B]))

        var dispatched: [[PendingAttachment]] = []
        coordinator.onQuickTurnAttachments = { dispatched.append($0) }
        coordinator.quickDraft = "a question with no screenshot of its own"
        coordinator.sendQuickTypedDraft()

        await waitUntil("the turn to assemble its attachments") { !dispatched.isEmpty }
        XCTAssertEqual(
            dispatched.first?.count, 0,
            "A parked ⌃⌘W screenshot became this turn's attachment: \(String(describing: dispatched.first))"
        )
        XCTAssertNotNil(
            coordinator.pendingWorkCaptureImage,
            "…and the chat turn consumed it on the way out. It belongs to a composition the person "
            + "never sent and never discarded."
        )
    }

    /// A staged Work picture is enough to commit the Work surface on its own
    /// (a screenshot with no caption is a perfectly good note) and is not chat
    /// compose state at all — the two gates read two different slots.
    func testAWorkScreenshotIsWorkComposeStateAndNotChatComposeState() {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.openComposeForWorkOnly()
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))

        XCTAssertTrue(coordinator.hasWorkComposeState,
                      "Add to Work is disabled on a captioned-by-nothing screenshot, which is the "
                      + "commonest ⌃⌘W there is.")
        XCTAssertFalse(coordinator.hasComposeState,
                       "A desk screenshot counts as chat compose state, so it pins the chat lane's "
                       + "one-shot destination pick across dismissals.")
    }

    /// ⌘⇧1 off the Work surface is a NAVIGATION: the words park, and so does the
    /// picture. What it may never do is carry either into the Chat composition
    /// underneath, where one Return sends them to a gateway.
    func testLeavingTheWorkSurfaceParksItsPictureAndCarriesNothingToChat() {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.openComposeForWorkOnly()
        coordinator.quickWorkDraft = "for the desk"
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))

        coordinator.closeWorkOnlyCompose()

        XCTAssertEqual(coordinator.composeTarget, .chat)
        XCTAssertNil(coordinator.pendingCaptureImage,
                     "The Work screenshot followed the aim into the Chat composition, where the next "
                     + "Return uploads it.")
        XCTAssertNotNil(coordinator.pendingWorkCaptureImage,
                        "The parked composition lost its picture to a navigation — the exact failure "
                        + "the aim-travels-with-the-words design exists to prevent.")
        XCTAssertEqual(coordinator.quickWorkDraft, "for the desk")
    }

    /// The state a text-mode ⌘⇧2 leaves behind when a Work composition was
    /// standing: the two calls its handler now makes, in order.
    ///
    /// All four facts matter together. The aim is back on Chat, so Return sends
    /// rather than saves. The dragged region is in the Chat slot, which is the
    /// one the Chat surface's thumbnail reads. And the Work words and picture
    /// are untouched, waiting for the ⌃⌘W that re-enters them.
    func testATextModeAskOverAParkedWorkCompositionEndsAimedAtChat() {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.openComposeForWorkOnly()
        coordinator.quickWorkDraft = "a note for the desk"
        coordinator.setPendingWorkCaptureImage(Data([0x57, 0x4F, 0x52, 0x4B]))

        // What `handleRegionCapturePress`'s text arm does, in its order.
        coordinator.closeWorkOnlyCompose()
        coordinator.setPendingCaptureImage(Data([0x89, 0x50, 0x4E, 0x47]))

        XCTAssertEqual(coordinator.composeTarget, .chat,
                       "Return would still save this question to the desk instead of sending it.")
        XCTAssertEqual(coordinator.pendingCaptureImage, Data([0x89, 0x50, 0x4E, 0x47]),
                       "The dragged region has to land in the slot the Chat surface draws.")
        XCTAssertEqual(coordinator.pendingWorkCaptureImage, Data([0x57, 0x4F, 0x52, 0x4B]),
                       "The parked Work picture is re-entered by the next ⌃⌘W; an Ask may not take it.")
        XCTAssertEqual(coordinator.quickWorkDraft, "a note for the desk",
                       "…and neither may it take the words.")
    }

    /// The explicit bail throws the whole composition away, picture included: a
    /// screenshot that outlived the words it was dragged for would attach itself
    /// to the next ⌃⌘W.
    func testDiscardingTheWorkCompositionThrowsAwayItsPicture() {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.openComposeForWorkOnly()
        coordinator.quickWorkDraft = "abandoned"
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))

        coordinator.discardWorkOnlyCompose()

        XCTAssertNil(coordinator.pendingWorkCaptureImage)
        XCTAssertEqual(coordinator.quickWorkDraft, "")
    }

    /// Esc over the CHAT surface bails the chat composition. `cancelActiveCapture`
    /// tears both lanes down on that one press, so the Work slot has to be
    /// scoped to a capture that is actually running — otherwise a bail the person
    /// aimed at their own draft silently takes a picture they parked elsewhere.
    func testABailOverTheChatSurfaceLeavesAParkedWorkPictureAlone() {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))
        coordinator.quickWorkDraft = "parked for the desk"
        coordinator.quickDraft = "words to discard"

        coordinator.cancelActiveCapture()

        XCTAssertEqual(coordinator.quickDraft, "", "The chat draft is what the bail was aimed at.")
        XCTAssertNotNil(coordinator.pendingWorkCaptureImage)
        XCTAssertEqual(coordinator.quickWorkDraft, "parked for the desk",
                       "Control: the words survive, so the picture must too — one composition, one "
                       + "survival rule.")
    }

    /// …and the mirror: a capture that IS running loses its picture to the same
    /// call, because that picture is the running capture's own.
    func testCancellingARunningWorkCaptureDropsItsPicture() {
        let (coordinator, _) = makeCoordinator()
        coordinator.claimPopoverForWorkVoiceCapture()   // the ⌃⌘W press's claim
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))
        XCTAssertTrue(coordinator.workCaptureIsActive, "Control: the claim counts as a live capture.")

        coordinator.cancelWorkVoiceCapture()

        XCTAssertNil(coordinator.pendingWorkCaptureImage,
                     "The cancelled capture's screenshot survives it, and the next ⌃⌘W — including "
                     + "one that skipped its screenshot — would show it above the wrong words.")
    }

    /// In voice mode the Work slot is the HUD's thumbnail, so a picture stranded
    /// there by a text-mode composition would caption the next ⌃⌘W recording.
    /// Same rule the chat slot already follows across the same flip.
    func testFlipToVoiceClearsAStagedWorkScreenshot() async {
        let (coordinator, _) = makeTextModeCoordinator()
        coordinator.openComposeForWorkOnly()
        coordinator.setPendingWorkCaptureImage(Data([0x89, 0x50]))
        coordinator.quickWorkDraft = "typed before the flip"

        modeDefaults.set(MenuBarInputMode.voice.rawValue,
                         forKey: Constants.menuBarInputModeKey)
        NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)

        await waitUntil("mode mirror to refresh") { coordinator.menuBarInputMode == .voice }
        XCTAssertNil(coordinator.pendingWorkCaptureImage)
        XCTAssertEqual(coordinator.quickWorkDraft, "typed before the flip",
                       "The draft survives the flip exactly as the chat one does — it is inert in "
                       + "voice mode and comes back intact on flipping again.")
    }
}
#endif
