// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkVoicePublicationProhibitionTests.swift
//
// PROHIBITION GUARD: no voice lane may put a RECORDING on the Work desk, read
// from the app's own sources on disk.
//
// The rule is the founder's, and it is a privacy rule before it is a storage
// one: the words are the artifact. A `.audio` desk card owns its bytes, a
// compressed voice note is far below `Constants.workboardSyncCeilingBytes`, and
// a card below the ceiling rides the person's private CloudKit as a blob — so
// every voice capture that published one made a permanent, syncing copy of
// somebody's voice out of a step that only ever existed to reach a transcript.
//
// Five lanes could do it — the Shortcut, the in-app sheet, the macOS menu bar,
// CarPlay and the wrist relay — and all five now park the recording in the
// device-local retry queue, transcribe, publish the WORDS, and delete the audio.
// That is a rule about ORDER, and order is invisible in a diff: a lane that
// publishes its bytes first still compiles, still passes its own tests, and
// still looks like every other capture surface. This guard is the cheap half —
// the token can simply never appear on the voice path — and the behavioural half
// lives in `WorkboardAudioCaptureTests`, `WorkVoiceTranscriptPublicationTests`
// and each lane's own suite.
//
// ONE PRODUCTION SITE may still build an `.audio` draft:
// `WorkboardLiveRepository`'s import, which is where a file a person attaches in
// Work — through the chat-bar paperclip or a drop onto the pane — becomes a
// playable card. That door is deliberate, it is the only way an audio file is
// kept at all, and nothing about it transcribes anything.
//
// The scan reads squeezed, comment-stripped source, so a multi-line call and a
// one-line call read the same and a header that DESCRIBES the old order cannot
// stand in for it — which matters here more than anywhere, because every file on
// this list discusses the rule at length. `RefusalLaneSource.stripComments` does
// not model string literals; a `//` inside a literal would drop the rest of that
// line, so the one direction this guard can miss in is a false pass on a
// publication written after such a literal on the same line.

import XCTest

final class WorkVoicePublicationProhibitionTests: XCTestCase {

    // MARK: - The rule's addresses

    /// The app target's source root, relative to the project container.
    private static let appTargetDirectory = "Conduck"

    /// The ONE production file that may build a `WorkMaterialDraft` with
    /// `kind: .audio`: the desk's own import, reached by the paperclip and the
    /// drop and by nothing else.
    private static let importDoor = "Conduck/Services/Workboard/WorkboardLiveRepository.swift"

    /// Files that are reached only by walking a directory, because a new file
    /// added beside them is exactly the drift this guard exists to catch: a
    /// sixth voice lane, or a second CarPlay recording service.
    private static let voiceLaneDirectories = [
        "Conduck/Intents",
        "Conduck/CarPlay",
        "Conduck/MenuBar"
    ]

    /// The named files on the voice path. Each is one of the five lanes, the
    /// seam they all write through, or a surface that recovers a parked capture.
    private static let voiceLaneFiles = [
        "Conduck/ContentView.swift",
        "Conduck/Services/InAppAudioRecorder.swift",
        "Conduck/Services/AppleSpeechRelayCoordinator.swift",
        "Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift",
        "Conduck/Services/Workboard/WorkCaptureDrainer.swift"
    ]

    /// The chat-capture path, scoped to its own function. Its file is the desk's
    /// write door and names `.audio` legitimately elsewhere — a folded card's
    /// delete accepts an `.audio` child, for one — so the whole file cannot be
    /// on the list above without saying something the rule does not mean.
    private static let chatCapturePath = "Conduck/Services/ConversationStore+Workboard.swift"

    private static let chatCaptureFunction = "captureMessageToWork"

    /// The draft the desk is written with. A `kind:` argument inside one of
    /// these is the thing being prohibited; the same argument label anywhere
    /// else describes something that is not a desk card.
    private static let draftInitializer = "WorkMaterialDraft("

    /// The kind no voice lane may ask for.
    private static let audioKind = "kind:.audio"

    /// The retired phase-one publication. It has no declaration left anywhere,
    /// so a call to it cannot compile — the token is here to stop the SHAPE from
    /// coming back under its old name, which is the form this mistake took.
    private static let retiredPublication = "publishRecording("

    /// Squeezed characters after `WorkMaterialDraft(` in which a `kind:`
    /// argument still belongs to THAT draft. Long enough for an `id:` line and a
    /// wrapped `kind:` beneath it, short enough that it cannot reach the next
    /// statement's arguments.
    private static let windowLength = 120

    // MARK: - (1) The voice path

    /// Not one file on the voice path may name either shape, anywhere in it.
    /// This is the whole-file form of the rule rather than the windowed one
    /// because these files have no legitimate reason to mention an audio desk
    /// card at all: what they produce is words.
    func testNoVoiceLaneFileEverPublishesARecording() throws {
        let paths = try Self.voiceLanePaths()
        XCTAssertGreaterThanOrEqual(
            paths.count, Self.voiceLaneFiles.count + 3,
            "The walk found \(paths.count) files; the directory derivation is broken and this "
                + "guard is asserting about almost nothing."
        )

        for path in paths {
            let source = Self.squeezed(try RefusalLaneSource.source(at: path))

            XCTAssertFalse(
                source.contains(Self.audioKind),
                "\(path) builds a desk card whose kind is `.audio`. A voice capture's artifact is "
                    + "its WORDS: a card that owns the recording keeps those bytes for ever and "
                    + "syncs them to the person's private CloudKit, which is exactly what parking "
                    + "the audio in the device-local retry queue exists to avoid. An audio file "
                    + "becomes a playable card through the desk's own attachment door and nowhere "
                    + "else."
            )
            XCTAssertFalse(
                source.contains(Self.retiredPublication),
                "\(path) calls `\(Self.retiredPublication)`. Phase one is a PARK, not a "
                    + "publication: nothing reaches the desk until the words do, and a lane that "
                    + "publishes its bytes first is the shape this whole lane inversion removed."
            )
        }
    }

    // MARK: - (2) The one door, across the whole app target

    func testNoAppTargetFileNamesAudioAsTheKindOfACardItBuilds() throws {
        let files = try Self.swiftFiles(under: Self.appTargetDirectory)
        XCTAssertGreaterThan(
            files.count, 100,
            "The app-target walk found \(files.count) files; the path derivation is broken."
        )

        for file in files where Self.buildsAnAudioDraft(in: file.squeezedSource) {
            XCTAssertEqual(
                file.relativePath, Self.importDoor,
                "\(file.relativePath) builds a `WorkMaterialDraft` with `kind: .audio`. The only "
                    + "audio a Work desk keeps is a file a person attached themselves, and the "
                    + "import in \(Self.importDoor) is the one place that happens — every other "
                    + "door refuses a recording, and no capture lane produces one."
            )
        }
    }

    /// A recording shared into Chat and then captured into Work would ride the
    /// desk's CloudKit lane as a `.file` card carrying audio bytes — the same
    /// permanent copy under a different kind — so the capture skips it. The
    /// assertion is scoped to the function because the store file names `.audio`
    /// legitimately elsewhere.
    func testTheChatCaptureNeverBuildsAnAudioDraft() throws {
        let source = try RefusalLaneSource.source(at: Self.chatCapturePath)
        let body = try RefusalLaneSource.body(
            ofFunction: Self.chatCaptureFunction, in: source, path: Self.chatCapturePath
        )
        XCTAssertFalse(
            Self.buildsAnAudioDraft(in: Self.squeezed(body)),
            "\(Self.chatCaptureFunction) builds an audio desk card. An attachment captured out of "
                + "a conversation reaches the desk through the same lane every other material "
                + "does, so a recording among them is a syncing copy of somebody's voice that "
                + "nobody asked Work to keep."
        )
    }

    // MARK: - (3) Non-vacuity

    /// The scans above pass trivially if NOTHING can mint an audio card any
    /// more, and a rule with no remaining subject reads exactly like a rule that
    /// holds. So the one route to one is asserted to still be open.
    ///
    /// The door does not spell `kind: .audio`; it spells
    /// `kind: storageKind(material.kind)`, and `storageKind` — which is private
    /// to that file, so the compiler is what stops a second caller — maps a
    /// presentation `.audio` onto a storage `.audio`. That two-step is the whole
    /// reason the literal token can be prohibited everywhere without also
    /// prohibiting the attachment button.
    func testTheImportDoorIsStillTheOneRouteToAnAudioCard() throws {
        let source = try RefusalLaneSource.source(at: Self.importDoor)

        let importer = try RefusalLaneSource.body(
            ofFunction: "importMaterial", in: source, path: Self.importDoor
        )
        XCTAssertTrue(
            Self.squeezed(importer).contains("kind:storageKind("),
            "\(Self.importDoor)'s import no longer takes its kind from `storageKind`. If it now "
                + "spells the kind literally, the scan above flags it and this exemption is the "
                + "reason; if it stopped building a card at all, the paperclip and the drop have "
                + "no door left."
        )

        let mapping = try RefusalLaneSource.body(
            ofFunction: "storageKind", in: source, path: Self.importDoor
        )
        XCTAssertTrue(
            Self.squeezed(mapping).contains("case.audio:return.audio"),
            "\(Self.importDoor) no longer maps a presentation `.audio` onto a storage `.audio`. "
                + "Either the paperclip stopped producing playable recordings, or the mapping "
                + "moved — and every scan above is now asserting about nothing."
        )
    }

    // MARK: - (4) The detector's own proof

    func testTheDetectorRecognisesEveryDraftShapeAndIgnoresProseAndOtherKinds() {
        let oneLine = Self.squeezed("""
        let draft = WorkMaterialDraft(id: captureID, kind: .audio, title: title)
        """)
        XCTAssertTrue(Self.buildsAnAudioDraft(in: oneLine))

        let wrapped = Self.squeezed("""
        let draft = WorkMaterialDraft(
            id: captureID,
            kind: .audio,
            title: WorkVoiceCaptureCoordinator.untranscribedTitle
        )
        """)
        XCTAssertTrue(
            Self.buildsAnAudioDraft(in: wrapped),
            "The wrapped form is how every draft in this repository is actually written."
        )

        let transcript = Self.squeezed("""
        let draft = WorkMaterialDraft(id: captureID, kind: .transcript, title: title)
        """)
        XCTAssertFalse(
            Self.buildsAnAudioDraft(in: transcript),
            "A words-only card is what every voice lane publishes; flagging it would make the "
                + "rule say the opposite of what it means."
        )

        let mapping = Self.squeezed("""
        switch kind {
        case .audio: return .audio
        case .transcript: return .transcript
        }
        """)
        XCTAssertFalse(
            Self.buildsAnAudioDraft(in: mapping),
            "Naming the kind is not building a card with it — the desk's own read path "
                + "enumerates every kind there is."
        )

        let prose = RefusalLaneSource.stripComments("""
        // Phase one published WorkMaterialDraft(id: captureID, kind: .audio, …) before the hop.
        let x = 1
        """)
        XCTAssertFalse(
            Self.buildsAnAudioDraft(in: Self.squeezed(prose)),
            "Every file on this list explains the rule at length; a header that describes the "
                + "old order must not read as the old order."
        )

        let neighbours = Self.squeezed("""
        let picture = WorkMaterialDraft(id: pictureID, kind: .image, title: name)
        try await store.upsertDeskMaterial(picture)
        let existing = try await store.fetchWorkMaterial(id: id)
        let matches = existing?.kind == .audio
        """)
        XCTAssertFalse(
            Self.buildsAnAudioDraft(in: neighbours),
            "The window must not reach past the draft it is scanning, or a file that WRITES a "
                + "picture beside a file that READS a recording is flagged for neither."
        )
    }

    // MARK: - Detection

    /// True when `source` builds a `WorkMaterialDraft` whose `kind:` is
    /// `.audio`, in any layout.
    private static func buildsAnAudioDraft(in source: String) -> Bool {
        var searchStart = source.startIndex
        while let found = source.range(of: draftInitializer, range: searchStart..<source.endIndex) {
            let end = source.index(
                found.upperBound, offsetBy: windowLength, limitedBy: source.endIndex
            ) ?? source.endIndex
            if source[found.upperBound..<end].contains(audioKind) { return true }
            searchStart = found.upperBound
        }
        return false
    }

    // MARK: - Fixtures

    /// Every file on the voice path: the named ones, plus everything in the
    /// directories that hold a whole lane.
    private static func voiceLanePaths() throws -> [String] {
        var paths = voiceLaneFiles
        for directory in voiceLaneDirectories {
            paths.append(contentsOf: try swiftFiles(under: directory).map(\.relativePath))
        }
        for path in voiceLaneFiles {
            _ = try RefusalLaneSource.rawSource(at: path)
        }
        return paths.sorted()
    }

    private struct ScannedFile {
        let relativePath: String
        let squeezedSource: String
    }

    /// Every Swift source under `directory`, relative to the project container.
    private static func swiftFiles(under directory: String) throws -> [ScannedFile] {
        let root = RefusalLaneSource.projectContainerURL.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not walk \(directory) — the path derivation is broken.")
            return []
        }
        var files: [ScannedFile] = []
        let prefix = RefusalLaneSource.projectContainerURL.path + "/"
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append(
                ScannedFile(
                    relativePath: String(url.path.dropFirst(prefix.count)),
                    squeezedSource: squeezed(RefusalLaneSource.stripComments(text))
                )
            )
        }
        return files
    }

    /// Whitespace-free, so line breaks and indentation cannot hide a token from
    /// a literal match.
    private static func squeezed(_ source: String) -> String {
        source.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
