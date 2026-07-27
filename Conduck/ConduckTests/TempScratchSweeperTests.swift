// SPDX-License-Identifier: Apache-2.0

// Conduck
// TempScratchSweeperTests.swift
//
// Locks the two properties that make the orphaned-temp sweep safe to run at
// launch, plus the envelope change that lets a background STT completion reclaim
// its request body after a process relaunch.
//
// The sweep exists because every capture and request body is written to
// `temporaryDirectory` under a fresh UUID name and every cleanup is in-process,
// so a jetsam/crash/force-quit between write and cleanup leaks a raw voice
// recording (or a plaintext copy of the conversation history) with no owner. The
// two ways that fix could go wrong are (a) deleting something it does not own and
// (b) deleting a file a live background upload is still streaming — so both are
// asserted directly rather than reasoned about.
//
// Pure Foundation + FileManager; runs in the unsigned logic test pass. Every file
// it creates lives in its own throwaway subdirectory, so it never touches the
// real `temporaryDirectory` entries the running app owns.

import XCTest
@testable import Conduck

final class TempScratchSweeperTests: XCTestCase {

    // MARK: - Prefix ownership

    func testOwnedPrefixesCoverEveryAudioAndRequestBodyWriter() {
        // The names below are the literals the app's writers actually build. Each
        // must be claimed by a prefix, or its orphan is never reclaimed. Kept as a
        // list (not a comment) so adding a writer without a prefix fails here.
        let writtenNames = [
            "conduck_capture_ABC.m4a",                   // DictationService
            "conduck_retry_ABC.m4a",                     // ContentView / DictationService
            "conduck-inapp-ABC.m4a",                     // InAppAudioRecorder
            "conduck-stt-ABC.m4a",                       // ConverseIntent handoff
            "conduck-stt-body-ABC.bin",                  // STTClient+Background
            "conduck-apple-test-ABC.m4a",                // AppleSpeechTester (Settings mic test)
            "conduck-cloud-stt-test-ABC.m4a",            // CloudSTTTester (Settings mic test)
            "carplay_ABC.caf",                           // CarPlayRecordingService capture
            "carplay_upload_ABC.m4a",                    // CarPlayRecordingService upload copy
            "wav_input_ABC.m4a", "wav_output_ABC.wav",   // AudioCompressor
            "compress_input_ABC.m4a", "compress_output_ABC.m4a",
            "stt-body-ABC.bin",                          // STTMultipartBuilder
            "stt-json-body-ABC.json",                    // WatchAudioUploader
            "conduck-converse-body-ABC.json",            // BackgroundRemoteAgent
            "conduck-carplay-converse-body-ABC.json",    // CarPlayConverseUploader
            "conduck-watch-converse-body-ABC.json",      // WatchAudioUploader (converse hop)
            "apple-relay-ABC.m4a",                       // RelayInboxMover / PhoneSessionManager
            "apple-relay-out-ABC.m4a",                   // WatchRecordingService relay copy
            "watch-capture-ABC.m4a",                     // WatchRecordingService recorder output
            "watch-stt-audio-ABC.m4a",                   // WatchSTTRequest
            "conduck-download-ABC",                      // BackgroundFileTransfer completed download (no extension)
            "conduck-recorder-ABC.m4a",                  // AudioRecorder (menu-bar dictation + Settings STT tests)
            "conduck-imgupload-ABC.png",                 // ComposerAttachmentCoordinator / MessageComposerBar
            "conduck-ftstage-ABC-report.pdf",            // …ftstage leaves append the ORIGINAL filename
            "conduck-share-imgupload-ABC",               // SharedInboxDrainer (share-extension image)
            "conduck-share-upload-ABC",                  // SharedInboxDrainer (share-extension file)
            "diagnostics-stt-probe-ABC.m4a",             // DiagnosticsRunner bundled probe copy
            "conduck-ftupload-ABC",                       // ConversationDetailViewModel
        ]
        for name in writtenNames {
            XCTAssertTrue(
                TempScratchSweeper.ownedPrefixes.contains(where: { name.hasPrefix($0) }),
                "\(name) is written by this app but no owned prefix claims it — its orphans are unreclaimable"
            )
        }
    }

    func testForeignNamesAreNotClaimed() {
        // The sweep runs over the SHARED `temporaryDirectory`, where the system and
        // other frameworks stage files too. Claiming any of these would delete
        // someone else's data.
        let foreignNames = [
            "CFNetworkDownload_a1b2c3.tmp",
            "com.apple.nsurlsessiond",
            "AgentFileDownloads",
            "somebody-elses-conduck.m4a",   // prefix must anchor at the START
            "TemporaryItems",
            "audio.m4a",
            "body.json",
        ]
        for name in foreignNames {
            XCTAssertFalse(
                TempScratchSweeper.ownedPrefixes.contains(where: { name.hasPrefix($0) }),
                "\(name) is not written by this app and must never be swept"
            )
        }
    }

    // MARK: - Age bound

    func testAgeBoundClearsTheLongestPossibleInFlightUploadWindow() {
        // The one way this sweep could destroy live data is by deleting a body file
        // a background upload is still streaming from. The longest resource budget
        // in the app is the converse hop's, so the floor must sit far above it.
        XCTAssertGreaterThan(
            TempScratchSweeper.maxOrphanAge,
            Constants.remoteAgentConverseResourceTimeout * 10,
            "the orphan age floor must clear the longest background-upload window by a wide margin"
        )
        XCTAssertEqual(TempScratchSweeper.maxOrphanAge, 24 * 60 * 60)
    }

    // MARK: - Behaviour

    func testSweepDeletesAgedOwnedFilesAndSparesFreshOnesAndForeignOnes() throws {
        // Run against a private directory: `sweep()` enumerates the real
        // `temporaryDirectory`, so the observable behaviour is asserted here on the
        // same predicate (prefix + cutoff) rather than by polluting a shared dir.
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempScratchSweeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let aged = Date().addingTimeInterval(-TempScratchSweeper.maxOrphanAge - 60)
        let fresh = Date()

        func write(_ name: String, created: Date) throws -> URL {
            let url = sandbox.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: created], ofItemAtPath: url.path
            )
            return url
        }

        let agedOwned = try write("conduck_capture_aged.m4a", created: aged)
        let freshOwned = try write("conduck_capture_fresh.m4a", created: fresh)
        let agedForeign = try write("CFNetworkDownload_aged.tmp", created: aged)

        // Mirror of `sweep()`'s predicate over the sandbox.
        let entries = try FileManager.default.contentsOfDirectory(
            at: sandbox,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let cutoff = Date().addingTimeInterval(-TempScratchSweeper.maxOrphanAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard TempScratchSweeper.ownedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let created, created < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: agedOwned.path),
                       "an aged orphan we own must be reclaimed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshOwned.path),
                      "a fresh file we own may still be in flight — never delete it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: agedForeign.path),
                      "another framework's aged file is not ours to delete")
    }

    func testSweepInBackgroundActuallyPerformsTheSweep() async throws {
        // The launch entry point hands the scan to a detached task, so the work is
        // no longer ordered against the caller. Prove it still HAPPENS — a
        // fire-and-forget wrapper that silently dropped the sweep would leave a
        // raw recording on disk forever and break nothing else. Runs against the
        // REAL `temporaryDirectory` because that is the directory `sweep()`
        // enumerates; the leaf carries a per-run UUID and the 24 h floor means a
        // concurrently-running test's fresh files can never be in range.
        let leaf = "conduck_capture_\(UUID().uuidString)-sweepInBackground.m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(leaf)
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("x".utf8).write(to: url)
        let aged = Date().addingTimeInterval(-TempScratchSweeper.maxOrphanAge - 3600)
        try FileManager.default.setAttributes([.creationDate: aged], ofItemAtPath: url.path)

        // PRECONDITION, not an assertion about the sweep: a filesystem that refuses
        // to backdate makes the check below meaningless rather than failing.
        let recorded = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        try XCTSkipUnless(
            recorded.map { abs($0.timeIntervalSince(aged)) < 2 } ?? false,
            "The filesystem did not honour the backdated creation date — this test cannot age a file here."
        )

        TempScratchSweeper.sweepInBackground()

        // Poll rather than sleep a fixed interval: the detached task's start is at
        // the scheduler's discretion, and the directory it scans is shared, so its
        // duration is not ours to predict.
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "sweepInBackground() never reclaimed an aged orphan we own — the detached task is not running the sweep"
        )
    }

    func testSweepIsSafeOnAnUnreadableRoot() {
        // Best-effort contract: nothing throws, nothing traps, no matter what the
        // directory looks like. Runs against the live temp dir on purpose — it must
        // be safe to call at launch on any device state.
        TempScratchSweeper.sweep()
        TempScratchSweeper.sweep()
    }

    // MARK: - The sweep stays OFF the main thread
    //
    // `sweep()` is a synchronous scan of the SHARED `temporaryDirectory` — a
    // directory every framework in the process also stages files in, so its size
    // is not ours to bound. The app targets build with
    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes this trap easy to
    // walk back into and invisible in review:
    //
    //   • an unannotated type is implicitly `@MainActor`;
    //   • a plain `Task { }` created from a main-actor context INHERITS that
    //     isolation, so it defers the work to a later main-thread turn rather
    //     than moving it off the main thread;
    //   • and a synchronous `nonisolated` call runs on whatever thread invokes
    //     it, so `nonisolated` alone does not move it either.
    //
    // Only `sweepInBackground()`'s detached task actually reaches a background
    // executor. No runtime seam can observe another process's launch, so the
    // call-site shape is pinned against the sources — the same `#filePath`
    // derivation the leaf drift guard uses, independent of the runner's cwd.

    /// `.../Conduck/Conduck` — the project container holding every target's sources.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line so prose naming the sweeper is never read as a
    /// call. A `//` inside a string literal truncates that line early; no source
    /// pairs one with a sweeper call, and the failure mode is a MISSED call, not
    /// a false alarm.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Test targets call `sweep()` directly on purpose (they need the scan to have
    /// finished before they assert), and `AgentDownloadScratch.swift` is where the
    /// detached wrapper legitimately calls it.
    private static let sweepCallExemptions: Set<String> = [
        "ConduckTests", "ConduckWatchTests", "AgentDownloadScratch.swift",
    ]

    func testLaunchEntryPointsUseTheDetachedSweep() throws {
        let container = projectContainerURL()
        for (directory, file) in [("Conduck", "ConduckApp.swift"), ("Conduck", "AppDelegate.swift")] {
            let url = container.appendingPathComponent(directory).appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("\(file) unreadable at \(url.path) — this guard runs against a checkout only.")
            }
            XCTAssertTrue(
                strippingComments(source).contains("TempScratchSweeper.sweepInBackground()"),
                "\(file) no longer reclaims orphaned capture audio / request bodies at launch. If the call moved, re-point this guard at its new home."
            )
        }
    }

    func testNoShippingCodeCallsTheSynchronousSweep() throws {
        let container = projectContainerURL()
        guard let walker = FileManager.default.enumerator(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }

        var offenders: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            guard Set(url.pathComponents).isDisjoint(with: Self.sweepCallExemptions) else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = strippingComments(raw)
            guard let hit = code.range(of: "TempScratchSweeper.sweep()") else { continue }
            let line = code[code.startIndex..<hit.lowerBound].lazy.filter { $0 == "\n" }.count + 1
            offenders.append("\(url.lastPathComponent):\(line)")
        }

        XCTAssertEqual(
            offenders, [],
            """
            These call the SYNCHRONOUS TempScratchSweeper.sweep(), which runs the shared-temp \
            directory scan on the calling thread — and every caller here is main-actor isolated \
            (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor). Wrapping it in `Task { }` does NOT help: \
            a Task created from a main-actor context inherits that isolation. Call \
            sweepInBackground() instead.
            """
        )
    }

    // MARK: - STT envelope carries the body path (cross-launch reclaim)

    func testSTTMetadataRoundTripsBodyPath() throws {
        let metadata = STTBackgroundTaskMetadata(
            audioPath: "/tmp/audio.m4a",
            providerID: "mistral-voxtral",
            pinnedFingerprintHex: nil,
            bodyPath: "/tmp/stt-body-abc.bin"
        )
        let decoded = try STTBackgroundTaskMetadata.decode(try metadata.encodedString())
        XCTAssertEqual(decoded.bodyPath, "/tmp/stt-body-abc.bin",
                       "without this the cross-launch completion cannot delete the request body — a full second copy of the recording")
        XCTAssertEqual(decoded.audioPath, "/tmp/audio.m4a")
        XCTAssertEqual(decoded.providerID, "mistral-voxtral")
    }

    func testSTTMetadataDecodesLegacyEnvelopeWithoutBodyPath() throws {
        // A task enqueued by the PREVIOUS build is still resumable, and its
        // `taskDescription` predates the field. It must decode, not throw — the
        // in-memory registry still covers that task's same-process cleanup.
        let legacy = #"{"audioPath":"/tmp/a.m4a","providerID":"mistral-voxtral"}"#
        let decoded = try STTBackgroundTaskMetadata.decode(legacy)
        XCTAssertNil(decoded.bodyPath)
        XCTAssertNil(decoded.pinnedFingerprintHex)
        XCTAssertEqual(decoded.audioPath, "/tmp/a.m4a")
    }

    // MARK: - Background response ceiling

    func testBackgroundResponseCeilingIsGenerousButFinite() {
        // Finite at all is the point: four background delegates buffered a
        // peer-controlled body with no ceiling, and watchOS jetsams first.
        XCTAssertEqual(Constants.maxBackgroundResponseBytes, 16 * 1024 * 1024)
        // Far above any legitimate reply — a model's maximum output is ~0.5 MB of
        // text, so no real long answer or verbose transcript can be rejected.
        XCTAssertGreaterThan(Constants.maxBackgroundResponseBytes, 8 * 1024 * 1024)
    }
}
