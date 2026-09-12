// SPDX-License-Identifier: Apache-2.0

// Recovery requires local evidence of an accepted user turn. Missing rows and
// failed reads must not be mistaken for permission to repeat a prior send.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskInterruptedHandoffLookupTests: XCTestCase {
    private enum Failure: Error { case unreadable }

    func testMissingConversationDoesNotInspectTurnsOrClaimAcceptance() async throws {
        var inspectedTurns = false
        let lookup = WorkDeskInterruptedHandoffLookup(conversationExists: { _ in false }, userTurnExists: { _ in
            inspectedTurns = true
            return true
        })
        let result = try await lookup.existingConversationID(UUID())
        XCTAssertNil(result)
        XCTAssertFalse(inspectedTurns)
    }

    func testEmptyConversationWithoutAUserTurnDoesNotClaimAcceptance() async throws {
        let lookup = WorkDeskInterruptedHandoffLookup(conversationExists: { _ in true }, userTurnExists: { _ in false })
        let result = try await lookup.existingConversationID(UUID())
        XCTAssertNil(result)
    }

    func testAcceptedTurnResolvesOnlyTheRecordedConversation() async throws {
        let id = UUID()
        var checked: [UUID] = []
        let lookup = WorkDeskInterruptedHandoffLookup(conversationExists: { value in
            checked.append(value)
            return true
        }, userTurnExists: { value in
            checked.append(value)
            return true
        })
        let result = try await lookup.existingConversationID(id)
        XCTAssertEqual(result, id)
        XCTAssertEqual(checked, [id, id])
    }

    func testUnreadableConversationOrTurnsRemainFailuresRatherThanAbsence() async {
        for failConversation in [true, false] {
            let lookup = WorkDeskInterruptedHandoffLookup(conversationExists: { _ in
                if failConversation { throw Failure.unreadable }
                return true
            }, userTurnExists: { _ in throw Failure.unreadable })
            do {
                _ = try await lookup.existingConversationID(UUID())
                XCTFail("A storage read failure must remain retryable.")
            } catch Failure.unreadable {
                // Expected: the UI keeps the saved attempt and offers retry.
            } catch {
                XCTFail("Unexpected lookup error type.")
            }
        }
    }
}
