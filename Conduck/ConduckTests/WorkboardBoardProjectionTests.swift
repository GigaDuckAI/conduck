// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardBoardProjectionTests.swift
//
// The board's derived surface: the composer's emptiness flag normalizes before
// it answers, and a mutation's result is adopted only when it cannot undo a
// newer read. The second property is invisible on a fast machine and decides
// what a person sees when a capture, a removal or a drag answers after a
// CloudKit import has already refreshed the desk underneath it.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardBoardProjectionTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }

    /// The desk the injected operations read and write, so a test can move the
    /// stored board while one of them is still in flight.
    private final class DeskHarness {
        var desk: WorkboardItemSnapshot?

        init(desk: WorkboardItemSnapshot? = nil) {
            self.desk = desk
        }
    }

    /// Suspends one desk mutation so a fresher read can land while its result
    /// is still in flight. That is exactly what another device's change looks
    /// like from here: the operation was built from the desk the store held
    /// when it STARTED and answers after the board has moved on.
    private final class MutationGate {
        private var continuation: CheckedContinuation<WorkboardItemSnapshot, any Error>?

        var isWaiting: Bool { continuation != nil }

        func suspend() async throws -> WorkboardItemSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(returning snapshot: WorkboardItemSnapshot) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: snapshot)
        }
    }

    // MARK: - Composer flag

    func testComposerFlagTracksNormalizedEmptinessRatherThanRawText() {
        let viewModel = makeViewModel(harness: DeskHarness())

        viewModel.setComposerDraft("   \n ")
        XCTAssertFalse(viewModel.hasComposerDraft, "whitespace is not a thought")
        XCTAssertEqual(viewModel.composerDraft, "   \n ", "the draft keeps what was typed")

        viewModel.setComposerDraft("  a real thought ")
        XCTAssertTrue(viewModel.hasComposerDraft)

        viewModel.setComposerDraft("")
        XCTAssertFalse(viewModel.hasComposerDraft)
        XCTAssertEqual(viewModel.composerDraft, "")
    }

    // MARK: - Late results

    /// A removal that answers after a newer read must not resurrect the board
    /// it was built from — the card the other device added would vanish.
    func testARemovalResultOlderThanTheBoardIsDropped() async {
        let kept = makeMaterial(name: "Kept")
        let harness = DeskHarness(desk: makeDesk(materials: [kept], revision: 5))
        let gate = MutationGate()
        let viewModel = makeViewModel(harness: harness, removal: gate)
        await viewModel.load()

        let removal = Task { @MainActor in
            await viewModel.removeMaterialFromBoard(kept.id)
        }
        await waitUntil { gate.isWaiting }

        // The other device's card arrives while the removal is still in flight.
        let arrived = makeMaterial(name: "Arrived from another device")
        harness.desk = makeDesk(materials: [kept, arrived], revision: 9)
        await viewModel.load()
        XCTAssertEqual(viewModel.desk?.revision, 9, "the corrective read landed first")

        // The removal finally answers with the board as it stood BEFORE it.
        gate.resume(returning: makeDesk(materials: [], revision: 6))
        _ = await removal.value

        XCTAssertEqual(
            viewModel.desk?.revision,
            9,
            "a result built on an older desk never replaces a newer one"
        )
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.name),
            ["Kept", "Arrived from another device"],
            "adopting the late result would have thrown away the arriving card"
        )
    }

    /// The same rule, on the lane a drag takes: a reorder that answers late is
    /// dropped rather than reinstating the order the person no longer has.
    func testAReorderResultOlderThanTheBoardIsDropped() async {
        let first = makeMaterial(name: "First", sequence: 0)
        let second = makeMaterial(name: "Second", sequence: 1)
        let harness = DeskHarness(desk: makeDesk(materials: [first, second], revision: 4))
        let gate = MutationGate()
        let viewModel = makeViewModel(harness: harness, reorder: gate)
        await viewModel.load()

        let drag = Task { @MainActor in
            await viewModel.reorderMaterial(second.id, toInsertionIndex: 0)
        }
        await waitUntil { gate.isWaiting }

        let arrived = makeMaterial(name: "Arrived from another device", sequence: 2)
        harness.desk = makeDesk(materials: [first, second, arrived], revision: 11)
        await viewModel.load()

        gate.resume(returning: makeDesk(materials: [second, first], revision: 5))
        _ = await drag.value

        XCTAssertEqual(viewModel.desk?.revision, 11)
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.name),
            ["First", "Second", "Arrived from another device"],
            "a late drag result never reinstates the board it was planned on"
        )
    }

    /// Equal revisions still adopt. Both values describe the same `updatedAt`,
    /// and the operation's own result is the one carrying what it just wrote —
    /// refusing it would leave the person looking at the card they removed.
    func testAResultCarryingTheSameRevisionIsAdopted() async {
        let removed = makeMaterial(name: "Removed")
        let kept = makeMaterial(name: "Kept", sequence: 1)
        let harness = DeskHarness(desk: makeDesk(materials: [removed, kept], revision: 5))
        let gate = MutationGate()
        let viewModel = makeViewModel(harness: harness, removal: gate)
        await viewModel.load()

        let removal = Task { @MainActor in
            await viewModel.removeMaterialFromBoard(removed.id)
        }
        await waitUntil { gate.isWaiting }
        gate.resume(returning: makeDesk(materials: [kept], revision: 5))
        let didRemove = await removal.value

        XCTAssertTrue(didRemove)
        XCTAssertEqual(
            viewModel.desk?.materials.map(\.name),
            ["Kept"],
            "a result at the board's own revision is what that operation did"
        )
    }

    // MARK: - Helpers

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test state", file: file, line: line)
    }

    private func makeDesk(
        materials: [WorkboardMaterialSnapshot],
        revision: Int64
    ) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(
            id: Constants.workboardDeskItemID,
            materials: materials,
            revision: revision
        )
    }

    private func makeMaterial(name: String, sequence: Int = 0) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            kind: .note,
            name: name,
            textContent: name,
            sequence: sequence
        )
    }

    private func makeViewModel(
        harness: DeskHarness,
        removal: MutationGate? = nil,
        reorder: MutationGate? = nil
    ) -> WorkboardViewModel {
        let reorderMaterials: (
            @MainActor ([UUID], WorkboardReorderBaseline) async throws -> WorkboardItemSnapshot
        )?
        if let reorder {
            reorderMaterials = { _, _ in try await reorder.suspend() }
        } else {
            reorderMaterials = nil
        }
        return WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { [harness] in harness.desk },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _ in
                guard let removal else { throw TestError.unexpectedCall }
                return try await removal.suspend()
            },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openMaterial: { _ in },
            reorderMaterials: reorderMaterials
        ))
    }
}
