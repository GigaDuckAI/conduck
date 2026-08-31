// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardLiveRepositorySupportTests.swift
//
// The three seams the live board reads on every refresh: the batched vault URL
// lookup behind the preview wave, the batched turn lookup behind every run's
// displayed result, and the per-item search haystack that the sidebar filter
// would otherwise rebuild on each keystroke.

import Foundation
import XCTest
@testable import Conduck

final class WorkboardLiveRepositorySupportTests: XCTestCase {
    func testBatchedURLLookupResolvesOnlyPresentSafeKeys() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-urls-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let present = try await vault.store(Data("bytes".utf8), suggestedExtension: "png")
        let removed = try await vault.store(Data("gone".utf8), suggestedExtension: "png")
        try await vault.remove(removed)

        let resolved = await vault.urls(for: [present, removed, "../escape.png", present])

        XCTAssertEqual(Set(resolved.keys), [present])
        XCTAssertEqual(resolved[present]?.lastPathComponent, present)
        XCTAssertEqual(resolved[present]?.path, directory.appendingPathComponent(present).path)
    }

    func testBatchedURLLookupOnNoKeysIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-urls-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let resolved = await vault.urls(for: [])

        XCTAssertTrue(resolved.isEmpty)
    }

    /// One refresh resolves the displayed turn of every run on the board, so the
    /// read is batched into a single fetch. It must still make the ownership
    /// proof the single-id read makes: a run whose stored link names a different
    /// conversation resolves to nothing rather than borrowing another thread's
    /// turn.
    func testBatchedTurnLookupSpansConversationsAndRefusesAMispairedLink() async throws {
        let store = ConversationStore(inMemory: true)
        let first = try await store.createConversation(backend: "hermes")
        let second = try await store.createConversation(backend: "openclaw")
        let inFirst = try await store.appendMessage(
            role: "agent",
            text: "First reply",
            conversationID: first.id,
            sourceDevice: "test"
        )
        let inSecond = try await store.appendMessage(
            role: "agent",
            text: "Second reply",
            conversationID: second.id,
            sourceDevice: "test"
        )

        let resolved = try await store.fetchMessages(conversationIDsByMessageID: [
            inFirst.id: first.id,
            inSecond.id: second.id,
            // A run whose reply row has not synced to this device yet.
            UUID(): first.id,
        ])

        XCTAssertEqual(Set(resolved.keys), [inFirst.id, inSecond.id])
        XCTAssertEqual(resolved[inFirst.id]?.text, "First reply")
        XCTAssertEqual(resolved[inSecond.id]?.text, "Second reply")

        let mispaired = try await store.fetchMessages(
            conversationIDsByMessageID: [inFirst.id: second.id]
        )
        XCTAssertTrue(
            mispaired.isEmpty,
            "A turn is this run's result only inside the conversation the run named"
        )

        let none = try await store.fetchMessages(conversationIDsByMessageID: [:])
        XCTAssertTrue(none.isEmpty)
    }

    func testSearchReachesEveryBriefMaterialAndRunFieldRegardlessOfCase() {
        let item = WorkboardItemSnapshot(
            title: "Quarterly Plan",
            objective: "Ship The Board",
            context: "Founder Review",
            desiredResult: "Approved Copy",
            constraints: "No New Vendors",
            materials: [
                WorkboardMaterialSnapshot(
                    kind: .note,
                    name: "Pricing Note",
                    detail: "Available On This Device",
                    textContent: "Anchor At Twenty"
                )
            ],
            runs: [
                WorkboardRunSnapshot(
                    state: .replied,
                    gatewayRef: .builtin(.openrouter),
                    gatewayName: "OpenRouter",
                    sentPrompt: "Draft The Announcement",
                    resultMarkdown: "Here Is A Draft",
                    failureMessage: "Timed Out"
                )
            ]
        )

        // Deliberately lowercase needles against a title-cased fixture: the
        // matcher folds BOTH operands, which is why the corpus is stored
        // verbatim rather than as a second lowercased copy of the whole board.
        for needle in [
            "quarterly plan",
            "ship the board",
            "founder review",
            "approved copy",
            "no new vendors",
            "pricing note",
            "available on this device",
            "anchor at twenty",
            "openrouter",
            "draft the announcement",
            "here is a draft",
            "timed out"
        ] {
            XCTAssertTrue(
                WorkboardPresentationLogic.matches(item, needle: needle),
                "Search must still reach \(needle)"
            )
        }
        XCTAssertTrue(
            item.searchCorpus.contains("Quarterly Plan"),
            "The corpus keeps the brief's own casing; folding is the matcher's job"
        )
        XCTAssertFalse(WorkboardPresentationLogic.matches(item, needle: "unrelated"))
    }

    func testSearchCorpusOfAnEmptyBriefCarriesNoContent() {
        let item = WorkboardItemSnapshot()

        XCTAssertTrue(
            item.searchCorpus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
