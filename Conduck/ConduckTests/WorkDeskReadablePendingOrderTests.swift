// SPDX-License-Identifier: Apache-2.0

// An accepted drag may render ahead of persistence, but must never freeze card
// content or hide a newer arrival, removal, filing or order from another device.

import XCTest
@testable import Conduck

@MainActor
final class WorkDeskReadablePendingOrderTests: XCTestCase {
    private func context(_ materials: [WorkboardMaterialSnapshot]) -> WorkDeskReadableReorderContext {
        .init(scope: .all, search: "", layout: .tiles,
              visibleIDs: materials.map(\.id), projectIDs: [:])
    }

    private func cards() -> [WorkboardMaterialSnapshot] {
        ["First", "Second", "Third"].map { .init(id: UUID(), kind: .note, name: $0) }
    }

    func testPendingDropMovesImmediatelyButUsesLatestCardContent() throws {
        let original = cards()
        let baseline = context(original)
        let pending = try XCTUnwrap(WorkDeskReadablePendingOrder(moving: original[0].id,
            relativeTo: original[2].id, placement: .after, materials: original, context: baseline))
        var latest = original
        latest[0].name = "Edited while saving"
        let projected = pending.project(latest, context: baseline)
        XCTAssertEqual(projected.map(\.id), [original[1].id, original[2].id, original[0].id])
        XCTAssertEqual(projected.last?.name, "Edited while saving")
        XCTAssertEqual(original.map(\.name), ["First", "Second", "Third"],
                       "The preview must not mutate the authoritative snapshots")
    }

    func testNewerArrivalsRemovalsAndOrdersSupersedePendingDrop() throws {
        let original = cards()
        let pending = try XCTUnwrap(WorkDeskReadablePendingOrder(moving: original[0].id,
            relativeTo: original[2].id, placement: .after, materials: original, context: context(original)))
        let arrival = original + [WorkboardMaterialSnapshot(id: UUID(), kind: .note, name: "Arrived")]
        let removed = Array(original.dropFirst())
        let reordered = Array(original.reversed())
        for current in [arrival, removed, reordered] {
            XCTAssertEqual(pending.project(current, context: context(current)), current)
        }
    }

    func testNavigationAndChangedMembershipSupersedePendingDrop() throws {
        let original = cards()
        let baseline = context(original)
        let pending = try XCTUnwrap(WorkDeskReadablePendingOrder(moving: original[0].id,
            relativeTo: original[2].id, placement: .after, materials: original, context: baseline))
        let contexts: [WorkDeskReadableReorderContext] = [
            .init(scope: .project(UUID()), search: "", layout: .tiles, visibleIDs: baseline.visibleIDs, projectIDs: [:]),
            .init(scope: .all, search: "First", layout: .tiles, visibleIDs: baseline.visibleIDs, projectIDs: [:]),
            .init(scope: .all, search: "", layout: .list, visibleIDs: baseline.visibleIDs, projectIDs: [:]),
            .init(scope: .all, search: "", layout: .tiles, visibleIDs: baseline.visibleIDs,
                  projectIDs: [original[0].id: UUID()]),
        ]
        for current in contexts { XCTAssertEqual(pending.project(original, context: current), original) }
    }

    func testNoOpDropCreatesNoPendingPresentation() {
        let original = cards()
        XCTAssertNil(WorkDeskReadablePendingOrder(moving: original[0].id, relativeTo: original[1].id,
            placement: .before, materials: original, context: context(original)))
    }
}
