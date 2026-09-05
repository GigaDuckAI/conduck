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
// The wrist's "Save to Work" lane: the route it pushes and the sentence each
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

    private static let durableOutcomes: [WatchWorkCaptureOutcome] = [
        .saved, .deferredToPhone, .savedWordsOnly
    ]
}
