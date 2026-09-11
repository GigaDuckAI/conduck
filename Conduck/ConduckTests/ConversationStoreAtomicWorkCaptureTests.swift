// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// ConversationStoreAtomicWorkCaptureTests.swift
//
// Work is ONE desk, so an unfiled capture publishes at most two metadata rows:
// the desk itself, created lazily by the first card ever captured, and the card.
// Both commit in one save or neither does — a half-created desk is a board the
// person can see and a capture they cannot find, and staged bytes left behind by a refused
// transaction are a payload no row will ever name.
//
// The desk being the only owner is also a claim about the SHIPPED surface, not
// merely about what today's callers happen to do. The constructors that can name
// an arbitrary owner are fixtures for the pre-desk rows an upgrade still meets,
// and the last test here is what keeps them out of a build a person runs.

import XCTest
@testable import Conduck

final class ConversationStoreAtomicWorkCaptureTests: XCTestCase {

    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    func testTheFirstCaptureCommitsTheDeskRowAndItsCardInOneSave() async throws {
        let store = isolated.make()
        let materialID = UUID()
        let payload = Data("private launch notes".utf8)

        let deskBefore = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertNil(deskBefore, "the desk row is created by the first capture, not at launch")

        let card = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: materialID,
                kind: .file,
                title: "notes.txt",
                filename: "notes.txt",
                mimeType: "text/plain",
                payload: payload,
                byteSize: Int64(payload.count),
                sourceDevice: "test"
            )
        )

        XCTAssertEqual(card.workItemID, Constants.workboardDeskItemID)
        XCTAssertEqual(card.availability, .synced,
                       "a file within the sync ceiling rides private CloudKit")
        let loadedPayload = try await store.loadWorkMaterialPayload(id: materialID)
        XCTAssertEqual(loadedPayload, payload)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue, "the card's owner row committed with it")
        XCTAssertEqual(desk.materials.map(\.id), [materialID])
        XCTAssertTrue(desk.content.title.isEmpty,
                      "the desk holds no brief; nothing displays one")
        XCTAssertTrue(desk.content.objective.isEmpty)
    }

    func testAStagingFailureCommitsNeitherTheDeskNorACardAndLeavesTheNextCaptureClean()
        async throws {
        let store = isolated.make()
        let materialID = UUID()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-work-capture-\(UUID().uuidString).pdf")

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: materialID,
                    kind: .file,
                    title: "missing.pdf",
                    filename: "missing.pdf",
                    mimeType: "application/pdf",
                    byteSize: -1,
                    sourceDevice: "test"
                ),
                sourceFileURL: missingURL,
                sourceFileByteSize: -1
            )
            XCTFail("an unreadable source must fail before publishing either row")
        } catch {
            // Expected: preparation never reaches the atomic Core Data save.
        }

        let storedDesk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let storedMaterial = try await store.loadWorkMaterial(id: materialID)
        let reclaimedCount = try await store.reconcileWorkAssetVault()
        XCTAssertNil(storedDesk, "a failed first capture leaves no half-created desk behind")
        XCTAssertNil(storedMaterial)
        XCTAssertEqual(reclaimedCount, 0)

        // The desk is still unwritten, so the next capture takes the same
        // lazy-creation path the first one did rather than meeting a row the
        // failure left half-formed.
        let recovered = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "After the failure", textContent: "still fine")
        )
        XCTAssertEqual(recovered.workItemID, Constants.workboardDeskItemID)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(try XCTUnwrap(deskValue).materials.count, 1)
    }

    func testARefusedTransactionRemovesTheBytesItStaged() async throws {
        let store = isolated.make()
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .note, title: "Already durable", textContent: "x")
        )
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let staleRevision = WorkboardRevision.value(for: desk.updatedAt) - 1

        // Over the ceiling, so the bytes are staged into the vault and a
        // refusal has something physical to take back.
        let payload = Data(
            repeating: 0xA5,
            count: Int(Constants.workboardSyncCeilingBytes) + 1
        )
        let refusedID = UUID()
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: refusedID,
                    kind: .file,
                    title: "late.bin",
                    filename: "late.bin",
                    payload: payload,
                    byteSize: Int64(payload.count)
                ),
                expectedOwnerRevision: staleRevision
            )
            XCTFail("a write against a revision the board has moved past must be refused")
        } catch WorkboardStoreError.staleRevision {
            // Expected.
        }

        let settledValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let settled = try XCTUnwrap(settledValue)
        XCTAssertEqual(settled.materials.count, 1, "the refused card never reached the desk")
        let reclaimedCount = try await store.reconcileWorkAssetVault()
        XCTAssertEqual(reclaimedCount, 0,
                       "the rejected transaction must clean its staged vault file")
    }

    // MARK: - The shipped surface has one owner

    /// The desk id is the only owner a shipped build can name, and this is what
    /// makes that a property of the BUILD rather than of today's call sites.
    ///
    /// It reads source rather than calling anything, because what it asserts is
    /// the absence of declarations from a build this suite is not: the test
    /// bundle compiles with `CONDUCK_TESTING` defined, so every symbol behind
    /// that flag is present and callable here — the compiler cannot be asked
    /// whether a shipping build would have it. The region walk is the same
    /// shape `WorkboardBlobSeamPlatformGuardTests` uses on the store's payload
    /// seams, for the same reason.
    ///
    /// The behavioural half is the case above: what a capture actually
    /// publishes names `Constants.workboardDeskItemID`.
    func testNoArbitraryOwnerConstructorSurvivesIntoAShippedBuild() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)   // .../ConduckTests/<this>
                .deletingLastPathComponent()              // .../ConduckTests
                .deletingLastPathComponent()              // .../Conduck/Conduck
                .appendingPathComponent("Conduck/Services/ConversationStore+Workboard.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: "\n")

        // Compilation conditions wrapping each line, outermost first. Directives
        // count only at the start of a line, so a `#if` quoted inside a doc
        // comment cannot unbalance the stack.
        var stack: [String] = []
        var conditionsByLine: [[String]] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                conditionsByLine.append(stack)
            } else if line.hasPrefix("#if ") {
                stack.append(String(line.dropFirst(4)).filter { !$0.isWhitespace })
                conditionsByLine.append(stack)
            } else if line == "#endif" {
                conditionsByLine.append(stack)
                if !stack.isEmpty { stack.removeLast() }
            } else {
                conditionsByLine.append(stack)
            }
        }
        XCTAssertTrue(stack.isEmpty, "unbalanced #if/#endif — the region walk cannot be trusted")

        let arbitraryOwnerEntryPoints = [
            "func createWorkItem(",
            "func addWorkMaterial(",
            "func addWorkMaterialFile(",
            "func insertWorkMaterial("
        ]
        for declaration in arbitraryOwnerEntryPoints {
            let index = try XCTUnwrap(
                lines.firstIndex {
                    let line = $0.trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && line.contains(declaration)
                },
                "`\(declaration)` is gone or renamed — rename this guard with it, or drop the row."
            )
            XCTAssertTrue(
                conditionsByLine[index].contains("CONDUCK_TESTING"),
                """
                `\(declaration)` is compiled into a shipping build. It can mint or fill a Work \
                item that is not the desk, which is a second board a person can capture into \
                and never see: the desk view model fetches the fixed id alone. It exists to \
                build the pre-desk rows the adoption path has to be tested against, and \
                nothing else — keep it behind #if CONDUCK_TESTING. Conditions found: \
                \(conditionsByLine[index]).
                """
            )
        }

        XCTAssertFalse(
            source.contains("func createWorkItemWithInitialMaterial"),
            """
            The provisional-item constructor is back. Work has no provisional item any more: \
            the desk's id is a compile-time constant, so the first capture creates that row \
            and every later one finds it.
            """
        )
    }
}
