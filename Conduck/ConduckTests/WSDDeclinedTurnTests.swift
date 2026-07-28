// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WSDDeclinedTurnTests.swift
//
// Declined-turn UX. Covers the four layers the feature spans:
// 1. Wire-code classification (`classifyBodyError`): the frozen revision-1.3
//    vocabulary maps exactly, wins over contradicting regex heuristics, works
//    at any 4xx/5xx, and degrades safely on unknown/numeric codes.
// 2. Compat-mode substitution (`substitutingHistoricalImages`): in-place,
//    exact canonical disclosure, text turns untouched.
// 3. Presentation truth table (`DeclinedTurnPresentation`): confident vs
//    hedged copy, poisoned-chat gating on the dispatch-time fact, generic and
//    legacy fallbacks.
// 4. Store transitions (`failTurn` / `beginRetry` / clear-on-sent): the
//    guarded writer race rules and the atomic retry claim.
// Plus the REAL migration test: a v3 SQLite store opened under the v4 model.

import XCTest
import CoreData
@testable import Conduck

final class WSDDeclinedTurnTests: XCTestCase {

    // MARK: - Helpers

    private func body(message: String, code: Any? = nil) -> Data {
        var err: [String: Any] = ["message": message]
        if let code { err["code"] = code }
        return try! JSONSerialization.data(withJSONObject: ["error": err])
    }

    // MARK: - 1. classifyBodyError — wire codes

    func testEveryFrozenWireCodeMapsToItsAppError() {
        let expectations: [(AdapterWireCode, AppError)] = [
            (.imageUnsupported, .remoteAgentVisionUnsupported),
            (.modelNotFound, .remoteAgentModelUnavailable),
            (.contextTooLong, .remoteAgentContextTooLong),
            (.imageTooLarge, .remoteAgentImageTooLarge),
            (.overloaded, .remoteAgentRateLimited),
            (.upstreamTimeout, .remoteAgentTimeout),
            (.upstreamFailure, .remoteAgentServerError),
        ]
        for (code, expected) in expectations {
            let classified = RemoteAgentClient.classifyBodyError(
                status: 400,
                body: body(message: "opaque prose", code: code.rawValue)
            )
            XCTAssertEqual(classified?.appError.errorCode, expected.errorCode,
                           "wire code \(code.rawValue) must map to \(expected)")
            XCTAssertEqual(classified?.wireCode, code)
        }
    }

    func testWireCodeWinsOverContradictingRegex() {
        // Prose matches the context-too-long regex; the code says image.
        let classified = RemoteAgentClient.classifyBodyError(
            status: 400,
            body: body(message: "maximum context length exceeded", code: "image_unsupported")
        )
        XCTAssertEqual(classified?.appError.errorCode, AppError.remoteAgentVisionUnsupported.errorCode,
                       "the structured code is authoritative over prose heuristics")
        XCTAssertEqual(classified?.wireCode, .imageUnsupported)
    }

    func testWireCodeAppliesAtFiveHundredStatuses() {
        // The regex pass is gated to 400/404/413(+422) — the code pass is not.
        let classified = RemoteAgentClient.classifyBodyError(
            status: 503,
            body: body(message: "busy", code: "overloaded")
        )
        XCTAssertEqual(classified?.appError.errorCode, AppError.remoteAgentRateLimited.errorCode)
        XCTAssertEqual(classified?.wireCode, .overloaded)
    }

    func testUnknownCodeFallsThroughToRegex() {
        let classified = RemoteAgentClient.classifyBodyError(
            status: 400,
            body: body(message: "this model does not support image input", code: "server_hiccup")
        )
        XCTAssertEqual(classified?.appError.errorCode, AppError.remoteAgentVisionUnsupported.errorCode,
                       "an unknown code must not block the regex fallback")
        XCTAssertNil(classified?.wireCode, "an unknown code is NO code — never a confident classification")
    }

    func testNumericCodeToleratedAndIgnored() {
        let classified = RemoteAgentClient.classifyBodyError(
            status: 400,
            body: body(message: "unsupported content: image parts", code: 400)
        )
        XCTAssertEqual(classified?.appError.errorCode, AppError.remoteAgentVisionUnsupported.errorCode)
        XCTAssertNil(classified?.wireCode)
    }

    func testRegexClassificationCarriesNilWireCode() {
        let classified = RemoteAgentClient.classifyBodyError(
            status: 400,
            body: body(message: "image input is not supported here")
        )
        XCTAssertEqual(classified?.appError.errorCode, AppError.remoteAgentVisionUnsupported.errorCode)
        XCTAssertNil(classified?.wireCode)
    }

    func testMapBodyErrorWrapperStaysBehaviorIdentical() {
        // The legacy wrapper keeps returning the bare AppError (pinned by the
        // pre-existing eligibility tests) — spot-check equivalence.
        let data = body(message: "not a valid model")
        XCTAssertEqual(
            RemoteAgentClient.mapBodyError(status: 404, body: data)?.errorCode,
            RemoteAgentClient.classifyBodyError(status: 404, body: data)?.appError.errorCode
        )
    }

    // MARK: - 2. Compat-mode substitution

    func testSubstitutingHistoricalImagesReplacesInPlace() {
        let messages: [ConverseRequest.Message] = [
            .init(role: "user", content: .parts([
                .text("look at these"),
                .imageURL("data:image/jpeg;base64,AAA"),
                .imageURL("data:image/jpeg;base64,BBB"),
            ])),
            .init(role: "assistant", content: "two photos of ducks"),
        ]
        let substituted = ConverseRequest.substitutingHistoricalImages(in: messages)

        guard case .parts(let parts) = substituted[0].content else {
            return XCTFail("multimodal turn must stay a parts array (positions preserved)")
        }
        XCTAssertEqual(parts.count, 3, "part count preserved — replaced in place, never dropped")
        XCTAssertEqual(parts[0], .text("look at these"))
        XCTAssertEqual(parts[1], .text(ConverseRequest.historicalImageDisclosure))
        XCTAssertEqual(parts[2], .text(ConverseRequest.historicalImageDisclosure))
        XCTAssertEqual(substituted[1].content, .text("two photos of ducks"), "text turns untouched")
    }

    func testDisclosureIsTheCanonicalContractString() {
        XCTAssertEqual(
            ConverseRequest.historicalImageDisclosure,
            "An image was attached in this earlier message, but this adapter cannot inspect it. Do not infer its contents."
        )
    }

    func testContainsImageParts() {
        XCTAssertFalse(ConverseRequest.containsImageParts([
            .init(role: "user", content: "plain"),
            .init(role: "user", content: .parts([.text("only text part")])),
        ]))
        XCTAssertTrue(ConverseRequest.containsImageParts([
            .init(role: "user", content: .parts([.text("t"), .imageURL("data:image/jpeg;base64,AAA")])),
        ]))
    }

    // MARK: - 3. Presentation truth table

    func testPhotoDeclinedConfidentVsHedged() {
        let confident = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: "image_unsupported",
            turnHasOwnImages: true,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(confident.kind, .photoDeclined(confident: true))
        XCTAssertEqual(confident.title, "Photo declined")
        XCTAssertTrue(confident.offersResendWithoutPhoto)
        XCTAssertFalse(confident.offersKeepChattingWithoutPhotos)

        let hedged = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: nil,
            turnHasOwnImages: true,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: false
        )
        XCTAssertEqual(hedged.kind, .photoDeclined(confident: false))
        XCTAssertEqual(hedged.title, "No reply")
        XCTAssertFalse(hedged.offersResendWithoutPhoto, "an image-only turn has nothing to resend without the photo")
    }

    func testHistoryBlockedConfidenceNeedsWireCodeAndDispatchFact() {
        let confident = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: "image_unsupported",
            turnHasOwnImages: false,
            hadHistoryImages: true,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(confident.kind, .historyBlocked(confident: true))
        XCTAssertEqual(confident.title, "Chat blocked by an earlier photo")
        XCTAssertTrue(confident.offersKeepChattingWithoutPhotos)

        // Missing dispatch-time fact → hedged ("may be").
        let noFact = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: "image_unsupported",
            turnHasOwnImages: false,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(noFact.kind, .historyBlocked(confident: false))
        XCTAssertEqual(noFact.title, "This chat may be blocked by an earlier photo")

        // Missing wire code → hedged, even with the fact.
        let noCode = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: nil,
            turnHasOwnImages: false,
            hadHistoryImages: true,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(noCode.kind, .historyBlocked(confident: false))
    }

    func testArbitraryWireCodeStringNeverConfident() {
        // A non-vocabulary string persisted in `failureWireCode` (defensive —
        // nothing writes one, but sync could deliver anything) must not
        // masquerade as a structured classification.
        let presentation = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentVisionUnsupported.errorCode,
            failureWireCode: "totally_made_up",
            turnHasOwnImages: true,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(presentation.kind, .photoDeclined(confident: false))
    }

    func testGenericAndLegacyFallbacks() {
        // Known troubleshootable code → its AppError copy + Diagnostics link.
        let known = DeclinedTurnPresentation.classify(
            failureCode: AppError.remoteAgentUnreachable.errorCode,
            failureWireCode: nil,
            turnHasOwnImages: false,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(known.kind, .generic)
        XCTAssertEqual(known.title, "No reply")
        // Cause AND remedy — the row is the whole story for the failed turn.
        XCTAssertEqual(known.body, AppError.remoteAgentUnreachable.descriptionWithRecovery)
        XCTAssertEqual(known.troubleshootCode, AppError.remoteAgentUnreachable.errorCode)
        XCTAssertTrue(known.offersRetry, "an unreachable gateway can succeed on the next tap")

        // Legacy row (nil code) → neutral copy, no Diagnostics link.
        let legacy = DeclinedTurnPresentation.classify(
            failureCode: nil,
            failureWireCode: nil,
            turnHasOwnImages: false,
            hadHistoryImages: nil,
            hasResendableNonPhotoContent: true
        )
        XCTAssertEqual(legacy.kind, .generic)
        XCTAssertEqual(legacy.body, "This message wasn't delivered.")
        XCTAssertNil(legacy.troubleshootCode)
        XCTAssertTrue(legacy.offersRetry, "no persisted taxonomy is not a terminal verdict")

        // Terminal refusals keep their explanation and lose only the button
        // that could never have honoured it — the identical request would meet
        // the identical refusal, on both certificate families alike.
        for terminal in [AppError.remoteAgentCertUntrusted, .remoteAgentCertMismatch, .remoteAgentAuthFailed] {
            let refused = DeclinedTurnPresentation.classify(
                failureCode: terminal.errorCode,
                failureWireCode: nil,
                turnHasOwnImages: false,
                hadHistoryImages: nil,
                hasResendableNonPhotoContent: true
            )
            XCTAssertFalse(refused.offersRetry, "\(terminal) is terminal — no Try again")
            XCTAssertEqual(refused.body, terminal.descriptionWithRecovery)
        }
    }

    // MARK: - 4. Store transitions

    private func makeStoreWithSendingTurn() async throws -> (ConversationStore, UUID, UUID) {
        let store = ConversationStore(inMemory: true)
        let convo = try await store.createConversation(backend: "openclaw")
        let message = try await store.appendMessage(
            role: "user", text: "hello", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        return (store, convo.id, message.id)
    }

    private func fetchTurn(_ store: ConversationStore, _ conversationID: UUID, _ messageID: UUID) async throws -> MessageRecord? {
        try await store.fetchMessages(for: conversationID).first { $0.id == messageID }
    }

    func testFailTurnWritesClassificationOnSendingTurn() async throws {
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.status, "failed")
        XCTAssertEqual(turn?.failureCode, 32)
        XCTAssertEqual(turn?.failureWireCode, "image_unsupported")
        XCTAssertEqual(turn?.failureHadHistoryImages, true)
    }

    func testPlainFailedThenCodedWriteUpgrades() async throws {
        // The foreground VM's plain `failed` wins the race; the delegate's
        // coded write must still land (metadata upgrade in place).
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.markPendingUserTurn(messageID: mid, to: "failed")
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: false))
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.status, "failed")
        XCTAssertEqual(turn?.failureCode, 32)
        XCTAssertEqual(turn?.failureWireCode, "image_unsupported")
    }

    func testCodedThenNilWriteNeverErases() async throws {
        // Reverse order: the coded write landed first; a trailing nil-code
        // writer (generic catch arm) must not strip the richer classification.
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))
        await store.failTurn(messageID: mid, classification: nil)
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: AppError.remoteAgentUnreachable.errorCode, wireCode: nil, hadHistoryImages: nil))
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.failureCode, 32, "an existing classification is never downgraded")
        XCTAssertEqual(turn?.failureWireCode, "image_unsupported")
    }

    func testFailTurnNeverDisturbsAResolvedTurn() async throws {
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        try await store.updateStatus(messageID: mid, status: "sent")
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: nil, hadHistoryImages: nil))
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.status, "sent", "a delivered turn is never flipped back")
        XCTAssertNil(turn?.failureCode)
    }

    func testBeginRetryClaimsOnceAndKeepsClassification() async throws {
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))

        let first = await store.beginRetry(messageID: mid)
        XCTAssertTrue(first, "the first claim wins")
        let second = await store.beginRetry(messageID: mid)
        XCTAssertFalse(second, "a concurrent second claim must lose (no double dispatch)")

        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.status, "sending")
        XCTAssertEqual(turn?.failureCode, 32, "classification survives the claim — cleared only on success")
    }

    func testSentClearsClassification() async throws {
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))
        _ = await store.beginRetry(messageID: mid)
        try await store.updateStatus(messageID: mid, status: "sent")
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.status, "sent")
        XCTAssertNil(turn?.failureCode, "success clears the classification (frozen rule)")
        XCTAssertNil(turn?.failureWireCode)
        XCTAssertNil(turn?.failureHadHistoryImages)
    }

    func testWideWriterNeverContaminatesOldFailedTurns() async throws {
        // Review regression: `failPendingUserTurns` (the no-exact-id legacy
        // fallback) must flip only still-`sending` turns — never stamp the
        // current failure's classification onto an OLD unrelated failed turn.
        let store = ConversationStore(inMemory: true)
        let convo = try await store.createConversation(backend: "openclaw")
        let oldTurn = try await store.appendMessage(
            role: "user", text: "old network failure", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: oldTurn.id, classification: nil)  // legacy generic failure
        let currentTurn = try await store.appendMessage(
            role: "user", text: "current photo turn", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        await store.failPendingUserTurns(conversationID: convo.id, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))

        let old = try await fetchTurn(store, convo.id, oldTurn.id)
        XCTAssertNil(old?.failureCode, "the old failed turn must NOT inherit the new classification")
        XCTAssertNil(old?.failureWireCode)
        let current = try await fetchTurn(store, convo.id, currentTurn.id)
        XCTAssertEqual(current?.status, "failed")
        XCTAssertEqual(current?.failureCode, 32, "the sending turn gets the classification")
    }

    func testWireCodedWriteUpgradesOverGenericCodedWrite() async throws {
        // Review regression: richest-wins — a generic (non-wire) classification
        // landing FIRST must not block the delegate's later wire-coded write.
        let (store, cid, mid) = try await makeStoreWithSendingTurn()
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: AppError.remoteAgentUnreachable.errorCode, wireCode: nil, hadHistoryImages: nil))
        await store.failTurn(messageID: mid, classification: .init(
            failureCode: 32, wireCode: "image_unsupported", hadHistoryImages: true))
        let turn = try await fetchTurn(store, cid, mid)
        XCTAssertEqual(turn?.failureCode, 32, "the wire-coded classification is richer and wins")
        XCTAssertEqual(turn?.failureWireCode, "image_unsupported")
        XCTAssertEqual(turn?.failureHadHistoryImages, true)
    }

    func testHideEarlierPhotosRoundTrip() async throws {
        let store = ConversationStore(inMemory: true)
        let convo = try await store.createConversation(backend: "openclaw")
        let before = try await store.fetchConversation(id: convo.id)
        XCTAssertEqual(before?.hideEarlierPhotos, false, "default off")

        await store.setHideEarlierPhotos(conversationID: convo.id, true)
        let on = try await store.fetchConversation(id: convo.id)
        XCTAssertEqual(on?.hideEarlierPhotos, true)

        await store.setHideEarlierPhotos(conversationID: convo.id, false)
        let off = try await store.fetchConversation(id: convo.id)
        XCTAssertEqual(off?.hideEarlierPhotos, false, "reversible (Try photos again)")
    }

    // MARK: - 5. Migration — a REAL v3 SQLite store under the v4 model

    func testV3OnDiskStoreOpensUnderCurrentModel() async throws {
        // Build the store with the ACTUAL compiled v3 model (from the app
        // bundle's momd), close it, then open the same file through
        // `ConversationStore` (current model = v4). Lightweight migration must
        // add the three new columns with nil/default values.
        guard let momd = Bundle.main.url(forResource: "Conversations", withExtension: "momd"),
              let v3Model = NSManagedObjectModel(contentsOf: momd.appendingPathComponent("Conversations 3.mom")) else {
            return XCTFail("compiled v3 model not found in the host app bundle")
        }

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsd-migration-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            let fm = FileManager.default
            try? fm.removeItem(at: storeURL)
            try? fm.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal"))
            try? fm.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm"))
        }

        // 1. Write one conversation + one failed user turn under v3.
        let conversationID = UUID()
        let messageID = UUID()
        do {
            let container = NSPersistentContainer(name: "Conversations", managedObjectModel: v3Model)
            let description = NSPersistentStoreDescription(url: storeURL)
            container.persistentStoreDescriptions = [description]
            let loaded = expectation(description: "v3 store loads")
            container.loadPersistentStores { _, error in
                XCTAssertNil(error)
                loaded.fulfill()
            }
            await fulfillment(of: [loaded], timeout: 10)

            let context = container.newBackgroundContext()
            try await context.perform {
                let convo = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
                convo.setValue(conversationID, forKey: "id")
                convo.setValue("openclaw", forKey: "backend")
                convo.setValue(Date(), forKey: "createdAt")
                convo.setValue(Date(), forKey: "lastActivityAt")
                convo.setValue(conversationID.uuidString, forKey: "sessionID")
                let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context)
                message.setValue(messageID, forKey: "id")
                message.setValue("user", forKey: "role")
                message.setValue("legacy failed turn", forKey: "text")
                message.setValue(Date(), forKey: "createdAt")
                message.setValue("phone", forKey: "sourceDevice")
                message.setValue("failed", forKey: "status")
                message.setValue(convo, forKey: "conversation")
                try context.save()
            }
            // Drop the container so the file is closed before re-opening.
        }

        // 2. Re-open the SAME file through the production store (v4 model).
        let store = ConversationStore(storeURL: storeURL)
        let convo = try await store.fetchConversation(id: conversationID)
        XCTAssertNotNil(convo, "the v3 row must survive migration")
        XCTAssertEqual(convo?.hideEarlierPhotos, false, "new flag defaults off for migrated rows")

        let turn = try await fetchTurn(store, conversationID, messageID)
        XCTAssertEqual(turn?.status, "failed")
        XCTAssertNil(turn?.failureCode, "a legacy failed row has no classification (generic row copy)")
        XCTAssertNil(turn?.failureWireCode)
        XCTAssertNil(turn?.failureHadHistoryImages)

        // 3. And the new columns are writable post-migration.
        await store.failTurn(messageID: messageID, classification: nil)  // no-op: already failed, nil incoming
        await store.setHideEarlierPhotos(conversationID: conversationID, true)
        let flagged = try await store.fetchConversation(id: conversationID)
        XCTAssertEqual(flagged?.hideEarlierPhotos, true)
    }
}
