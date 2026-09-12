// SPDX-License-Identifier: Apache-2.0

// Cross-container native drags carry the source appearance and its complete
// organization revision. These checks exercise delayed, duplicate, foreign,
// malformed and shared-material payloads independently of pointer hardware.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskMaterialTransferTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let projectA = UUID()
    private let projectB = UUID()

    func testTypedPayloadRoundTripsEverySourceTokenWithoutMaterialContent() throws {
        let payload = makePayload()
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(WorkMaterialDragPayload.self, from: data), payload)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["itemID", "materialID", "sourceLocation", "additionalMaterialIDs", "expectedLocationTokens"])
        let move = try XCTUnwrap(payload.validatedLocationMove(to: .home, current: tokens))
        XCTAssertEqual(move.materialIDs, [first, second])
        XCTAssertEqual(move.source, .project(projectA))
        XCTAssertEqual(move.destination, .home)
        XCTAssertEqual(move.expected, tokens)
    }

    func testLegacyPayloadRemainsDecodableButCannotInventHomeAsSource() throws {
        let legacy = ["itemID": Constants.workboardDeskItemID.uuidString, "materialID": first.uuidString]
        let payload = try JSONDecoder().decode(WorkMaterialDragPayload.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(payload.sourceLocation)
        XCTAssertEqual(payload.materialIDs, [first])
        XCTAssertNil(payload.validatedLocationMove(to: .project(projectB), current: tokens))
    }

    func testMissingForeignDuplicateAndIncompletePayloadsRefuseWholeMove() {
        let incomplete = [first: tokens[first]!]
        let cases: [WorkMaterialDragPayload] = [
            .init(itemID: UUID(), materialID: first, sourceLocation: .project(projectA),
                  additionalMaterialIDs: [second], expectedLocationTokens: tokens),
            .init(itemID: Constants.workboardDeskItemID, materialID: first, sourceLocation: .project(projectA)),
            .init(itemID: Constants.workboardDeskItemID, materialID: first, sourceLocation: .project(projectA),
                  additionalMaterialIDs: [first], expectedLocationTokens: incomplete),
            .init(itemID: Constants.workboardDeskItemID, materialID: first, sourceLocation: .project(projectA),
                  additionalMaterialIDs: [second], expectedLocationTokens: incomplete),
            .init(itemID: Constants.workboardDeskItemID, materialID: first, sourceLocation: .home,
                  additionalMaterialIDs: [second], expectedLocationTokens: tokens)
        ]
        for payload in cases {
            XCTAssertNil(payload.validatedLocationMove(to: .project(projectB), current: tokens))
        }
    }

    func testChangedSharedMembershipOrPositionRefusesAtomicGroupMove() {
        var sharedChanged = tokens
        sharedChanged[first]?.append(.init(materialID: first, location: .project(UUID()), position: nil))
        var positionChanged = tokens
        positionChanged[second]?[0].position = .init(x: 100, y: 200)
        var revisionChanged = tokens
        revisionChanged[second]?[0].revision = UUID()
        var deleted = tokens
        deleted.removeValue(forKey: second)
        for changed in [sharedChanged, positionChanged, revisionChanged, deleted] {
            XCTAssertNil(makePayload().validatedLocationMove(to: .home, current: changed))
        }
    }

    func testRecordOrderingDoesNotCreateAFalseStaleRefusal() {
        var reversed = tokens
        reversed[first]?.reverse()
        XCTAssertNotNil(makePayload().validatedLocationMove(to: .home, current: reversed))
    }

    func testProviderCompletionIsConsumedExactlyOnce() throws {
        let session = WorkDeskMaterialDropSession()
        let token = try XCTUnwrap(session.accept(at: .home))
        XCTAssertNil(session.accept(at: .home))
        XCTAssertNotNil(session.resolve(makePayload(), token: token, destination: .home,
                                       isEnabled: true, current: tokens))
        XCTAssertNil(session.resolve(makePayload(), token: token, destination: .home,
                                    isEnabled: true, current: tokens))
        XCTAssertFalse(session.isResolving)
    }

    func testCancelledOldCallbackCannotConsumeANewerDestination() throws {
        let session = WorkDeskMaterialDropSession()
        let old = try XCTUnwrap(session.accept(at: .home))
        session.cancel()
        let newer = try XCTUnwrap(session.accept(at: .project(projectB)))
        XCTAssertNil(session.resolve(makePayload(), token: old, destination: .home,
                                    isEnabled: true, current: tokens))
        XCTAssertTrue(session.isResolving)
        XCTAssertNotNil(session.resolve(makePayload(), token: newer, destination: .project(projectB),
                                       isEnabled: true, current: tokens))
    }

    func testHiddenChangedAndMalformedDestinationCompletionRefuses() throws {
        for scenario in 0..<3 {
            let session = WorkDeskMaterialDropSession()
            let token = try XCTUnwrap(session.accept(at: .home))
            XCTAssertNil(session.resolve(scenario == 0 ? nil : makePayload(), token: token,
                destination: scenario == 1 ? .project(projectB) : .home,
                isEnabled: scenario != 2, current: tokens))
            XCTAssertFalse(session.isResolving)
        }
    }

    private var tokens: WorkDeskLocationTokens {
        [first: [.init(materialID: first, location: .project(projectA), position: .init(x: 1, y: 2)),
                 .init(materialID: first, location: .project(projectB), position: .init(x: 3, y: 4))],
         second: [.init(materialID: second, location: .project(projectA), position: .init(x: 5, y: 6))]]
    }

    private func makePayload() -> WorkMaterialDragPayload {
        .init(itemID: Constants.workboardDeskItemID, materialID: first, sourceLocation: .project(projectA),
              additionalMaterialIDs: [second], expectedLocationTokens: tokens)
    }
}
