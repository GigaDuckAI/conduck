//
//  FileTransferOutputDetectorTests.swift
//  ConduckTests
//
//  Locks the PURE halves of the file-transfer output detector (the network +
//  store plumbing of `detect(...)` is singleton-bound and covered by the
//  founder's on-device QA):
//    • `extractCandidates(from:)` — allowlist filtering, first-appearance
//      dedup, and that extraction is UNCAPPED (the cap moved into `detect`
//      AFTER inbound exclusion, so an echoed inbound name can't displace a
//      real output from the cap window).
//    • `inboundStoredKeyTokens(in:)` — the inbound-exclusion set: storedKeys
//      of non-agent turns (full key + last path component of a nested key),
//      agent-side keys NOT excluded, nil storedKeys ignored, unknown roles
//      treated as inbound (conservative: a suppressed chip beats a wrong one).
//
//  WHY this exists (regression lock): an agent reply that merely ECHOES an
//  inbound file's stored name (`7b06c382__image.jpg`) used to probe `.exists`
//  — the file IS on the server, because the app put it there — and rendered a
//  download chip offering the user their own upload back.
//
//  Deterministic + headless: no network, no Core Data, no Keychain. Synthetic
//  fixtures only; no real filenames/keys logged.
//

import XCTest
@testable import Conduck

final class FileTransferOutputDetectorTests: XCTestCase {

    // MARK: - Fixtures

    private func message(
        role: String,
        storedKeys: [String?]
    ) -> MessageRecord {
        let attachments = storedKeys.enumerated().map { index, key in
            AttachmentRecord(
                id: UUID(),
                mimeType: "application/octet-stream",
                filename: nil,
                thumbnailData: nil,
                extractedText: nil,
                width: 0,
                height: 0,
                byteSize: 0,
                sequence: index,
                createdAt: Date(timeIntervalSince1970: 0),
                isServerReference: key != nil,
                storedKey: key
            )
        }
        return MessageRecord(
            id: UUID(),
            role: role,
            text: "",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: "phone",
            attachments: attachments
        )
    }

    // MARK: - extractCandidates

    func testExtractKeepsOnlyAllowlistedExtensions() {
        let reply = "See report.pdf and data.csv; visit example.com, not v1.1 or e.g. anything.exe"
        let out = FileTransferOutputDetector.extractCandidates(from: reply)
        XCTAssertEqual(out, ["report.pdf", "data.csv"],
                       "only allowlisted extensions survive; prose tokens and .com/.exe drop")
    }

    func testExtractDedupsPreservingFirstAppearance() {
        let reply = "wrote out.zip, checked out.zip again, then made notes.md"
        let out = FileTransferOutputDetector.extractCandidates(from: reply)
        XCTAssertEqual(out, ["out.zip", "notes.md"], "dedup keeps first appearance order")
    }

    /// Extraction is UNCAPPED — `detect` caps at 5 only AFTER the inbound
    /// exclusion. If the cap ever moves back into extraction, an echoed inbound
    /// name could silently displace the 5th real output.
    func testExtractIsUncapped() {
        let names = (1...8).map { "file\($0).csv" }
        let out = FileTransferOutputDetector.extractCandidates(from: names.joined(separator: " "))
        XCTAssertEqual(out, names, "extraction returns ALL allowlisted tokens; the cap lives in detect")
    }

    // MARK: - Cost bound (boundedRunInput)

    /// The bound must be INVISIBLE on real content: no over-long run, so the
    /// input is returned unchanged (identical instance semantics aside) and the
    /// extracted tokens are byte-identical.
    func testRunBoundLeavesRealContentUntouched() {
        let reply = "Wrote report.pdf, archive.tar.gz and a-long_file.name.v2.csv for you."
        XCTAssertEqual(FileTransferOutputDetector.boundedRunInput(reply), reply,
                       "a reply with no over-long token run must pass through verbatim")
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: reply),
                       ["report.pdf", "archive.tar.gz", "a-long_file.name.v2.csv"])
    }

    /// A run at exactly the ceiling is a filename a server could actually hold,
    /// so it must survive.
    func testRunAtTheCeilingSurvives() {
        let base = String(repeating: "a", count: FileTransferOutputDetector.maxFilenameRunScalars - 4)
        let name = base + ".csv"          // exactly maxFilenameRunScalars scalars
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: "wrote \(name) ok"), [name],
                       "a name at POSIX NAME_MAX is storable and must still be a candidate")
    }

    /// THE bound: a hostile unbroken run is excised, and — the part that makes it
    /// free — a real filename elsewhere in the SAME reply is still found.
    func testHostileRunIsExcisedButRealCandidateSurvives() {
        let hostile = String(repeating: "a", count: 400_000)
        let reply = "\(hostile) but also report.pdf"
        let started = Date()
        let out = FileTransferOutputDetector.extractCandidates(from: reply)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(out, ["report.pdf"],
                       "the over-long run yields no storable name; the real one is untouched")
        // Unbounded, 400 KB of one run is ~20 minutes of ICU backtracking; the
        // bound makes it milliseconds. A very loose ceiling keeps this from
        // flaking on a loaded CI machine while still failing loudly on a
        // regression to quadratic.
        XCTAssertLessThan(elapsed, 5.0,
                          "extraction must be linear in the reply length, not quadratic in its longest run")
    }

    /// The excision inserts a SPACE, so the text on either side cannot fuse into
    /// a token that was never in the reply.
    func testExcisionCannotFuseNeighbouringTokens() {
        let reply = "note" + String(repeating: "z", count: 300) + ".pdf"
        // One single run (the letters, the digits-free filler and `.pdf` are all
        // token scalars) → excised whole, nothing left to match.
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: reply), [],
                       "a >NAME_MAX run yields no storable candidate")
        let split = "note " + String(repeating: "z", count: 300) + " .pdf"
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: split), [],
                       "excising the middle run must not join `note` to `.pdf`")
    }

    /// The case a silent file loss would hide in: a hostile run GLUED to a real
    /// filename with no separator. It is one single run either way, so the
    /// filename is not a distinguishable token to begin with — the unbounded
    /// pattern yields the whole run as one >NAME_MAX "filename" (verified as an
    /// oracle at 8 KB: a single 8202-character token, never `report.pdf`), and
    /// the bound yields nothing. Both are conclusive with zero chips, so the
    /// `outputScanDone` bookkeeping does not diverge either. ONE separator —
    /// whitespace or punctuation, anything outside the token class — is all it
    /// takes to make the name extractable, under both.
    func testAGluedHostileRunHidesTheFilenameFromEitherPass() {
        let hostile = String(repeating: "a", count: 8 * 1024)
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: hostile + "report.pdf"), [],
                       "a name glued to a >NAME_MAX run is not a separate token — no pass could extract it")
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: "report.pdf" + hostile), [],
                       "reverse adjacency likewise: the greedy tail eats the extension")
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: hostile + " report.pdf"), ["report.pdf"])
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: hostile + ")report.pdf"), ["report.pdf"],
                       "any non-token character ends the run — the separator need not be whitespace")
    }

    // MARK: - inboundStoredKeyTokens

    func testUserTurnFlatKeyIsExcluded() {
        let messages = [message(role: "user", storedKeys: ["7b06c382__image.jpg"])]
        let tokens = FileTransferOutputDetector.inboundStoredKeyTokens(in: messages)
        XCTAssertEqual(tokens, ["7b06c382__image.jpg"],
                       "a flat inbound key lands in the exclusion set verbatim")
    }

    /// Nested key → BOTH the full key and its last path component are excluded:
    /// the candidate regex can't match across `/`, so a reply echoing
    /// `<convID>/<key>` only ever surfaces the filename segment.
    func testUserTurnNestedKeyExcludesFullKeyAndLastComponent() {
        let key = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/a1b2c3d4__report.pdf"
        let messages = [message(role: "user", storedKeys: [key])]
        let tokens = FileTransferOutputDetector.inboundStoredKeyTokens(in: messages)
        XCTAssertTrue(tokens.contains(key))
        XCTAssertTrue(tokens.contains("a1b2c3d4__report.pdf"),
                      "the last path component is what the reply-side regex can actually match")
        XCTAssertEqual(tokens.count, 2)
    }

    /// Agent-side storedKeys (previously detected outputs) are NOT excluded — a
    /// later reply re-mentioning a genuine output file should still chip it.
    func testAgentTurnKeysAreNotExcluded() {
        let messages = [
            message(role: "user", storedKeys: ["7b06c382__in.png"]),
            message(role: "agent", storedKeys: ["summary.pdf"])
        ]
        let tokens = FileTransferOutputDetector.inboundStoredKeyTokens(in: messages)
        XCTAssertTrue(tokens.contains("7b06c382__in.png"))
        XCTAssertFalse(tokens.contains("summary.pdf"),
                       "agent-side outputs stay chippable on a later re-mention")
    }

    func testNilStoredKeysAreIgnored() {
        let messages = [message(role: "user", storedKeys: [nil, nil])]
        XCTAssertTrue(FileTransferOutputDetector.inboundStoredKeyTokens(in: messages).isEmpty,
                      "attachments without a storedKey contribute nothing")
    }

    /// Unknown/legacy roles count as inbound — the conservative direction: a
    /// wrongly-suppressed chip beats offering the user their own file back.
    func testUnknownRoleCountsAsInbound() {
        let messages = [message(role: "", storedKeys: ["deadbeef__odd.txt"])]
        let tokens = FileTransferOutputDetector.inboundStoredKeyTokens(in: messages)
        XCTAssertTrue(tokens.contains("deadbeef__odd.txt"),
                      "anything that isn't the agent's own turn is treated as inbound")
    }
}
