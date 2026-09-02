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
