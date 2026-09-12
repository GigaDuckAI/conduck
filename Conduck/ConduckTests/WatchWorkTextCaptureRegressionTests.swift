// SPDX-License-Identifier: Apache-2.0

// Independent receipt-to-desk regression. Queue deduplication alone does not
// prove capture identity survives a completed drain followed by a replay: the
// first envelope has already been deleted when the second arrives.

#if os(iOS)
import XCTest
@testable import Conduck

@MainActor
final class WatchWorkTextCaptureRegressionTests: XCTestCase {
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testAcknowledgedTextKeepsItsMaterialIdentityAfterDrainAndReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = WorkCaptureInbox(baseURL: directory)
        let store = isolated.make()
        let drainer = WorkCaptureDrainer(inbox: inbox, store: store, sourceDevice: "phone")
        let capture = WatchWorkTextCapture(id: UUID(), text: "The same captured thought", createdAt: Date())

        for _ in 0..<2 {
            let receipt = await PhoneSessionManager.acceptWorkTextCapture(capture, inbox: inbox)
            XCTAssertEqual(WatchWorkTextCaptureWire.accepted(receipt, for: capture.id), true)
            _ = try await drainer.drainAvailableCaptures()
            let pending = try await inbox.pendingCount()
            XCTAssertEqual(pending, 0)
        }

        let items = try await store.fetchWorkItems()
        let notes = items.flatMap(\.materials)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.id, capture.id)
        XCTAssertEqual(notes.first?.textContent, capture.text)
    }
}
#endif
