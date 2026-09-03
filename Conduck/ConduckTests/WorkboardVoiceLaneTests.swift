// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardVoiceLaneTests.swift
//
// The Shortcuts / Action-Button lane that lands a Work voice capture, and the
// identities a capture needs beyond its own.
//
// One capture can produce three cards, and the whole subject here is that they
// are three IDENTITIES. The recording is named by the capture id; a screenshot
// and a note-shaped fallback are named by ids DERIVED from it. A material id
// names ONE card, so an artifact published at the recording's id is a
// COLLISION: the counterfactuals below measure the desk refusing it outright,
// which leaves the screenshot and the recovered words with nowhere to go on
// every attempt. A capture may not lean on that refusal — it is the last line,
// not the plan.
//
// The intent's own ordering cannot be driven from this suite: `perform()` takes
// an `IntentFile` the Shortcuts runtime supplies and drives a live `STTClient`
// upload. What is untestable there is WHERE a statement sits, so that is what
// the source rules assert — and they are a VALUE (`WorkVoiceIntentLaneRule`)
// evaluated by one predicate, run against the live source and against fixtures
// that each break exactly one rule. A control that re-implements the check it
// controls proves nothing about the check.
//
// The desk decision a recovered capture faces is NOT asserted here any more.
// It moved into `WorkVoiceCaptureCoordinator.recover`, where it is driven
// behaviourally against a real store by `WorkVoiceRecoveryTests`; what is left
// at the two retry surfaces is a call-site policy, guarded in
// `WorkboardAudioCaptureTests`.

import XCTest
@testable import Conduck

/// The rules the Shortcuts Work lane's `perform()` has to satisfy, named so a
/// failure says which one broke rather than which string moved.
enum WorkVoiceIntentLaneRule: String, CaseIterable {
    /// The card is attempted with the recording ALREADY preserved, so a store
    /// that refuses costs the card and never the bytes.
    case armedBeforeThePublication
    /// The card must hold the bytes the transcription was made from.
    case compressedBeforeThePublication
    /// A key that cannot be read is a transcription failure, and such a failure
    /// has to leave a playable card behind.
    case publishedBeforeTheKeyVerdict
    /// Publishing after the upload is the defect: an OS kill, an outage or an
    /// abandoned request between the two loses the recording entirely.
    case publishedBeforeTheUpload
    /// The recovery writes onto the card phase one made; reversed, onto nothing.
    case publishedBeforeTheRecovery
    /// One capture, one identity — minted once, before anything durable exists.
    case oneCaptureIdentity
    /// Compressed once: a second pass is a second payload, and only one of them
    /// can be on the card.
    case oneCompressionPass
    /// Every payload this lane hands to something durable is the ONE compressed
    /// copy — the preserved retry copy, the desk card and the recovery record
    /// at least — and never a second set of bytes beside them. Preserving the
    /// Shortcut's original while carding the compressed one gives a retry that
    /// transcribes a payload the card does not hold.
    case onePayloadForEveryUse
    /// Chat retains no audio, so its upload stays the Shortcut's own recording.
    case chatKeepsItsOwnRecording
    /// A publication the desk REFUSED is written into the retry record. Without
    /// it a later recovery cannot tell bytes that never reached the desk from a
    /// card a person deleted, and the two call for opposite acts.
    case aRefusedPublicationIsRecorded
    /// The recovery is handed the capture's OWN record — its metadata and its
    /// payload — not a fresh one that names nothing.
    case theRecoveryCarriesTheCapturesRecord
    /// The durable record is released only on an outcome that says a card holds
    /// the words. Disarming on the mere absence of an error deletes the audio
    /// whenever the desk answered "not yet".
    case releasedOnlyOnATerminalOutcome
}

/// One predicate for every rule, over a comment-stripped function body.
///
/// A MISSING anchor is a violation, never a silent pass: "the lane no longer
/// publishes a recording at all" is precisely the shape these rules exist to
/// refuse, and an ordering comparison that cannot find its operands would
/// otherwise report it as compliant.
enum WorkVoiceIntentLaneValidator {

    private static let publish = "WorkVoiceCaptureCoordinator.publishRecording("
    private static let recover = "WorkVoiceCaptureCoordinator.recover("

    static func violations(in body: String) -> Set<WorkVoiceIntentLaneRule> {
        var found: Set<WorkVoiceIntentLaneRule> = []

        func at(_ token: String) -> String.Index? { body.range(of: token)?.lowerBound }

        func require(_ earlier: String, before later: String, _ rule: WorkVoiceIntentLaneRule) {
            guard let first = at(earlier), let second = at(later), first < second else {
                found.insert(rule)
                return
            }
        }

        func require(_ token: String, appears count: Int, _ rule: WorkVoiceIntentLaneRule) {
            if body.components(separatedBy: token).count - 1 != count { found.insert(rule) }
        }

        require("PendingRetryGuard.arm", before: publish, .armedBeforeThePublication)
        require("Self.compressForWork(", before: publish, .compressedBeforeThePublication)
        require(publish, before: "STTKeyReadiness.resolve", .publishedBeforeTheKeyVerdict)
        require(publish, before: "STTClient.shared.transcribe", .publishedBeforeTheUpload)
        require(publish, before: recover, .publishedBeforeTheRecovery)

        require("let captureID = UUID()", appears: 1, .oneCaptureIdentity)
        require("Self.compressForWork(", appears: 1, .oneCompressionPass)

        // Counted rather than fixed at a number: the lane may hand the one
        // payload to further durable writes over time, and it may never hand a
        // different one to any of them. Three is the floor a capture cannot do
        // without — the retry copy, the card, the record it is recovered from.
        //
        // Two labels, one handoff: `audio:` is what the guard and the desk
        // publication take, `audioData:` what a queue ENTRY takes. The rule is
        // about which bytes are handed over, never about which label carries
        // them, so a lane that packages its record differently is not thereby
        // exempt from it.
        let payloads = ["audio: ", "audioData: "].flatMap {
            body.components(separatedBy: $0).dropFirst()
        }
        if payloads.count < 3 || payloads.contains(where: { !$0.hasPrefix("uploadData") }) {
            found.insert(.onePayloadForEveryUse)
        }

        if !body.contains(".phaseOneFailed") { found.insert(.aRefusedPublicationIsRecorded) }

        // Read off the RECOVERY's own first argument rather than off a type
        // name: whatever wraps the capture — a record, a claim over its queue
        // entry — the value handed over has to be built from THIS capture's
        // metadata and THIS capture's bytes. Built inline at the call, or bound
        // just above it; both are read the same way. Naming the wrapper here is
        // how a rule about which VALUE is carried turns into a rule about a
        // type, which the next refactor renames out from under it.
        let handed = firstArgument(of: recover, in: body)
        let carried = handed.flatMap { $0.contains("(") ? $0 : binding(of: $0, in: body) }
        if carried?.contains("pendingMetadata") != true
            || carried?.contains("uploadData") != true {
            found.insert(.theRecoveryCarriesTheCapturesRecord)
        }

        if let recovered = body.range(of: recover)?.upperBound,
           let disarm = body.range(of: "PendingRetryGuard.disarm",
                                   range: recovered..<body.endIndex)?.lowerBound {
            if !body[recovered..<disarm].contains("isTerminal") {
                found.insert(.releasedOnlyOnATerminalOutcome)
            }
        } else {
            found.insert(.releasedOnlyOnATerminalOutcome)
        }

        if let branches = RefusalLaneSource.branches(ofIf: "if destination == .work {", in: body) {
            let chatKeepsItsOwn = branches.then.contains("Self.compressForWork(")
                && branches.else.contains("uploadData = originalAudioData")
                && !branches.else.contains("compressForWork")
                && branches.else.contains("audioFileExtension = \"m4a\"")
            if !chatKeepsItsOwn { found.insert(.chatKeepsItsOwnRecording) }
        } else {
            found.insert(.chatKeepsItsOwnRecording)
        }

        return found
    }

    /// The first argument of `call`, trimmed — the text up to the first comma
    /// that is not inside a nested call.
    static func firstArgument(of call: String, in body: String) -> String? {
        guard let args = arguments(of: call, in: body) else { return nil }
        var depth = 0
        var index = args.startIndex
        while index < args.endIndex {
            let character = args[index]
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            if character == ",", depth == 0 { break }
            index = args.index(after: index)
        }
        return String(args[args.startIndex..<index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The right-hand side of `let <name> = …`, to the end of the call it
    /// builds. Nil when nothing binds that name, which the caller reports as a
    /// violation rather than passing silently.
    static func binding(of name: String, in body: String) -> String? {
        guard let assignment = body.range(of: "let \(name) = ") else { return nil }
        let rest = body[assignment.upperBound...]
        guard let opening = rest.firstIndex(of: "(") else {
            return String(rest.prefix { !$0.isNewline })
        }
        var index = rest.index(after: opening)
        var depth = 1
        while index < rest.endIndex, depth > 0 {
            if rest[index] == "(" { depth += 1 }
            if rest[index] == ")" { depth -= 1 }
            index = rest.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(rest[rest.startIndex..<index])
    }

    /// The paren-matched argument text of `call` (which must end in its `(`).
    /// Nil when the call is absent or the parentheses do not balance — both of
    /// which the callers report as a violation rather than passing silently.
    static func arguments(of call: String, in body: String) -> String? {
        guard let opening = body.range(of: call) else { return nil }
        var index = opening.upperBound
        let start = index
        var depth = 1
        while index < body.endIndex, depth > 0 {
            if body[index] == "(" { depth += 1 }
            if body[index] == ")" { depth -= 1 }
            index = body.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(body[start..<body.index(before: index)])
    }
}

final class WorkboardVoiceLaneTests: XCTestCase {

    private static let intentPath = "Conduck/Intents/ConverseIntent.swift"
    private static let contentViewPath = "Conduck/ContentView.swift"
    private static let dictationPath = "Conduck/MenuBar/DictationService.swift"
    private static let sttClientPath = "Conduck/Services/STTClient.swift"

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-voice-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The Shortcuts lane, against the rules themselves

    /// The lane the finding is about: a Shortcut or Action-Button capture bound
    /// to Work used to reach the desk only AFTER speech recognition returned, so
    /// every way that hop can fail took the recording with it — and when phase
    /// one failed, the words landed as a note while the retry that held the
    /// only copy of the audio was disarmed.
    func testTheShortcutsLaneSatisfiesEveryRuleOfTheWorkVoiceLane() throws {
        let violations = WorkVoiceIntentLaneValidator.violations(in: try Self.performBody())
        XCTAssertEqual(
            violations.map(\.rawValue).sorted(), [],
            "`ConverseIntent.perform()` breaks the Work voice lane's rules named above. Each one is "
            + "documented on its case in `WorkVoiceIntentLaneRule`."
        )
    }

    /// Rule 0, and the whole reason the rules are a value: the SAME predicate
    /// that reads the live source is run against a compliant fixture and
    /// against one mutation per rule, so no rule is an assertion nobody has
    /// seen bite — and none of them is satisfied by a fixture that only looks
    /// compliant.
    func testTheIntentLaneValidatorRefusesEveryShapeItExistsToRefuse() {
        XCTAssertEqual(
            WorkVoiceIntentLaneValidator.violations(in: Self.compliantIntentBody).map(\.rawValue).sorted(),
            [],
            "Control: the compliant shape must pass every rule, or the rules are unsatisfiable and "
            + "the live-source check above is failing for the wrong reason."
        )

        for (rule, broken) in Self.brokenIntentBodies {
            XCTAssertEqual(
                WorkVoiceIntentLaneValidator.violations(in: broken).map(\.rawValue).sorted(),
                [rule.rawValue],
                "Control: the fixture written to break \(rule.rawValue) must break that rule and "
                + "only that rule."
            )
        }

        // …and the shape this round replaced — a lane that reached the desk
        // through `attachTranscript` with no publication verdict recorded —
        // fails on the three rules that carry the fix.
        let shipped = Self.compliantIntentBody
            .replacingOccurrences(of: Self.recordChunk, with: "")
            .replacingOccurrences(
                of: Self.recoverChunk,
                with: """
                switch try await WorkVoiceCaptureCoordinator.attachTranscript(transcript, toRecording: captureID) {
                case .attached: break
                case .recordingMissing, .notAudio:
                    _ = try await WorkCaptureRetryCoordinator.publish(transcript: transcript)
                }
                await PendingRetryGuard.disarm(guardToken)
                """
            )
            .replacingOccurrences(of: "workPublicationState = .phaseOneFailed", with: "")
        XCTAssertEqual(
            WorkVoiceIntentLaneValidator.violations(in: shipped).map(\.rawValue).sorted(),
            [
                WorkVoiceIntentLaneRule.aRefusedPublicationIsRecorded,
                .onePayloadForEveryUse,
                .publishedBeforeTheRecovery,
                .releasedOnlyOnATerminalOutcome,
                .theRecoveryCarriesTheCapturesRecord,
            ].map(\.rawValue).sorted(),
            "Control: the shape that shipped really did decide for itself, record no verdict, and "
            + "disarm on the absence of an error."
        )
    }

    /// The file-level half of `oneCompressionPass`: the rule reads one function,
    /// and a second compressor call anywhere else in the intent would give the
    /// lane a payload the card does not hold.
    func testOnlyOneSiteInTheWholeIntentReachesTheCompressor() throws {
        XCTAssertEqual(
            RefusalLaneSource.stripComments(try Self.source(Self.intentPath))
                .components(separatedBy: "AudioCompressor.compress").count - 1, 1,
            "exactly one site in the whole intent reaches the compressor"
        )
    }

    // MARK: - The screenshot's own identity

    /// The capture id names the recording, so the screenshot cannot have it. The
    /// derivation is deterministic (a replay repairs one card rather than adding
    /// a second), differs per capture, and lands in neither of the other two
    /// identities this capture can need.
    func testTheScreenshotTakesAnIdentityOfItsOwn() {
        let captureID = UUID()
        let screenshotID = WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID)

        XCTAssertNotEqual(screenshotID, captureID,
                          "the recording already stands at the capture id")
        XCTAssertNotEqual(screenshotID,
                          WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID),
                          "…and the note-shaped fallback of the same capture stands at its own")
        XCTAssertEqual(screenshotID,
                       WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID),
                       "deterministic, so a replayed capture repairs the same card")
        XCTAssertNotEqual(screenshotID,
                          WorkVoiceScreenshotCoordinator.materialID(forCapture: UUID()),
                          "…and two captures do not share one screenshot card")
    }

    /// End to end: a capture that carries both artifacts leaves TWO cards, and
    /// the recording's bytes are untouched by the picture's arrival.
    func testTheScreenshotBecomesASecondCardBesideTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID()
        let recording = Self.recordingBytes
        _ = try await Self.publishRecording(captureID: captureID, audio: recording, in: store)

        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let published = try await WorkVoiceScreenshotCoordinator.publish(
            Data("the shortcut's raw screenshot".utf8),
            forCapture: captureID,
            createdAt: Date(),
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            normalize: { _ in picture }
        )
        let screenshotID = try XCTUnwrap(published, "the screenshot published nothing")

        XCTAssertEqual(screenshotID, WorkVoiceScreenshotCoordinator.materialID(forCapture: captureID))
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, screenshotID],
                       "one capture, two cards")

        let card = try XCTUnwrap(desk.materials.first { $0.id == captureID })
        XCTAssertEqual(card.kind, .audio, "the recording is still a recording")
        let recordingPayload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(recordingPayload, recording, "and still holds the bytes that were spoken")

        let image = try XCTUnwrap(desk.materials.first { $0.id == screenshotID })
        XCTAssertEqual(image.kind, .image)
        let imagePayload = try await store.loadWorkMaterialPayload(id: screenshotID)
        XCTAssertEqual(imagePayload, picture)
    }

    /// Every surface that can recover this capture publishes the screenshot, so
    /// publishing it twice has to repair rather than duplicate.
    func testAScreenshotPublishedTwiceRepairsTheSameCard() async throws {
        let store = ConversationStore(inMemory: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID()
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

        let first = try await Self.publishScreenshot(picture, for: captureID, inbox: inbox, store: store)
        let second = try await Self.publishScreenshot(picture, for: captureID, inbox: inbox, store: store)

        XCTAssertEqual(first, second)
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "one picture, however many surfaces recovered it")
    }

    /// The counterfactual the derived id exists for, MEASURED rather than
    /// argued. Publishing the screenshot at the capture's own id is a COLLISION:
    /// a material id names one card, so the desk refuses it outright and the
    /// picture reaches nothing — a capture that used this identity would fail
    /// its screenshot on every attempt, and would have done far worse before the
    /// desk learned to refuse it.
    func testAScreenshotPublishedAtTheCaptureIdIsRefusedRatherThanBecomingTheRecording() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        let recording = Self.recordingBytes
        _ = try await Self.publishRecording(captureID: captureID, audio: recording, in: store)

        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: captureID,
                    kind: .image,
                    title: "screenshot.jpg",
                    filename: "screenshot.jpg",
                    mimeType: "image/jpeg",
                    payload: picture,
                    byteSize: Int64(picture.count)
                )
            )
            XCTFail("a picture at the recording's own id must not be written")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // The id already names a card of another kind.
        }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 1, "no second card — the id was already taken")
        XCTAssertEqual(desk.materials.first?.kind, .audio, "and the card there is still the recording")
        let stored = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(
            stored, recording,
            """
            MEASURED: the recording keeps its own bytes because the collision was REFUSED. The \
            refusal is what stands between this identity and the picture, which is the state \
            `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` exists to make unreachable — \
            a capture cannot rely on a store's refusal to publish its own artifacts correctly.
            """
        )
        XCTAssertNotEqual(stored, picture)
    }

    // MARK: - The fallback note's own identity

    /// The other half of the same defect. When a capture owns no recording card
    /// the recovered words are published note-shaped — and at the capture's own
    /// id that publication collides with whatever already stands there and is
    /// refused, so the words reach nothing and no retry of it can ever land
    /// them.
    func testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishingIntoIt() async throws {
        let store = ConversationStore(inMemory: true)
        let captureID = UUID()
        _ = try await Self.publishRecording(captureID: captureID, audio: Self.recordingBytes, in: store)
        let words = "Ferry leaves at 07:30"

        // The shape the finding names: the fallback minted at the capture id.
        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: captureID,
                    kind: .note,
                    title: "Voice capture",
                    textContent: words,
                    storageMode: .metadataOnly
                )
            )
            XCTFail("a note at the recording's own id must not be written")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // MEASURED: the desk refuses an id that already names a recording.
        }
        let deskAfterCollision = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let collided = try XCTUnwrap(
            deskAfterCollision?.materials.first { $0.id == captureID }
        )
        XCTAssertEqual(collided.kind, .audio,
                       "MEASURED: the recording standing there is untouched")
        XCTAssertNil(collided.textContent, "…and the recovered words are written nowhere at all")

        // The shape it takes now.
        let noteID = WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: captureID)
        XCTAssertNotEqual(noteID, captureID)
        let note = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: noteID,
                kind: .note,
                title: "Voice capture",
                textContent: words,
                storageMode: .metadataOnly
            )
        )
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.textContent, words)

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(Set(desk.materials.map(\.id)), [captureID, noteID],
                       "the words stand beside the recording instead of inside it")
        let recordingPayload = try await store.loadWorkMaterialPayload(id: captureID)
        XCTAssertEqual(recordingPayload, Self.recordingBytes,
                       "and a metadata-only note carries no bytes that could disturb the recording")
    }

    // MARK: - A recovered recording is described by what it actually is

    /// Both capture lanes preserve COMPRESSED bytes, and `AudioCompressor`
    /// answers WAV whenever AAC encoding fails — so the container a retry holds
    /// is not knowable from the lane it came from, only from the bytes.
    ///
    /// The helper is the single source of that truth, and the two surfaces are
    /// held to using it rather than to a name: a `.m4a` file carrying RIFF tells
    /// a provider something untrue about its own input, and the stricter ones
    /// refuse it outright — every retry of that capture, forever.
    func testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer() throws {
        XCTAssertEqual(PendingRetryAudioFile.extension(for: Self.wavBytes), "wav")
        XCTAssertEqual(PendingRetryAudioFile.extension(for: Self.m4aBytes), "m4a")
        XCTAssertEqual(PendingRetryAudioFile.extension(for: Self.recordingBytes), "m4a",
                       "unrecognised bytes keep the recorders' native container")

        // Anchored on the STAGING itself, not on the function that happens to
        // contain it: a surface may split its retry across a claim step and an
        // attempt step, and the rule — every recovered file this surface writes
        // is named from the bytes it holds — is a property of the staging, not
        // of a function name. Matched on the argument rather than on the
        // variable's, for the same reason.
        for path in Self.retrySurfaces {
            let text = RefusalLaneSource.stripComments(try Self.source(path))
            let stagings = Self.ranges(of: "conduck_retry_", in: text)
            XCTAssertFalse(
                stagings.isEmpty,
                "\(path) no longer stages the recovered bytes for the upload at all."
            )
            for staging in stagings {
                let expression = String(text[staging.lowerBound...].prefix(240))
                XCTAssertNotNil(
                    expression.range(
                        of: #"PendingRetryAudioFile\.extension\(for: [A-Za-z0-9_.]*audioData\)"#,
                        options: .regularExpression
                    ),
                    "\(path) names a staged file without reading the bytes it holds."
                )
            }
            XCTAssertNil(
                text.range(of: "conduck_retry_\\(UUID().uuidString).m4a"),
                "\(path) still hard-codes `.m4a` for whatever container it recovered."
            )
        }
    }

    /// …and the same truth has to reach the wire, or the staged file is
    /// corrected while the part that providers actually parse still claims
    /// MPEG-4. The upload's claim about its payload comes FROM the payload.
    func testTheMultipartAudioPartDescribesTheBytesItCarries() async {
        for (bytes, mime, filename) in [
            (Self.wavBytes, "audio/wav", "audio.wav"),
            (Self.m4aBytes, "audio/mp4", "audio.m4a"),
            (Self.cafBytes, "audio/x-caf", "audio.caf"),
            (Self.recordingBytes, "audio/mp4", "audio.m4a"),
        ] {
            let part = await STTClient.multipartAudioPart(for: bytes)
            XCTAssertEqual(part.mime, mime)
            XCTAssertEqual(part.filename, filename)

            let (_, body) = STTMultipartBuilder.build(
                audioData: bytes,
                audioMIME: part.mime,
                audioFilename: part.filename,
                model: "whisper-1",
                language: nil,
                fieldNames: .openAICompat
            )
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("filename=\"\(filename)\""), "filename for \(mime)")
            XCTAssertTrue(text.contains("Content-Type: \(mime)"), "part MIME for \(mime)")
        }
    }

    /// …and the multipart branch has to actually ASK. `transcribe` needs a
    /// provider on the other end, so the one thing left unreachable — that the
    /// request is built from the answer above rather than from two literals —
    /// is asserted where it is written.
    func testTheUploadBuildsItsAudioPartFromThatAnswer() throws {
        let body = try Self.functionBody("transcribe", in: Self.sttClientPath)
        XCTAssertTrue(
            body.contains("Self.multipartAudioPart(for: audioData)"),
            "`transcribe` no longer reads the container off the bytes it is about to send."
        )
        XCTAssertNil(body.range(of: "audioMIME: \"audio/mp4\""),
                     "the audio part still hard-codes MPEG-4 for whatever it was handed")
        XCTAssertNil(body.range(of: "audioFilename: \"audio.m4a\""),
                     "…and still names it `.m4a`")
    }

    // MARK: - Fixtures

    /// The two surfaces that recover a parked Work capture.
    private static let retrySurfaces = [contentViewPath, dictationPath]

    /// Every range at which `needle` occurs, so a rule can be asserted at each
    /// site rather than once for the file.
    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// Stands in for a compressed 16 kHz mono AAC voice note: small, so the
    /// storage policy picks the synced lane exactly as it does in the app.
    private static let recordingBytes = Data(repeating: 0x5A, count: 4_096)

    /// RIFF/WAVE header — what `AudioCompressor` returns when AAC encoding
    /// fails, and the container a `.m4a` name misdescribes.
    private static let wavBytes = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)

    /// ISO-BMFF `ftyp` box tag at bytes 4..<8 — the recorders' native container.
    private static let m4aBytes = Data([0, 0, 0, 0x18]) + Data("ftypM4A ".utf8)

    /// CarPlay's PCM tap file.
    private static let cafBytes = Data("caff\u{0}\u{1}\u{0}\u{0}".utf8)

    @discardableResult
    private static func publishRecording(
        captureID: UUID,
        audio: Data,
        in store: ConversationStore
    ) async throws -> WorkMaterialRecord {
        try await WorkVoiceCaptureCoordinator.publishRecording(
            captureID: captureID,
            audio: audio,
            fileExtension: "m4a",
            mimeType: "audio/mp4",
            store: store
        )
    }

    private static func publishScreenshot(
        _ jpeg: Data,
        for captureID: UUID,
        inbox: WorkCaptureInbox,
        store: ConversationStore
    ) async throws -> UUID? {
        try await WorkVoiceScreenshotCoordinator.publish(
            Data("the shortcut's raw screenshot".utf8),
            forCapture: captureID,
            createdAt: Date(),
            inbox: inbox,
            store: store,
            sourceDevice: "test-device",
            normalize: { _ in jpeg }
        )
    }

    private static func performBody() throws -> String {
        try functionBody("perform", in: intentPath)
    }

    /// One function's body, comment-stripped. Both halves matter: scoping to the
    /// function keeps an unrelated statement elsewhere in a 1,600-line view from
    /// satisfying an ordering check, and stripping comments keeps a header that
    /// DESCRIBES the rule from standing in for code that does it.
    private static func functionBody(_ name: String, in path: String) throws -> String {
        let source = RefusalLaneSource.stripComments(try self.source(path))
        return try RefusalLaneSource.body(ofFunction: name, in: source, path: path)
    }

    /// `.../Conduck/Conduck` — the project container holding the app sources.
    /// Derived from this file's compile-time path so the source guards do not
    /// depend on the test runner's working directory.
    private static func source(_ relativePath: String) throws -> String {
        let container = URL(fileURLWithPath: #filePath)  // .../ConduckTests/<this>
            .deletingLastPathComponent()                 // .../ConduckTests
            .deletingLastPathComponent()                 // .../Conduck/Conduck
        return try String(
            contentsOf: container.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Fixtures the validator is controlled against

    /// A miniature of the compliant lane, assembled from named chunks so each
    /// mutation below is one swap rather than a second hand-written body that
    /// could drift from this one.
    private static let payloadChunk = """
    let uploadData: Data
    if destination == .work {
        let compression = await Self.compressForWork(originalAudioData)
        uploadData = compression.data
    } else {
        uploadData = originalAudioData
        audioFileExtension = "m4a"
    }
    """

    private static let identityChunk = "let captureID = UUID()"

    private static let metadataChunk =
        "let pendingMetadata = PendingRetryMetadata(id: captureID, destination: retryDestination)"

    private static let armChunk =
        "let guardToken = await PendingRetryGuard.arm(audio: uploadData, metadata: pendingMetadata)"

    private static let publishChunk = """
    var workPublicationState: PendingRetryPublicationState?
    if destination == .work, let workAudioMIMEType {
        do {
            _ = try await WorkVoiceCaptureCoordinator.publishRecording(captureID: captureID, audio: uploadData)
            workPublicationState = .published
        } catch {
            workPublicationState = .phaseOneFailed
        }
    }
    """

    private static let keyChunk = "let keyReadiness = await STTKeyReadiness.resolve(presetID: snapshot.presetID)"

    private static let uploadChunk = "let response = try await STTClient.shared.transcribe(audioFileURL: audioFileURL)"

    private static let flagChunk = "transcriptCaptured = true"

    private static let recordChunk = """
    let record = Self.heldCapture(
        Self.stamped(pendingMetadata, publicationState: workPublicationState),
        audio: uploadData,
        reservation: guardToken
    )
    """

    private static let recoverChunk = """
    let outcome = try await WorkVoiceCaptureCoordinator.recover(record, transcript: transcript)
    if await outcome.isTerminal {
        await PendingRetryGuard.disarm(guardToken)
    }
    """

    private static var compliantIntentBody: String {
        [payloadChunk, identityChunk, metadataChunk, armChunk, publishChunk,
         keyChunk, uploadChunk, flagChunk, recordChunk, recoverChunk].joined(separator: "\n")
    }

    /// One fixture per rule, each breaking exactly that rule.
    private static var brokenIntentBodies: [(WorkVoiceIntentLaneRule, String)] {
        [
            (.armedBeforeThePublication,
             [payloadChunk, identityChunk, metadataChunk, publishChunk, armChunk,
              keyChunk, uploadChunk, flagChunk, recordChunk, recoverChunk].joined(separator: "\n")),

            (.compressedBeforeThePublication,
             [identityChunk, metadataChunk, armChunk, publishChunk, payloadChunk,
              keyChunk, uploadChunk, flagChunk, recordChunk, recoverChunk].joined(separator: "\n")),

            (.publishedBeforeTheKeyVerdict,
             [payloadChunk, identityChunk, metadataChunk, armChunk, keyChunk, publishChunk,
              uploadChunk, flagChunk, recordChunk, recoverChunk].joined(separator: "\n")),

            (.publishedBeforeTheUpload,
             [payloadChunk, identityChunk, metadataChunk, armChunk, uploadChunk, publishChunk,
              keyChunk, flagChunk, recordChunk, recoverChunk].joined(separator: "\n")),

            // The publication stays above the key verdict and the upload — only
            // the recovery moves above IT, so exactly one rule breaks.
            (.publishedBeforeTheRecovery,
             [payloadChunk, identityChunk, metadataChunk, armChunk, recordChunk, recoverChunk,
              publishChunk, keyChunk, uploadChunk, flagChunk].joined(separator: "\n")),

            (.oneCaptureIdentity,
             compliantIntentBody.replacingOccurrences(
                of: identityChunk, with: identityChunk + "\n" + identityChunk)),

            (.oneCompressionPass,
             compliantIntentBody + "\nlet again = await Self.compressForWork(originalAudioData)"),

            (.onePayloadForEveryUse,
             compliantIntentBody.replacingOccurrences(
                of: armChunk,
                with: "let guardToken = await PendingRetryGuard.arm(audio: originalAudioData, "
                    + "metadata: pendingMetadata)")),

            (.chatKeepsItsOwnRecording,
             compliantIntentBody.replacingOccurrences(
                of: "uploadData = originalAudioData", with: "uploadData = Data()")),

            (.aRefusedPublicationIsRecorded,
             compliantIntentBody.replacingOccurrences(
                of: "workPublicationState = .phaseOneFailed",
                with: "Self.log.error(\"not published\")")),

            (.theRecoveryCarriesTheCapturesRecord,
             compliantIntentBody.replacingOccurrences(
                of: "Self.stamped(pendingMetadata, publicationState: workPublicationState),",
                with: "PendingRetryMetadata(id: UUID(), destination: .work),")),

            (.releasedOnlyOnATerminalOutcome,
             compliantIntentBody.replacingOccurrences(
                of: recoverChunk,
                with: """
                let outcome = try await WorkVoiceCaptureCoordinator.recover(record, transcript: transcript)
                await PendingRetryGuard.disarm(guardToken)
                """)),
        ]
    }
}
