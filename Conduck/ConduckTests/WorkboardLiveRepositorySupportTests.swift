// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardLiveRepositorySupportTests.swift
//
// The batched seams behind a board refresh: the vault URL lookup that feeds the
// preview wave, the batched turn lookup that resolves many messages in one fetch
// without borrowing another conversation's turn, and the two pure projections
// every card is drawn from — the kind it claims to be and the name it shows.

import Foundation
import XCTest
@testable import Conduck

final class WorkboardLiveRepositorySupportTests: XCTestCase {
    func testBatchedURLLookupResolvesOnlyPresentSafeKeys() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-vault-urls-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WorkAssetVault(baseURL: directory)

        let present = try await vault.store(bytes: Data("bytes".utf8), suggestedExtension: "png").key
        let removed = try await vault.store(bytes: Data("gone".utf8), suggestedExtension: "png").key
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

    // MARK: - Card projections

    /// A stored kind is broader than the shapes a card can draw, so the
    /// narrowing is stated once. A voice note travels as its recording and draws
    /// as its own transport-bearing card rather than as the note its transcript
    /// becomes, and `.unknown` is decided by whether there is anything to open.
    @MainActor
    func testPresentationKindNarrowsEveryStoredKindToACardShape() {
        let expected: [(WorkMaterialKind, WorkboardMaterialKind)] = [
            (.image, .image),
            (.file, .file),
            (.audio, .audio),
            (.link, .link),
            (.note, .note),
            (.transcript, .note),
        ]
        for (stored, card) in expected {
            XCTAssertEqual(
                WorkboardLiveRepository.presentationKind(Self.record(kind: stored)),
                card,
                "a stored \(stored.rawValue) draws as a \(card.rawValue) card"
            )
        }

        XCTAssertEqual(
            WorkboardLiveRepository.presentationKind(Self.record(kind: .unknown)),
            .note,
            "an unknown kind with nothing to open is a note"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.presentationKind(
                Self.record(kind: .unknown, filename: "report.xyz")
            ),
            .file
        )
        XCTAssertEqual(
            WorkboardLiveRepository.presentationKind(
                Self.record(kind: .unknown, hasPayload: true)
            ),
            .file,
            "bytes this build cannot render richly are still bytes the person can open"
        )

        XCTAssertEqual(
            Set(WorkMaterialKind.allCases.map {
                WorkboardLiveRepository.presentationKind(Self.record(kind: $0))
            }),
            [.image, .file, .link, .note, .audio],
            "every stored kind resolves; a new one must be given a shape here"
        )
    }

    /// Title, then filename, then the link's host, then the kind's own noun.
    /// Each candidate is judged trimmed and emitted verbatim — the card owns the
    /// final normalization, so a name padded by the person survives to it.
    @MainActor
    func testMaterialNameFallsBackFromTitleToFilenameToHostToKind() {
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(
                Self.record(kind: .file, title: "  Rate card  ", filename: "rates.txt")
            ),
            "  Rate card  ",
            "a title wins and is emitted verbatim"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(
                Self.record(kind: .file, title: "   ", filename: "rates.txt")
            ),
            "rates.txt",
            "a title that is only whitespace is not a name"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(
                Self.record(kind: .link, urlString: "https://example.org/pricing?a=1")
            ),
            "example.org"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(
                Self.record(kind: .link, urlString: "not a url")
            ),
            String(localized: "workboard.material.link", defaultValue: "Link"),
            "an unparseable link falls through to the kind's noun"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(Self.record(kind: .image)),
            String(localized: "workboard.material.image", defaultValue: "Image")
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(Self.record(kind: .audio)),
            String(localized: "workboard.material.audio", defaultValue: "Voice note"),
            "a nameless recording is named by the shape it draws as, which is its own"
        )
        XCTAssertEqual(
            WorkboardLiveRepository.materialName(Self.record(kind: .note)),
            String(localized: "workboard.material.note", defaultValue: "Note")
        )
    }

    /// Only the fields the two projections read carry values; everything else is
    /// the empty shape, so a case states exactly the input it depends on.
    private static func record(
        kind: WorkMaterialKind,
        title: String = "",
        filename: String? = nil,
        urlString: String? = nil,
        hasPayload: Bool = false
    ) -> WorkMaterialRecord {
        let now = Date(timeIntervalSince1970: 0)
        return WorkMaterialRecord(
            id: UUID(),
            workItemID: Constants.workboardDeskItemID,
            kind: kind,
            title: title,
            caption: "",
            textContent: nil,
            urlString: urlString,
            filename: filename,
            mimeType: nil,
            thumbnailData: nil,
            width: nil,
            height: nil,
            byteSize: 0,
            hasPayload: hasPayload,
            storageMode: .metadataOnly,
            availability: .metadataOnly,
            localVaultKey: nil,
            sourceDevice: nil,
            sequence: 0,
            createdAt: now,
            updatedAt: now
        )
    }
}
