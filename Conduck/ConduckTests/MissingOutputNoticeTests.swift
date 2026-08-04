// SPDX-License-Identifier: Apache-2.0

// Conduck
// MissingOutputNoticeTests.swift
//
// Locks the PURE gate behind the "this reply named a file that isn't on your
// file server" row. The row is the ONLY place the app makes a claim about the
// user's own server out of a heuristic, so the tests here are weighted the way
// the feature is: the NEGATIVE cases (it must stay silent) are the ones that
// matter, because a notice that cries wolf on ordinary prose is worse than the
// silence it replaced.
//
// Six independent gates, each with its own section below:
//   1. `isEvaluable` — agent role, scan CLOSED (`outputScanDone == true`, which
//      under `FileTransferOutputDetector.scanMayClose` already excludes auth /
//      certificate / 5xx / transport failures AND premature misses inside the
//      grace window), an owning dispatch lane, and NO attachment carrying a
//      stored key or a server-reference flag — production's own exclusion
//      predicate, so the reconstruction's empty exclusion set is the one the
//      closing pass used.
//   2. `standaloneClaimTokens` — the structural prose discriminator: a
//      handover stands on its own line, a mention shares one.
//   3. `ecosystemProseTokens` — the short tail the line rule can't reach.
//   4. `shouldSurface` — current-lane match, non-truncated plan, and the token
//      actually inside the window a closing pass PROBED.
//   5. The evidence floor — the marker records that a pass closed the turn, not
//      which build's probe rules it ran under, so the window is the
//      INTERSECTION of today's rules and the frozen older ones. A name only
//      today's wider allowlist admits was never asked about by the build that
//      may have closed the turn, and an unasked question is not evidence.
//   6. The maximal universe — the marker is equally silent about the inbound
//      exclusion set the pass filtered with, and that set is device state that
//      can be smaller at probe time (a failed fetch, a still-syncing upload).
//      A pass filtering with fewer exclusions faced a longer list, which the
//      cap may have cut, so truncation is judged against the longest list any
//      pass could have seen.
//
// Deterministic + headless: no network, no Core Data, no Keychain. Synthetic
// fixtures only; no real filenames/keys.

import XCTest
@testable import Conduck

final class MissingOutputNoticeTests: XCTestCase {

    // MARK: - Fixtures

    private let laneID = String(repeating: "a", count: 64)
    private let otherLaneID = String(repeating: "b", count: 64)

    /// `serverFileKeys` builds the ordinary delivered chip (flag AND key).
    /// `keyOnlyKeys` and `flagOnlyCount` build the two PARTIAL shapes:
    /// `isServerReference` and `storedKey` are separate CloudKit fields that
    /// `AttachmentRecord.init(managedObject:)` nil-coalesces independently, so
    /// either can be present without the other on a still-syncing row.
    private func agentTurn(
        text: String = "",
        outputScanDone: Bool? = true,
        outputScanLaneID: String? = nil,
        serverFileKeys: [String] = [],
        keyOnlyKeys: [String] = [],
        flagOnlyCount: Int = 0,
        role: String = "agent"
    ) -> MessageRecord {
        var attachments: [AttachmentRecord] = []
        func append(key: String?, isServerReference: Bool) {
            attachments.append(AttachmentRecord(
                id: UUID(),
                mimeType: "application/octet-stream",
                filename: key,
                thumbnailData: nil,
                extractedText: nil,
                width: 0,
                height: 0,
                byteSize: 0,
                sequence: attachments.count,
                createdAt: Date(timeIntervalSince1970: 0),
                isServerReference: isServerReference,
                storedKey: key
            ))
        }
        for key in serverFileKeys { append(key: key, isServerReference: true) }
        for key in keyOnlyKeys { append(key: key, isServerReference: false) }
        for _ in 0..<flagOnlyCount { append(key: nil, isServerReference: true) }
        return MessageRecord(
            id: UUID(),
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: "iphone",
            outputScanDone: outputScanDone,
            outputScanLaneID: outputScanLaneID ?? laneID,
            attachments: attachments
        )
    }

    /// The production derivation, minus the actor hop.
    private func claims(
        _ reply: String,
        inbound: Set<String> = []
    ) -> MissingOutputNotice.ReplyClaims {
        MissingOutputNotice.replyClaims(
            reply: reply,
            candidates: FileTransferOutputDetector.extractCandidates(from: reply),
            inboundTokens: inbound
        )
    }

    /// End-to-end verdict on a reply, with every gate other than the reply text
    /// itself held OPEN. Anything that returns false here was refused by the
    /// prose filter, which is the thing under test in most of this file.
    private func surfaces(_ reply: String, inbound: Set<String> = []) -> Bool {
        MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: claims(reply, inbound: inbound)
        )
    }

    // MARK: - 1. isEvaluable — the record-level gate

    func testEvaluableForClosedOwnedEmptyHandedAgentTurn() {
        XCTAssertTrue(MissingOutputNotice.isEvaluable(agentTurn()))
    }

    func testUserTurnIsNeverEvaluable() {
        XCTAssertFalse(MissingOutputNotice.isEvaluable(agentTurn(role: "user")))
    }

    func testPendingScanIsNotEvaluable() {
        // `outputScanDone == false` conflates never-attempted, transport
        // failure, certificate refusal and a provisional in-grace miss. None of
        // those is evidence of anything, so none of them may produce a notice.
        XCTAssertFalse(MissingOutputNotice.isEvaluable(agentTurn(outputScanDone: false)))
    }

    func testLegacyNilScanMarkerIsNotEvaluable() {
        XCTAssertFalse(MissingOutputNotice.isEvaluable(agentTurn(outputScanDone: nil)))
    }

    func testOwnerlessTurnIsNotEvaluable() {
        // No dispatch lane ⇒ the delivery instruction was never spliced, so the
        // agent was never asked to hand a file back.
        let message = MessageRecord(
            id: UUID(),
            role: "agent",
            text: "report.pdf",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDevice: "iphone",
            outputScanDone: true,
            outputScanLaneID: nil
        )
        XCTAssertFalse(MissingOutputNotice.isEvaluable(message))
    }

    func testAnyDeliveredChipSuppressesTheWholeTurn() {
        // The lane demonstrably worked this turn. Deliberate and documented:
        // a partial handback stays silent about the files that did NOT arrive.
        let message = agentTurn(text: "a.pdf\nb.pdf", serverFileKeys: ["a.pdf"])
        XCTAssertFalse(MissingOutputNotice.isEvaluable(message))
    }

    func testStoredKeyWithoutTheServerFlagSuppressesTheWholeTurn() {
        // The gate must match production's EXCLUSION predicate, which is
        // `attachments.compactMap(\.storedKey)` — not the server-reference flag.
        // A key the reconstruction ignores is one `probePlan` filtered out, took
        // budget for, or (at the chip ceiling) closed the turn over WITHOUT
        // probing anything, so the reconstructed window would claim more than
        // any pass examined.
        let message = agentTurn(text: "a.pdf\nb.pdf", keyOnlyKeys: ["a.pdf"])
        XCTAssertFalse(MissingOutputNotice.isEvaluable(message))
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: message,
            currentLaneID: laneID,
            claims: claims("a.pdf\nb.pdf")
        ))
    }

    func testStoredKeyUnrelatedToTheReplyStillSuppresses() {
        // The exclusion set costs budget whether or not its keys appear in the
        // reply — `min(maxCandidates, maxOutputChipsPerMessage - excludedKeys
        // .count)` — so a key that shares nothing with the text still means the
        // pass probed a shorter window than this reconstruction rebuilds.
        XCTAssertFalse(MissingOutputNotice.isEvaluable(
            agentTurn(text: "report.pdf", keyOnlyKeys: ["9f21__unrelated.png"])
        ))
    }

    func testServerFlagWithoutAStoredKeySuppressesTheWholeTurn() {
        // The inverse partial row: a delivered output whose flag has synced and
        // whose key has not. It contributes no exclusion, but it is still a
        // handback in flight, and the lane demonstrably worked.
        XCTAssertFalse(MissingOutputNotice.isEvaluable(
            agentTurn(text: "report.pdf", flagOnlyCount: 1)
        ))
    }

    // MARK: - 2. The prose discriminator — NEGATIVE cases

    func testIncidentalMentionsInProseNeverSurface() {
        // Every one of these is a real shape a coding agent produces, and every
        // one would fire on a naive "the reply contains a filename" rule.
        let prose = [
            "Updated README.md and package.json; all tests pass.",
            "Changed App.swift, Theme.scss, and schema.sql.",
            "This uses Node.js with Express.js and Chart.js.",
            "I couldn't create report.pdf because the destination was read-only.",
            "README.md lives in docs/.",
            "I reviewed report.pdf but made no changes.",
            "Look at src/index.js for the handler.",
            "Your config.yaml already sets that flag.",
            "Done.go ahead and restart the service."
        ]
        for reply in prose {
            XCTAssertFalse(surfaces(reply), "prose must not surface a notice: \(reply.prefix(24))…")
        }
    }

    func testHeadingIsNotAHandover() {
        // Markdown heading markers are deliberately NOT stripped, so a section
        // title can never normalize to a bare token.
        XCTAssertFalse(surfaces("## report.pdf\n\nSome notes about it."))
    }

    func testFencedBlockLinesAreNotHandovers() {
        // A fenced block is quoted material — a listing, command output, file
        // contents — where bare filenames on their own lines are the norm.
        let reply = """
        Here is what the folder holds:

        ```
        report.pdf
        notes.md
        ```

        Nothing was written.
        """
        XCTAssertFalse(surfaces(reply))
    }

    func testTildeFencedBlockLinesAreNotHandovers() {
        XCTAssertFalse(surfaces("~~~\nreport.pdf\n~~~"))
    }

    func testEchoedInboundUploadNeverSurfaces() {
        // The turn text tells the agent each uploaded file's stored name, so a
        // reply repeating it is the app hearing its own voice.
        XCTAssertFalse(surfaces("7b06c382__notes.md", inbound: ["7b06c382__notes.md"]))
    }

    func testReplyWithNoFilenameAtAllNeverSurfaces() {
        XCTAssertFalse(surfaces("All done — nothing to hand over this time."))
    }

    // MARK: - 2b. The prose discriminator — POSITIVE cases

    func testBareFilenameReplySurfaces() {
        // The exact failure that motivated this: a reply whose entire content
        // is the filename, with no explanation and no file on the server.
        XCTAssertTrue(surfaces("bowl_on_scale_poem.md"))
    }

    func testFilenameOnItsOwnLineSurfaces() {
        let reply = """
        I've written the poem you asked for.

        bowl_on_scale_poem.md

        Let me know if you want a different meter.
        """
        XCTAssertTrue(surfaces(reply))
    }

    func testWrappedAndListedHandoversSurface() {
        // The forms an agent actually uses when it puts a deliverable on its
        // own line: inline code, emphasis, list markers, trailing punctuation.
        let forms = [
            "`report.pdf`",
            "**report.pdf**",
            "- report.pdf",
            "* `report.pdf`",
            "1. report.pdf",
            "2) report.pdf",
            "report.pdf."
        ]
        for form in forms {
            XCTAssertTrue(
                surfaces("Here you go:\n\n\(form)\n"),
                "handover form must surface: \(form)"
            )
        }
    }

    func testNormalizationLeavesUnderscoresAlone() {
        // `_` is an ordinary filename character; stripping it as emphasis would
        // mangle a real name into a token that matches nothing.
        XCTAssertEqual(MissingOutputNotice.normalizedClaimLine("_config.md"), "_config.md")
        XCTAssertEqual(MissingOutputNotice.normalizedClaimLine("- **`out.csv`**."), "out.csv")
    }

    // MARK: - 3. The ecosystem tail

    func testFrameworkNameInAStackListDoesNotSurface() {
        // Survives the line rule (it IS alone on its line) and is caught here.
        let reply = """
        The stack is:

        - Node.js
        - Vue.js
        """
        XCTAssertFalse(surfaces(reply))
    }

    func testGenuineSourceFileStillSurfaces() {
        // The denylist must not be a blanket ban on the extensions it mentions.
        XCTAssertTrue(surfaces("Wrote the handler:\n\nrate_limiter.js\n"))
    }

    // MARK: - 4. shouldSurface — lane, truncation, and probe-window gates

    func testRemovedLaneRetiresTheNotice() {
        // No configured ready lane ⇒ the verdict describes a server that is no
        // longer in play, and a warning about a deleted setup is worse than
        // silence.
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: "report.pdf"),
            currentLaneID: nil,
            claims: claims("report.pdf")
        ))
    }

    func testRepointedLaneRetiresTheNotice() {
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: "report.pdf"),
            currentLaneID: otherLaneID,
            claims: claims("report.pdf")
        ))
    }

    func testTruncatedPlanNeverSurfaces() {
        // `scanMayClose` lets a TRUNCATED pass close at `truncatedScanHorizon`
        // having probed only a prefix, so the tail carries a definitive-looking
        // marker over evidence never gathered. The binding cap is the floor's
        // (see section 5): whichever build closed the turn, the narrower one
        // stopped short.
        let names = (0..<(MissingOutputNotice.evidenceFloorMaxCandidates + 1))
            .map { "deliverable\($0).pdf" }
        let reply = names.joined(separator: "\n")
        let derived = claims(reply)
        XCTAssertTrue(derived.truncated, "fixture must actually overflow the probe window")
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    func testExactlyFullPlanIsNotTruncatedAndSurfaces() {
        let names = (0..<MissingOutputNotice.evidenceFloorMaxCandidates)
            .map { "deliverable\($0).pdf" }
        let reply = names.joined(separator: "\n")
        let derived = claims(reply)
        XCTAssertFalse(derived.truncated)
        XCTAssertTrue(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    func testStandaloneTokenOutsideTheProbedWindowNeverSurfaces() {
        // Belt-and-braces on the same hole as truncation: a claim the app has
        // no probe evidence for must not become a claim to the user.
        let derived = MissingOutputNotice.ReplyClaims(
            probedWindow: ["probed.pdf"],
            truncated: false,
            standaloneClaims: ["unprobed.pdf"]
        )
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: "unprobed.pdf"),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    func testEmptyProbeWindowNeverSurfaces() {
        let derived = MissingOutputNotice.ReplyClaims(
            probedWindow: [],
            truncated: false,
            standaloneClaims: ["report.pdf"]
        )
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: "report.pdf"),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    // MARK: - 5. The evidence floor — a marker from an unknown build

    /// THE case this section exists for. `outputScanDone` says a pass closed
    /// the turn; it does not say which build's rules that pass ran under, and
    /// the probe allowlist widens over time. A turn closed before an extension
    /// was admitted was never asked about that name at all, so the app holds no
    /// evidence and may claim none — even though today's rules would happily
    /// have probed it.
    func testClaimOnlyTodaysAllowlistAdmitsNeverSurfaces() {
        for reply in ["narration.mp3", "main.go", "episode.m4a", "Theme.scss"] {
            XCTAssertTrue(
                FileTransferOutputDetector.extractCandidates(from: reply).count == 1,
                "fixture must be a candidate under TODAY's rules: \(reply)"
            )
            XCTAssertFalse(
                surfaces(reply),
                "a name outside the evidence floor has no probe behind it: \(reply)"
            )
        }
    }

    /// The floor is not a blanket ban: a name every shipped build would have
    /// probed still earns its notice.
    func testClaimInsideTheFloorStillSurfaces() {
        XCTAssertTrue(surfaces("report.pdf"))
    }

    /// Ten `.go` names plus `k.md`: more than today's cap can hold, while the
    /// floor sees only `k.md`. The INTERSECTION is what the reconstruction is
    /// built on, and here it agrees on `k.md` — today's overflowing window
    /// reserves its head for the extensions the older build probed
    /// (`FileTransferOutputDetector.probeOrderedCandidates`), so the narrower
    /// window can no longer fall outside the wider one.
    ///
    /// Agreement is not enough on its own. Today's rules still could not examine
    /// the whole reply, and a truncated pass may close at `truncatedScanHorizon`
    /// having seen only a prefix — so the turn stays silent on the truncation
    /// guard alone, which is the conservative direction this diagnostic always
    /// takes.
    func testOverflowingWindowStaysSilentEvenWhenTheFloorAgrees() {
        let reply = (0..<FileTransferOutputDetector.maxCandidates)
            .map { "src\($0).go" }
            .joined(separator: "\n") + "\nk.md"
        let derived = claims(reply)
        XCTAssertEqual(
            derived.probedWindow, ["k.md"],
            "the compatibility reserve keeps the older build's candidate in today's window"
        )
        XCTAssertTrue(derived.truncated)
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    /// A name past the floor's cap was never probed by the narrower build, and
    /// overflowing that cap makes the whole turn truncated — silence twice
    /// over.
    func testClaimPastTheFloorCapNeverSurfaces() {
        let names = (0..<MissingOutputNotice.evidenceFloorMaxCandidates)
            .map { "early\($0).pdf" } + ["late.pdf"]
        let reply = names.joined(separator: "\n")
        let derived = claims(reply)
        XCTAssertFalse(derived.probedWindow.contains("late.pdf"))
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    /// The floor's own plan, direct: only floor-allowlisted names are eligible,
    /// inbound echoes drop out before the cap, and overflow is truncation.
    func testEvidenceFloorPlanShape() {
        let plan = MissingOutputNotice.evidenceFloorPlan(
            candidates: ["echo.png", "a.pdf", "b.mp3", "c.csv"],
            inboundTokens: ["echo.png"]
        )
        XCTAssertEqual(plan.window, ["a.pdf", "c.csv"],
                       "audio is outside the floor; the inbound echo was never eligible")
        XCTAssertFalse(plan.truncated)

        let overflowing = MissingOutputNotice.evidenceFloorPlan(
            candidates: (0...MissingOutputNotice.evidenceFloorMaxCandidates).map { "f\($0).pdf" },
            inboundTokens: []
        )
        XCTAssertEqual(overflowing.window.count, MissingOutputNotice.evidenceFloorMaxCandidates)
        XCTAssertTrue(overflowing.truncated)
    }

    /// The floor is a floor: every extension in it is still in today's rules,
    /// so the intersection can only ever narrow what today would probe.
    func testFloorIsASubsetOfTodaysAllowlist() {
        XCTAssertTrue(
            MissingOutputNotice.evidenceFloorAllowlist
                .isSubset(of: FileTransferOutputDetector.outputAllowlist)
        )
        XCTAssertLessThanOrEqual(
            MissingOutputNotice.evidenceFloorMaxCandidates,
            FileTransferOutputDetector.maxCandidates
        )
    }

    // MARK: - 6. The maximal universe — an inbound set the pass never had

    /// THE case this section exists for. The inbound-exclusion set is DEVICE
    /// STATE, not a build constant: `inboundStoredKeyTokens` yields an empty set
    /// when its store fetch fails, and a device holding the marker may not yet
    /// hold the user turn whose upload contributed a token. A pass that filtered
    /// with FEWER exclusions faced a LONGER eligible list — long enough here to
    /// overflow the floor's cap and close at the horizon having probed only a
    /// prefix. Reconstructed against the real inbound set the list fits, so
    /// `truncated` would read false and the tail token would speak for evidence
    /// nobody gathered.
    func testTailTokenStaysSilentWhenTheEmptyInboundUniverseOverflowsTheFloor() {
        let echoes = (0..<MissingOutputNotice.evidenceFloorMaxCandidates)
            .map { "up\($0)__notes.md" }
        let reply = (echoes + ["out.pdf"]).joined(separator: "\n")
        let derived = claims(reply, inbound: Set(echoes))
        XCTAssertEqual(
            derived.probedWindow, ["out.pdf"],
            "the real inbound set hides the overflow the closing pass may have hit"
        )
        XCTAssertTrue(
            derived.truncated,
            "the no-exclusions universe overflows the floor cap, so some pass may have been cut"
        )
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    /// The same divergence against TODAY's cap rather than the floor's: eleven
    /// candidates of which only one is floor-allowlisted, so the floor's
    /// universe fits comfortably and only the wider plan overflows.
    func testTailTokenStaysSilentWhenTheEmptyInboundUniverseOverflowsTodaysCap() {
        let echoes = (0...FileTransferOutputDetector.maxCandidates)
            .map { "up\($0)__src.go" }
        let reply = (echoes + ["out.md"]).joined(separator: "\n")
        let derived = claims(reply, inbound: Set(echoes))
        XCTAssertEqual(derived.probedWindow, ["out.md"])
        XCTAssertTrue(derived.truncated)
        XCTAssertFalse(MissingOutputNotice.shouldSurface(
            message: agentTurn(text: reply),
            currentLaneID: laneID,
            claims: derived
        ))
    }

    /// The rule is a truncation guard, not a ban on conversations that upload
    /// files: an ordinary turn that echoes one uploaded name and hands back one
    /// deliverable still earns its notice.
    func testInboundEchoesDoNotSilenceAnOrdinaryDeliverable() {
        let reply = """
        I read 7b06c382__notes.md and wrote the summary.

        summary.pdf
        """
        XCTAssertTrue(surfaces(reply, inbound: ["7b06c382__notes.md"]))
    }

    /// The maximal-universe predicate direct: overflow on EITHER cap counts,
    /// and a list that fits both is not truncation.
    func testMaximalUniverseOverflowShape() {
        let floorCap = MissingOutputNotice.evidenceFloorMaxCandidates
        XCTAssertFalse(MissingOutputNotice.maximalUniverseOverflows(
            candidates: (0..<floorCap).map { "f\($0).pdf" }
        ))
        XCTAssertTrue(MissingOutputNotice.maximalUniverseOverflows(
            candidates: (0...floorCap).map { "f\($0).pdf" }
        ))
        XCTAssertTrue(MissingOutputNotice.maximalUniverseOverflows(
            candidates: (0...FileTransferOutputDetector.maxCandidates).map { "s\($0).go" }
        ))
        // Floor-allowlisted names at exactly the floor cap, padded with names
        // only today's rules admit, up to exactly today's cap: neither overflows.
        let mixed = (0..<floorCap).map { "f\($0).pdf" }
            + (0..<(FileTransferOutputDetector.maxCandidates - floorCap)).map { "s\($0).go" }
        XCTAssertFalse(MissingOutputNotice.maximalUniverseOverflows(candidates: mixed))
    }

    func testExtensionIsTakenFromTheLastDot() {
        XCTAssertEqual(MissingOutputNotice.fileExtension(of: "archive.tar.GZ"), "gz")
        XCTAssertEqual(MissingOutputNotice.fileExtension(of: "notes.md"), "md")
    }

    // MARK: - Cost / robustness

    func testHostileReplyStaysBounded() {
        // Adversary-shaped input (a hostile gateway, or an honest agent
        // prompt-injected by a page it read). The line scan must not blow up,
        // and an over-long line can hold no storable filename anyway.
        let longLine = String(repeating: "x", count: 4096) + ".pdf"
        let reply = ([longLine] + Array(repeating: "just prose here", count: 5000))
            .joined(separator: "\n")
        XCTAssertFalse(surfaces(reply))
    }

    // MARK: - 7. The claim-scan size ceiling

    /// The memory-pressure kill this ceiling exists for, in the shape that
    /// causes it: a body of bare newlines splits into one array element per
    /// byte. The notice path is the dangerous one because it re-derives on
    /// EVERY thread open from persisted, CloudKit-synced text, so a jetsam kill
    /// relaunches straight back into the same computation on every device.
    func testOversizedReplyIsRefusedWithoutScanning() {
        let token = "deliverable.md"
        let hostile = token + String(
            repeating: "\n",
            count: FileTransferOutputDetector.maxClaimOrderingReplyBytes + 1
        )
        let derived = claims(hostile)

        // Every field is the suppressed one. If the guard were missing, the
        // token WOULD be found (it stands alone on the first line), so a claim
        // here is direct proof the scan ran.
        XCTAssertEqual(derived, MissingOutputNotice.ReplyClaims.unscannable)
        XCTAssertTrue(derived.standaloneClaims.isEmpty, "the line scan must not run at all")
        XCTAssertTrue(derived.truncated, "an unscannable reply fails closed")
        XCTAssertTrue(derived.probedWindow.isEmpty)
        XCTAssertFalse(
            MissingOutputNotice.shouldSurface(
                message: agentTurn(text: hostile),
                currentLaneID: laneID,
                claims: derived
            ),
            "a reply too large to classify can never produce a notice"
        )
    }

    /// The ceiling is a boundary, not an off switch: a reply that only just
    /// fits is scanned normally.
    func testReplyExactlyAtTheCeilingIsStillScanned() {
        let token = "deliverable.md\n"
        let padding = FileTransferOutputDetector.maxClaimOrderingReplyBytes - token.utf8.count
        let atCeiling = token + String(repeating: "\n", count: padding)
        XCTAssertEqual(atCeiling.utf8.count, FileTransferOutputDetector.maxClaimOrderingReplyBytes)

        XCTAssertFalse(MissingOutputNotice.replyExceedsClaimScanCeiling(atCeiling))
        XCTAssertTrue(MissingOutputNotice.replyExceedsClaimScanCeiling(atCeiling + "!"))
        XCTAssertEqual(claims(atCeiling).standaloneClaims, ["deliverable.md"])
    }

    // MARK: - 8. Line terminators — the rule may not depend on the gateway

    /// Splitting on the line feed alone leaves the carriage return of a CRLF
    /// reply attached to every line, and `.whitespaces` (Zs plus tab) does not
    /// contain U+000D — so the entire claim rule silently did nothing for any
    /// gateway that emits CRLF. Every Unicode line terminator must read the
    /// same, because a rule that fires on one gateway and not another is
    /// per-backend behaviour by accident.
    func testEveryLineTerminatorReadsTheSame() {
        let terminators: [(name: String, value: String)] = [
            ("LF", "\n"),
            ("CRLF", "\r\n"),
            ("CR", "\r"),
            ("VT U+000B", "\u{000B}"),
            ("FF U+000C", "\u{000C}"),
            ("NEL U+0085", "\u{0085}"),
            ("LS U+2028", "\u{2028}"),
            ("PS U+2029", "\u{2029}")
        ]
        for terminator in terminators {
            let eol = terminator.value
            let reply = "Here you go:\(eol)\(eol)report.pdf\(eol)"
            XCTAssertTrue(
                surfaces(reply),
                "a handover must be read identically for \(terminator.name)"
            )
            // And the negative half: prose is prose under every terminator too.
            XCTAssertFalse(
                surfaces("I reviewed report.pdf but made no changes.\(eol)"),
                "prose must stay silent for \(terminator.name)"
            )
        }
    }

    /// CRLF and LF are the two that occur in the wild, so they get their own
    /// direct equivalence check on both readings of the scan.
    func testCRLFAndLFAgreeOnBothReadings() {
        let lf = "Here you go:\n\n- a.pdf\n- b.pdf\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let candidates: Set<String> = ["a.pdf", "b.pdf"]

        XCTAssertEqual(
            MissingOutputNotice.blockIsolatedClaimTokens(in: crlf, candidates: candidates),
            MissingOutputNotice.blockIsolatedClaimTokens(in: lf, candidates: candidates)
        )
        XCTAssertEqual(
            MissingOutputNotice.standaloneClaimTokens(in: crlf, candidates: candidates),
            MissingOutputNotice.standaloneClaimTokens(in: lf, candidates: candidates)
        )
        XCTAssertEqual(
            MissingOutputNotice.blockIsolatedClaimTokens(in: crlf, candidates: candidates),
            candidates,
            "a two-item list handover is claimed under either terminator"
        )
    }

    // MARK: - 9. A source line is not a rendered line

    /// The false notice the terminator fix would otherwise have widened. A
    /// single newline between two prose lines is a Markdown SOFT break: the
    /// three source lines below render as ONE paragraph — "I reviewed
    /// report.pdf No file was created." Announcing a missing file there
    /// contradicts a sentence the user can read on the same screen.
    func testSoftBreakProseIsNotAHandover() {
        for eol in ["\n", "\r\n"] {
            XCTAssertFalse(
                surfaces("I reviewed\(eol)report.pdf\(eol)No file was created."),
                "a soft-wrapped prose line renders inline, not as a handover"
            )
        }
    }

    /// The ordering path keeps the LOOSE reading on purpose, and this locks the
    /// asymmetry so neither consumer silently inherits the other's rule: a
    /// wrong claim costs the probe order one 404 and costs the notice its
    /// credibility, so the two are tuned in opposite directions.
    func testOrderingKeepsTheLooseReadingTheNoticeRefuses() {
        let reply = "I reviewed\nreport.pdf\nNo file was created."
        XCTAssertEqual(
            MissingOutputNotice.standaloneClaimTokens(in: reply, candidates: ["report.pdf"]),
            ["report.pdf"],
            "the probe order still promotes it — a wrong promotion costs one request"
        )
        XCTAssertTrue(
            MissingOutputNotice.blockIsolatedClaimTokens(in: reply, candidates: ["report.pdf"])
                .isEmpty,
            "the notice refuses it — a wrong notice costs every later notice"
        )
    }

    /// The other half of the block rule, and the reason it is not simply
    /// "surrounded by blank lines": consecutive bare filenames are a MANIFEST.
    /// The block holds nothing but tokens, so every line in it is a handover
    /// even though no blank separates them.
    func testBlockOfNothingButFilenamesIsAManifest() {
        let reply = "report.pdf\nnotes.md\nsummary.csv"
        XCTAssertEqual(
            MissingOutputNotice.blockIsolatedClaimTokens(
                in: reply,
                candidates: ["report.pdf", "notes.md", "summary.csv"]
            ),
            ["report.pdf", "notes.md", "summary.csv"]
        )
        XCTAssertTrue(surfaces(reply))
    }

    /// One prose line anywhere in the block silences the WHOLE block. A
    /// filename sharing a rendered paragraph with a sentence is being talked
    /// about, not handed over, and there is no way to tell which of the two the
    /// user is looking at from inside the paragraph.
    func testOneProseLineSilencesTheWholeBlock() {
        XCTAssertTrue(
            MissingOutputNotice.blockIsolatedClaimTokens(
                in: "report.pdf\nnotes.md\nI could not write either one.",
                candidates: ["report.pdf", "notes.md"]
            ).isEmpty
        )
    }

    func testSetextHeadingIsNotAHandover() {
        // `report.pdf` over a rule of dashes is a heading, and headings are
        // titles rather than handovers — the same call `##` already gets.
        XCTAssertFalse(surfaces("report.pdf\n----------\n\nSome notes."))
    }

    func testIndentedCodeLineIsNotAHandover() {
        // Four leading spaces open a CommonMark code block, so this is quoted
        // material for the same reason a fenced listing is.
        XCTAssertFalse(surfaces("Existing listing:\n\n    report.pdf\n"))
        XCTAssertFalse(surfaces("Existing listing:\n\n\treport.pdf\n"))
    }

    func testInnerFenceDoesNotEndAnOuterFence() {
        // A fence closes only on its OWN marker at its own length or longer.
        // Toggling on any three-character run lets the inner ``` end the outer
        // fence and expose the quoted lines after it.
        let reply = """
        ````
        ```
        report.pdf
        ```
        ````
        """
        XCTAssertFalse(surfaces(reply))
    }

    func testQuestionMarkKeepsALineAQuestion() {
        // `report.pdf?` asks about a file. Normalising the mark away would turn
        // a question into a delivery claim — the one direction this must not
        // move in. The other sentence punctuation still normalises.
        XCTAssertFalse(surfaces("Did you want:\n\nreport.pdf?\n"))
        XCTAssertTrue(surfaces("Here you go:\n\nreport.pdf!\n"))
        XCTAssertEqual(MissingOutputNotice.normalizedClaimLine("report.pdf?"), "report.pdf?")
    }
}
