// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayAttemptRecordTests.swift
//
// The three things the attempt ledger's domain layer must never get wrong.
//
// 1. DECODING A STORED VALUE NEVER CRASHES AND NEVER GUESSES. Attempt rows sync
//    between devices, so a newer client's vocabulary can arrive at an older one;
//    an unrecognised outcome, origin or input mode decodes to `unknown` rather
//    than trapping or silently dropping a row that genuinely happened.
// 2. THE EFFECTIVE OUTCOME IS DERIVED, SYMMETRICALLY, AND WRITTEN NOWHERE. The
//    clock-skew half is the subtle one: a row stamped by a device whose clock
//    runs fast is FUTURE-dated on this one, and an elapsed-only window would
//    leave it hedged forever because the interval only grows more negative.
// 3. ONE DERIVATION POINT PER HALF OF A `sourceDevice` TAG — modality for a
//    retry, device class for a row that predates the column. Both split on the
//    same dash, and reconstructing either twice in two places is how the two
//    answers start disagreeing.
//
// The KVC round-trip at the end is the compile-time-invisible one: the record's
// key strings are the ONLY link between the Swift snapshot and the v11 model,
// and a typo in either surfaces as a permanently nil column, never as a build
// error.

import XCTest
import CoreData
@testable import Conduck

final class GatewayAttemptRecordTests: XCTestCase {

    private let grace = ConversationActivityResolver.staleSendingGrace
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Vocabulary decoding

    func testEveryOutcomeRoundTripsThroughItsRawValue() {
        for outcome in GatewayAttemptOutcome.allCases {
            XCTAssertEqual(GatewayAttemptOutcome.from(raw: outcome.rawValue), outcome)
        }
    }

    func testUnrecognisedOutcomeDecodesAsUnknown() {
        XCTAssertEqual(GatewayAttemptOutcome.from(raw: "throttledByFutureClient"), .unknown,
                       "a newer client's vocabulary reaching an older one must not drop the row — "
                       + "the attempt still happened")
        XCTAssertEqual(GatewayAttemptOutcome.from(raw: ""), .unknown)
    }

    func testNilOutcomeDecodesAsUnknownNotInFlight() {
        XCTAssertEqual(GatewayAttemptOutcome.from(raw: nil), .unknown,
                       "every insert stamps inFlight, so a row with no outcome is a partially "
                       + "materialised record — reading it as live would hedge it forever")
    }

    func testOnlyInFlightIsNonTerminal() {
        XCTAssertFalse(GatewayAttemptOutcome.inFlight.isTerminal)
        for outcome in GatewayAttemptOutcome.allCases where outcome != .inFlight {
            XCTAssertTrue(outcome.isTerminal, "\(outcome.rawValue) ends the attempt")
        }
    }

    func testOriginAndInputModeDecodeToleranly() {
        for origin in GatewayAttemptOrigin.allCases {
            XCTAssertEqual(GatewayAttemptOrigin.from(raw: origin.rawValue), origin)
        }
        XCTAssertEqual(GatewayAttemptOrigin.from(raw: "hologram"), .unknown)
        XCTAssertEqual(GatewayAttemptOrigin.from(raw: nil), .unknown)

        for mode in GatewayInputMode.allCases {
            XCTAssertEqual(GatewayInputMode.from(raw: mode.rawValue), mode)
        }
        XCTAssertEqual(GatewayInputMode.from(raw: "telepathy"), .unknown)
        XCTAssertEqual(GatewayInputMode.from(raw: nil), .unknown)
    }

    func testTheStoredVocabulariesAreFrozenSpellings() {
        // These raw values are written into a CloudKit-mirrored column, so a
        // rename would split one account's history into two vocabularies with
        // no way to reconcile them.
        XCTAssertEqual(GatewayAttemptOutcome.allCases.map(\.rawValue),
                       ["inFlight", "succeeded", "failed", "cancelled", "unknown"])
        XCTAssertEqual(GatewayAttemptOrigin.allCases.map(\.rawValue),
                       ["app", "quickCapture", "menuBar", "share", "watch", "carPlay", "unknown"])
        XCTAssertEqual(GatewayInputMode.allCases.map(\.rawValue),
                       ["text", "voice", "shared", "unknown"])
    }

    // MARK: - Input mode from a sourceDevice tag

    func testInputModeIsDerivedFromTheModalitySuffix() {
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone-voice"), .voice)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone-text"), .text)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "ipad-text"), .text)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "mac-voice"), .voice)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "watch-voice"), .voice)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "watch-text"), .text)
    }

    func testUnsuffixedAndUnrecognisedTagsDeriveUnknown() {
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone"), .unknown,
                       "a legacy turn recorded nothing about how it was typed or spoken")
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "carplay"), .unknown,
                       "CarPlay stamps a bare tag; its lane passes .voice explicitly at dispatch, "
                       + "and this helper is only the retry fallback")
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "mac-hologram"), .unknown)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: ""), .unknown)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "-"), .unknown)
    }

    func testTheSuffixIsTakenAfterTheFIRSTDash() {
        // Same split `MessageRowFormatters.baseDevice` performs, so the device
        // half and the modality half can never disagree about where the tag
        // divides.
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone-voice-extra"), .unknown)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "some-text"), .text)
    }

    func testASharedSuffixIsRecognisedEvenThoughNothingStampsOneToday() {
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone-shared"), .shared,
                       "the share lane passes .shared explicitly; recognising the suffix means a "
                       + "tag that ever carries one lands correctly rather than as unknown")
    }

    // MARK: - Device class from a sourceDevice tag

    func testTheDeviceClassIsDerivedFromTheBaseWord() {
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "iphone-voice"), "iphone")
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "iphone"), "iphone")
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "ipad-text"), "ipad")
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "mac-voice"), "mac")
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "watch-voice"), "watch")
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "carplay"), "carplay",
                       "nothing stamps the column with it, but a legacy turn tag carrying it must "
                       + "land in the CarPlay bucket rather than nowhere")
    }

    func testTheBaseWordIsTakenBeforeTheFIRSTDash() {
        // The same split `GatewayInputMode.from(sourceDevice:)` performs on the
        // other half of the tag, so the two halves can never disagree about
        // where it divides.
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: "mac-voice-extra"), "mac")
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: "-mac"))
    }

    func testAnUnrecognisedOrAbsentTagDerivesNilNotAGuess() {
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: nil))
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: ""))
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: "vision-voice"),
                     "a device this build has never heard of is unattributable, and bucketing it "
                     + "anywhere would put real attempts on hardware they never ran on")
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: "iPhone"),
                     "the stored tag is lower-case; matching loosely here would make the column "
                     + "and the fallback disagree")
        XCTAssertNil(GatewayAttemptDeviceClass.from(sourceDevice: "macbook"))
    }

    func testTheDeviceVocabularyIsFrozenSpellings() {
        // These raw values reach storage and cross device boundaries; a rename
        // orphans every row already written with the old spelling.
        XCTAssertEqual(GatewayAttemptDeviceClass.allCases.map(\.rawValue),
                       ["iphone", "ipad", "mac", "watch", "carplay"])
    }

    // MARK: - Effective outcome

    private func derive(
        stored: GatewayAttemptOutcome,
        startedAt: Date?,
        isLocallyLive: Bool = false
    ) -> GatewayAttemptEffectiveOutcome {
        GatewayAttemptEffectiveOutcome.derive(
            storedOutcome: stored, startedAt: startedAt,
            isLocallyLive: isLocallyLive, now: now, grace: grace)
    }

    func testAStoredTerminalOutcomeIsReportedVerbatim() {
        for outcome in GatewayAttemptOutcome.allCases where outcome != .inFlight {
            XCTAssertEqual(derive(stored: outcome, startedAt: now.addingTimeInterval(-99_999)),
                           .terminal(outcome),
                           "nothing is inferred over a row that already ended")
        }
    }

    func testALiveLocalTaskOutranksTheClock() {
        XCTAssertEqual(
            derive(stored: .inFlight, startedAt: now.addingTimeInterval(-99_999), isLocallyLive: true),
            .inFlight,
            "a background upload can legitimately wait for connectivity far past the grace; the "
            + "live task is direct evidence and the clock is not")
    }

    func testALiveTaskCannotResurrectATerminalRow() {
        XCTAssertEqual(derive(stored: .succeeded, startedAt: now, isLocallyLive: true),
                       .terminal(.succeeded))
    }

    func testAYoungOpenRowIsPending() {
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(-1)), .pending)
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now), .pending)
    }

    func testTheGraceBoundaryIsInclusive() {
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(-grace)),
                       .pending)
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(-grace - 1)),
                       .unconfirmed)
    }

    func testAnOldOpenRowIsUnconfirmedNotUnknown() {
        // `unconfirmed` is a statement about THIS device, and it is derived
        // precisely so that no device writes its own ignorance over another
        // device's live row and races the real success.
        let outcome = derive(stored: .inFlight, startedAt: now.addingTimeInterval(-grace * 10))
        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertNotEqual(outcome, .terminal(.unknown))
        XCTAssertFalse(outcome.isResolved,
                       "unconfirmed stays out of resolved-reliability and token-coverage "
                       + "denominators")
    }

    func testAFutureDatedRowInsideTheGraceIsStillPending() {
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(grace - 1)),
                       .pending,
                       "ordinary multi-device clock drift is absorbed, not punished")
    }

    func testAFutureDatedRowBeyondTheGraceIsUnconfirmed() {
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(grace + 1)),
                       .unconfirmed,
                       "THE CLOCK-SKEW RULE. An elapsed-only test (now - startedAt <= grace) is "
                       + "TRUE for every future-dated row and stays true forever as the interval "
                       + "grows more negative, so such a row would hedge permanently")
        XCTAssertEqual(derive(stored: .inFlight, startedAt: now.addingTimeInterval(grace * 100)),
                       .unconfirmed)
    }

    func testAnOpenRowWithNoStartInstantIsUnconfirmed() {
        XCTAssertEqual(derive(stored: .inFlight, startedAt: nil), .unconfirmed,
                       "a row that cannot say when it began cannot be called young")
    }

    func testOnlyTerminalStatesCountAsResolved() {
        XCTAssertTrue(GatewayAttemptEffectiveOutcome.terminal(.failed).isResolved)
        XCTAssertTrue(GatewayAttemptEffectiveOutcome.terminal(.unknown).isResolved,
                      "a persisted unknown came from a real terminal callback — it is evidence, "
                      + "unlike the derived unconfirmed")
        XCTAssertFalse(GatewayAttemptEffectiveOutcome.inFlight.isResolved)
        XCTAssertFalse(GatewayAttemptEffectiveOutcome.pending.isResolved)
        XCTAssertFalse(GatewayAttemptEffectiveOutcome.unconfirmed.isResolved)
    }

    func testTheRecordConvenienceAgreesWithTheStaticDerivation() {
        let record = Self.record(outcome: .inFlight, startedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(record.effectiveOutcome(isLocallyLive: false, now: now, grace: grace),
                       .pending)
        XCTAssertEqual(record.effectiveOutcome(isLocallyLive: true, now: now, grace: grace),
                       .inFlight)
    }

    // MARK: - Stored snapshot

    func testNewWritesDeclareRecordVersionOne() {
        XCTAssertEqual(GatewayAttemptRecord.currentRecordVersion, 1)
    }

    func testTheReportedColumnsViewBackAsTheParsedMetadata() {
        let record = GatewayAttemptRecord(
            id: UUID(), conversationID: UUID(), userMessageID: UUID(),
            gatewayRef: "openclaw", startedAt: now, completedAt: now.addingTimeInterval(3),
            outcome: .succeeded, reportedModel: "m1", reportedResponseID: "r1",
            finishReason: "stop", reportedInputTokens: 5, reportedOutputTokens: 6,
            reportedTotalTokens: 11, reportedCachedInputTokens: 3,
            reportedCacheWriteInputTokens: 1, reportedReasoningOutputTokens: 4)
        XCTAssertEqual(record.reportedMetadata,
                       GatewayResponseMetadata(reportedModel: "m1", reportedResponseID: "r1",
                                               finishReason: "stop", reportedInputTokens: 5,
                                               reportedOutputTokens: 6, reportedTotalTokens: 11,
                                               reportedCachedInputTokens: 3,
                                               reportedCacheWriteInputTokens: 1,
                                               reportedReasoningOutputTokens: 4))
    }

    /// The KVC keys the snapshot reads are the only thing tying it to the v11
    /// model, and neither half can fail at compile time: a mistyped key reads
    /// nil forever and a mistyped column name is a silent no-op on write. This
    /// writes every column through KVC and reads the whole row back through the
    /// snapshot, so either mistake is a failure here.
    func testEveryColumnRoundTripsThroughTheManagedObjectInitialiser() async throws {
        let container = try await loadCurrentModelInMemory()
        let context = container.newBackgroundContext()

        let attemptID = UUID()
        let conversationID = UUID()
        let userMessageID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let completedAt = startedAt.addingTimeInterval(4.25)

        try await context.perform {
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            row.setValue(attemptID, forKey: "id")
            row.setValue(conversationID, forKey: "conversationID")
            row.setValue(userMessageID, forKey: "userMessageID")
            row.setValue("custom_\(UUID().uuidString)", forKey: "gatewayRef")
            row.setValue(startedAt, forKey: "startedAt")
            row.setValue(completedAt, forKey: "completedAt")
            row.setValue(GatewayAttemptOutcome.failed.rawValue, forKey: "outcome")
            row.setValue(NSNumber(value: Int32(42)), forKey: "appErrorCode")
            row.setValue(GatewayAttemptOrigin.carPlay.rawValue, forKey: "originSurface")
            row.setValue(GatewayInputMode.voice.rawValue, forKey: "inputMode")
            row.setValue("requested/model", forKey: "requestedModel")
            row.setValue("reported/model", forKey: "reportedModel")
            row.setValue("chatcmpl-1", forKey: "reportedResponseID")
            row.setValue("length", forKey: "finishReason")
            row.setValue(NSNumber(value: Int64(11)), forKey: "reportedInputTokens")
            row.setValue(NSNumber(value: Int64(22)), forKey: "reportedOutputTokens")
            row.setValue(NSNumber(value: Int64(33)), forKey: "reportedTotalTokens")
            row.setValue(NSNumber(value: Int64(44)), forKey: "reportedCachedInputTokens")
            row.setValue(NSNumber(value: Int64(55)), forKey: "reportedCacheWriteInputTokens")
            row.setValue(NSNumber(value: Int64(66)), forKey: "reportedReasoningOutputTokens")
            row.setValue(NSNumber(value: Int16(GatewayAttemptRecord.currentRecordVersion)),
                         forKey: "recordVersion")
            row.setValue(GatewayAttemptDeviceClass.iphone.rawValue, forKey: "originDeviceClass")
            row.setValue(NSNumber(value: Int32(2)), forKey: "currentTurnInlineImageCount")
            row.setValue(NSNumber(value: Int32(5)), forKey: "priorTurnInlineImageCount")
            row.setValue(NSNumber(value: Int32(1)), forKey: "currentTurnInlineTextFileCount")
            row.setValue(NSNumber(value: Int32(3)), forKey: "priorTurnInlineTextFileCount")
            try context.save()

            let record = GatewayAttemptRecord(managedObject: row)
            XCTAssertEqual(record.id, attemptID)
            XCTAssertEqual(record.conversationID, conversationID)
            XCTAssertEqual(record.userMessageID, userMessageID)
            XCTAssertEqual(record.startedAt, startedAt)
            XCTAssertEqual(record.completedAt, completedAt)
            XCTAssertEqual(record.outcome, .failed)
            XCTAssertEqual(record.appErrorCode, 42)
            XCTAssertEqual(record.origin, .carPlay)
            XCTAssertEqual(record.inputMode, .voice)
            XCTAssertEqual(record.requestedModel, "requested/model")
            XCTAssertEqual(record.reportedModel, "reported/model")
            XCTAssertEqual(record.reportedResponseID, "chatcmpl-1")
            XCTAssertEqual(record.finishReason, "length")
            XCTAssertEqual(record.reportedInputTokens, 11)
            XCTAssertEqual(record.reportedOutputTokens, 22)
            XCTAssertEqual(record.reportedTotalTokens, 33)
            XCTAssertEqual(record.reportedCachedInputTokens, 44)
            XCTAssertEqual(record.reportedCacheWriteInputTokens, 55)
            XCTAssertEqual(record.reportedReasoningOutputTokens, 66)
            XCTAssertEqual(record.recordVersion, GatewayAttemptRecord.currentRecordVersion)
            XCTAssertEqual(record.originDeviceClass, "iphone")
            XCTAssertEqual(record.currentTurnInlineImageCount, 2)
            XCTAssertEqual(record.priorTurnInlineImageCount, 5)
            XCTAssertEqual(record.currentTurnInlineTextFileCount, 1)
            XCTAssertEqual(record.priorTurnInlineTextFileCount, 3)
            XCTAssertNil(record.fallbackSourceDevice,
                         "it is not a column — only the store's fetch, reading the parent turn, "
                         + "may ever fill it in")
        }
    }

    /// The whole reason the four attachment columns are modelled non-scalar: a
    /// turn measured as carrying nothing and a turn nothing ever measured are
    /// different facts, and every coverage caption in the dashboard is built on
    /// telling them apart.
    func testAnExplicitZeroAttachmentCountIsNotTheSameAsAnUnmeasuredOne() async throws {
        let container = try await loadCurrentModelInMemory()
        let context = container.newBackgroundContext()
        try await context.perform {
            let measured = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            measured.setValue(NSNumber(value: Int32(0)), forKey: "currentTurnInlineImageCount")
            measured.setValue(NSNumber(value: Int32(0)), forKey: "priorTurnInlineImageCount")
            measured.setValue(NSNumber(value: Int32(0)), forKey: "currentTurnInlineTextFileCount")
            measured.setValue(NSNumber(value: Int32(0)), forKey: "priorTurnInlineTextFileCount")

            let legacy = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            try context.save()

            let measuredRecord = GatewayAttemptRecord(managedObject: measured)
            XCTAssertEqual(measuredRecord.currentTurnInlineImageCount, 0)
            XCTAssertEqual(measuredRecord.priorTurnInlineImageCount, 0)
            XCTAssertEqual(measuredRecord.currentTurnInlineTextFileCount, 0)
            XCTAssertEqual(measuredRecord.priorTurnInlineTextFileCount, 0)

            let legacyRecord = GatewayAttemptRecord(managedObject: legacy)
            XCTAssertNil(legacyRecord.currentTurnInlineImageCount,
                         "a row written before anything measured attachments says nothing, and "
                         + "must never be counted as a turn that sent none")
            XCTAssertNil(legacyRecord.priorTurnInlineImageCount)
            XCTAssertNil(legacyRecord.currentTurnInlineTextFileCount)
            XCTAssertNil(legacyRecord.priorTurnInlineTextFileCount)
            XCTAssertNil(legacyRecord.originDeviceClass)
        }
    }

    /// `fallbackSourceDevice` is the one mutable field on the snapshot, and it
    /// exists only so the store can enrich a legacy row at fetch time. Nothing
    /// persists it, so the only property worth locking is that setting it
    /// changes the value and touches nothing else.
    func testTheFallbackSourceDeviceIsSetAfterTheFactAndPersistsNowhere() {
        var record = Self.record(outcome: .succeeded, startedAt: Date())
        XCTAssertNil(record.fallbackSourceDevice)
        record.fallbackSourceDevice = "ipad-voice"
        XCTAssertEqual(GatewayAttemptDeviceClass.from(sourceDevice: record.fallbackSourceDevice),
                       "ipad")
        XCTAssertNil(record.originDeviceClass,
                     "the enrichment never stands in for the stored column; the derivation picks "
                     + "which one to trust")
    }

    /// A half-materialised row — the shape CloudKit can genuinely deliver, with
    /// relationships and columns arriving out of order — must read as a row
    /// that says nothing, never as a row that says zero.
    func testAnEmptyRowReadsAsUnknownWithNoFabricatedZeros() async throws {
        let container = try await loadCurrentModelInMemory()
        let context = container.newBackgroundContext()
        try await context.perform {
            let row = NSEntityDescription.insertNewObject(
                forEntityName: "GatewayAttempt", into: context)
            try context.save()

            let record = GatewayAttemptRecord(managedObject: row)
            XCTAssertNil(record.conversationID)
            XCTAssertNil(record.userMessageID)
            XCTAssertNil(record.gatewayRef)
            XCTAssertNil(record.startedAt)
            XCTAssertNil(record.completedAt)
            XCTAssertEqual(record.outcome, .unknown)
            XCTAssertNil(record.appErrorCode)
            XCTAssertEqual(record.origin, .unknown)
            XCTAssertEqual(record.inputMode, .unknown)
            XCTAssertNil(record.reportedInputTokens,
                         "a non-scalar Integer 64 must read nil, not 0 — coverage percentages are "
                         + "built on exactly that distinction")
            XCTAssertNil(record.reportedTotalTokens)
            XCTAssertNil(record.reportedCachedInputTokens,
                         "a row that predates the token-detail columns says nothing about them, "
                         + "and there is no backfill that could ever make it say zero")
            XCTAssertNil(record.reportedCacheWriteInputTokens)
            XCTAssertNil(record.reportedReasoningOutputTokens)
            XCTAssertNil(record.recordVersion)
            XCTAssertNil(record.originDeviceClass)
            XCTAssertNil(record.currentTurnInlineImageCount,
                         "a non-scalar Integer 32 must read nil, not 0 — the same distinction the "
                         + "token columns depend on")
            XCTAssertNil(record.priorTurnInlineImageCount)
            XCTAssertNil(record.currentTurnInlineTextFileCount)
            XCTAssertNil(record.priorTurnInlineTextFileCount)
            XCTAssertNil(record.fallbackSourceDevice)
            XCTAssertEqual(record.effectiveOutcome(isLocallyLive: false, now: Date()), .unconfirmed)
        }
    }

    // MARK: - Helpers

    private static func record(
        outcome: GatewayAttemptOutcome,
        startedAt: Date?
    ) -> GatewayAttemptRecord {
        GatewayAttemptRecord(
            id: UUID(), conversationID: UUID(), userMessageID: UUID(), gatewayRef: "openclaw",
            startedAt: startedAt, completedAt: nil, outcome: outcome)
    }

    /// The CURRENT compiled model, in memory. Deliberately not
    /// `ConversationStore(inMemory:)` — this test needs a raw context so it can
    /// write columns through KVC exactly the way the store's extension will.
    private func loadCurrentModelInMemory() async throws -> NSPersistentContainer {
        let bundles = [Bundle.main, Bundle(for: Self.self)]
        let momd = try XCTUnwrap(
            bundles.compactMap { $0.url(forResource: "Conversations", withExtension: "momd") }.first,
            "compiled Conversations.momd not found in the host app bundle")
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: momd),
                                  "the momd resolves to the CURRENT model version")
        let container = NSPersistentContainer(name: "Conversations", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.url = URL(fileURLWithPath: "/dev/null")
        container.persistentStoreDescriptions = [description]
        let loaded = expectation(description: "store loads")
        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 15)
        if let loadError { throw loadError }
        return container
    }
}
