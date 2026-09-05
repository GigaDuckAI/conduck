// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkShortcutIntentsTests.swift
//
// Work's two new Shortcuts actions, and the launch route between the foreground
// one and the desk.
//
// THREE of these read SOURCE rather than behaviour, and each for a reason no
// runtime assertion can cover:
//
//   • An `AppShortcut`'s phrases and titles are metadata `appintentsd` indexes
//     at install time; a shipped phrase is what an installed Shortcut and a
//     spoken request are bound to, so the three that already shipped are pinned
//     as text.
//   • `WorkboardCopyTruthGuardTests` rule (7) enforces the no-platform-name rule
//     against the shipped CATALOG, which cannot see a value until the copy pass
//     writes the row — and cannot see a bare-English title at all. Reading the
//     `defaultValue:` literals here closes both halves at the call site, which
//     is where an ITMS-90626 rejection is actually authored.
//   • The refusal rules are asserted as a pure function because the queue's own
//     copy of them needs a filesystem, an App Group and a headless process to
//     reach.

import Foundation
import XCTest
@testable import Conduck

final class WorkShortcutIntentsTests: XCTestCase {

    // MARK: - The launch route

    /// The whole point of the route: a request survives the gap between a
    /// foreground intent and the desk mounting, and is answered exactly once.
    /// Two readers consult it — a notification handler and the canvas appearing
    /// — so a second true would open a second recorder over the first.
    func testARequestIsConsumedOnceAndOnlyOnce() {
        let route = WorkVoiceCaptureLaunchRoute()

        route.request()
        XCTAssertTrue(route.consume(), "the pending request is answered")
        XCTAssertFalse(route.consume(), "a consumed request is gone, not repeatable")
    }

    func testConsumingWithoutARequestAnswersNothing() {
        let route = WorkVoiceCaptureLaunchRoute()

        XCTAssertFalse(
            route.consume(),
            "a desk that mounts for any other reason must not open a recorder"
        )
    }

    /// SET-THEN-POST. A surface that mounts while the notification is being
    /// delivered has to find the flag already true, or the warm path and the
    /// cold path disagree about the same request.
    func testTheFlagIsAlreadySetWhenTheNotificationIsDelivered() {
        let route = WorkVoiceCaptureLaunchRoute()
        var observedDuringPost: Bool?
        let token = NotificationCenter.default.addObserver(
            forName: .showWorkboardVoiceCapture,
            object: nil,
            queue: nil
        ) { _ in
            observedDuringPost = route.consume()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        route.request()

        XCTAssertEqual(observedDuringPost, true)
        XCTAssertFalse(route.consume(), "the observer's read consumed it")
    }

    /// A shell reveals Work for a pending request and leaves the request alone:
    /// the composer is the only surface that can actually present the recorder,
    /// so a shell that consumed would spend a request nothing then answers.
    func testRevealingAPendingRequestDoesNotSpendIt() {
        let route = WorkVoiceCaptureLaunchRoute()
        let revealed = expectation(forNotification: .showWorkboard, object: nil)

        route.request()
        XCTAssertTrue(route.isPending, "a peek reads the request without claiming it")
        route.revealWorkIfPending()

        wait(for: [revealed], timeout: 2)
        XCTAssertTrue(route.isPending, "the reveal left the request for the composer")
        XCTAssertTrue(route.consume(), "the composer still gets to answer it")
    }

    /// The other half of the same rule: nothing pending means nothing is
    /// revealed, so a plain launch never yanks a person off Chats.
    func testRevealingWithoutARequestPostsNothing() {
        let route = WorkVoiceCaptureLaunchRoute()
        var reveals = 0
        let token = NotificationCenter.default.addObserver(
            forName: .showWorkboard,
            object: nil,
            queue: nil
        ) { _ in reveals += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        route.revealWorkIfPending()
        let settled = expectation(description: "the reveal's main-actor hop has had its turn")
        Task { @MainActor in settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(reveals, 0, "an unasked-for launch must stay on its own destination")
    }

    /// The cold-launch hole S2 named, closed at the shell: the root (and the
    /// Mac's window) reveal Work on appearance when a request is still pending.
    /// Source-shaped, because the alternative is standing up a SwiftUI
    /// hierarchy on two platforms to observe one notification.
    func testTheShellsRevealWorkForAPendingRequestAndLeaveConsumptionToTheComposer() throws {
        for path in ["Conduck/RootView.swift", "Conduck/ConduckApp.swift"] {
            let source = try RefusalLaneSource.source(at: path)
            XCTAssertTrue(
                source.contains("WorkVoiceCaptureLaunchRoute.shared.revealWorkIfPending()"),
                "\(path) no longer reveals Work for a request that arrived before it mounted"
            )
            XCTAssertFalse(
                source.contains("WorkVoiceCaptureLaunchRoute.shared.consume()"),
                "\(path) claims the request; only the visible composer can present the recorder"
            )
        }
    }

    // MARK: - Identity copy carries no platform name

    /// Apple rejects an upload whose intent title or description names a
    /// platform (ITMS-90626), and the catalog-side rule cannot see a value that
    /// has not been written into the catalog yet.
    ///
    /// The FILES action's keys are pinned by name; the voice action's are pinned
    /// by shape (one keyed title, one keyed description), because its copy — and
    /// with it its keys — is owned by the claims lane next door.
    func testNoNewIntentTitleOrDescriptionNamesAPlatform() throws {
        let rows = try intentIdentityRows()

        XCTAssertEqual(
            Set(rows.filter { $0.path.contains("AddFilesToWork") }.map(\.key)),
            ["intent.workAddFiles.title", "intent.workAddFiles.description"],
            "the files action declares a keyed title AND a keyed description"
        )
        XCTAssertEqual(
            Set(
                rows.filter { $0.path.contains("RecordWorkNote") }
                    .compactMap { $0.key.split(separator: ".").last.map(String.init) }
            ),
            ["title", "description"],
            "the voice action declares a keyed title AND a keyed description"
        )
        XCTAssertEqual(rows.count, 4, "four identity rows across the two intent files")
        for row in rows {
            let words = Set(
                row.value.lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                    .map(String.init)
            )
            let offenders = words.intersection(Self.platformWords).sorted()
            XCTAssertTrue(
                offenders.isEmpty,
                "\(row.key) names a platform (\(offenders.joined(separator: ", "))) — Apple rejects the upload"
            )
        }
    }

    /// The hole the catalog-side rule cannot see: a title written as a bare
    /// English literal carries no `intent.` key, so no catalog scan can ever
    /// read it.
    func testTheNewIntentsDeclareKeyedIdentityRatherThanBareLiterals() throws {
        let bareLiteral = try NSRegularExpression(
            pattern: #"(?:static var title: LocalizedStringResource\s*=|IntentDescription\()\s*""#
        )
        for path in Self.intentPaths {
            let source = try RefusalLaneSource.source(at: path)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            XCTAssertEqual(
                bareLiteral.numberOfMatches(in: source, range: range),
                0,
                "\(path) writes an identity string as a bare literal; no catalog scan can read it"
            )
        }
    }

    // MARK: - The shipped shortcut tiles

    /// Phrases and short titles an installed Shortcut, a Siri request and the
    /// Action Button are bound to. The three that shipped are frozen; the two
    /// new ones are pinned so a rename has to be a decision.
    func testTheShortcutProviderCarriesTheFrozenEntriesAndTheTwoNewOnes() throws {
        let source = try RefusalLaneSource.rawSource(at: "Conduck/Intents/AppShortcuts.swift")

        for frozen in [
            "\"Ask \\(.applicationName)\"",
            "\"Talk to \\(.applicationName)\"",
            "shortTitle: \"Ask Conduck\"",
            "\"Check \\(.applicationName) is ready\"",
            "shortTitle: \"Check Conduck\"",
            "\"Add a thought to my Work desk in \\(.applicationName)\"",
            "\"Capture a thought in \\(.applicationName)\"",
            "shortTitle: \"Add to Work\"",
        ] {
            XCTAssertTrue(
                source.contains(frozen),
                "a shipped shortcut entry changed: \(frozen) is no longer in AppShortcuts.swift"
            )
        }

        for added in [
            "intent: AddFilesToWorkIntent()",
            "\"Add files to Work in \\(.applicationName)\"",
            "\"Put this on my Work desk in \\(.applicationName)\"",
            "shortTitle: \"Add Files to Work\"",
            "intent: RecordWorkNoteIntent()",
            "\"Record a note to Work in \\(.applicationName)\"",
            "\"Save a voice note to Work in \\(.applicationName)\"",
            "shortTitle: \"Record a Note to Work\"",
        ] {
            XCTAssertTrue(source.contains(added), "AppShortcuts.swift is missing \(added)")
        }
    }

    /// A phrase is spoken and read, so it is copy too — and a phrase naming a
    /// platform is the same upload rejection as a title naming one.
    func testNoShortcutPhraseNamesAPlatform() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Intents/AppShortcuts.swift")
        let phrases = source
            .split(separator: "\n")
            .filter { $0.contains("\\(.applicationName)") }
            .map(String.init)

        XCTAssertGreaterThanOrEqual(phrases.count, 9, "the phrase scan found nothing to check")
        for phrase in phrases {
            let words = Set(
                phrase.lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                    .map(String.init)
            )
            XCTAssertTrue(
                words.intersection(Self.platformWords).isEmpty,
                "a spoken phrase names a platform: \(phrase.trimmingCharacters(in: .whitespaces))"
            )
        }
    }

    // MARK: - Whole-set refusals

    func testASetWithinEveryLimitIsNotRefused() {
        let files = (0..<WorkCaptureEnvelope.maximumEntryCount).map { index in
            Self.input(named: "file-\(index).txt", byteCount: 1_024)
        }

        XCTAssertNil(AddFilesToWorkIntent.refusal(for: files))
    }

    func testAnEmptySetIsRefused() {
        XCTAssertEqual(AddFilesToWorkIntent.refusal(for: []), .noFiles)
    }

    func testOneFileAboveTheEntryLimitIsRefusedWhole() {
        let files = (0...WorkCaptureEnvelope.maximumEntryCount).map { index in
            Self.input(named: "file-\(index).txt", byteCount: 1)
        }

        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(for: files),
            .tooManyFiles(limit: WorkCaptureEnvelope.maximumEntryCount)
        )
    }

    /// The ceiling itself is allowed; one byte past it is not — and the refusal
    /// names the file, because "one of them is too big" is unactionable when a
    /// person handed over twenty.
    func testAFileOverTheFileCeilingIsRefusedByName() {
        let exactly = Self.input(named: "fits.bin", byteCount: WorkCaptureEnvelope.maximumFileBytes)
        let over = Self.input(named: "huge.bin", byteCount: WorkCaptureEnvelope.maximumFileBytes + 1)

        XCTAssertNil(AddFilesToWorkIntent.refusal(for: [exactly]))
        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(for: [exactly, over]),
            .fileTooLarge(name: "huge.bin")
        )
    }

    func testASetOverTheEnvelopeCeilingIsRefusedAsASet() {
        let each = WorkCaptureEnvelope.maximumEnvelopeBytes / 2
        let files = (0..<3).map { index in
            Self.input(named: "half-\(index).bin", byteCount: each)
        }

        XCTAssertEqual(AddFilesToWorkIntent.refusal(for: files), .setTooLarge)
    }

    /// A file whose size could not be read declares zero. The queue measures the
    /// bytes it actually stages, so an unreadable size must cost the early
    /// refusal and nothing else — never the capture.
    func testAnUnreadableSizeDoesNotRefuseTheCapture() {
        XCTAssertNil(AddFilesToWorkIntent.refusal(for: [Self.input(named: "unknown.bin", byteCount: 0)]))
    }

    // MARK: - The note is refused as a note

    /// The ceiling itself passes; one character past it is the note's own
    /// refusal, decided before a byte is staged.
    func testAnOversizedNoteIsRefusedAsANote() {
        let atCeiling = String(repeating: "a", count: WorkCaptureEnvelope.maximumNoteCharacters)

        XCTAssertNil(AddFilesToWorkIntent.refusal(forNote: nil))
        XCTAssertNil(AddFilesToWorkIntent.refusal(forNote: atCeiling))
        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(forNote: atCeiling + "a"),
            .noteTooLong
        )
    }

    /// And if the queue is the one that says so, the sentence still names the
    /// note. Mapping this verdict onto "that file couldn't be read" sends a
    /// person to re-pick a file that was never the problem, and re-picking it
    /// cannot make the capture succeed.
    func testTheQueuesNoteVerdictIsNotReportedAsAnUnreadableFile() {
        let refusal = WorkFileCaptureRefusal(
            publicationFailure: .noteTooLong,
            files: [Self.input(named: "memo.txt", byteCount: 5)]
        )

        XCTAssertEqual(refusal, .noteTooLong)
        XCTAssertNotEqual(refusal, .unreadableFile(name: "memo.txt"))
        XCTAssertNotNil(refusal.errorDescription)
    }

    // MARK: - The capture identity a rerun reproduces

    func testTheCaptureIdentityIsDerivedFromTheInput() {
        let files = [
            Self.snapshot(named: "one.txt", byteCount: 10, digest: 0x11),
            Self.snapshot(named: "two.txt", byteCount: 20, digest: 0x22),
        ]

        let first = AddFilesToWorkIntent.captureIdentity(note: "survey", files: files)
        let second = AddFilesToWorkIntent.captureIdentity(note: "survey", files: files)
        XCTAssertEqual(first, second, "a rerun over the same input repairs the same cards")

        XCTAssertNotEqual(
            first,
            AddFilesToWorkIntent.captureIdentity(note: "survey", files: files.reversed()),
            "the entry ids under the capture are named by POSITION, so order is part of the name"
        )
        XCTAssertNotEqual(
            first,
            AddFilesToWorkIntent.captureIdentity(note: "something else", files: files),
            "the note is part of the capture, so it is part of its name"
        )
        XCTAssertNotEqual(
            first,
            AddFilesToWorkIntent.captureIdentity(
                note: "survey",
                files: [Self.snapshot(named: "one.txt", byteCount: 11, digest: 0x11), files[1]]
            ),
            "a file that changed size is a different file"
        )
        XCTAssertNotEqual(
            first,
            AddFilesToWorkIntent.captureIdentity(
                note: "survey",
                files: [Self.snapshot(named: "one.txt", byteCount: 10, digest: 0x99), files[1]]
            ),
            "a file that changed CONTENT is a different file, at the same name and size"
        )
    }

    /// Name-based UUIDv5, the same shape `WorkCaptureInbox.fileEntryID` derives
    /// the entry ids with — a random id here would defeat every repair below it.
    func testTheCaptureIdentityIsANameBasedUUID() {
        let id = AddFilesToWorkIntent.captureIdentity(
            note: nil,
            files: [Self.snapshot(named: "one.txt", byteCount: 1, digest: 0x01)]
        )

        XCTAssertEqual(id.uuid.6 & 0xF0, 0x50, "version 5")
        XCTAssertEqual(id.uuid.8 & 0xC0, 0x80, "RFC 4122 variant")
    }

    /// The collision that makes repair destructive. Two different `memo.txt`s of
    /// equal size are ONE id under a name-and-size hash, and the second capture
    /// then republishes over the first's cards — the bytes saved an hour ago are
    /// gone. The digest is what separates them, and it must not separate a
    /// genuine replay of the same bytes, which is the property the whole derived
    /// identity exists for.
    func testTwoFilesAlikeInNameAndSizeButNotInBytesAreDifferentCaptures() throws {
        let root = try Self.makeScratchDirectory()
        let first = try Self.snapshot(
            of: Self.writeFile(named: "memo.txt", bytes: "alpha", under: root, in: "one"),
            under: root,
            leaf: "snapshot-one.txt"
        )
        let second = try Self.snapshot(
            of: Self.writeFile(named: "memo.txt", bytes: "bravo", under: root, in: "two"),
            under: root,
            leaf: "snapshot-two.txt"
        )
        let replay = try Self.snapshot(
            of: Self.writeFile(named: "memo.txt", bytes: "alpha", under: root, in: "three"),
            under: root,
            leaf: "snapshot-three.txt"
        )

        let firstID = AddFilesToWorkIntent.captureIdentity(note: nil, files: [first])

        XCTAssertNotEqual(
            firstID,
            AddFilesToWorkIntent.captureIdentity(note: nil, files: [second]),
            "different bytes are a different capture — the same id would overwrite the first card"
        )
        XCTAssertEqual(
            firstID,
            AddFilesToWorkIntent.captureIdentity(note: nil, files: [replay]),
            "the same bytes are the same capture, so a killed shortcut's rerun still repairs"
        )
        XCTAssertEqual(firstID.uuid.6 & 0xF0, 0x50, "still version 5")
    }

    /// The snapshot is a COPY, and the digest describes that copy. A source the
    /// person's editor rewrites a moment later cannot change what this capture
    /// is called, because the bytes it was named after are already this
    /// process's own.
    func testTheSnapshotFreezesTheBytesTheIdentityWasTakenOver() throws {
        let root = try Self.makeScratchDirectory()
        let source = try Self.writeFile(named: "memo.txt", bytes: "alpha", under: root, in: "source")
        let snapshot = try Self.snapshot(of: source, under: root, leaf: "snapshot.txt")
        let id = AddFilesToWorkIntent.captureIdentity(note: nil, files: [snapshot])

        try Data("bravo".utf8).write(to: source.url, options: .atomic)

        XCTAssertEqual(
            try Data(contentsOf: snapshot.input.url),
            Data("alpha".utf8),
            "the published bytes are the snapshot's, not whatever the source now holds"
        )
        XCTAssertEqual(
            id,
            AddFilesToWorkIntent.captureIdentity(note: nil, files: [snapshot]),
            "the identity is a fact about the snapshot, so a rewritten source cannot move it"
        )
        XCTAssertNotEqual(
            id,
            AddFilesToWorkIntent.captureIdentity(
                note: nil,
                files: [try Self.snapshot(of: source, under: root, leaf: "snapshot-after.txt")]
            ),
            "the rewritten source is a different capture — one id for both would overwrite the card"
        )
    }

    /// A source that cannot be read REFUSES the whole capture rather than
    /// digesting as a sentinel: one shared name for every unreadable file is a
    /// name that replaces whatever it collides with, which is the loss the
    /// digest exists to prevent.
    func testAnUnreadableSourceRefusesTheCaptureInsteadOfNamingIt() throws {
        let root = try Self.makeScratchDirectory()
        let missing = WorkCaptureFileInput(
            url: root.appendingPathComponent("absent/note.txt"),
            displayName: "note.txt",
            mimeType: nil,
            typeIdentifier: nil,
            byteCount: 0
        )

        XCTAssertThrowsError(
            try Self.snapshot(of: missing, under: root, leaf: "snapshot-missing.txt")
        ) { error in
            XCTAssertEqual(
                error as? WorkFileCaptureRefusal,
                .unreadableFile(name: "note.txt"),
                "the sentence names the file the person has to re-pick"
            )
        }
    }

    // MARK: - The ceilings bind the copy, not its result

    /// The window a declared size cannot cover. A source belongs to somebody
    /// else's process until it is copied, so the size preflight admitted it on
    /// is a claim about a file that can be replaced a moment later — and a copy
    /// that measured only its RESULT would write every byte of a multi-gigabyte
    /// replacement onto a disk the person may be short of before refusing it.
    ///
    /// The ceiling is INJECTED rather than reached: the production limit is 256
    /// MB and no unit test should stage that, so the parameter carries the real
    /// one for every caller and a small one here. The small one is still bigger
    /// than a 256 KB chunk, so the abort lands part way THROUGH the copy rather
    /// than before it starts, which is the half a result-time check would miss.
    func testASourceThatOutgrewItsDeclaredSizeIsRefusedMidCopyAndLeavesNothingStaged() throws {
        let root = try Self.makeScratchDirectory()
        let grown = try Self.writeFile(
            named: "video.mov",
            byteCount: 768 * 1_024,
            declaring: 5,
            under: root,
            in: "grown"
        )
        XCTAssertNil(
            AddFilesToWorkIntent.refusal(for: [grown]),
            "the declared size passes preflight — that the copy is the only thing left is the premise"
        )
        let destination = root.appendingPathComponent("snapshot-grown.mov", isDirectory: false)

        XCTAssertThrowsError(
            try AddFilesToWorkIntent.snapshot(grown, into: destination, fileCeiling: 300 * 1_024)
        ) { error in
            XCTAssertEqual(
                error as? WorkFileCaptureRefusal,
                .fileTooLarge(name: "video.mov"),
                "the person reads the size sentence they can act on, not “couldn’t be read”"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "the abandoned partial copy is reclaimed where it stands, not left for the sweeper"
        )
    }

    /// The other half of the same rule: what is LEFT of the set's budget stops
    /// a copy too, and it is a whole-set sentence — naming one file would send
    /// the person to re-pick a file that is not individually too big.
    func testASnapshotThatWouldExhaustTheRemainingSetBudgetIsRefusedAsASet() throws {
        let root = try Self.makeScratchDirectory()
        let source = try Self.writeFile(
            named: "clip.mov",
            byteCount: 768 * 1_024,
            declaring: 5,
            under: root,
            in: "budget"
        )
        let refused = root.appendingPathComponent("snapshot-over-budget.mov", isDirectory: false)

        XCTAssertThrowsError(
            try AddFilesToWorkIntent.snapshot(source, into: refused, setBudget: 300 * 1_024)
        ) { error in
            XCTAssertEqual(
                error as? WorkFileCaptureRefusal,
                .setTooLarge,
                "the aggregate is the set's refusal, not one file's"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: refused.path),
            "nothing of the refused copy survives"
        )

        // The budget is spendable to its last byte: an exact fit that refused
        // would turn every full set into a false refusal.
        let fits = root.appendingPathComponent("snapshot-exact.mov", isDirectory: false)
        let staged = try AddFilesToWorkIntent.snapshot(source, into: fits, setBudget: 768 * 1_024)

        XCTAssertEqual(staged.input.byteCount, Int64(768 * 1_024), "the ceiling itself is allowed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fits.path), "a copy within budget is kept")
    }

    /// The budget belongs to the SET, so it only means something if the staging
    /// loop spends it down: a loop that handed every file the whole envelope
    /// ceiling would let twenty-four files each write it.
    ///
    /// Source-shaped because the loop lives inside `perform()`, which needs an
    /// intent process, an App Group and a filesystem to reach — the three
    /// things the rest of this file exists to avoid.
    func testTheStagingLoopSpendsTheSetBudgetDownFileByFile() throws {
        let path = "Conduck/Intents/AddFilesToWorkIntent.swift"
        let body = try RefusalLaneSource.body(
            ofFunction: "perform",
            in: try RefusalLaneSource.source(at: path),
            path: path
        )

        XCTAssertTrue(
            body.contains("var remainingSetBytes = WorkCaptureEnvelope.maximumEnvelopeBytes"),
            "the staging loop carries no set budget"
        )
        XCTAssertTrue(
            body.contains("setBudget: remainingSetBytes"),
            "a snapshot is not told what is left of the set, so the aggregate binds nothing while copying"
        )
        XCTAssertTrue(
            body.contains("remainingSetBytes -= max(0, staged.input.byteCount)"),
            "the budget is not spent down by what each snapshot actually held"
        )
    }

    // MARK: - The digest reads bytes without holding them

    /// BOUNDED MEMORY, not bounded I/O. The digest is the one thing in this file
    /// that touches a person's bytes, and it runs in a headless process the
    /// system kills without warning: a per-file ceiling of 256 MB means naming a
    /// capture with `Data(contentsOf:)` is the jetsam the envelope queue exists
    /// to avoid. Reading the same bytes in fixed chunks costs a pass over a file
    /// that is about to be copied anyway and holds one chunk at a time.
    ///
    /// Source-shaped because a peak footprint is not observable from a unit
    /// test, and the property is about HOW the bytes are read, not what they
    /// hash to.
    func testTheCaptureDigestStreamsTheBytesRatherThanLoadingThem() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Intents/AddFilesToWorkIntent.swift")

        XCTAssertTrue(
            source.contains("FileHandle(forReadingFrom:"),
            "the digest no longer reads through a handle"
        )
        XCTAssertTrue(
            source.contains("read(upToCount:"),
            "the digest no longer reads in fixed chunks — one read of a 256 MB file is the crash"
        )
        XCTAssertFalse(
            source.contains("Data(contentsOf:"),
            "a headless intent process must never hold a whole file in memory"
        )
        XCTAssertTrue(
            source.contains("try writer.write(contentsOf: chunk)"),
            "the copy and the digest are no longer ONE pass — a digest of a separate read describes bytes the desk may never receive"
        )
    }

    // MARK: - The window a fully quit Mac never opened

    /// The last sliver of the cold-launch hole, and the one no appearance hook
    /// can reach: on a Mac that is fully QUIT the intent performs before the
    /// scene's subscribers exist, so nothing opens a window and every
    /// appearance-time recovery waits for an appearance that never comes. The
    /// application lifetime is the only level that can create that window.
    ///
    /// Source-shaped for the same reason as the shells' guard above: the
    /// alternative is driving an AppKit launch from a unit test.
    func testTheMacLifetimeOpensAWindowForARequestThatArrivedBeforeAnyExisted() throws {
        let path = "Conduck/AppDelegate.swift"
        let source = try RefusalLaneSource.source(at: path)

        for lifecycle in ["applicationDidFinishLaunching", "applicationDidBecomeActive"] {
            let body = try RefusalLaneSource.body(ofFunction: lifecycle, in: source, path: path)
            XCTAssertTrue(
                body.contains("revealWorkForAPendingVoiceRequest()"),
                "\(lifecycle) no longer answers a Work voice request that arrived before any window existed"
            )
        }

        let hook = try RefusalLaneSource.body(
            ofFunction: "revealWorkForAPendingVoiceRequest",
            in: source,
            path: path
        )
        XCTAssertTrue(
            hook.contains("WorkVoiceCaptureLaunchRoute.shared.isPending"),
            "the hook no longer checks for a pending request, so it reveals Work at every launch"
        )
        XCTAssertTrue(
            hook.contains("NSApp.activate"),
            "a quiet Mac that opens the window without activating puts it behind whatever is frontmost"
        )
        XCTAssertTrue(
            hook.contains("WorkVoiceCaptureLaunchRoute.shared.revealWorkIfPending()"),
            "the hook no longer opens the window for the pending request"
        )
        XCTAssertFalse(
            hook.contains("consume()"),
            "the launch hook claims the request; only the visible composer can present the recorder"
        )
    }

    // MARK: - The rows these actions ship

    /// Every keyed string these two files ask for has a row in the shipped
    /// catalog. A referenced key with no row renders the source's
    /// `defaultValue:` forever and can never be translated, and neither half is
    /// visible in a diff — `WorkboardCopyTruthGuardTests`' both-directions rule
    /// walks `workboard.*` and `pendingRetry.*`, never `intent.*`.
    func testEveryIntentKeyTheseFilesReferenceHasACatalogRow() throws {
        let strings = try catalogStrings()
        let expression = try NSRegularExpression(pattern: #""(intent\.[A-Za-z0-9.]+)""#)
        var scanned = 0

        for path in Self.intentPaths {
            let source = try RefusalLaneSource.source(at: path)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[range])
                scanned += 1
                XCTAssertNotNil(
                    strings[key],
                    "\(key) is referenced in \(path) but has no catalog row"
                )
            }
        }

        XCTAssertGreaterThanOrEqual(scanned, 12, "the key scan found almost nothing to check")
    }

    /// The voice action may not borrow the files action's promise. Its lane has
    /// ONE outbound hop — the speech provider the person configured, whose
    /// roster is mostly cloud vendors and several of whose entries are AI models
    /// — so "nothing is sent to an AI" is a claim the code cannot keep. What it
    /// may promise is the boundary the desk enforces: the audio becomes words
    /// and never becomes a conversation. Same honest shape as
    /// `workboard.voice.privacy`, which the sheet shows for the same lane.
    func testTheVoiceActionsDescriptionNamesItsOneOutboundHopInsteadOfDenyingIt() throws {
        let strings = try catalogStrings()
        let value = try XCTUnwrap(
            englishValue(try XCTUnwrap(strings["intent.workVoiceNote.description"])),
            "the voice action's description has no catalog row"
        ).lowercased()

        XCTAssertTrue(
            value.contains("speech provider"),
            "the one place the audio goes has to be named: \(value)"
        )
        XCTAssertTrue(
            value.contains("conversation"),
            "the boundary that IS true — never a conversation turn — is the promise to make"
        )
        for denial in ["nothing is sent", "nothing was sent", "never reaches an ai", "not to an ai"] {
            XCTAssertFalse(
                value.contains(denial),
                "the voice lane has an outbound hop, so it may not deny one: \(value)"
            )
        }
    }

    // MARK: - Fixtures

    /// Scratch under the sweeper-owned prefix, removed at teardown — the same
    /// leaf discipline the intent's own data fallback follows.
    private static func makeScratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workboard-intake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratchRoots.append(root)
        return root
    }

    private static var scratchRoots: [URL] = []

    override class func tearDown() {
        for root in scratchRoots { try? FileManager.default.removeItem(at: root) }
        scratchRoots.removeAll()
        super.tearDown()
    }

    /// The same leaf name in a different directory, so the inputs differ in
    /// exactly the thing under test.
    private static func writeFile(
        named name: String,
        bytes: String,
        under root: URL,
        in folder: String
    ) throws -> WorkCaptureFileInput {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(bytes.utf8).write(to: url, options: .atomic)
        return WorkCaptureFileInput(
            url: url,
            displayName: name,
            mimeType: nil,
            typeIdentifier: nil,
            byteCount: Int64(bytes.utf8.count)
        )
    }

    /// A source whose REAL size and DECLARED size disagree — the shape a file
    /// takes when it is replaced between the preflight that measured it and the
    /// copy that stages it. Generated rather than written from a fixture: a
    /// repeating pattern is all a ceiling test needs, and three chunks of it
    /// cost nothing.
    private static func writeFile(
        named name: String,
        byteCount: Int,
        declaring declared: Int64,
        under root: URL,
        in folder: String
    ) throws -> WorkCaptureFileInput {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(repeating: 0x41, count: byteCount).write(to: url, options: .atomic)
        return WorkCaptureFileInput(
            url: url,
            displayName: name,
            mimeType: nil,
            typeIdentifier: nil,
            byteCount: declared
        )
    }

    /// The shipped catalog's `strings` table, read from disk: the `en` value in
    /// it is what a person actually reads, and it wins over a source
    /// `defaultValue:` at runtime.
    private func catalogStrings() throws -> [String: Any] {
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any], "the catalog has no strings table")
    }

    private func englishValue(_ entry: Any) -> String? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any],
              let unit = english["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    private static let intentPaths = [
        "Conduck/Intents/AddFilesToWorkIntent.swift",
        "Conduck/Intents/RecordWorkNoteIntent.swift",
    ]

    /// The same word set `WorkboardCopyTruthGuardTests` rule (7) uses, matched
    /// word-ish rather than by substring: "watch out" IS a platform name here
    /// and "machine" is not.
    private static let platformWords: Set<String> = [
        "iphone", "iphones", "ipad", "ipads", "ipados",
        "mac", "macs", "macos", "watch", "watches", "watchos", "carplay",
    ]

    private struct IdentityRow {
        let path: String
        let key: String
        let value: String
    }

    /// Every `intent.<name>.title` / `.description` row the two new intent files
    /// declare, read as `(key, defaultValue)` pairs from the source itself.
    private func intentIdentityRows() throws -> [IdentityRow] {
        let pattern = #""(intent\.[A-Za-z0-9]+\.(?:title|description))",\s*defaultValue:\s*"([^"]*)""#
        let expression = try NSRegularExpression(pattern: pattern)
        var rows: [IdentityRow] = []
        for path in Self.intentPaths {
            let source = try RefusalLaneSource.rawSource(at: path)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let key = Range(match.range(at: 1), in: source),
                      let value = Range(match.range(at: 2), in: source) else { continue }
                rows.append(IdentityRow(
                    path: path,
                    key: String(source[key]),
                    value: String(source[value])
                ))
            }
        }
        return rows
    }

    /// The production snapshot: a real copy under the scratch root, digested in
    /// the same pass. Used wherever the property under test is about the bytes
    /// that get PUBLISHED rather than about the hash's shape.
    private static func snapshot(
        of file: WorkCaptureFileInput,
        under root: URL,
        leaf: String
    ) throws -> AddFilesToWorkIntent.Snapshot {
        try AddFilesToWorkIntent.snapshot(
            file,
            into: root.appendingPathComponent(leaf, isDirectory: false)
        )
    }

    /// A snapshot with a made-up digest, for the assertions about the identity's
    /// SHAPE — those need no filesystem at all now that the derivation is pure.
    private static func snapshot(
        named name: String,
        byteCount: Int64,
        digest: UInt8
    ) -> AddFilesToWorkIntent.Snapshot {
        AddFilesToWorkIntent.Snapshot(
            input: input(named: name, byteCount: byteCount),
            digest: Data(repeating: digest, count: 32)
        )
    }

    private static func input(named name: String, byteCount: Int64) -> WorkCaptureFileInput {
        WorkCaptureFileInput(
            url: URL(fileURLWithPath: "/dev/null"),
            displayName: name,
            mimeType: nil,
            typeIdentifier: nil,
            byteCount: byteCount
        )
    }
}
