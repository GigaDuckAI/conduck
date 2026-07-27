// Conduck — a long filename must survive the WHOLE upload path, not just the mint.
//
// `FileServerClientTests` already pins `boundedStoredKeyName`: the stored key's
// last path component fits POSIX `NAME_MAX`. That is the REMOTE half. This file
// covers the two halves it cannot see:
//
//   1. THE LOCAL STAGING COPY, which happens BEFORE the mint. Every composer
//      attachment is first copied out of its security scope into
//      `tmp/conduck-ftstage-<uuid>-<source name>`. That leaf is the source
//      filename plus a fixed 53-byte prefix, so a filename the SOURCE volume
//      accepts at its own 255-byte limit mints a 308-byte leaf here — which
//      `copyItem` refuses with `ENAMETOOLONG`. The binary composer path treats a
//      nil staging URL as "skip this file": no chip, no error, no attachment.
//      The user picks a PDF and nothing happens. The bound belongs where the
//      filesystem constraint is, so it lives in `AttachmentStagingFile`.
//
//   2. THE WIRE, AFTER the mint. `BackgroundFileTransfer` hands the stored key
//      to `FileServerClient.build*Request`, which resolves it with
//      `URL.appending(path:)`. These tests assert the long name reaches
//      `URLRequest.url` with its extension intact, its folder segment intact,
//      every path component inside `NAME_MAX`, and byte-identically across the
//      upload / download / probe / delete builders — the four verbs that must
//      agree or a retry orphans its own partial blob.
//
// Both mint entry points are covered: `makeStoredKey` (in-app composer) and
// `deterministicStoredKey` (share sheet, where the key must re-derive
// identically after a relaunch).
//
// Privacy: every filename here is synthetic and none is logged.

import Foundation
import XCTest
@testable import Conduck

final class AttachmentStagingFileTests: XCTestCase {

    /// POSIX `NAME_MAX`. Every path component the app writes — locally or on the
    /// user's file server — has to fit inside this many BYTES.
    private let nameMax = 255

    /// Scratch directory for source fixtures. A subdirectory (not the temp root)
    /// so nothing here can be confused with the production staging leaves the
    /// tests below deliberately create in the root. Prefixed with a claimed
    /// `TempScratchSweeper` prefix so an abandoned run is reclaimable like any
    /// other orphan.
    private var scratch: URL!

    /// Staged copies produced by `copyUnderScope`, removed in teardown — they
    /// land in the REAL temporary directory, exactly as production does.
    private var staged: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-ftstage-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in staged { try? FileManager.default.removeItem(at: url) }
        staged = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A synthetic snapshot pointing at a fake base URL, matching
    /// `FileServerClientTests` (no trailing slash, so `appending(path:)` does the
    /// joining).
    private func makeSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://fileserver.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    /// A filename of exactly `bytes` bytes ending in `extension`, built from
    /// `unit` (1 byte for ASCII, 3 for a CJK ideograph).
    private func filename(bytes: Int, unit: Character = "a", extension ext: String) -> String {
        let unitWidth = String(unit).utf8.count
        let stemBytes = bytes - ext.utf8.count
        precondition(stemBytes > 0 && stemBytes % unitWidth == 0, "fixture arithmetic is wrong")
        return String(repeating: String(unit), count: stemBytes / unitWidth) + ext
    }

    /// Write `name` into the scratch directory and return its URL.
    private func makeSourceFile(named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data("conduck-staging-fixture".utf8).write(to: url)
        return url
    }

    // MARK: - The bound itself

    /// The bound must be invisible to every name that already fits, or ordinary
    /// attachments would start staging under a different leaf for no reason.
    func testOrdinaryNamesPassThroughUntouched() {
        for name in ["a", "report.pdf", "Q3 review (final).xlsx", ".gitignore", "archive.tar.gz"] {
            XCTAssertEqual(
                AttachmentStagingFile.boundedSourceLeaf(name), name,
                "a name that already fits must stage under exactly the leaf it always did"
            )
        }
    }

    func testAnOverlongNameIsBoundedWithItsExtensionKept() {
        let name = filename(bytes: 250, extension: ".pdf")
        let bounded = AttachmentStagingFile.boundedSourceLeaf(name)

        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            AttachmentStagingFile.stagingLeafMaxBytes - AttachmentStagingFile.stagingLeafReservedBytes,
            "the bounded source name must leave room for the prefix and the UUID"
        )
        XCTAssertTrue(
            bounded.hasSuffix(".pdf"),
            "the stem is what gets cut — an agent routes on the extension, so `report.p` is worth nothing where `repo.pdf` still works"
        )
    }

    /// The distinguishing property versus `FileServerClient.boundedStoredKeyName`.
    /// That one counts characters because its input is already `[A-Za-z0-9._-]`;
    /// this one takes the RAW filesystem name, where one character can be four
    /// bytes. 70 emoji are a legal 280-byte filename on the source volume.
    func testTheBoundIsCountedInBytesNotCharacters() {
        // 82 CJK ideographs = 246 bytes, but only 82 characters. A
        // character-counted bound of 202 would wave this straight through.
        let name = filename(bytes: 250, unit: "漢", extension: ".pdf")
        XCTAssertLessThan(name.count, 202, "fixture: this name is short in CHARACTERS")
        XCTAssertGreaterThan(name.utf8.count, 202, "fixture: and long in BYTES")

        let bounded = AttachmentStagingFile.boundedSourceLeaf(name)
        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            AttachmentStagingFile.stagingLeafMaxBytes - AttachmentStagingFile.stagingLeafReservedBytes,
            "a multibyte name must be bounded by the byte budget the filesystem actually enforces"
        )
    }

    /// A cut in the middle of a UTF-8 sequence would be rejected by the
    /// filesystem for a second, much harder-to-read reason.
    func testTheCutNeverSeversAUTF8Sequence() {
        for unit in ["漢", "🐤", "é"] {
            for extra in 0..<8 {
                let name = String(repeating: unit, count: 100) + String(repeating: "a", count: extra) + ".bin"
                let bounded = AttachmentStagingFile.boundedSourceLeaf(name)
                XCTAssertEqual(
                    String(decoding: Array(bounded.utf8), as: UTF8.self), bounded,
                    "the bounded leaf must round-trip through UTF-8 — a severed scalar would decode to U+FFFD"
                )
                XCTAssertFalse(bounded.unicodeScalars.contains("\u{FFFD}"))
            }
        }
    }

    /// A leading dot is a dotfile — all stem. Reading it as an extension would
    /// truncate the whole name away.
    func testALeadingDotIsStemNotExtension() {
        let name = "." + String(repeating: "a", count: 300)
        let bounded = AttachmentStagingFile.boundedSourceLeaf(name)
        XCTAssertTrue(bounded.hasPrefix(".a"), "the dotfile name is truncated, not consumed")
    }

    /// A pathological "extension" must not eat the budget the stem needs.
    func testAnAbsurdSuffixIsCutRatherThanPreserved() {
        let name = "report." + String(repeating: "z", count: 300)
        let bounded = AttachmentStagingFile.boundedSourceLeaf(name)
        XCTAssertTrue(bounded.hasPrefix("report."), "the real stem survives; the absurd suffix is simply cut")
        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            AttachmentStagingFile.stagingLeafMaxBytes - AttachmentStagingFile.stagingLeafReservedBytes
        )
    }

    // MARK: - The staging copy, against the real filesystem
    //
    // The bound above is arithmetic; these are the tests that would actually have
    // caught the defect. They copy a real file with a real long name through the
    // real `copyUnderScope` into the real temporary directory.

    func testA250CharacterFilenameActuallyStages() throws {
        let source = try makeSourceFile(named: filename(bytes: 250, extension: ".pdf"))

        let stagedURL = try XCTUnwrap(
            AttachmentStagingFile.copyUnderScope(source),
            "a 250-byte filename is legal on every volume the picker can reach. A nil here is the field bug: the binary composer path skips the attachment silently — no chip, no error, no upload."
        )
        staged.append(stagedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(
            try Data(contentsOf: stagedURL), try Data(contentsOf: source),
            "the staged copy must be the source bytes"
        )
        XCTAssertLessThanOrEqual(
            stagedURL.lastPathComponent.utf8.count, nameMax,
            "the staging leaf must fit NAME_MAX in bytes"
        )
    }

    /// The worst case the source volume can hand us: a leaf at its own limit.
    func testAFilenameAtTheSourceVolumesOwnLimitStages() throws {
        let source = try makeSourceFile(named: filename(bytes: nameMax, extension: ".zip"))

        let stagedURL = try XCTUnwrap(AttachmentStagingFile.copyUnderScope(source))
        staged.append(stagedURL)
        XCTAssertLessThanOrEqual(stagedURL.lastPathComponent.utf8.count, nameMax)
    }

    /// Multibyte names are where a character-counted bound looks correct and is
    /// not: 83 ideographs are 249 bytes.
    func testAMultibyteFilenameAtTheSourceVolumesLimitStages() throws {
        let source = try makeSourceFile(named: filename(bytes: 253, unit: "漢", extension: ".txt"))

        let stagedURL = try XCTUnwrap(
            AttachmentStagingFile.copyUnderScope(source),
            "a CJK filename at the volume's byte limit must stage — this is the case a character-counted bound waves through and the filesystem then rejects"
        )
        staged.append(stagedURL)
        XCTAssertLessThanOrEqual(stagedURL.lastPathComponent.utf8.count, nameMax)
    }

    /// The staged leaf is an orphan risk like any other temp write, so it has to
    /// stay claimable by the sweeper even after the bound cut it.
    func testTheStagedLeafStaysClaimedByAnOwnedPrefix() throws {
        let source = try makeSourceFile(named: filename(bytes: 250, extension: ".pdf"))
        let stagedURL = try XCTUnwrap(AttachmentStagingFile.copyUnderScope(source))
        staged.append(stagedURL)

        let leaf = stagedURL.lastPathComponent
        XCTAssertTrue(
            TempScratchSweeper.ownedPrefixes.contains(where: { leaf.hasPrefix($0) }),
            "a staged copy that no owned prefix claims is unreclaimable: its only cleanup is in-process, so a jetsam strands the user's file forever"
        )
    }

    /// The declared reserve must match the leaf the code actually builds, or the
    /// budget is arithmetic about a format string that has since changed.
    func testTheDeclaredPrefixReserveMatchesTheLeafTheCodeBuilds() throws {
        let name = "x.bin"
        let source = try makeSourceFile(named: name)
        let stagedURL = try XCTUnwrap(AttachmentStagingFile.copyUnderScope(source))
        staged.append(stagedURL)

        XCTAssertEqual(
            stagedURL.lastPathComponent.utf8.count - name.utf8.count,
            AttachmentStagingFile.stagingLeafReservedBytes,
            "`stagingLeafReservedBytes` no longer describes the leaf `copyUnderScope` builds — the byte budget is now wrong by exactly this difference"
        )
    }

    /// A short name must reach the staging leaf verbatim: the leaf embeds it so a
    /// human reading a stranded temp file can tell what it is.
    func testAShortNameReachesTheStagingLeafVerbatim() throws {
        let name = "quarterly report.pdf"
        let source = try makeSourceFile(named: name)
        let stagedURL = try XCTUnwrap(AttachmentStagingFile.copyUnderScope(source))
        staged.append(stagedURL)

        XCTAssertTrue(stagedURL.lastPathComponent.hasSuffix("-\(name)"))
    }

    // MARK: - Beyond the mint: the constructed request
    //
    // What the unit tests on `boundedStoredKeyName` cannot see — that the bounded
    // key survives URL assembly with its extension and folder segment intact.

    /// The composer path, end to end: 250-character name → mint → upload request.
    func testALongComposerFilenameSurvivesToTheUploadURL() throws {
        let snapshot = makeSnapshot()
        let conversation = UUID()
        let name = filename(bytes: 250, extension: ".pdf")

        let key = FileServerClient.makeStoredKey(
            originalName: name, uuid: UUID(), folder: conversation.uuidString)
        let url = try XCTUnwrap(
            FileServerClient.buildUploadRequest(
                snapshot: snapshot, storedKey: key, contentLength: 1
            ).url
        )

        XCTAssertEqual(
            url.lastPathComponent, key.components(separatedBy: "/").last,
            "the minted key must reach the wire byte-identically — no second truncation, no re-sanitization"
        )
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".pdf"), "the extension must survive to the wire")
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent, conversation.uuidString,
            "the per-conversation folder must survive as a real path segment"
        )
        for component in url.pathComponents where component != "/" {
            XCTAssertLessThanOrEqual(
                component.utf8.count, nameMax,
                "every path component becomes a filename on the user's server — `\(component.prefix(8))…` is \(component.utf8.count) bytes"
            )
        }
        XCTAssertFalse(
            url.absoluteString.contains("%"),
            "a bounded key is already in the WebDAV-safe set, so nothing should be percent-encoded"
        )
    }

    /// The share-sheet path, end to end. `SharedInboxManifest` bounds the name on
    /// the way in, but a manifest decoded from an older build carries whatever it
    /// was written with — so the mint has to hold on its own.
    func testALongShareSheetFilenameSurvivesToTheUploadURL() throws {
        let snapshot = makeSnapshot()
        let conversation = UUID()
        let name = filename(bytes: 400, extension: ".tar.gz")

        let key = FileServerClient.deterministicStoredKey(
            envelopeID: UUID(), sequence: 7, originalName: name, folder: conversation.uuidString)
        let url = try XCTUnwrap(
            FileServerClient.buildUploadRequest(
                snapshot: snapshot, storedKey: key, contentLength: 1
            ).url
        )

        XCTAssertTrue(url.lastPathComponent.hasSuffix(".gz"), "the final extension survives")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, conversation.uuidString)
        for component in url.pathComponents where component != "/" {
            XCTAssertLessThanOrEqual(component.utf8.count, nameMax)
        }
    }

    /// A retry re-PUTs over the partial blob and the output path GETs it back, so
    /// all four verbs have to resolve the same long key to the same URL. If they
    /// diverge, a retry orphans its own upload.
    func testEveryVerbResolvesTheSameLongKeyToTheSameURL() throws {
        let snapshot = makeSnapshot()
        let key = FileServerClient.makeStoredKey(
            originalName: filename(bytes: 250, extension: ".pdf"),
            uuid: UUID(),
            folder: UUID().uuidString
        )

        let urls = [
            FileServerClient.buildUploadRequest(snapshot: snapshot, storedKey: key, contentLength: 1).url,
            FileServerClient.buildDownloadRequest(snapshot: snapshot, storedKey: key).url,
            FileServerClient.buildProbeRequest(snapshot: snapshot, storedKey: key).url,
            FileServerClient.buildDeleteRequest(snapshot: snapshot, storedKey: key).url,
        ].map { $0?.absoluteString }

        XCTAssertEqual(
            Set(urls).count, 1,
            "upload / download / probe / delete disagree on where a long key lives: \(urls)"
        )
    }

    /// The MKCOL that precedes a nested PUT has to name the same folder segment
    /// the PUT will use, or the server 409s a parent it was never asked to make.
    func testTheCollectionURLMatchesTheUploadsParentForALongKey() throws {
        let snapshot = makeSnapshot()
        let conversation = UUID().uuidString
        let key = FileServerClient.makeStoredKey(
            originalName: filename(bytes: 250, extension: ".pdf"),
            uuid: UUID(),
            folder: conversation
        )
        let collectionKey = String(key[key.startIndex..<key.lastIndex(of: "/")!])

        let put = try XCTUnwrap(
            FileServerClient.buildUploadRequest(snapshot: snapshot, storedKey: key, contentLength: 1).url)
        let mkcol = try XCTUnwrap(
            FileServerClient.buildMkcolRequest(snapshot: snapshot, collectionKey: collectionKey).url)

        // Compared by path components: `deletingLastPathComponent()` leaves a
        // trailing slash that `appending(path:)` never adds, and that difference
        // is presentational, not a different resource.
        XCTAssertEqual(put.deletingLastPathComponent().pathComponents, mkcol.pathComponents)
    }

    // MARK: - Collisions past the cut

    /// Two names that differ only PAST the truncation point produce the same
    /// bounded segment. The 8-hex prefix is the only thing keeping them apart, so
    /// assert it actually does.
    func testTwoComposerAttachmentsWhoseNamesTruncateIdenticallyDoNotCollide() {
        let shared = String(repeating: "a", count: 300)
        let first = FileServerClient.makeStoredKey(originalName: shared + "-one.pdf", uuid: UUID())
        let second = FileServerClient.makeStoredKey(originalName: shared + "-two.pdf", uuid: UUID())

        XCTAssertNotEqual(
            first, second,
            "the truncated segments are identical, so a shared key would silently overwrite one attachment with the other"
        )
    }

    /// Same hazard inside one share envelope, where the 8-hex prefix is FIXED (it
    /// is the envelope's) — only `sequence` separates the two.
    func testTwoAttachmentsInOneEnvelopeWhoseNamesTruncateIdenticallyDoNotCollide() {
        let envelope = UUID()
        let shared = String(repeating: "b", count: 300)
        let first = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 0, originalName: shared + "-one.pdf")
        let second = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 1, originalName: shared + "-two.pdf")

        XCTAssertNotEqual(
            first, second,
            "one envelope, one 8-hex prefix, two names that truncate to the same thing — `sequence` is the only disambiguator and it has to be inside the bounded component"
        )
    }

    /// Idempotent recovery: the share drain re-mints from the persisted envelope
    /// + sequence + name after a relaunch, so a long name must re-mint the SAME
    /// key or the re-PUT lands beside the partial blob instead of over it.
    func testALongShareNameReMintsIdenticallyAcrossRelaunch() {
        let envelope = UUID()
        let name = filename(bytes: 400, extension: ".pdf")
        let folder = UUID().uuidString

        XCTAssertEqual(
            FileServerClient.deterministicStoredKey(
                envelopeID: envelope, sequence: 3, originalName: name, folder: folder),
            FileServerClient.deterministicStoredKey(
                envelopeID: envelope, sequence: 3, originalName: name, folder: folder)
        )
    }
}
