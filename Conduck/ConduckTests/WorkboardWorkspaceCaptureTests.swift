// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardWorkspaceCaptureTests.swift
//
// The desk is a capture surface. These tests hold that boundary while also
// covering ordered partial-success imports: a thought or drop only appends to
// the desk's card list, and every mutation runs on one serialized lane against
// an advancing desk revision — starting from no revision at all, which is what
// "the desk row does not exist yet" means to the store.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardWorkspaceCaptureTests: XCTestCase {
    private enum TestError: Error { case expectedFailure, unexpectedCall }

    private final class Harness {
        /// The desk, or nil until a capture creates its row.
        var item: WorkboardItemSnapshot?
        var importedNames: [String] = []
        var importExpectedRevisions: [Int64?] = []
        var failingImportNames: Set<String> = []

        init(item: WorkboardItemSnapshot? = nil) {
            self.item = item
        }
    }

    /// Suspends every material import so a test can prove the capture lane
    /// serializes a thought and a drop against one advancing desk revision.
    private final class ImportGate {
        struct PendingImport {
            let materialImport: WorkboardMaterialImport
            let continuation: CheckedContinuation<WorkboardItemSnapshot, any Error>
        }

        var pending: [PendingImport] = []
        var startedNames: [String] = []
        var expectedRevisions: [Int64?] = []
        private var revision: Int64 = 0
        private var materials: [WorkboardMaterialSnapshot] = []

        func importMaterial(
            expectedRevision: Int64?,
            materialImport: WorkboardMaterialImport
        ) async throws -> WorkboardItemSnapshot {
            startedNames.append(materialImport.name)
            expectedRevisions.append(expectedRevision)
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(PendingImport(
                    materialImport: materialImport,
                    continuation: continuation
                ))
            }
        }

        func resolveNext() {
            let next = pending.removeFirst()
            materials.append(WorkboardMaterialSnapshot(
                id: next.materialImport.id,
                kind: next.materialImport.kind,
                name: next.materialImport.name,
                textContent: next.materialImport.textContent,
                sequence: materials.count,
                revision: 1
            ))
            revision += 1
            next.continuation.resume(returning: WorkboardItemSnapshot(
                id: Constants.workboardDeskItemID,
                materials: materials,
                revision: revision
            ))
        }
    }

    func testCaptureLogicNormalizesAndInfersACompactFirstLineTitle() {
        let longFirstLine = String(repeating: "a", count: 90)
        let normalized = WorkboardWorkspaceCaptureLogic.normalizedThought(
            "  \r\n\(longFirstLine)\rsecond line  \n"
        )

        XCTAssertEqual(normalized, "\(longFirstLine)\nsecond line")
        XCTAssertEqual(WorkboardWorkspaceCaptureLogic.title(for: normalized).count, 72)
        XCTAssertEqual(
            WorkboardWorkspaceCaptureLogic.title(for: "\n  Useful idea\nMore"),
            "Useful idea"
        )
    }

    func testFirstThoughtOnTheEmptyDeskBecomesANoteAndLeavesTheDeskWithoutABrief() async {
        let harness = Harness()
        let viewModel = makeViewModel(harness: harness)

        let added = await viewModel.addWorkspaceThought(
            "  Compare the launch plans\nwith the latest notes.  ",
            to: Constants.workboardDeskItemID
        )

        XCTAssertTrue(added)
        XCTAssertEqual(harness.importedNames, ["Compare the launch plans"])
        XCTAssertEqual(
            harness.importExpectedRevisions,
            [nil],
            "a desk row that does not exist yet has no revision to compare"
        )
        let desk = viewModel.item(withID: Constants.workboardDeskItemID)
        XCTAssertEqual(desk?.materials.map(\.kind), [.note])
        XCTAssertEqual(
            desk?.materials.first?.textContent,
            "Compare the launch plans\nwith the latest notes."
        )
        XCTAssertEqual(desk?.objective, "")
        XCTAssertEqual(desk?.title, "")
    }

    func testLaterThoughtBecomesAChronologicalNote() async {
        let harness = Harness(item: makeDesk(revision: 7))
        let viewModel = makeViewModel(harness: harness)
        await viewModel.load()

        let added = await viewModel.addWorkspaceThought(
            "Customer interviews favor the smaller launch.",
            to: Constants.workboardDeskItemID
        )

        XCTAssertTrue(added)
        XCTAssertEqual(harness.importedNames, ["Customer interviews favor the smaller launch."])
        XCTAssertEqual(harness.importExpectedRevisions, [7])
        XCTAssertEqual(
            viewModel.item(withID: Constants.workboardDeskItemID)?.materials.count,
            1
        )
    }

    func testBatchImportPreservesSuccessesAndAdvancesOnlySuccessfulRevisions() async {
        let harness = Harness(item: makeDesk(revision: 3))
        harness.failingImportNames = ["Unreadable"]
        let viewModel = makeViewModel(harness: harness)
        await viewModel.load()

        let report = await viewModel.importWorkspaceMaterials(
            [
                WorkboardMaterialImport(kind: .note, name: "First", textContent: "One"),
                WorkboardMaterialImport(kind: .file, name: "Unreadable"),
                WorkboardMaterialImport(kind: .link, name: "Third", urlString: "https://example.com")
            ],
            to: Constants.workboardDeskItemID
        )

        XCTAssertEqual(report, WorkboardWorkspaceImportReport(addedCount: 2, failedCount: 1))
        XCTAssertEqual(harness.importExpectedRevisions, [3, 4, 4])
        XCTAssertEqual(harness.importedNames, ["First", "Third"])
        XCTAssertEqual(
            viewModel.item(withID: Constants.workboardDeskItemID)?.materials.map(\.name),
            ["First", "Third"]
        )
        XCTAssertNil(viewModel.workspaceImportState)
    }

    func testCaptureAimedAtAnyBoardButTheDeskIsRefusedWithoutReachingTheStore() async {
        let harness = Harness(item: makeDesk(revision: 3))
        let viewModel = makeViewModel(harness: harness)
        await viewModel.load()

        let added = await viewModel.addWorkspaceThought("A stray thought", to: UUID())
        let report = await viewModel.importWorkspaceMaterials(
            [WorkboardMaterialImport(kind: .note, name: "Stray", textContent: "Stray")],
            to: UUID()
        )

        XCTAssertFalse(added)
        XCTAssertEqual(report, WorkboardWorkspaceImportReport(addedCount: 0, failedCount: 1))
        XCTAssertTrue(
            harness.importedNames.isEmpty,
            "Work is one desk: a capture aimed elsewhere is refused, never redirected"
        )
        XCTAssertEqual(
            viewModel.item(withID: Constants.workboardDeskItemID)?.materials.count,
            0
        )
    }

    func testFirstThoughtAndDropShareOneSerializedMutationLane() async {
        let gate = ImportGate()
        let viewModel = WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { nil },
            importMaterial: { [gate] expectedRevision, materialImport, onProgress in
                onProgress(1)
                return try await gate.importMaterial(
                    expectedRevision: expectedRevision,
                    materialImport: materialImport
                )
            },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))

        let thoughtTask = Task { @MainActor in
            await viewModel.addWorkspaceThought(
                "First thought",
                to: Constants.workboardDeskItemID
            )
        }
        await waitUntil { gate.pending.count == 1 }
        let dropTask = Task { @MainActor in
            await viewModel.importWorkspaceMaterials(
                [WorkboardMaterialImport(kind: .note, name: "Second", textContent: "Second")],
                to: Constants.workboardDeskItemID
            )
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            gate.startedNames,
            ["First thought"],
            "the drop must wait for the first thought revision"
        )
        gate.resolveNext()
        await waitUntil { gate.pending.count == 1 }
        gate.resolveNext()

        let thoughtAdded = await thoughtTask.value
        let dropReport = await dropTask.value
        XCTAssertTrue(thoughtAdded)
        XCTAssertEqual(dropReport, WorkboardWorkspaceImportReport(addedCount: 1, failedCount: 0))
        XCTAssertEqual(gate.startedNames, ["First thought", "Second"])
        // An absent token publishes the desk with its first card; the drop then
        // runs against the revision that write returned.
        XCTAssertEqual(gate.expectedRevisions, [nil, 1])
    }

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

    private func makeDesk(revision: Int64) -> WorkboardItemSnapshot {
        WorkboardItemSnapshot(id: Constants.workboardDeskItemID, revision: revision)
    }

    private func makeViewModel(harness: Harness) -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { [harness] in harness.item },
            importMaterial: { [harness] expectedRevision, materialImport, onProgress in
                harness.importExpectedRevisions.append(expectedRevision)
                if harness.failingImportNames.contains(materialImport.name) {
                    throw TestError.expectedFailure
                }
                // The desk row is published by the same write that stores the
                // first card, so an absent revision is the create case rather
                // than a separate lane.
                let existing = harness.item
                XCTAssertEqual(expectedRevision, existing?.revision)
                let material = WorkboardMaterialSnapshot(
                    id: materialImport.id,
                    kind: materialImport.kind,
                    name: materialImport.name,
                    detail: materialImport.detail,
                    textContent: materialImport.textContent,
                    urlString: materialImport.urlString,
                    mimeType: materialImport.mimeType,
                    byteCount: materialImport.byteCount,
                    sequence: existing?.materials.count ?? 0,
                    revision: 1
                )
                let updated = WorkboardItemSnapshot(
                    id: Constants.workboardDeskItemID,
                    materials: (existing?.materials ?? []) + [material],
                    revision: (existing?.revision ?? 0) + 1
                )
                harness.item = updated
                harness.importedNames.append(materialImport.name)
                onProgress(1)
                return updated
            },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
    }
}
