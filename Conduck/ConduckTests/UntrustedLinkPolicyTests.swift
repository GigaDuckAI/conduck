// SPDX-License-Identifier: Apache-2.0

// Conduck
// UntrustedLinkPolicyTests.swift
//
// Behaviour coverage for the link half of the untrusted-Markdown policy
// (Utilities/MarkdownAttachmentPolicy.swift). A tapped link in an agent reply is
// attacker-chosen in BOTH halves — the visible text AND the destination — so the
// policy decides per scheme: web/mail go straight out, a schemeless target stays
// a no-op, and anything else stops to show the destination, asking when it can be
// shown in full and refusing when it can't.
//
// The source-level drift guard (MarkdownAttachmentPolicyDriftGuardTests) only
// proves the modifier is APPLIED at every render site. These tests prove it does
// the right thing when it is — including two traps a source scan can never see:
// returning `.handled` for an allowed scheme (compiles, reads like "allowed",
// silently swallows every legitimate link), and returning `.systemAction` for a
// prompted one (opens it regardless of the answer).
//
// The presenter is injected as a recorder, so no test ever puts an alert on
// screen: presenting for real would run an app-modal `NSAlert` on the runner's
// main run loop and hang the whole suite.

import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class UntrustedLinkPolicyTests: XCTestCase {

    // MARK: - Helpers

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), "Test fixture is not a URL: \(string)")
    }

    /// `OpenURLAction.Result` is neither `Equatable` nor introspectable, and its
    /// cases are indistinguishable except through their description. So assert on
    /// that, and say so — if a future SDK reshapes the description this fails
    /// loudly instead of silently passing.
    private func describe(_ result: OpenURLAction.Result) -> String {
        String(describing: result)
    }

    /// Runs the real handler with a recording presenter.
    private func tap(_ target: URL) -> (result: String, prompts: [UntrustedLinkPolicy.Prompt]) {
        var prompts: [UntrustedLinkPolicy.Prompt] = []
        let result = UntrustedLinkPolicy.handleTap(on: target, presenting: { prompts.append($0) })
        return (describe(result), prompts)
    }

    // MARK: - The lists themselves

    /// Locks the pass-through set. Adding a scheme here means "one tap, straight
    /// to another app, destination never shown" — it should take a deliberate
    /// edit with a reason, not a drive-by.
    func testPassThroughSchemesAreWebAndMailOnly() {
        XCTAssertEqual(UntrustedLinkPolicy.passThroughSchemes, ["http", "https", "mailto"])
    }

    func testActiveContentSchemesAreRefusedOutright() {
        XCTAssertEqual(UntrustedLinkPolicy.activeContentSchemes, ["javascript", "data"])
    }

    // MARK: - decision(for:)

    func testWebSchemesPassThrough() throws {
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("https://example.com/docs")), .open)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("http://example.com")), .open)
    }

    /// Markdown keeps the scheme's case verbatim (`AttributedString(markdown:)`
    /// does no normalisation), so the comparison has to fold case or an
    /// `HTTPS://` link would be treated as an unknown scheme.
    func testSchemeMatchingIsCaseInsensitive() throws {
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("HTTPS://example.com/x")), .open)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("hTtP://example.com")), .open)
        XCTAssertEqual(
            UntrustedLinkPolicy.decision(for: try url("JavaScript:alert(1)")),
            .refuse(.activeContent)
        )
    }

    /// `mailto` is in the allowlist because it opens a compose window the user
    /// must still send — a prefilled draft is not an action.
    func testMailtoPassesThrough() throws {
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("mailto:someone@example.com")), .open)
        XCTAssertEqual(
            UntrustedLinkPolicy.decision(for: try url("mailto:someone@example.com?subject=Hi&body=Text")),
            .open
        )
    }

    /// The headline case: a scheme that hands the device to another app on one
    /// tap. Not blocked — confirmed, because a self-hosted agent may have a real
    /// reason to link into an app the user runs.
    func testAppSchemesAskFirst() throws {
        for target in [
            "shortcuts://run-shortcut?name=GigaAction",
            "file:///Applications/Utilities/Terminal.app",
            "obsidian://open?vault=notes&file=today",
            "vscode://file/Users/someone/project"
        ] {
            XCTAssertEqual(
                UntrustedLinkPolicy.decision(for: try url(target)), .confirm,
                "\(target) must not reach the system without the destination being shown"
            )
        }
    }

    /// Dialling and messaging schemes are deliberately NOT pass-through: one tap
    /// would place a call or prefill a message (premium-rate abuse), and no agent
    /// answer needs them without the user seeing the number.
    func testDiallingSchemesAskFirst() throws {
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("tel:+19005550123")), .confirm)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("sms:+19005550123&body=YES")), .confirm)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("facetime:someone@example.com")), .confirm)
    }

    /// `javascript:` / `data:` get no Open button at all: the "destination" is a
    /// payload rather than a place, so showing it in full still tells the user
    /// nothing they can judge.
    func testActiveContentSchemesAreRefused() throws {
        XCTAssertEqual(
            UntrustedLinkPolicy.decision(for: try url("javascript:alert(1)")),
            .refuse(.activeContent)
        )
        XCTAssertEqual(
            UntrustedLinkPolicy.decision(for: try url("data:text/html;base64,AAAA")),
            .refuse(.activeContent)
        )
    }

    /// Agents routinely answer with a bare host path, which Markdown parses as a
    /// relative link with no scheme (`ReplySanitizerTests` locks that shape). The
    /// system open handler already does nothing with it, so the tap stays a
    /// no-op: a confirmation would be a dead end.
    func testSchemelessTargetsAreIgnored() throws {
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("/Users/testuser/conduck-files/poem.md")), .ignore)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("poem.md")), .ignore)
        // Protocol-relative: a host but no scheme, so still nothing to open.
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: try url("//evil.example/path")), .ignore)
    }

    // MARK: - Padding attack

    /// THE reason the confirmation shows the whole destination or nothing. A
    /// padded query would push the decisive `&name=…` past any truncation point,
    /// so consent would be uninformed — the tap is refused instead of offered.
    func testPaddedDestinationIsRefusedNotConfirmed() throws {
        let padding = String(repeating: "a", count: 4000)
        let padded = try url("shortcuts://run-shortcut?pad=\(padding)&name=GigaAction")

        XCTAssertEqual(UntrustedLinkPolicy.decision(for: padded), .refuse(.tooLongToShow))

        let outcome = tap(padded)
        XCTAssertEqual(outcome.prompts.count, 1, "The user must still be told why nothing happened")
        XCTAssertFalse(
            try XCTUnwrap(outcome.prompts.first).offersOpen,
            "A destination that can't be shown in full must not come with an Open button"
        )
    }

    /// The limit is a policy boundary, so pin both sides of it.
    func testConfirmationLimitBoundary() throws {
        let prefix = "shortcuts://run-shortcut?name="
        let atLimit = try url(prefix + String(
            repeating: "a",
            count: UntrustedLinkPolicy.maxConfirmableDestinationLength - prefix.count
        ))
        // Fixture sanity: the URL really is exactly at the limit.
        XCTAssertEqual(atLimit.absoluteString.count, UntrustedLinkPolicy.maxConfirmableDestinationLength)
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: atLimit), .confirm)

        let overLimit = try url(atLimit.absoluteString + "a")
        XCTAssertEqual(UntrustedLinkPolicy.decision(for: overLimit), .refuse(.tooLongToShow))
    }

    // MARK: - handleTap(on:presenting:)

    /// Trap 1. An allowed scheme MUST come back as `.systemAction`; `.handled`
    /// would look like "allowed" and swallow every real link.
    func testAllowedSchemeReturnsSystemActionAndNeverPrompts() throws {
        let outcome = tap(try url("https://example.com/docs"))
        XCTAssertTrue(
            outcome.result.contains("systemAction"),
            "Expected `.systemAction` so the system opens the link; got \(outcome.result)"
        )
        XCTAssertTrue(outcome.prompts.isEmpty, "A web link must open without an interstitial")
    }

    /// Trap 2. The confirmation must REPLACE the open, not accompany it: the
    /// handler reports the tap handled, and the URL is opened later only if the
    /// user says so from the alert.
    func testUnknownSchemePromptsWithTheRealDestinationAndDoesNotOpen() throws {
        let target = try url("shortcuts://run-shortcut?name=GigaAction")
        let outcome = tap(target)

        let prompt = try XCTUnwrap(outcome.prompts.first)
        XCTAssertEqual(outcome.prompts.count, 1)
        XCTAssertEqual(prompt.url, target, "The alert must be about the destination, not the label")
        XCTAssertTrue(prompt.offersOpen)
        XCTAssertTrue(
            outcome.result.contains("handled"),
            "Expected `.handled` (the alert owns the outcome); got \(outcome.result)"
        )
        XCTAssertFalse(
            outcome.result.contains("systemAction"),
            "A confirmed scheme must NOT also be handed to the system — that would open it regardless of the answer"
        )
    }

    func testRefusedSchemePromptsWithoutAnOpenButtonAndDoesNotOpen() throws {
        let outcome = tap(try url("javascript:alert(1)"))

        XCTAssertFalse(try XCTUnwrap(outcome.prompts.first).offersOpen)
        XCTAssertTrue(outcome.result.contains("handled"), "got \(outcome.result)")
        XCTAssertFalse(outcome.result.contains("systemAction"), "got \(outcome.result)")
    }

    func testSchemelessTargetIsDiscardedSilently() throws {
        let outcome = tap(try url("/Users/testuser/conduck-files/poem.md"))
        XCTAssertTrue(
            outcome.result.contains("discarded"),
            "Expected `.discarded`; got \(outcome.result)"
        )
        XCTAssertTrue(outcome.prompts.isEmpty, "A link that can't open anything must not raise an alert")
    }
}
