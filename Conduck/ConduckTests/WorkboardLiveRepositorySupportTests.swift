// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardLiveRepositorySupportTests.swift
//
// The batched seams behind a board refresh: the vault URL lookup that feeds the
// preview wave, and the batched turn lookup that resolves many messages in one
// fetch without borrowing another conversation's turn.

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

    /// Many displayed turns resolve in one fetch rather than one read each. The
    /// batch must still make the ownership proof the single-id read makes: a
    /// link naming a different conversation resolves to nothing rather than
    /// borrowing another thread's turn.
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
}
