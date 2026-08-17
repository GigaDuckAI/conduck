// SPDX-License-Identifier: Apache-2.0

// Conduck
// NotificationBodyProjectionTests.swift
//
// Locks the three notification bodies that carry UNTRUSTED remote text:
//
//   • `BackgroundRemoteAgent.postReplyNotification` — the agent reply, iOS/macOS.
//   • `WatchAudioUploader`'s converse completion — the same reply, on the wrist.
//   • `AppleRelayPendingQueue.postTranscriptNotification` — a queued relay's
//     verdict, whose input is a transcript from a BYO speech endpoint.
//
// WHY A NOTIFICATION BODY IS ITS OWN HAZARD CLASS. It is an OS-owned,
// app-branded glance surface: it persists in Notification Center, mirrors to a
// paired Watch, and renders on a LOCKED screen — read without an unlock, and
// read as something Conduck is saying. A bidi override in it makes the
// displayed order disagree with the actual string, which is the classic
// label-spoof primitive, and a C0 escape opens an ANSI sequence in whatever
// reads the body downstream.
//
// TWO LAYERS, because neither is sufficient alone:
//
//   1. VALUE PINS against `ReplySanitizer.displayLine` at the cap the posters
//      actually use (`Constants.replyNotificationBodyCharacterCount`). These
//      answer "does the projection hold at this cap" — including at the cap
//      BOUNDARY, where a bare `prefix` strands a bidi opener whose terminator
//      it just cut.
//   2. SOURCE DRIFT GUARDS over the three posting sites. Nothing observable at
//      runtime from this target distinguishes "projected then capped" from
//      "capped then projected" — both posters are unreachable from a test host
//      without a notification centre, and two of the three live in the WATCH
//      target, which `ConduckTests` cannot link at all. So the shape is pinned
//      against the sources, the same way `ReplySanitizerLinkScannerTests` pins
//      the scalar-view walk and `RelayWireSourceDriftGuardTests` pins the Watch
//      copy of the relay wire.
//
// The primitive's own semantics are pinned by `ReplySanitizerDisplayLineTests`;
// this file pins only what is true of these three SITES.

import XCTest
@testable import Conduck

final class NotificationBodyProjectionTests: XCTestCase {

    /// Sentinel used wherever the test cares THAT the fallback came back rather
    /// than what it says. The shipped copy is pinned separately, against the
    /// posters' own sources.
    private let fallback = "FALLBACK-SENTINEL"

    /// The explicit bidi formatting controls — marks, embeddings, overrides and
    /// isolates. Deliberately a LOCAL restatement of the denylist rather than a
    /// call into `ReplySanitizer`: a denylist that grades its own homework
    /// passes even when it is wrong.
    nonisolated private static let bidiControlScalars: [Unicode.Scalar] = [
        "\u{200E}", "\u{200F}",                                     // LRM, RLM
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", // LRE, RLE, PDF, LRO, RLO
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"              // LRI, RLI, FSI, PDI
    ]

    nonisolated private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        bidiControlScalars.contains(scalar)
    }

    private var cap: Int { Constants.replyNotificationBodyCharacterCount }

    // MARK: - Value pins at the notification cap

    /// The cap has to be a real budget: `.max` would make the walk unbounded on
    /// a multi-megabyte reply, and zero or less would turn every banner into the
    /// fallback.
    func testNotificationCapIsAPositiveBudget() {
        XCTAssertGreaterThan(cap, 0)
        XCTAssertLessThan(cap, Int.max)
    }

    /// A reply that embeds every bidi control yields a body carrying none of
    /// them, while the human-readable words survive.
    func testBidiControlsNeverReachTheNotificationBody() {
        let reply = Self.bidiControlScalars
            .map { "before\(Character($0))after" }
            .joined(separator: " ")
        let body = ReplySanitizer.displayLine(reply, maxLength: cap, fallback: fallback)

        for scalar in Self.bidiControlScalars {
            XCTAssertFalse(
                body.unicodeScalars.contains(scalar),
                "U+\(String(scalar.value, radix: 16, uppercase: true)) survived into a notification body."
            )
        }
        XCTAssertTrue(body.contains("beforeafter"))
    }

    /// THE CAP BOUNDARY IS THE POINT. A bare prefix keeps an override and cuts
    /// the terminator that would have ended its run, so everything the banner
    /// still shows renders reversed. Taking the cut inside the projection makes
    /// that unreachable: the controls are gone before the budget is ever spent.
    func testCapBoundaryCannotStrandAnUnbalancedControl() {
        let reply = "\u{202E}" + String(repeating: "a", count: cap * 2) + "\u{202C}"

        let cut = String(reply.prefix(cap))
        XCTAssertTrue(cut.unicodeScalars.contains("\u{202E}"), "Test input no longer exercises the boundary.")
        XCTAssertFalse(cut.unicodeScalars.contains("\u{202C}"), "Test input no longer exercises the boundary.")

        for maxLength in [1, 2, cap - 1, cap, cap + 1] {
            let body = ReplySanitizer.displayLine(reply, maxLength: maxLength, fallback: fallback)
            XCTAssertFalse(
                body.unicodeScalars.contains { Self.isBidiControl($0) },
                "A bidi control survived at maxLength \(maxLength)."
            )
            XCTAssertLessThanOrEqual(body.count, maxLength)
        }
    }

    /// A reply of nothing but hostile scalars projects to empty, and an empty
    /// body is a BLANK banner — which reads as a bug in Conduck rather than as a
    /// bad reply. The fallback comes back verbatim instead.
    func testAllControlReplyYieldsTheFixedFallback() {
        let controlOnly = "\u{202E}\u{0000}\u{001B}\u{200F}\u{2066}\u{009F}\u{007F}"
        XCTAssertEqual(
            ReplySanitizer.displayLine(controlOnly, maxLength: cap, fallback: fallback),
            fallback
        )
    }

    /// The canonical reply is what history keeps and what the next turn replays
    /// to the agent, so the poster must derive a string rather than rewrite one.
    func testProjectionLeavesTheStoredReplyUnchanged() {
        let stored = "\u{202E}reversed\u{202C}\nsecond line\ttabbed"
        let before = Array(stored.unicodeScalars)

        _ = ReplySanitizer.displayLine(stored, maxLength: cap, fallback: fallback)

        XCTAssertEqual(Array(stored.unicodeScalars), before)
        XCTAssertTrue(stored.unicodeScalars.contains("\u{202E}"))
        XCTAssertTrue(stored.contains("\n"))
    }

    /// One line, inside budget, no ragged whitespace edge — the three properties
    /// a banner needs from a reply of arbitrary shape.
    func testBodyIsOneTrimmedLineInsideTheBudget() {
        let reply = "   \n\n  Line one.\r\nLine two.\u{2028}Line three.  \t \n  "
            + String(repeating: " word", count: cap)
        let body = ReplySanitizer.displayLine(reply, maxLength: cap, fallback: fallback)

        XCTAssertLessThanOrEqual(body.count, cap)
        XCTAssertFalse(body.contains("\n"))
        XCTAssertFalse(body.contains("\r"))
        XCTAssertFalse(body.contains("\t"))
        XCTAssertFalse(body.contains("\u{2028}"))
        XCTAssertEqual(body, body.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(body.hasPrefix("Line one. Line two. Line three."))
    }

    /// RIGHT-TO-LEFT SCRIPT IS NOT THE HAZARD. What goes are the explicit
    /// formatting controls; Arabic and Hebrew content reaches the banner
    /// byte-for-byte and the system's own bidi algorithm lays it out. Stripping
    /// the script instead would render those languages as mojibake on every
    /// notification the user receives.
    func testRightToLeftScriptSurvivesTheNotificationBody() {
        let reply = "مرحبا שלום"
        XCTAssertEqual(
            ReplySanitizer.displayLine(reply, maxLength: cap, fallback: fallback),
            reply
        )
    }

    // MARK: - Source drift guards

    /// `.../Conduck/Conduck` — the project container holding every target's
    /// sources, derived from this file's compile-time path so it is independent
    /// of the runner's working directory.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)   // .../ConduckTests/<thisFile>
            .deletingLastPathComponent()  // .../ConduckTests
            .deletingLastPathComponent()  // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line so the prose explaining why a raw prefix is
    /// wrong is never read as the raw prefix coming back.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func strippedSource(at relativePath: String) throws -> String {
        let url = projectContainerURL().appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(relativePath) unreadable at \(url.path) — this guard runs against a checkout only.")
        }
        return strippingComments(raw)
    }

    /// Both reply posters take the cut INSIDE the projection, from the one named
    /// constant. The literal `maxLength:` pairing is what pins the ORDER: a
    /// poster that cut first would have to spell the cut somewhere else.
    func testBothReplyPostersProjectAndCapInOneCall() throws {
        let sites = [
            "Conduck/Services/RemoteAgent/BackgroundRemoteAgent.swift",
            "ConduckWatch Watch App/Services/WatchAudioUploader.swift"
        ]
        for site in sites {
            let source = try strippedSource(at: site)
            XCTAssertTrue(
                source.contains("maxLength: Constants.replyNotificationBodyCharacterCount"),
                """
                \(site) no longer caps its notification body inside \
                `ReplySanitizer.displayLine`. The body is untrusted agent text on a lock \
                screen: cutting before projecting can sever a bidi opener from its \
                terminator and leave the opener governing everything the banner shows.
                """
            )
            XCTAssertFalse(
                source.contains("reply.prefix("),
                """
                \(site) cuts the raw reply with `prefix` again. Pass the whole reply to \
                `ReplySanitizer.displayLine` and let it take the cut.
                """
            )
        }
    }

    /// The empty-projection fallback is app-owned copy, and it must say
    /// something a user can act on rather than leave a blank banner.
    func testBothReplyPostersShipTheSameEmptyBodyCopy() throws {
        let sites = [
            "Conduck/Services/RemoteAgent/BackgroundRemoteAgent.swift",
            "ConduckWatch Watch App/Services/WatchAudioUploader.swift"
        ]
        for site in sites {
            let source = try strippedSource(at: site)
            XCTAssertTrue(
                source.contains("remoteAgent.notification.reply.emptyBody"),
                "\(site) no longer passes the shared empty-body key to `displayLine`."
            )
            XCTAssertTrue(
                source.contains("Your AI replied. Open Conduck to read it."),
                "\(site) no longer carries the empty-body default value the catalog is keyed to."
            )
        }
    }

    /// The queued-relay banner carries FIXED copy, so the transcript — untrusted
    /// text from a BYO speech endpoint — cannot reach a lock screen at all. The
    /// signature is the pin: a poster that takes no transcript cannot show one.
    /// Showing it would buy nothing either, because `completeEntry` dispatches
    /// the converse hop in the same beat and the user has no window to act.
    func testTranscriptNotificationTakesNoTranscript() throws {
        let site = "ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift"
        let source = try strippedSource(at: site)

        XCTAssertTrue(
            source.contains("func postTranscriptNotification("),
            "`postTranscriptNotification` is gone from \(site) — the queued-relay banner moved."
        )
        XCTAssertTrue(
            source.contains("func postTranscriptNotification()"),
            """
            `postTranscriptNotification` takes a parameter again. The queued-relay banner \
            must carry fixed copy: its input is a transcript from a user-configured speech \
            endpoint, and the body renders on the wrist AND mirrors to the paired iPhone's \
            lock screen.
            """
        )
        XCTAssertTrue(
            source.contains("Transcription complete. Sending to your AI."),
            "\(site) no longer carries the fixed queued-relay copy the catalog is keyed to."
        )
    }
}
