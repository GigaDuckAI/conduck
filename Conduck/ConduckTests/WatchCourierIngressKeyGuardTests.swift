// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchCourierIngressKeyGuardTests.swift
//
// SOURCE-READING DRIFT GUARD for the wrist's two agent-file courier ingress
// paths.
//
// The courier batch arrives on BOTH WatchConnectivity channels — the queued
// `didReceiveUserInfo` (the durable spine) and the interactive
// `didReceiveMessage` (the lane that makes the file row appear in about a
// second). Both have to read the batch's `kind` field through the courier
// contract's OWN key constant, `AttachedFileCourierWire.kindKey`.
//
// WHY THIS NEEDS A GUARD AND NOT JUST A CODE REVIEW. The relay's wire enum and
// the courier's both spell that key "kind" today, so an ingress that borrows
// `AppleSpeechRelayCoordinator.Wire.kindKey` to read a COURIER discriminator
// compiles and behaves identically — until someone namespaces one of the two
// contracts. Then the borrowing path silently reads the wrong field, falls
// through to the wrong branch, and the interactive lane stops delivering with no
// compile error and no failing test; only the queued copy still arrives, so the
// symptom is "files show up on the wrist, but a minute late", which nobody
// reports as a bug. This project already paid for that lesson once with the
// relay's literal-duplicated wire strings (see `RelayWireSourceDriftGuardTests`).
//
// `WatchSessionManager` is Watch-target-only and invisible to this test host, so
// the check reads the source off disk via `#filePath`, exactly as the relay
// guard does. It asserts the file reads the courier's key as many times as it
// tests the courier's value — one read per branch — which is precisely what
// fails if a branch reverts to a shared or borrowed key.
//
// Deterministic + headless: one file read, no WCSession, no network.

import XCTest
@testable import Conduck

// `@MainActor` because `AppleSpeechRelayCoordinator` is, so reading its nested
// `Wire` constants below is a main-actor access.
@MainActor
final class WatchCourierIngressKeyGuardTests: XCTestCase {

    /// `.../Conduck/Conduck` — the Xcode project container holding both the iOS
    /// app source and the Watch app source. Derived from this file's
    /// compile-time absolute path, so it does not depend on the runner's working
    /// directory.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)      // .../ConduckTests/<thisFile>
            .deletingLastPathComponent()     // .../ConduckTests
            .deletingLastPathComponent()     // .../Conduck/Conduck
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testBothCourierIngressPathsReadTheCourierContractsOwnKey() throws {
        let url = projectContainerURL()
            .appendingPathComponent("ConduckWatch Watch App/Services/WatchSessionManager.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Watch session source not found at \(url.path) — update this guard's path derivation.")
        let source = try String(contentsOf: url, encoding: .utf8)

        let valueTests = occurrences(of: "AttachedFileCourierWire.kindValue", in: source)
        let keyReads = occurrences(of: "AttachedFileCourierWire.kindKey", in: source)

        // Sanity: both ingress paths must still be there at all. A guard that
        // silently passes because the code moved is worse than no guard.
        XCTAssertEqual(valueTests, 2,
                       "Expected the two courier ingress branches (interactive `didReceiveMessage` + queued `didReceiveUserInfo`); found \(valueTests). Update this guard if the ingress set intentionally changed.")

        XCTAssertEqual(
            keyReads, valueTests,
            "A courier ingress branch tests `AttachedFileCourierWire.kindValue` without reading `AttachedFileCourierWire.kindKey` — it is borrowing another contract's key constant. Both spell \"kind\" today, so this compiles and works until either contract renames its key; then that branch silently reads the wrong field and stops delivering, with no compile error."
        )
    }

    /// The two contracts are independent by design, and their VALUES must stay
    /// distinct or the branch order in `didReceiveMessage` becomes load-bearing
    /// instead of merely tidy. Compile-time symbols here — `AttachedFileCourierWire`
    /// is cross-target, and the relay `Wire` enum has an iOS copy this host can see.
    func testCourierAndRelayKindValuesCannotBeConfused() {
        XCTAssertNotEqual(AttachedFileCourierWire.kindValue,
                          AppleSpeechRelayCoordinator.Wire.kindValue)
        XCTAssertNotEqual(AttachedFileCourierWire.kindValue,
                          AppleSpeechRelayCoordinator.Wire.replyKind)
    }
}
