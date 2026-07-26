// Conduck — watchOS orphaned-temp reclaim tests.
//
// The wrist is the surface where the orphan the sweep exists to reclaim is MOST
// likely and LEAST recoverable: every cleanup for a capture or request body is
// in-process (a `defer`, or a URLSession delegate callback), watchOS jetsams a
// backgrounded app aggressively — routinely mid-upload — and the user has no way
// to inspect or clear a Watch's `tmp` themselves. The files at stake are raw voice
// recordings (`watch-capture-`, `watch-stt-audio-`, `apple-relay-out-`) and request
// bodies that embed either a second copy of a recording (`stt-body-`,
// `stt-json-body-`) or the whole client-owned conversation history in plaintext
// (`conduck-watch-converse-body-`).
//
// THAT THIS FILE COMPILES IS HALF THE POINT. `TempScratchSweeper` lives in
// `Conduck/Services/AgentDownloadScratch.swift`, and the watch app pulls its shared
// sources in one-by-one through a target membership exception list. A type absent
// from that list does not fail to run — it fails to EXIST on the wrist, silently.
// So these tests pin three separate things, because each can regress alone:
//   1. the type is a member of the watch target at all (compilation),
//   2. `ConduckWatchApp` actually calls it at launch (source scan — no runtime
//      seam can observe another process's launch), and
//   3. it does the right thing to real files in the real `temporaryDirectory`
//      (behaviour, against the live `sweep()` rather than a re-stated predicate).
//
// The behavioural test writes into the REAL `temporaryDirectory` on purpose: that
// is the exact directory `sweep()` enumerates, and asserting against a private
// sandbox would only prove a copy of the predicate right. Its files carry a
// per-run UUID, and the 24 h age floor means a concurrently-running test's fresh
// files can never be in range.

import Foundation
import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchTempScratchSweeperTests: XCTestCase {

    /// Distinguishes this run's files from every other test's. Sits AFTER the
    /// owned prefix in each leaf, exactly as the production UUID does.
    private let runToken = UUID().uuidString

    // MARK: - Writer coverage

    /// The literal leaf shapes the watchOS surface writes into `temporaryDirectory`.
    /// A writer missing from `ownedPrefixes` leaks forever, so the list is data the
    /// test iterates rather than prose a reader is trusted to check.
    private func wristLeaves(_ discriminator: String) -> [String] {
        [
            "watch-capture-\(discriminator)-1.m4a",              // WatchRecordingService recorder output
            "watch-stt-audio-\(discriminator)-2.m4a",            // WatchSTTRequest multipart input copy
            "stt-body-\(discriminator)-3.bin",                   // STTMultipartBuilder
            "stt-json-body-\(discriminator)-4.json",             // WatchAudioUploader (STT hop)
            "conduck-watch-converse-body-\(discriminator)-5.json", // WatchAudioUploader (converse hop)
            "apple-relay-out-\(discriminator)-6.m4a",            // WatchRecordingService relay copy
            "wav_input_\(discriminator)-7.m4a",                  // AudioCompressor
            "wav_output_\(discriminator)-8.wav",
            "compress_input_\(discriminator)-9.m4a",
            "compress_output_\(discriminator)-10.m4a",
        ]
    }

    /// Names the wrist must NEVER claim. `sweep()` runs over the SHARED
    /// `temporaryDirectory`, where the system and other frameworks stage files too.
    private func foreignLeaves(_ discriminator: String) -> [String] {
        [
            "CFNetworkDownload_\(discriminator).tmp",
            "com.apple.nsurlsessiond-\(discriminator)",
            "\(discriminator).m4a",                     // a bare-UUID leaf is NOT ours to judge
            "not-watch-capture-\(discriminator).m4a",   // the prefix must anchor at the START
            "TemporaryItems-\(discriminator)",
        ]
    }

    func testEveryWatchTempWriterIsClaimedByAnOwnedPrefix() {
        for leaf in wristLeaves("ABC") {
            XCTAssertTrue(
                TempScratchSweeper.ownedPrefixes.contains(where: { leaf.hasPrefix($0) }),
                "\(leaf) is written by the watch app but no owned prefix claims it — a jetsam mid-turn strands it permanently"
            )
        }
    }

    func testForeignNamesAreNeverClaimedOnTheWrist() {
        for leaf in foreignLeaves("ABC") {
            XCTAssertFalse(
                TempScratchSweeper.ownedPrefixes.contains(where: { leaf.hasPrefix($0) }),
                "\(leaf) is not written by this app and must never be swept"
            )
        }
    }

    // MARK: - Behaviour against the real temporary directory

    func testSweepReclaimsAgedWristOrphansAndSparesFreshAndForeignFiles() throws {
        let agedDate = Date().addingTimeInterval(-TempScratchSweeper.maxOrphanAge - 3600)
        let now = Date()

        var staged: [URL] = []
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }

        func stage(_ leaf: String, created: Date) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(leaf)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
            staged.append(url)
            return url
        }

        let agedOwned = try wristLeaves("\(runToken)-aged").map { try stage($0, created: agedDate) }
        let freshOwned = try wristLeaves("\(runToken)-fresh").map { try stage($0, created: now) }
        let agedForeign = try foreignLeaves("\(runToken)-aged").map { try stage($0, created: agedDate) }

        // PRECONDITION, not an assertion about the sweep: if the filesystem refused
        // to backdate, every deletion check below would fail for a reason that has
        // nothing to do with `sweep()`. Say so plainly instead.
        for url in agedOwned {
            let recorded = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            XCTAssertEqual(
                recorded?.timeIntervalSinceReferenceDate ?? Double.nan,
                agedDate.timeIntervalSinceReferenceDate,
                accuracy: 2,
                "The filesystem did not honour the backdated creation date for \(url.lastPathComponent) — this test cannot age a file here, so its results below are meaningless."
            )
        }

        TempScratchSweeper.sweep()

        for url in agedOwned {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) is an aged wrist orphan we own — leaving it keeps a voice recording or a plaintext conversation copy on disk indefinitely"
            )
        }
        for url in freshOwned {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) is fresh — a background upload may still be streaming from it, so it must survive the sweep"
            )
        }
        for url in agedForeign {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) belongs to the system or another framework — it is not ours to delete, at any age"
            )
        }
    }

    func testSweepIsSafeToCallRepeatedlyOnTheWrist() {
        // Best-effort contract: nothing throws or traps whatever the directory
        // holds. It runs on every launch, including background-URLSession
        // relaunches, so it must be safe in any process state.
        TempScratchSweeper.sweep()
        TempScratchSweeper.sweep()
    }

    // MARK: - Source guard
    //
    // No runtime seam can observe whether ANOTHER process called the sweep at its
    // own launch, so that one regression is checked against the sources — the same
    // `#filePath` derivation the iOS drift guards use, independent of the runner's
    // working directory.
    //
    // The sibling check — that every temp leaf is built from a CLAIMED prefix —
    // deliberately does NOT live here. It belongs to no single platform (the same
    // defect has now appeared on the wrist, in the download path, and in the wrist
    // converse body), so it runs once over the whole project container from
    // `ConduckTests/TempScratchLeafDriftGuardTests`. A wrist-scoped copy would have
    // missed two of the three.

    /// `.../Conduck/Conduck` — the Xcode project container.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckWatchTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    private func watchAppSourceURL() -> URL {
        projectContainerURL().appendingPathComponent("ConduckWatch Watch App")
    }

    /// Drops `//`-to-end-of-line on every line so a mention of the sweeper in prose
    /// can never satisfy — or trip — a scan meant to read code. A `//` inside a
    /// string literal would truncate that line early; no watch source pairs one
    /// with a temp-file write, and the failure mode is a false ALARM, never a
    /// false pass.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    func testWatchAppInvokesTheSweepAtLaunch() throws {
        let entry = watchAppSourceURL().appendingPathComponent("ConduckWatchApp.swift")
        guard let source = try? String(contentsOf: entry, encoding: .utf8) else {
            throw XCTSkip("Watch app source unreadable at \(entry.path) — this guard runs against a checkout only.")
        }
        let code = strippingComments(source)
        XCTAssertTrue(
            code.contains("TempScratchSweeper.sweepInBackground()"),
            "ConduckWatchApp no longer calls TempScratchSweeper.sweepInBackground(). Nothing else reclaims a stranded wrist recording or converse body: watchOS purges `tmp` only opportunistically, and the user cannot clear it by hand. If the call moved, re-point this guard at its new home."
        )
        // The bare synchronous entry point runs on the CALLING thread, and this
        // initializer is main-actor isolated (the watch target builds with
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so calling it here — even
        // wrapped in a plain `Task { }`, which inherits that isolation — puts a
        // shared-temp directory scan on the launch thread of the device with the
        // least headroom. Only `sweepInBackground()` detaches.
        XCTAssertFalse(
            code.contains("TempScratchSweeper.sweep()"),
            "ConduckWatchApp calls the synchronous TempScratchSweeper.sweep() directly. That runs the directory scan on the main thread — wrapping it in `Task { }` does not change that, because a Task created from a main-actor context inherits main-actor isolation. Use sweepInBackground()."
        )
    }
}
