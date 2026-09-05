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

    // MARK: - Identity copy carries no platform name

    /// Apple rejects an upload whose intent title or description names a
    /// platform (ITMS-90626), and the catalog-side rule cannot see a value that
    /// has not been written into the catalog yet.
    func testNoNewIntentTitleOrDescriptionNamesAPlatform() throws {
        let rows = try intentIdentityRows()

        XCTAssertEqual(
            Set(rows.map(\.key)),
            [
                "intent.workAddFiles.title",
                "intent.workAddFiles.description",
                "intent.workRecordNote.title",
                "intent.workRecordNote.description",
            ],
            "both new intents declare a keyed title AND a keyed description"
        )
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

    // MARK: - The capture identity a rerun reproduces

    func testTheCaptureIdentityIsDerivedFromTheInput() {
        let files = [
            Self.input(named: "one.txt", byteCount: 10),
            Self.input(named: "two.txt", byteCount: 20),
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
                files: [Self.input(named: "one.txt", byteCount: 11), files[1]]
            ),
            "a file that changed size is a different file"
        )
    }

    /// Name-based UUIDv5, the same shape `WorkCaptureInbox.fileEntryID` derives
    /// the entry ids with — a random id here would defeat every repair below it.
    func testTheCaptureIdentityIsANameBasedUUID() {
        let id = AddFilesToWorkIntent.captureIdentity(
            note: nil,
            files: [Self.input(named: "one.txt", byteCount: 1)]
        )

        XCTAssertEqual(id.uuid.6 & 0xF0, 0x50, "version 5")
        XCTAssertEqual(id.uuid.8 & 0xC0, 0x80, "RFC 4122 variant")
    }

    // MARK: - Fixtures

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
                rows.append(IdentityRow(key: String(source[key]), value: String(source[value])))
            }
        }
        return rows
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
