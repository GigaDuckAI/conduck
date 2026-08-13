// SPDX-License-Identifier: Apache-2.0

//
//  FileTransferOutputDetectorTests.swift
//  ConduckTests
//
//  Locks the PURE halves of the file-transfer output detector. The automatic
//  lane's own arithmetic — one listing of one dispatch folder — lives in
//  `OutboxReconcileTests`; what is pinned here is the machinery that survived
//  the demolition of automatic prose probing:
//    • `extractCandidates(from:)` — allowlist filtering (both what earns a probe
//      and what the prose-noise filter refuses), first-appearance dedup, and
//      that extraction is UNCAPPED (the cap lives in `probeNamedCandidates`,
//      AFTER the exclusions, so an echoed inbound name can't displace a real
//      output from the window).
//    • `boundedRunInput(_:)` — the cost bound that keeps an adversary-controlled
//      reply linear rather than quadratic. It matters MORE now, not less: the
//      regex only ever runs behind a user tap, and a tap is not consent to burn
//      a phone's CPU.
//    • `probeNamedCandidates` — the tap-only lane's zero-network exits.
//    • `scanMayClose` — the age ladder, and the verdict ladder over it.
//
//  WHAT IS NO LONGER HERE, and why: the probe PLAN, the claim ORDERING and the
//  inbound-exclusion set. All three existed to make automatic prose probing
//  survivable, and prose no longer triggers any network read. The ordering in
//  particular could never have worked under the folder design — the candidate
//  regex cannot cross a `/`, so a file delivered into
//  `<conversationID>/out-<nonce>/` yields only its bare leaf and no amount of
//  reordering finds it.
//
//  Deterministic + headless: no network, no Core Data, no Keychain. Synthetic
//  fixtures only; no real filenames/keys logged.
//

import XCTest
@testable import Conduck

final class FileTransferOutputDetectorTests: XCTestCase {

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

    /// Extraction is UNCAPPED — the cap is applied in `probeNamedCandidates`,
    /// only AFTER the exclusions. If it ever moves back into extraction, an
    /// echoed inbound name could silently displace a real output from the window.
    func testExtractIsUncapped() {
        let names = (1...(FileTransferOutputDetector.maxCandidates + 4)).map { "file\($0).csv" }
        let out = FileTransferOutputDetector.extractCandidates(from: names.joined(separator: " "))
        XCTAssertEqual(out, names,
                       "extraction returns ALL allowlisted tokens; the cap lives past the exclusions")
    }

    // MARK: - Allowlist coverage

    /// Audio earns a probe. This is a voice-first product whose agents
    /// synthesise speech and clips, and the allowlist is the gate the name has
    /// to pass to become a candidate at all: a tail that is not in it is never
    /// asked about, so the file it names can never be handed back.
    func testAudioOutputsAreCandidates() {
        let reply = "Rendered the narration: episode.m4a, episode.mp3, master.wav and archive.flac."
        XCTAssertEqual(
            FileTransferOutputDetector.extractCandidates(from: reply),
            ["episode.m4a", "episode.mp3", "master.wav", "archive.flac"]
        )
    }

    /// Unambiguous artifact tails with no prose shape: notebooks and TOML, plus
    /// `ppt` — the symmetry `doc` and `xls` each have with their modern twin.
    func testNotebookConfigAndLegacyOfficeOutputsAreCandidates() {
        let reply = "Wrote analysis.ipynb, pyproject.toml and the deck slides.ppt."
        XCTAssertEqual(
            FileTransferOutputDetector.extractCandidates(from: reply),
            ["analysis.ipynb", "pyproject.toml", "slides.ppt"]
        )
    }

    /// The showcase gateways are coding agents, so source files are a modal
    /// deliverable.
    func testSourceOutputsAreCandidates() {
        let reply = "Added main.go, lib.rs, App.java, Theme.scss and paper.tex."
        XCTAssertEqual(
            FileTransferOutputDetector.extractCandidates(from: reply),
            ["main.go", "lib.rs", "App.java", "Theme.scss", "paper.tex"]
        )
    }

    /// The allowlist doubles as the prose-noise filter, so the refusals matter
    /// as much as the additions. `.env` is the sharpest: the canonical filename
    /// can't match the regex anyway (no base before the dot) while ordinary code
    /// prose matches every time — all noise, and the artifact it would name is a
    /// secrets file this app must never pull into the conversation store.
    func testRefusedExtensionsStayOutOfTheCandidateSet() {
        let reply = "read process.env, opened cache.db, wrote blob.bin, dumped raw.dat, "
            + "checked section 4.c and store.sqlite"
        XCTAssertEqual(FileTransferOutputDetector.extractCandidates(from: reply), [],
                       "generic/secret/one-character tails must not reach the network")
    }

    // MARK: - probeNamedCandidates (the tap-only lane's zero-network exits)

    /// Nothing to ask about ⇒ no request and a CONCLUSIVE answer. This is the
    /// only branch of the manual lane that is reachable without a live server,
    /// and it is the one that has to be right: a tap on a reply that names
    /// nothing must not report "could not check".
    func testEmptyCandidateListProbesNothingAndIsConclusive() async {
        let result = await FileTransferOutputDetector.probeNamedCandidates(
            candidates: [],
            snapshot: Self.snapshot(),
            excludedKeys: []
        )
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.conclusive, "no names is a complete answer, not an unfinished one")
    }

    /// Every candidate excluded ⇒ likewise no request. The exclusions are the
    /// conversation's own inbound uploads plus the keys already on the message,
    /// and a reply that only echoes those has nothing left to look for.
    func testFullyExcludedCandidateListProbesNothingAndIsConclusive() async {
        let result = await FileTransferOutputDetector.probeNamedCandidates(
            candidates: ["mine.png", "also-mine.csv"],
            snapshot: Self.snapshot(),
            excludedKeys: ["mine.png", "also-mine.csv"]
        )
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.conclusive)
    }

    // MARK: - scanMayClose (the age ladder)

    /// A pass that could not learn anything definitive never closes the turn,
    /// whatever the clock says. Closing is permanent, so it is reserved for a
    /// pass that actually got an answer.
    func testNonDefinitiveEvidenceNeverClosesTheTurn() {
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: Date(timeIntervalSince1970: 0),
                scanStartedAt: Date(timeIntervalSince1970: 10 * 60 * 60),
                everyProbeDefinitive: false,
                truncated: false
            ),
            "an hour of waiting cannot substitute for evidence"
        )
    }

    /// A truncated pass may not close at the ORDINARY deadline — the pass never
    /// handed over the tail, and stamping it complete throws away whatever is
    /// there. It closes at the far longer horizon instead.
    func testTruncatedPassWaitsForTheLongerHorizon() {
        let created = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: created,
                scanStartedAt: created.addingTimeInterval(
                    FileTransferOutputDetector.outputScanGrace + 1),
                everyProbeDefinitive: true,
                truncated: true
            )
        )
        XCTAssertTrue(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: created,
                scanStartedAt: created.addingTimeInterval(
                    FileTransferOutputDetector.truncatedScanHorizon + 1),
                everyProbeDefinitive: true,
                truncated: true
            )
        )
    }

    /// The two caps answer different questions and must stay independent: one
    /// bounds a folder minted for a single reply, the other a search over reply
    /// prose. The message ceiling is what bounds the walk across passes, so it
    /// has to sit above the per-pass cap or the far end of a long list would be
    /// pinned at the same entry forever.
    func testTheThreeCapsHoldTheirRelationship() {
        XCTAssertEqual(
            FileTransferOutputDetector.maxOutputChipsPerMessage,
            FileTransferOutputDetector.maxCandidates * 2,
            "a ceiling at parity with the per-pass cap makes the walk an illusion"
        )
        XCTAssertLessThan(
            FileTransferOutputDetector.maxOutboxEntriesPerReply,
            FileTransferOutputDetector.maxOutputChipsPerMessage,
            "one pass may never exhaust a message's lifetime allowance in a single listing"
        )
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

    // MARK: - Shared fixture

    /// A synthetic ready lane. Never contacted by any test in this file — the
    /// only `probeNamedCandidates` branches exercised here return before the
    /// network.
    private static func snapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/")!,
            username: "conduck",
            credential: "secret",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }
}
