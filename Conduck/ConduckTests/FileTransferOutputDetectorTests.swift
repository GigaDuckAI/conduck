// SPDX-License-Identifier: Apache-2.0

//
//  FileTransferOutputDetectorTests.swift
//  ConduckTests
//
//  Locks the PURE halves of the file-transfer output detector (the network +
//  store plumbing of `detect(...)` is singleton-bound and covered by the
//  founder's on-device QA):
//    • `extractCandidates(from:)` — allowlist filtering (both what earns a
//      probe and what the prose-noise filter refuses), first-appearance dedup,
//      and that extraction is UNCAPPED (the cap lives in `probePlan`, AFTER
//      inbound exclusion, so an echoed inbound name can't displace a real
//      output from the cap window).
//    • `probePlan(candidates:inboundTokens:excludedKeys:claimTokens:)` — the
//      window a pass will probe and whether it saw EVERYTHING. A cut list is an
//      incomplete examination and must not be able to close a turn permanently;
//      the lifetime chip ceiling is what keeps "stays open" from meaning "probes
//      forever".
//    • `probeOrderedCandidates(_:claimTokens:)` — WHICH candidates survive when
//      the cap cuts the list. A truncated window only walks forward when a probe
//      CONFIRMS a file, so a window filled with names that do not exist never
//      advances and the turn closes having never asked about the artifact. The
//      compatibility reserve is what stops a widened allowlist from displacing a
//      handback that already worked.
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

    /// Extraction is UNCAPPED — the cap is applied in `probePlan`, only AFTER
    /// the inbound exclusion. If it ever moves back into extraction, an echoed
    /// inbound name could silently displace a real output from the window.
    func testExtractIsUncapped() {
        let names = (1...(FileTransferOutputDetector.maxCandidates + 4)).map { "file\($0).csv" }
        let out = FileTransferOutputDetector.extractCandidates(from: names.joined(separator: " "))
        XCTAssertEqual(out, names, "extraction returns ALL allowlisted tokens; the cap lives in probePlan")
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

    // MARK: - probePlan (cap, exclusion, truncation)

    func testPlanKeepsEveryEligibleCandidateBelowTheCap() {
        let names = ["a.pdf", "b.csv", "c.png"]
        let plan = FileTransferOutputDetector.probePlan(
            candidates: names, inboundTokens: [], excludedKeys: [])
        XCTAssertEqual(plan.window, names)
        XCTAssertFalse(plan.truncated, "a list that fits was examined in full")
    }

    /// A pass probes a PREFIX of the candidates, so a chatty reply that names
    /// its deliverable past the cap never reaches it. A cut list is by
    /// definition an incomplete examination, which is why it may not stamp the
    /// turn permanently complete at the ordinary grace deadline — that verdict
    /// would lose the unexamined file forever.
    func testMoreEligibleCandidatesThanTheCapMarksThePlanTruncated() {
        let names = (1...(FileTransferOutputDetector.maxCandidates + 1)).map { "file\($0).csv" }
        let plan = FileTransferOutputDetector.probePlan(
            candidates: names, inboundTokens: [], excludedKeys: [])
        XCTAssertEqual(plan.window.count, FileTransferOutputDetector.maxCandidates)
        XCTAssertTrue(plan.truncated)
        XCTAssertFalse(
            FileTransferOutputDetector.scanMayClose(
                turnCreatedAt: Date(timeIntervalSince1970: 0),
                scanStartedAt: Date(timeIntervalSince1970: 0)
                    .addingTimeInterval(FileTransferOutputDetector.outputScanGrace + 1),
                everyProbeDefinitive: true,
                truncated: plan.truncated
            ),
            "a truncated pass must not close the turn at the ordinary grace deadline"
        )
    }

    /// Exclusions run BEFORE the cap, so echoed inbound names can neither eat a
    /// probe slot nor push a real output out of the window.
    func testExclusionsRunBeforeTheCapAndDoNotCountAsTruncation() {
        let names = ["echo.png"] + (1...FileTransferOutputDetector.maxCandidates).map { "out\($0).csv" }
        let plan = FileTransferOutputDetector.probePlan(
            candidates: names, inboundTokens: ["echo.png"], excludedKeys: [])
        XCTAssertEqual(plan.window.count, FileTransferOutputDetector.maxCandidates)
        XCTAssertFalse(plan.window.contains("echo.png"))
        XCTAssertFalse(plan.truncated, "the inbound echo was never eligible in the first place")
    }

    /// Already-chipped keys fall out too, which is what makes the window WALK
    /// forward across passes on a long candidate list.
    func testAlreadyChippedKeysExposeTheNextSliceOfALongList() {
        let names = (1...(FileTransferOutputDetector.maxCandidates + 2)).map { "file\($0).csv" }
        let plan = FileTransferOutputDetector.probePlan(
            candidates: names,
            inboundTokens: [],
            excludedKeys: ["file1.csv", "file2.csv"]
        )
        XCTAssertFalse(plan.window.contains("file1.csv"))
        XCTAssertTrue(plan.window.contains("file11.csv"),
                      "confirming the head of the list exposes candidates the first pass never reached")
    }

    /// The terminator for the walk: a message that already holds its lifetime
    /// allowance of chips can gain nothing from another probe, so the turn
    /// closes without touching the network. Without this, a reply naming
    /// hundreds of files that happen to exist at the served root could walk the
    /// whole list over repeated thread opens, re-arming the per-pass preview
    /// download budget each time.
    func testMessageAtItsLifetimeChipCeilingClosesWithoutProbing() {
        let chipped = Set((1...FileTransferOutputDetector.maxOutputChipsPerMessage).map { "have\($0).csv" })
        let plan = FileTransferOutputDetector.probePlan(
            candidates: ["new.pdf"], inboundTokens: [], excludedKeys: chipped)
        XCTAssertTrue(plan.window.isEmpty)
        XCTAssertFalse(plan.truncated, "an empty window is a complete examination, not a cut one")
    }

    /// A partly-chipped message may only probe its REMAINING allowance, so a
    /// walked window can never overshoot the ceiling.
    func testRemainingAllowanceBoundsTheWindow() {
        let used = FileTransferOutputDetector.maxOutputChipsPerMessage - 2
        let chipped = Set((1...used).map { "have\($0).csv" })
        let names = (1...5).map { "new\($0).pdf" }
        let plan = FileTransferOutputDetector.probePlan(
            candidates: names, inboundTokens: [], excludedKeys: chipped)
        XCTAssertEqual(plan.window.count, 2)
        XCTAssertTrue(plan.truncated)
    }

    /// A reply with no filename-shaped token, or none left after the filters,
    /// needs no network evidence: the reply text is immutable, so no later pass
    /// could disagree. Those turns close immediately, grace window or not.
    func testNothingEligibleClosesTheTurnWithoutProbing() {
        for plan in [
            FileTransferOutputDetector.probePlan(
                candidates: [], inboundTokens: [], excludedKeys: []),
            FileTransferOutputDetector.probePlan(
                candidates: ["mine.png"], inboundTokens: ["mine.png"], excludedKeys: [])
        ] {
            XCTAssertTrue(plan.window.isEmpty)
            XCTAssertFalse(plan.truncated, "an empty window is a complete examination, not a cut one")
        }
    }

    // MARK: - probeOrderedCandidates (which candidates survive an overflow)

    /// Helper: the plan a real pass builds for `reply`, claim set included —
    /// the same two steps `detect` runs, minus the network.
    private func orderedPlan(
        for reply: String,
        inboundTokens: Set<String> = [],
        excludedKeys: Set<String> = []
    ) -> FileTransferOutputDetector.ProbePlan {
        let candidates = FileTransferOutputDetector.extractCandidates(from: reply)
        return FileTransferOutputDetector.probePlan(
            candidates: candidates,
            inboundTokens: inboundTokens,
            excludedKeys: excludedKeys,
            claimTokens: MissingOutputNotice.standaloneClaimTokens(
                in: reply,
                candidates: Set(candidates)
            )
        )
    }

    /// THE regression this ordering exists for. A coding agent reports the files
    /// it touched BEFORE naming what it produced; widening the allowlist to
    /// source extensions let ten `.go` names fill the whole window and push the
    /// deliverable off the end. Truncation keeps the turn open, but the window
    /// only WALKS when a probe CONFIRMS something — and none of those ten exist
    /// at the served root — so the turn closes at `truncatedScanHorizon` having
    /// never once asked about the artifact. The user's file silently never
    /// arrives, on a shape that worked before the widening.
    func testDeliverableNamedAfterTenTouchedSourceFilesStaysInTheWindow() {
        let touched = (1...10).map { "handler\($0).go" }
        let reply = "I updated \(touched.joined(separator: ", ")). "
            + "I've written the summary to deliverable.md."
        let plan = orderedPlan(for: reply)

        XCTAssertEqual(plan.window.count, FileTransferOutputDetector.maxCandidates)
        XCTAssertTrue(plan.truncated, "eleven eligible candidates cannot all be probed")
        XCTAssertEqual(plan.window.first, "deliverable.md",
                       "the compatibility reserve probes the deliverable FIRST, not eleventh")
    }

    /// The same shape with the deliverable on a line of its own — what
    /// `ConverseRequest.fileDeliveryInstruction` actually asks agents for.
    func testStandaloneDeliverableAfterTenTouchedSourceFilesStaysInTheWindow() {
        let touched = (1...10).map { "handler\($0).go" }
        let reply = "I updated \(touched.joined(separator: ", ")).\n\ndeliverable.md"
        let plan = orderedPlan(for: reply)

        XCTAssertTrue(plan.window.contains("deliverable.md"))
        XCTAssertTrue(plan.truncated)
    }

    /// The DUAL starvation, which a claim-only ordering would have introduced:
    /// the deliverable is named in prose while the touched files sit in a bullet
    /// list, so every one of them is "standalone" and the artifact is not. The
    /// compatibility reserve is what holds the line — `md` is an extension the
    /// previous build probed, `go` is not.
    func testProseDeliverableSurvivesABulletListOfStandaloneSourceFiles() {
        let bullets = (1...10).map { "- a\($0).go" }.joined(separator: "\n")
        let reply = "The artifact is deliverable.md.\n\nTouched files:\n\(bullets)"
        let plan = orderedPlan(for: reply)

        XCTAssertEqual(plan.window.first, "deliverable.md",
                       "ten standalone incidental names must not displace the deliverable")
        XCTAssertTrue(plan.truncated)
    }

    /// A benign tech-stack list is filename-shaped, standalone, and entirely
    /// prose. Without the `ecosystemProseTokens` subtraction these ten would rank
    /// as delivery claims and starve a deliverable the reserve does not cover.
    func testFrameworkBulletsDoNotRankAsDeliveryClaims() {
        let stack = [
            "Node.js", "Next.js", "Nuxt.js", "Vue.js", "React.js",
            "Three.js", "Chart.js", "Express.js", "Nest.js", "Ember.js"
        ].map { "- \($0)" }.joined(separator: "\n")
        // `.m4a` is outside the reserve, so ONLY the claim group can save it.
        // `.js` is INSIDE it, so five framework names legitimately hold the head
        // of the window — the question this locks is what happens to the other
        // five. Counted as claims they would fill every remaining slot and cut
        // `narration.m4a` off the end; counted as prose they fall behind it.
        let reply = "Stack:\n\(stack)\n\nnarration.m4a"
        let plan = orderedPlan(for: reply)

        XCTAssertTrue(plan.truncated)
        XCTAssertTrue(plan.window.contains("narration.m4a"),
                      "a framework name on a bullet is prose, not a handover")
        XCTAssertLessThan(
            plan.window.firstIndex(of: "narration.m4a") ?? .max,
            plan.window.firstIndex(of: "Three.js") ?? .max,
            "past the reserve, the real artifact outranks the rest of the stack list"
        )
    }

    /// Group 2 earns its keep for deliverables the reserve cannot know about:
    /// every candidate here uses a newly-admitted extension, so the standalone
    /// claim is the only thing separating the artifact from the noise.
    func testStandaloneClaimOutranksIncidentalMentionsOutsideTheReserve() {
        let touched = (1...10).map { "mod\($0).go" }
        let reply = "Refactored \(touched.joined(separator: ", ")).\n\nbundle.ipynb"
        let plan = orderedPlan(for: reply)

        XCTAssertEqual(plan.window.first, "bundle.ipynb")
        XCTAssertTrue(plan.truncated)
    }

    /// The partition is STABLE inside every group and drops nothing: reordering
    /// is a priority, not a filter. Non-claims stay probeable — on this pass when
    /// the budget reaches them, and on every later one.
    func testPartitionIsStableWithinGroupsAndRetainsEveryCandidate() {
        // b/d are reserve extensions; a/c/e are not; c and e are claims.
        let eligible = ["a.go", "b.md", "c.rs", "d.csv", "e.kt", "f.swift"]
        let ordered = FileTransferOutputDetector.probeOrderedCandidates(
            eligible,
            claimTokens: ["c.rs", "e.kt"]
        )
        XCTAssertEqual(ordered, ["b.md", "d.csv", "c.rs", "e.kt", "a.go", "f.swift"])
        XCTAssertEqual(Set(ordered), Set(eligible), "a reordering may not drop candidates")
        XCTAssertEqual(ordered.count, eligible.count, "…nor duplicate them")
    }

    /// An empty claim set is always safe — it costs ordering quality, never
    /// correctness. This is the shape `MissingOutputNotice` reconstructs with,
    /// and the shape an over-long reply degrades to.
    func testNoClaimsLeavesFirstAppearanceOrderInsideEachGroup() {
        let eligible = ["a.go", "b.md", "c.rs", "d.csv"]
        XCTAssertEqual(
            FileTransferOutputDetector.probeOrderedCandidates(eligible, claimTokens: []),
            ["b.md", "d.csv", "a.go", "c.rs"]
        )
    }

    /// The reserve is a HEAD, not an unbounded class: it protects exactly what
    /// the previous build's cap would have reached, so an eleventh reserve-
    /// extension name gets no special standing over a claim.
    func testReserveIsBoundedByThePreviousBuildsCap() {
        let old = (1...8).map { "old\($0).csv" }
        let ordered = FileTransferOutputDetector.probeOrderedCandidates(
            old + ["new.m4a"],
            claimTokens: ["new.m4a"]
        )
        XCTAssertEqual(
            Array(ordered.prefix(MissingOutputNotice.evidenceFloorMaxCandidates)),
            Array(old.prefix(MissingOutputNotice.evidenceFloorMaxCandidates))
        )
        XCTAssertEqual(ordered[MissingOutputNotice.evidenceFloorMaxCandidates], "new.m4a",
                       "past the previous build's cap, a claim outranks a reserve extension")
    }

    /// Ordering may only ever be reached on the truncating branch. That is what
    /// keeps `MissingOutputNotice`'s window reconstruction exact without the
    /// notice knowing anything about claims: on the branch a notice can survive,
    /// the window is the WHOLE eligible list and no ordering runs.
    func testAWindowThatHoldsEverythingIsNeverReordered() {
        let reply = "Touched a.go and b.go.\n\nreport.pdf"
        let candidates = FileTransferOutputDetector.extractCandidates(from: reply)
        let raw = FileTransferOutputDetector.probePlan(
            candidates: candidates, inboundTokens: [], excludedKeys: [])
        let ordered = orderedPlan(for: reply)

        XCTAssertFalse(raw.truncated)
        XCTAssertEqual(raw.window, candidates, "an untruncated window is first-appearance order")
        XCTAssertEqual(ordered.window, raw.window,
                       "claims cannot change a window that already holds everything")
    }

    /// The claim scan is bounded by reply SIZE, because a body of bare newlines
    /// is one array element per byte. Over the ceiling a pass keeps the
    /// compatibility reserve and skips claims — it degrades to the ordering it
    /// would have had anyway, never to something worse.
    func testOversizedReplySkipsTheClaimScanAndKeepsTheReserve() async {
        let filler = String(
            repeating: "\n",
            count: FileTransferOutputDetector.maxClaimOrderingReplyBytes + 1
        )
        let claims = await FileTransferOutputDetector.standaloneClaimTokensOffMainActor(
            in: "deliverable.md" + filler,
            candidates: ["deliverable.md"]
        )
        XCTAssertTrue(claims.isEmpty, "past the ceiling the scan is skipped, not run")

        let ordered = FileTransferOutputDetector.probeOrderedCandidates(
            (1...10).map { "m\($0).go" } + ["deliverable.md"],
            claimTokens: claims
        )
        XCTAssertEqual(ordered.first, "deliverable.md", "the reserve still applies")
    }

    /// A reply UNDER the ceiling really does get its claims scanned — the guard
    /// above must not be a permanent off switch.
    func testReplyUnderTheCeilingIsScannedForClaims() async {
        let claims = await FileTransferOutputDetector.standaloneClaimTokensOffMainActor(
            in: "Touched main.go.\n\ndeliverable.md\n",
            candidates: ["main.go", "deliverable.md"]
        )
        XCTAssertEqual(claims, ["deliverable.md"])
    }

    /// The reserve borrows the notice's frozen constants because a second copy of
    /// a thirty-entry list drifts. That borrowing is only sound while the frozen
    /// set really is a subset of today's rules — otherwise the reserve would
    /// prioritise extensions the extractor never admits.
    func testTheReserveAllowlistIsASubsetOfTodaysProbeRules() {
        XCTAssertTrue(
            MissingOutputNotice.evidenceFloorAllowlist
                .isSubset(of: FileTransferOutputDetector.outputAllowlist),
            "the previous build's allowlist must still be probeable today"
        )
        XCTAssertLessThanOrEqual(
            MissingOutputNotice.evidenceFloorMaxCandidates,
            FileTransferOutputDetector.maxCandidates,
            "a reserve larger than the window would leave no room for anything else"
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
