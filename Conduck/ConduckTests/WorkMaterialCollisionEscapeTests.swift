// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkMaterialCollisionEscapeTests.swift
//
// The escape id's derivation, pinned.
//
// The whole value of the escape is that it is the SAME id everywhere: the app
// and the headless intent process drain one queue file, and either may replay
// it after a crash. If the derivation ever changed, an escaped card already on
// a desk would be orphaned and the next replay would publish a second copy of
// it — silently, because every other test would still pass. So one fixed input
// is pinned to one literal answer here, and the namespace can no longer be
// changed without this case saying so.

import XCTest
@testable import Conduck

final class WorkMaterialCollisionEscapeTests: XCTestCase {

    /// Chosen once, arbitrary, and never to be changed: it exists only to name
    /// the answer below.
    private let fixedCaptureID = UUID(uuidString: "A1B2C3D4-E5F6-4708-8A9B-0C1D2E3F4051")!

    /// THE PIN. Recomputing this literal from a new namespace is not a fix.
    func testOneCaptureIdDerivesOnePinnedEscapeId() {
        XCTAssertEqual(
            WorkMaterialCollisionEscape.materialID(forCapture: fixedCaptureID),
            UUID(uuidString: "BAB27C0C-E2D6-5517-BC2A-74D5949AB973"),
            "the escape namespace is part of the on-disk contract, not an implementation detail"
        )
    }

    /// Pure: same input, same answer, however often and from wherever it is
    /// asked. This is what makes a replay in another process repair the card
    /// this one wrote instead of adding a second.
    func testTheEscapeIdIsAPureFunctionOfTheCaptureId() {
        let first = WorkMaterialCollisionEscape.materialID(forCapture: fixedCaptureID)
        for _ in 0..<8 {
            XCTAssertEqual(WorkMaterialCollisionEscape.materialID(forCapture: fixedCaptureID), first)
        }

        var derived: Set<UUID> = []
        for _ in 0..<64 {
            derived.insert(WorkMaterialCollisionEscape.materialID(forCapture: UUID()))
        }
        XCTAssertEqual(derived.count, 64, "distinct captures must not share one escape card")
    }

    /// The escape lives in a namespace of its own. A capture can need a
    /// recording card, a screenshot card, a fallback note and an escape, and no
    /// two of those derivations may ever name each other.
    func testTheEscapeNeverNamesAnotherDerivedIdentity() {
        for _ in 0..<32 {
            let captureID = UUID()
            let escape = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
            XCTAssertNotEqual(escape, captureID)
            XCTAssertNotEqual(escape, Constants.workboardDeskItemID)
            XCTAssertNotEqual(escape, WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID))
            XCTAssertNotEqual(escape, WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID))
            // And the escape of an escape is a third id, which is why the
            // drainer derives one and stops.
            XCTAssertNotEqual(WorkMaterialCollisionEscape.materialID(forCapture: escape), escape)
        }
    }

    /// RFC 4122 §4.3 name-based SHA-1, standard variant — the shape the other
    /// two derivations already carry, so a reader of any one of them recognises
    /// the rest.
    func testTheEscapeIdIsAVersionFiveUUID() {
        let escape = WorkMaterialCollisionEscape.materialID(forCapture: fixedCaptureID)
        let bytes = withUnsafeBytes(of: escape.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] >> 4, 5, "version 5")
        XCTAssertEqual(bytes[8] >> 6, 0b10, "the standard variant")
    }
}
