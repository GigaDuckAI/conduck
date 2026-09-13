// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayProjectRefusalTests.swift
//
// What the car says when a Work project refuses a new turn, and WHERE it says
// it. The copy is a pure map, pinned to be total over the two refusals in
// both error families and nil for everything else, and never to prompt a
// retry — nothing at the wheel can change a project's standing. The
// placement is a source guard: the pre-flight probe sits above the voice
// template's presentation and re-validates the claim as its very next
// statement, and the send-path probe sits between the abandoned-turn
// cleanup and the "couldn't reach your AI" fallback it used to collapse into.

import XCTest
@testable import Conduck

final class CarPlayProjectRefusalTests: XCTestCase {
    private static let sceneDelegatePath = "Conduck/CarPlay/CarPlaySceneDelegate.swift"
    private static let recordingServicePath = "Conduck/CarPlay/CarPlayRecordingService.swift"

    func testEveryRefusalHasADriverSafeLineInBothErrorFamilies() {
        let archived = CarPlayProjectRefusalCopy.phrase(.archived)
        let selection = CarPlayProjectRefusalCopy.phrase(.selectionRequired)
        XCTAssertNotEqual(archived, selection)
        XCTAssertEqual(CarPlayProjectRefusalCopy.phrase(for: WorkProjectAccessError.archived), archived)
        XCTAssertEqual(CarPlayProjectRefusalCopy.phrase(for: WorkProjectAccessError.selectionRequired), selection)
        XCTAssertEqual(CarPlayProjectRefusalCopy.phrase(for: WorkDeskStoreError.projectArchived), archived)
        XCTAssertEqual(CarPlayProjectRefusalCopy.phrase(for: WorkDeskStoreError.projectSelectionRequired), selection)
        for line in [archived, selection] {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("try again"),
                           "a retry prompt sends the driver back into the same refusal")
            XCTAssertTrue(line.contains("iPhone"), "the line names the one place the fix lives")
        }
    }

    func testEveryOtherErrorFallsThroughToTheOrdinaryMapping() {
        XCTAssertNil(CarPlayProjectRefusalCopy.phrase(for: WorkDeskStoreError.projectNotFound))
        XCTAssertNil(CarPlayProjectRefusalCopy.phrase(for: WorkDeskStoreError.staleProject))
        XCTAssertNil(CarPlayProjectRefusalCopy.phrase(for: AppError.remoteAgentUnreachable))
        XCTAssertNil(CarPlayProjectRefusalCopy.phrase(for: CancellationError()))
    }

    func testThePreFlightRefusesBeforeAnythingIsPresented() throws {
        let scene = try RefusalLaneSource.source(at: Self.sceneDelegatePath)
        let body = try RefusalLaneSource.body(ofFunction: "startSession", in: scene, path: Self.sceneDelegatePath)
        let probe = try XCTUnwrap(body.range(of: "workProjectActivityRefusal(projectID:"),
                                  "the pre-flight no longer asks the project before recording")
        let present = try XCTUnwrap(body.range(of: "ensureVoicePresented"),
                                    "the voice template is presented somewhere else now — update this guard")
        XCTAssertLessThan(probe.lowerBound, present.lowerBound,
                          "the refusal must land before the voice template exists, so a refused thread presents nothing")
        let afterProbe = body[probe.upperBound...]
        let speak = try XCTUnwrap(afterProbe.range(of: "CarPlayProjectRefusalCopy.phrase(refusal)"))
        XCTAssertLessThan(speak.lowerBound, present.lowerBound)
        XCTAssertTrue(afterProbe[..<speak.lowerBound].contains("startIsLive(serial"),
                      "the claim is re-validated between the await and the spoken refusal")
    }

    func testTheSendPathProbesTheProjectBeforeBlamingTheGateway() throws {
        let service = try RefusalLaneSource.source(at: Self.recordingServicePath)
        let cleanup = try XCTUnwrap(service.range(of: "await terminalizeAbandonedUserTurn(appendedUserMessageID)"))
        let tail = service[cleanup.upperBound...]
        let probe = try XCTUnwrap(tail.range(of: "CarPlayProjectRefusalCopy.phrase(for: error)"),
                                  "the send catch no longer probes the project refusal")
        let fallback = try XCTUnwrap(tail.range(of: "?? .remoteAgentUnreachable"))
        XCTAssertLessThan(probe.lowerBound, fallback.lowerBound,
                          "the project's own line must win over the unreachable fallback")
        XCTAssertTrue(tail[probe.upperBound..<fallback.lowerBound].contains("endSession(speak: phrase)"),
                      "a refusal ends the session on its own line, the shared terminal")
    }
}
