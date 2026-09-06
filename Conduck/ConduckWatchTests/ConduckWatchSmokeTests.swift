// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS unit-test target smoke test.
// Validates the ConduckWatchTests target compiles + runs on the watchOS
// Simulator. Real Watch-only contract tests live alongside this file.
import XCTest
import CoreData
@testable import ConduckWatch_Watch_App

final class ConduckWatchSmokeTests: XCTestCase {
    func testWatchTestTargetExecutes() {
        XCTAssertEqual(2 + 2, 4, "watchOS unit-test target is wired and executing on the watch simulator.")
    }

    func testWorkboardCaptureNormalizesAndBoundsItsTitle() throws {
        let firstLine = String(repeating: "a", count: 90)
        let capture = try WatchWorkboardCaptureText.prepare("  \(firstLine)\r\nMore detail  ")

        XCTAssertEqual(capture.title, String(repeating: "a", count: 72))
        XCTAssertEqual(capture.textContent, "\(firstLine)\nMore detail")
        XCTAssertThrowsError(try WatchWorkboardCaptureText.prepare(" \n "))
    }

    func testWorkboardCaptureRefusesAnOversizedThoughtInsteadOfTruncatingIt() throws {
        let bound = WatchWorkboardCaptureText.maximumNoteCharacters
        let atBound = try WatchWorkboardCaptureText.prepare(String(repeating: "a", count: bound))
        XCTAssertEqual(atBound.textContent.count, bound)

        XCTAssertThrowsError(
            try WatchWorkboardCaptureText.prepare(String(repeating: "a", count: bound + 1))
        ) { error in
            XCTAssertEqual(error as? WatchWorkboardCaptureError, .thoughtTooLong)
        }
    }

    func testWorkboardCapturePersistsOnlyAnInertNoteOnTheDesk() async throws {
        let store = ConversationStore(inMemory: true)
        let capture = WatchWorkboardCapture(
            title: "Prepare launch review",
            textContent: "Collect launch risks before deciding what to send."
        )

        let returnedTitle = try await store.upsertDeskMaterial(capture)
        let context = await store.newReadContext()
        let rows = try await context.perform { [context] in
            func count(_ entityName: String) throws -> Int {
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
            }
            let itemRequest = NSFetchRequest<NSDictionary>(entityName: "WorkItem")
            itemRequest.resultType = .dictionaryResultType
            itemRequest.propertiesToFetch = ["id", "title", "objective", "preferredGatewayRef"]
            let materialRequest = NSFetchRequest<NSDictionary>(entityName: "WorkMaterial")
            materialRequest.resultType = .dictionaryResultType
            materialRequest.propertiesToFetch = [
                "workItemID", "kind", "title", "textContent", "storageMode", "sequence", "sourceDevice",
            ]
            return (
                items: try context.fetch(itemRequest),
                materials: try context.fetch(materialRequest),
                dispatches: try count("WorkDispatch"),
                conversations: try count("Conversation"),
                messages: try count("Message")
            )
        }

        XCTAssertEqual(returnedTitle, capture.title)
        XCTAssertEqual(rows.items.count, 1)
        XCTAssertEqual(rows.items.first?["id"] as? UUID, Constants.workboardDeskItemID)
        // The desk owns no editable brief: nothing displays a title or an
        // objective on it, so the wrist must never write one.
        XCTAssertNil(rows.items.first?["title"] as? String)
        XCTAssertNil(rows.items.first?["objective"] as? String)
        XCTAssertNil(rows.items.first?["preferredGatewayRef"] as? String)
        XCTAssertEqual(rows.materials.count, 1)
        XCTAssertEqual(rows.materials.first?["workItemID"] as? UUID, Constants.workboardDeskItemID)
        XCTAssertEqual(rows.materials.first?["kind"] as? String, "note")
        XCTAssertEqual(rows.materials.first?["title"] as? String, capture.title)
        XCTAssertEqual(rows.materials.first?["textContent"] as? String, capture.textContent)
        XCTAssertEqual(rows.materials.first?["storageMode"] as? String, "metadataOnly")
        XCTAssertEqual((rows.materials.first?["sequence"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(rows.materials.first?["sourceDevice"] as? String, "watch")
        XCTAssertEqual(rows.dispatches, 0)
        XCTAssertEqual(rows.conversations, 0)
        XCTAssertEqual(rows.messages, 0)
    }

    /// The desk is created once and appended to thereafter. A second wrist
    /// capture that minted a second desk row would split the board in two on
    /// every other device.
    func testSecondWatchCaptureAppendsToTheSameDeskInsteadOfCreatingASecondOne() async throws {
        let store = ConversationStore(inMemory: true)
        let first = WatchWorkboardCapture(title: "First", textContent: "First thought.")
        let second = WatchWorkboardCapture(title: "Second", textContent: "Second thought.")

        _ = try await store.upsertDeskMaterial(first)
        _ = try await store.upsertDeskMaterial(second)

        let context = await store.newReadContext()
        let board = try await context.perform { [context] in
            let itemRequest = NSFetchRequest<NSDictionary>(entityName: "WorkItem")
            itemRequest.resultType = .dictionaryResultType
            itemRequest.propertiesToFetch = ["id"]
            let materialRequest = NSFetchRequest<NSDictionary>(entityName: "WorkMaterial")
            materialRequest.resultType = .dictionaryResultType
            materialRequest.propertiesToFetch = ["workItemID", "title", "sequence"]
            materialRequest.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
            return (
                items: try context.fetch(itemRequest),
                materials: try context.fetch(materialRequest)
            )
        }

        XCTAssertEqual(board.items.count, 1)
        XCTAssertEqual(board.items.first?["id"] as? UUID, Constants.workboardDeskItemID)
        XCTAssertEqual(board.materials.count, 2)
        XCTAssertEqual(board.materials.map { $0["title"] as? String }, [first.title, second.title])
        XCTAssertEqual(
            board.materials.map { ($0["sequence"] as? NSNumber)?.intValue },
            [0, 1]
        )
        XCTAssertEqual(
            Set(board.materials.compactMap { $0["workItemID"] as? UUID }),
            [Constants.workboardDeskItemID]
        )
    }

    /// Replaying one capture — a retried intent, a re-delivered Shortcut run —
    /// returns the card that is already there rather than adding a second one.
    func testReplayingOneWatchCaptureReturnsTheSameCardWithoutASecondRow() async throws {
        let store = ConversationStore(inMemory: true)
        let capture = WatchWorkboardCapture(title: "Once", textContent: "Only once.")
        let id = UUID()

        let firstTitle = try await store.upsertDeskMaterial(capture, id: id)
        let replayedTitle = try await store.upsertDeskMaterial(
            WatchWorkboardCapture(title: "Rewritten", textContent: "Rewritten."),
            id: id
        )

        let context = await store.newReadContext()
        let counts = try await context.perform { [context] in
            func count(_ entityName: String) throws -> Int {
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
            }
            return (items: try count("WorkItem"), materials: try count("WorkMaterial"))
        }

        XCTAssertEqual(firstTitle, capture.title)
        XCTAssertEqual(replayedTitle, capture.title)
        XCTAssertEqual(counts.items, 1)
        XCTAssertEqual(counts.materials, 1)
    }

    // MARK: - Work relay note identity

    /// The words-only fallback writes ONE card no matter how many times the
    /// queue re-fires the same capture, and that rests entirely on the id being
    /// derived from the claim token rather than minted per attempt.
    /// `upsertDeskMaterial` is idempotent on `id`; the intent's default (a fresh
    /// UUID) is right for a Shortcut run and would turn one retried wrist
    /// capture into a pile of identical notes.
    func testTheWorkRelayNoteIDIsDerivedFromTheClaimTokenAndIsStable() {
        let token = "6F1F2E3D-4C5B-6A79-8899-AABBCCDDEEFF"
        let first = WatchWorkRelayNoteIdentity.materialID(forRequestID: token)
        let second = WatchWorkRelayNoteIdentity.materialID(forRequestID: token)

        XCTAssertEqual(
            first, second,
            "The same claim token derived two different card ids. Every re-fire of a queue entry reuses its persisted requestID, so a non-deterministic derivation leaves one card per attempt on the desk."
        )
        XCTAssertNotEqual(
            first,
            WatchWorkRelayNoteIdentity.materialID(forRequestID: UUID().uuidString),
            "Two different captures derived the same card id — one would overwrite the other's words."
        )

        // Version 5 / RFC 4122 variant, so the value is a legitimate name-based
        // UUID rather than a hash with the header bits left as they fell.
        let bytes = withUnsafeBytes(of: first.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x50)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }

    /// The derivation IS RFC 4122 §4.3, checked against the specification's own
    /// worked example. A hand-rolled hash that merely looked stable would pass
    /// the test above while being something nobody else can reproduce.
    func testTheDerivationMatchesTheRFCsWorkedExample() throws {
        let dns = try XCTUnwrap(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        XCTAssertEqual(
            WatchWorkRelayNoteIdentity.uuidV5(namespace: dns, name: "www.example.com")
                .uuidString.lowercased(),
            "2ed6657d-e927-568b-95e1-2665a8aea6a2"
        )
    }

    /// The payload exclusion, observed where it actually applies.
    ///
    /// `ConversationStore.storeDescriptions` returns the Core description ALONE
    /// under `os(watchOS)`, and that omission IS how material bytes stay off the
    /// wrist: no `Blobs` store means no `WorkMaterialBlob` row is mountable, so
    /// CloudKit never has a reason to pull payloads onto a device with a watch's
    /// storage. Nothing else can see it — an iOS-hosted test can only hand-build
    /// a one-description container, which would stay green if the real watchOS
    /// branch regressed to two stores. This runs the production code path in the
    /// production build, so the regression is caught where it would happen.
    func testTheWatchBuildMountsTheCoreStoreAloneAndNoPayloadStore() async throws {
        let store = ConversationStore(inMemory: true)

        let mounted = try await store._mountedStoresForTesting()

        XCTAssertEqual(
            mounted.map(\.configuration), ["Core"],
            """
            The wrist mounted \(mounted.map(\.configuration)) rather than Core alone. A Blobs \
            store on watchOS puts every synced material payload on the watch.
            """
        )
    }
}

/// Watch-scoped official-identity drift guard — the wrist-side counterpart of
/// ConduckTests/OfficialIdentityLockTests, pinning the persistent identifiers
/// no iOS-hosted test can reach. Skips under a non-official (community) build
/// identity, same as the iOS lock suite.
final class OfficialIdentityWatchLockTests: XCTestCase {
    private static let officialNamespace = "ai.gigaduck.agentrelay"

    private func skipUnlessOfficial() throws {
        try XCTSkipUnless(Constants.identityNamespace == Self.officialNamespace,
                          "Official-identity lock — not applicable under a non-official (community) build identity")
    }

    /// Background-URLSession identifiers must never change across app updates —
    /// in-flight wrist uploads from the previous version would orphan.
    func testWatchSTTSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(WatchAudioUploader.sessionIdentifier, "ai.gigaduck.agentrelay.watch.stt")
    }

    /// The control-widget kind lives in the WIDGET appex (not a valid test
    /// host), so read the built artifact embedded in this test's host app.
    /// The CamelCase bundle-id base is load-bearing: a lowercase namespace
    /// derivation would silently orphan every user-placed control.
    func testWidgetControlKindIsFrozenInEmbeddedAppex() throws {
        try skipUnlessOfficial()
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL,
                                    "Test host has no PlugIns directory — expected the watch app with its embedded widget appex")
        let appex = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ConduckWatchExtension.appex")),
                                  "Widget appex missing from the watch app test host")
        XCTAssertEqual(appex.object(forInfoDictionaryKey: "ConduckControlKind") as? String,
                       "ai.gigaduck.AgentRelay.watch.RecordNoteControl")
    }
}

// MARK: - Work capture UI
//
// The wrist's Add to Work lane: the route it pushes and the sentence each
// terminal outcome renders. Both are pure values, so they are testable without
// a recorder, a relay or a watch face — and both are exactly where a silent
// mis-wire would be invisible on screen.

/// `@MainActor` because `WatchRoute` lives in a SwiftUI file and therefore
/// carries main-actor-isolated `Equatable`/`Hashable` conformances — comparing
/// two routes from a nonisolated test is an error under the Swift 6 language
/// mode. The copy helpers are `nonisolated` and callable from here either way.
@MainActor
final class WatchWorkCaptureUITests: XCTestCase {
    /// The Work route must be its OWN case, not a chat capture wearing a
    /// different label. If a Work push could ever compare or hash equal to a
    /// capture push, `navigationDestination` would build the chat thread for it
    /// — and a private thought would arrive at a gateway with the microphone
    /// already live.
    func testTheWorkCaptureRouteIsDistinctFromEveryChatCaptureRoute() {
        let nonce = UUID()
        let work = WatchRoute.workCapture(nonce: nonce)
        let newChat = WatchRoute.capture(.new(backendRef: "hermes"), nonce: nonce)
        let existingChat = WatchRoute.capture(.existing(nonce), nonce: nonce)

        XCTAssertNotEqual(work, newChat)
        XCTAssertNotEqual(work, existingChat)
        XCTAssertNotEqual(work, WatchRoute.thread(nonce))
        XCTAssertNotEqual(work, WatchRoute.conversations)
        XCTAssertEqual(Set([work, newChat, existingChat]).count, 3)
    }

    /// A second tap must remount rather than re-present: two Work pushes carry
    /// different nonces and are therefore different route values.
    func testTwoWorkCapturePushesAreDistinctRouteValues() {
        XCTAssertNotEqual(WatchRoute.workCapture(nonce: UUID()),
                          WatchRoute.workCapture(nonce: UUID()))
        let shared = UUID()
        XCTAssertEqual(WatchRoute.workCapture(nonce: shared),
                       WatchRoute.workCapture(nonce: shared))
    }

    /// Breadcrumbs carry the case kind only, and the Work lane has its own — a
    /// nav log that called it "capture" would make the one push we most need to
    /// tell apart indistinguishable from a chat turn.
    func testTheWorkCaptureRouteHasItsOwnLogLabel() {
        XCTAssertEqual(WatchRoute.workCapture(nonce: UUID()).logLabel, "workCapture")
        XCTAssertNotEqual(WatchRoute.workCapture(nonce: UUID()).logLabel,
                          WatchRoute.capture(.new(backendRef: "hermes"), nonce: UUID()).logLabel)
    }

    /// The mapping that matters: each outcome renders ITS OWN sentence. Two of
    /// these mean genuinely different things to the person reading them — "it
    /// is on the desk" versus "it is still on your wrist" — and a cross-wire
    /// tells someone their thought is safe when it has not left the watch.
    func testEveryTerminalOutcomeRendersItsOwnSentence() {
        XCTAssertEqual(WatchWorkCaptureCopy.terminalLine(for: .saved), "Saved to Work.")
        XCTAssertEqual(
            WatchWorkCaptureCopy.terminalLine(for: .deferredToPhone),
            "Saved on your watch. It reaches Work when your iPhone is nearby."
        )
        XCTAssertEqual(
            WatchWorkCaptureCopy.terminalLine(for: .savedWordsOnly),
            "Saved the words to Work. Update Conduck on your iPhone to keep recordings."
        )

        let lines = [
            WatchWorkCaptureCopy.terminalLine(for: .saved),
            WatchWorkCaptureCopy.terminalLine(for: .deferredToPhone),
            WatchWorkCaptureCopy.terminalLine(for: .savedWordsOnly)
        ]
        XCTAssertEqual(Set(lines).count, 3, "Two outcomes render the same sentence: \(lines)")
    }

    /// A refusal's sentence is already resolved by whoever refused (queue full,
    /// master switch off), so it passes through verbatim. Flattening it into a
    /// generic apology would delete the only part that says what to do next.
    func testARefusalRendersItsOwnReasonVerbatim() {
        let reason = "Work is waiting for your iPhone. Bring it nearby first."
        XCTAssertEqual(WatchWorkCaptureCopy.terminalLine(for: .refused(reason: reason)), reason)
    }

    /// Nothing on this surface may describe a thing the Work lane cannot do.
    /// The desk never reaches a gateway, so a line promising delivery to one is
    /// wrong twice: it is false, and it is false in the reassuring direction.
    func testNoTerminalLineSpeaksOfSendingAnythingAnywhere() {
        let banned = ["send", "sent", "sending", "dispatch", "draft", "brief", "reply", "agent"]
        for outcome in Self.durableOutcomes {
            let line = WatchWorkCaptureCopy.terminalLine(for: outcome).lowercased()
            for word in banned {
                XCTAssertFalse(
                    line.split(whereSeparator: { !$0.isLetter }).contains(Substring(word)),
                    "\(WatchWorkCaptureCopy.logLabel(for: outcome)) says “\(word)”: \(line)"
                )
            }
        }
    }

    /// Only a refusal captured nothing. The other three are durable somewhere —
    /// on the desk, or on the wrist waiting for the iPhone — so they earn the
    /// success haptic and the reassuring tint; a refusal must not.
    func testOnlyARefusalReadsAsAFailure() {
        for outcome in Self.durableOutcomes {
            XCTAssertTrue(WatchWorkCaptureCopy.isReassuring(outcome),
                          "\(WatchWorkCaptureCopy.logLabel(for: outcome)) should read as safe")
        }
        XCTAssertFalse(WatchWorkCaptureCopy.isReassuring(.refused(reason: "nope")))
    }

    /// Diagnostics carry the case kind only. A refusal sentence can name a
    /// gateway or a queue state, so it must never reach the log line.
    func testTheOutcomeLogLabelCarriesTheKindAndNeverTheReason() {
        XCTAssertEqual(WatchWorkCaptureCopy.logLabel(for: .saved), "saved")
        XCTAssertEqual(WatchWorkCaptureCopy.logLabel(for: .deferredToPhone), "deferred")
        XCTAssertEqual(WatchWorkCaptureCopy.logLabel(for: .savedWordsOnly), "wordsOnly")
        XCTAssertEqual(WatchWorkCaptureCopy.logLabel(for: .refused(reason: "hermes is unreachable")),
                       "refused")
    }

    /// The two "it is on the desk" outcomes share the desk glyph the launchpad
    /// button carries, so the end of the flow answers the button that began it;
    /// a refusal must not wear it.
    func testTheOutcomeGlyphsSeparateTheDeskFromTheWristAndTheRefusal() {
        XCTAssertEqual(WatchWorkCaptureCopy.symbolName(for: .saved), "tray.and.arrow.down.fill")
        XCTAssertEqual(WatchWorkCaptureCopy.symbolName(for: .savedWordsOnly), "tray.and.arrow.down.fill")
        XCTAssertNotEqual(WatchWorkCaptureCopy.symbolName(for: .deferredToPhone),
                          "tray.and.arrow.down.fill")
        XCTAssertNotEqual(WatchWorkCaptureCopy.symbolName(for: .refused(reason: "x")),
                          "tray.and.arrow.down.fill")
    }

    /// The destination raw values are persisted on the relay queue entry and
    /// stamped on the wire, so a rename would strand every queued capture and
    /// silently reclassify the ones in flight.
    func testTheCaptureDestinationRawValuesAreFrozen() {
        XCTAssertEqual(WatchCaptureDestination.chat.rawValue, "chat")
        XCTAssertEqual(WatchCaptureDestination.work.rawValue, "work")
        XCTAssertEqual(WatchCaptureDestination(rawValue: "work"), .work)
        XCTAssertNil(WatchCaptureDestination(rawValue: "Work"))
    }

    /// Done closes what the person just read, and a recorder error is not this
    /// screen's line to close: it is the SERVICE's state, so clearing only the
    /// outcome pops back to a launchpad that re-presents the identical failure.
    /// A failure with the words still on the wrist is neither of those: the
    /// recovery is offered HERE, because dismissing would delete the recording
    /// behind it and the launchpad's second showing is one failure read twice.
    func testTheEndOfCaptureButtonMatchesWhatIsActuallyLeftToDo() {
        XCTAssertEqual(
            WatchWorkCaptureView.messageAction(showingRecorderError: true, canRetry: false),
            .dismissErrorThenDone,
            "A dead-end failure must not be shown twice for one capture."
        )
        XCTAssertEqual(
            WatchWorkCaptureView.messageAction(showingRecorderError: true, canRetry: true),
            .retry,
            "Preserved audio is a real second chance, and it belongs on the failure the person is reading."
        )
        XCTAssertEqual(
            WatchWorkCaptureView.messageAction(showingRecorderError: false, canRetry: false),
            .done,
            "A terminal OUTCOME is this screen's own line; there is no error state under it to clear."
        )
        XCTAssertEqual(
            WatchWorkCaptureView.messageAction(showingRecorderError: false, canRetry: true),
            .done
        )
        // The label rides the action, or a button says Try Again and deletes the
        // recording it offered to re-send.
        XCTAssertEqual(
            WatchWorkCaptureView.buttonLabel(showingRecorderError: true, canRetry: true),
            "Try Again"
        )
        XCTAssertEqual(
            WatchWorkCaptureView.buttonLabel(showingRecorderError: true, canRetry: false),
            "Done"
        )
        XCTAssertEqual(
            WatchWorkCaptureView.buttonLabel(showingRecorderError: false, canRetry: true),
            "Done",
            "A terminal outcome is not a failure, and preserved audio is not an offer to make over it."
        )
    }

    /// NEGATIVE CONTROL for the truth table above, which only says what the
    /// button MEANS. This drives the production effect against a real service,
    /// so deleting the `dismissError()` call — the whole of the fix — fails
    /// here rather than passing on a helper nobody consults.
    @MainActor
    func testTheDeadEndFailureIsActuallyEndedAndTheRetryableOneIsKept() {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)

        // Dead end: no audio behind the error, so Done must land the machine on
        // `.idle`. Left standing, the launchpad re-presents this same sentence.
        service.state = .error(message: "nothing left to retry")
        XCTAssertFalse(service.canRetry, "Control: there is genuinely nothing to retry.")
        let leavesDeadEnd = WatchWorkCaptureView.perform(.dismissErrorThenDone, on: service)
        XCTAssertTrue(leavesDeadEnd, "A read dead end closes the screen.")
        XCTAssertEqual(service.state, .idle,
                       "Done left `.error` standing — the launchpad shows the identical failure on the pop.")
        XCTAssertNil(service.workCaptureOutcome)

        // Retryable: the screen STAYS, so the recording is never dismissed out
        // from under the offer. `retry()` with no file would reset to idle, so
        // the assertion is the dismissal verdict, which is what strands a
        // capture when it is wrong.
        service.state = .error(message: "prepare failed")
        XCTAssertFalse(WatchWorkCaptureView.perform(.retry, on: service),
                       "Try Again must not pop the screen — the retry it started renders here.")
    }

    /// The fourth line, and the one that is easiest to get wrong by reusing
    /// another: the iPhone kept the RECORDING and had no words for it — the
    /// exact mirror of `savedWordsOnly`. Saying "Saved to Work." here hides the
    /// one thing the person has to do next; saying the words-only sentence
    /// tells them their recording was thrown away, which is the opposite of
    /// what happened. The wording is CarPlay's own for the same state, because
    /// one product should not describe one outcome two ways.
    func testTheWordlessSaveNamesTheHalfThatIsMissing() {
        XCTAssertEqual(
            WatchWorkCaptureCopy.terminalLine(for: .savedWithoutWords),
            "Saved to Work. Add the words on your iPhone."
        )
        let lines = Self.durableOutcomes.map(WatchWorkCaptureCopy.terminalLine(for:))
        XCTAssertEqual(
            Set(lines).count, Self.durableOutcomes.count,
            "Two durable outcomes render the same sentence: \(lines)"
        )
        XCTAssertEqual(WatchWorkCaptureCopy.logLabel(for: .savedWithoutWords), "withoutWords")
        XCTAssertEqual(
            WatchWorkCaptureCopy.symbolName(for: .savedWithoutWords),
            "tray.and.arrow.down.fill",
            "The card IS on the desk, so it wears the desk's glyph."
        )
    }

    /// Settlement → line, in ONE place, because the live relay leg and the
    /// deferred queue both read it and a screen contradicting the banner beside
    /// it is the failure this mapping exists to prevent.
    func testEverySettlementNamesItsOwnLine() {
        XCTAssertEqual(WatchWorkCaptureOutcome.forSettlement(.workAcknowledged), .saved)
        XCTAssertEqual(
            WatchWorkCaptureOutcome.forSettlement(.workRecordingOnly), .savedWithoutWords,
            "A stamped reply with no words reported a clean save, over a card with nothing on it."
        )
        XCTAssertEqual(WatchWorkCaptureOutcome.forSettlement(.workWordsOnly), .savedWordsOnly)
        XCTAssertNil(
            WatchWorkCaptureOutcome.forSettlement(.converseHop),
            "A chat ask has no Work line; writing one would leave the next Work capture opening on it."
        )
    }

    private static let durableOutcomes: [WatchWorkCaptureOutcome] = [
        .saved, .deferredToPhone, .savedWordsOnly, .savedWithoutWords
    ]
}

// MARK: - Ask destination rows
//
// The Ask chooser's truth table, as a pure value. The wiring above it — Ask
// opens the chooser on every press — is two lines of view code and is pinned by
// founder QA; the row set is what can drift silently, and the row that must
// never go missing is Work: with no gateway configured at all it is the only
// destination that works, and with a full roster it is still the last one
// rather than a private-looking row somewhere in the middle of the AI ones.

final class WatchAskDestinationRowsTests: XCTestCase {

    /// Every roster shape the wrist can be in, including the empty one.
    func testWorkIsAlwaysOfferedAndAlwaysLast() {
        let rosters: [[String]] = [
            [],
            ["hermes"],
            ["hermes", "openclaw"],
            ["hermes", RemoteAgentRef.custom(UUID()).rawString]
        ]
        for roster in rosters {
            let rows = WatchAskDestinationRows.rows(configured: roster)
            XCTAssertEqual(rows.last, WatchAskDestinationRows.Row.work,
                           "Add to Work must be the LAST row for roster \(roster).")
            XCTAssertEqual(rows.filter { $0 == .work }.count, 1,
                           "Add to Work must appear exactly once for roster \(roster).")
            XCTAssertEqual(rows.count, roster.count + 1,
                           "Every configured gateway keeps a row of its own for roster \(roster).")
        }
    }

    /// Roster order is the iPhone's order, neither sorted nor reordered here:
    /// a gateway that silently changes position between presses is a chooser
    /// that trains the wrong muscle memory.
    func testGatewaysKeepRosterOrderAheadOfWork() {
        XCTAssertEqual(
            WatchAskDestinationRows.rows(configured: ["b", "a"]),
            [.gateway("b"), .gateway("a"), .work]
        )
    }

    /// The line belongs above a chooser with nothing but Work in it. Shown
    /// beside a working gateway row it would be false, and false in the one
    /// direction that matters — it would read as "your AI is gone".
    func testTheNoAILineShowsOnlyForAnEmptyRoster() {
        XCTAssertTrue(WatchAskDestinationRows.showsNoAILine(configured: []))
        XCTAssertFalse(WatchAskDestinationRows.showsNoAILine(configured: ["hermes"]))
        XCTAssertFalse(WatchAskDestinationRows.showsNoAILine(configured: ["hermes", "openclaw"]))
    }
}

// MARK: - Ask destination labels
//
// The chooser is a decision, and a label that cannot be told from the one
// above it is not one. The shared shortener is a head cut at 16 characters —
// right for the error banner and the sentence read aloud in the car, wrong on
// its own for a wrist surface where two gateways are compared side by side —
// so the wrist disambiguates locally and hands VoiceOver the untruncated name.

@MainActor
final class WatchGatewayLabelTests: XCTestCase {

    private func gateway(_ name: String) -> CustomGateway {
        CustomGateway(id: UUID(), name: name)
    }

    /// The failure this exists for: two customs the user named after the same
    /// machine. Under the shared shortener alone both rows read "Frankfurt
    /// produ…" and the chooser is a coin flip.
    func testCollidingCustomNamesGetLabelsThatCanBeToldApart() {
        let alpha = gateway("Frankfurt production alpha")
        let beta = gateway("Frankfurt production beta")
        let customs = [alpha, beta]

        let sharedShortForm = RemoteAgentRefMetadata.shortDisplayName(for: alpha.ref, customs: customs)
        XCTAssertEqual(
            sharedShortForm,
            RemoteAgentRefMetadata.shortDisplayName(for: beta.ref, customs: customs),
            "Control: the shared shortener genuinely collapses these two names — without that, this case proves nothing."
        )

        let alphaLabel = WatchGatewayLabel.visible(for: alpha.ref, customs: customs)
        let betaLabel = WatchGatewayLabel.visible(for: beta.ref, customs: customs)

        XCTAssertNotEqual(alphaLabel, betaLabel,
                          "Two rows that read identically are one row as far as the person tapping is concerned.")
        XCTAssertTrue(alphaLabel.hasSuffix("alpha"), "The label must show the part that differs, not the part they share.")
        XCTAssertTrue(betaLabel.hasSuffix("beta"))
    }

    /// Three names, two of which agree for longer than the group does: each
    /// still opens at a character that tells it from every name it collides
    /// with.
    func testEveryRowOfALongerCollidingGroupIsDistinct() {
        let customs = [
            gateway("Frankfurt production alpha one"),
            gateway("Frankfurt production alpha two"),
            gateway("Frankfurt production beta")
        ]
        let labels = customs.map { WatchGatewayLabel.visible(for: $0.ref, customs: customs) }

        XCTAssertEqual(Set(labels).count, customs.count,
                       "Every colliding row needs its own label, not just the first two: \(labels)")
        for label in labels {
            XCTAssertLessThanOrEqual(label.count, RemoteAgentRefMetadata.shortDisplayNameLimit + 1,
                                     "A disambiguated label stays inside the shared budget plus its leading ellipsis: \(label)")
        }
    }

    /// The case a per-name answer gets wrong. Two of these three agree far past
    /// the point the group does, so a label anchored on the name it agrees with
    /// LONGEST throws away the half that carries the difference — and lands on
    /// the third name's label. The group has to be resolved as a set.
    func testTwoNamesThatDivergeLateStillDoNotBorrowAThirdNamesLabel() {
        let customs = [
            gateway("Frankfurt production alpha one"),
            gateway("Frankfurt production alpha two"),
            gateway("Frankfurt production one")
        ]

        let sharedShortForm = RemoteAgentRefMetadata.shortDisplayName(for: customs[0].ref, customs: customs)
        for custom in customs {
            XCTAssertEqual(
                RemoteAgentRefMetadata.shortDisplayName(for: custom.ref, customs: customs),
                sharedShortForm,
                "Control: all three genuinely collapse to one string under the shared shortener."
            )
        }

        let labels = customs.map { WatchGatewayLabel.visible(for: $0.ref, customs: customs) }

        XCTAssertEqual(Set(labels).count, customs.count,
                       "Two gateways reading the same label are one row to the person tapping: \(labels)")
        for label in labels.prefix(2) {
            XCTAssertTrue(
                label.contains("alpha"),
                """
                A label anchored on the name it agrees with LONGEST throws away "alpha", which is \
                the half that tells these two from the third name. Unique is not enough — the \
                label has to carry the difference: \(labels)
                """
            )
        }
        for label in labels {
            XCTAssertLessThanOrEqual(label.count, RemoteAgentRefMetadata.shortDisplayNameLimit + 1,
                                     "A disambiguated label stays inside the shared budget plus its leading ellipsis: \(label)")
        }
    }

    /// The collision a group-only answer cannot see: a gateway whose name is
    /// SHORT enough to be left alone, and which already reads exactly like the
    /// label the colliding pair beside it resolves to. Its short form is not a
    /// truncation, so it never enters that pair's group — and the roster ends up
    /// with two rows saying "…alpha" anyway. Uniqueness has to be checked over
    /// the whole roster, untouched labels included.
    func testAShortNameThatAlreadyReadsLikeADisambiguatedLabelStillGetsItsOwnRow() {
        let customs = [
            gateway("Frankfurt production alpha"),
            gateway("Frankfurt production beta"),
            gateway("…alpha")
        ]

        let sharedShortForm = RemoteAgentRefMetadata.shortDisplayName(for: customs[0].ref, customs: customs)
        XCTAssertEqual(
            RemoteAgentRefMetadata.shortDisplayName(for: customs[1].ref, customs: customs),
            sharedShortForm,
            "Control: the first two genuinely collapse to one string under the shared shortener."
        )
        XCTAssertEqual(
            RemoteAgentRefMetadata.shortDisplayName(for: customs[2].ref, customs: customs),
            customs[2].name,
            "Control: the third name is short enough that the shortener leaves it exactly as typed — which is "
            + "why a group-only pass never looks at it."
        )

        let labels = customs.map { WatchGatewayLabel.visible(for: $0.ref, customs: customs) }

        XCTAssertEqual(Set(labels).count, customs.count,
                       "Three gateways, three rows the person can tell apart: \(labels)")
        for label in labels {
            XCTAssertLessThanOrEqual(label.count, RemoteAgentRefMetadata.shortDisplayNameLimit + 1,
                                     "A disambiguated label stays inside the shared budget plus its leading ellipsis: \(label)")
        }
    }

    /// The residual case the ordinal exists for: nothing in the names can tell
    /// them apart, so the label says WHICH of them this row is rather than
    /// pretending they differ.
    func testIdenticallyNamedGatewaysStillGetOneLabelEach() {
        let customs = [
            gateway("Frankfurt production alpha"),
            gateway("Frankfurt production alpha")
        ]

        let labels = customs.map { WatchGatewayLabel.visible(for: $0.ref, customs: customs) }

        XCTAssertEqual(Set(labels).count, customs.count, "Same name, still two rows: \(labels)")
        for label in labels {
            XCTAssertLessThanOrEqual(label.count, RemoteAgentRefMetadata.shortDisplayNameLimit + 1, label)
        }
    }

    /// The shared policy is untouched for everyone else — this is a local
    /// answer to a local problem, not a new app-wide naming rule.
    func testANameThatCollidesWithNothingKeepsTheSharedShortForm() {
        let customs = [gateway("Frankfurt production alpha"), gateway("Reykjavik box")]
        for custom in customs {
            XCTAssertEqual(
                WatchGatewayLabel.visible(for: custom.ref, customs: customs),
                RemoteAgentRefMetadata.shortDisplayName(for: custom.ref, customs: customs),
                "\(custom.name) shares its short form with nothing, so it must read exactly as it does everywhere else."
            )
        }
        for backend in RemoteAgentBackend.allCases {
            XCTAssertEqual(
                WatchGatewayLabel.visible(for: .builtin(backend), customs: customs),
                RemoteAgentRefMetadata.shortDisplayName(for: .builtin(backend), customs: customs),
                "A built-in's name is compiled in and short; nothing here may reshape it."
            )
        }
    }

    /// A custom with no usable name resolves to its monogram / the generic
    /// label, which is not a truncation of anything — reshaping THAT would
    /// invent a name for a gateway that has none.
    func testAnUnnamedCustomIsLeftOnItsFallbackLabel() {
        let unnamed = CustomGateway(id: UUID(), name: "   ", monogram: "FR")
        let customs = [unnamed, gateway("Frankfurt production alpha")]

        XCTAssertEqual(WatchGatewayLabel.visible(for: unnamed.ref, customs: customs),
                       RemoteAgentRefMetadata.shortDisplayName(for: unnamed.ref, customs: customs))
    }

    /// VoiceOver gets the name whole. A watch face runs out of width; the ear
    /// does not.
    func testTheSpokenLabelIsNeverCut() {
        let long = gateway("Frankfurt production alpha")
        let customs = [long, gateway("Frankfurt production beta")]

        XCTAssertEqual(WatchGatewayLabel.spoken(for: long.ref, customs: customs), long.name)
        XCTAssertGreaterThan(long.name.count, RemoteAgentRefMetadata.shortDisplayNameLimit,
                             "Control: the name must be long enough that the visible label really is cut.")
        XCTAssertNotEqual(WatchGatewayLabel.spoken(for: long.ref, customs: customs),
                          WatchGatewayLabel.visible(for: long.ref, customs: customs))
    }
}
