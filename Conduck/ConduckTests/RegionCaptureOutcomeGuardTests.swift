// SPDX-License-Identifier: Apache-2.0

// Conduck
// RegionCaptureOutcomeGuardTests.swift
//
// SOURCE DRIFT GUARD over `RegionCaptureController`, the ONE screenshot engine
// now shared by two lanes with opposite tolerances for "no picture":
//
//   • ⌘⇧2 "Screenshot & Ask" — the pixels ARE the question. No screenshot, no
//     request; every stop aborts.
//   • ⌃⌘W "Capture to Work"  — the picture is optional decoration on a private
//     note. A permission wall must cost the user the picture, never the note.
//
// Four facts hold that split together, and all four are invisible in a diff and
// checkable by hand only on a signed Mac with the TCC database in a specific
// state:
//
// (1) The answer is a FOUR-case outcome, not `Data?`. A single `nil` cannot say
//     whether the person chose to go without a screenshot or whether Conduck
//     failed to take one — and the caller starts a microphone on one and
//     nothing on the other. Collapsing the enum re-introduces exactly that
//     coin-flip.
// (2) Each lane draws its OWN hint key. Ask's overlay must not advertise a
//     Return-to-skip it does not implement, and Work's must advertise the one
//     it does; one shared key cannot say both.
// (3) Return skips only under `.work`. On Ask a Return that resolved the
//     overlay would send a question with no image and no error — the single
//     worst outcome available to this file.
// (4) The "Continue Without Screenshot" button exists only where a screenshot
//     is optional. Offering it on Ask names an outcome that lane has no code
//     path for; withholding it on Work makes Screen Recording a hard
//     requirement for a voice note that never needed a camera.
//
// The file under test is `#if os(macOS)` and is never compiled by this suite,
// so each invariant is asserted where it is written, over comment-stripped
// source (`RefusalLaneSource`) — a header that DESCRIBES the rule can never
// stand in for the code that does it. A guard that fails because the shape
// legitimately changed is a guard to update, not a bug to route around.

import XCTest

final class RegionCaptureOutcomeGuardTests: XCTestCase {

    private static let capturePath = "Conduck/ScreenCapture/RegionCaptureController.swift"

    // MARK: - (1) The outcome is four-valued

    func testTheOutcomeEnumCarriesExactlyTheFourResults() throws {
        let source = try Self.squeezedSource()
        let body = try RefusalLaneSource.trailingClosure(
            after: Self.squeezed("enum RegionCaptureOutcome: Sendable"),
            in: source,
            path: Self.capturePath
        )

        for expected in ["casecaptured(Data)", "caseskipped", "casecancelled", "caseunavailable"] {
            XCTAssertTrue(
                body.contains(expected),
                "`RegionCaptureOutcome` no longer declares `\(expected)`. Each case is a different "
                + "instruction to the caller — proceed with an image, proceed without one, start "
                + "nothing — and a missing one is a branch that silently becomes another."
            )
        }
        XCTAssertEqual(
            Self.occurrences(of: "case", in: body), 4,
            "`RegionCaptureOutcome` gained or lost a case. Every call site switches over it "
            + "exhaustively, so a fifth meaning added here is a meaning the Work lane handles by "
            + "accident: \(body)"
        )

        let purpose = try RefusalLaneSource.trailingClosure(
            after: Self.squeezed("enum RegionCapturePurpose: Sendable"),
            in: source,
            path: Self.capturePath
        )
        XCTAssertTrue(purpose.contains("caseask") && purpose.contains("casework"),
                      "`RegionCapturePurpose` no longer names both lanes: \(purpose)")
        XCTAssertEqual(
            Self.occurrences(of: "case", in: purpose), 2,
            "`RegionCapturePurpose` gained a third lane. The alert copy, the hint and the Return key "
            + "all switch over it, and a lane added here without copy of its own inherits somebody "
            + "else's promise about where data goes: \(purpose)"
        )
    }

    func testCaptureRegionAnswersWithTheOutcomeEnumOnBothLanes() throws {
        let source = try Self.squeezedSource()

        XCTAssertTrue(
            source.contains(Self.squeezed(
                "func captureRegion(purpose: RegionCapturePurpose = .ask, "
                + "requiresMicrophone: Bool = true) async -> RegionCaptureOutcome"
            )),
            "`captureRegion`'s signature drifted. Its callers are written against this exact shape: "
            + "the `.ask` DEFAULT is what keeps the ⌘⇧2 lane behaving as it always has, and the "
            + "`RegionCaptureOutcome` return is what lets Work tell a skip from a failure."
        )
    }

    // MARK: - (2) One hint key per lane

    func testEachLaneDrawsItsOwnOverlayHintKey() throws {
        let source = try Self.squeezedSource()

        XCTAssertTrue(
            source.contains(Self.squeezed(
                #""regionCapture.overlay.hint", defaultValue: "Drag to capture · Esc to cancel""#
            )),
            "The Ask overlay's hint key or its default drifted. Ask has no skip, so a hint that "
            + "mentions one advertises a key press that does nothing."
        )
        XCTAssertTrue(
            source.contains(Self.squeezed(
                #""regionCapture.overlay.hint.work", defaultValue: "Drag to capture · Return to skip · Esc to cancel""#
            )),
            "The Work overlay's hint key or its default drifted. Return-to-skip has no other "
            + "discoverable surface: a user who is not told about it will drag a stray pixel or "
            + "press Esc and lose the note."
        )
        XCTAssertFalse(
            source.contains(Self.squeezed(
                #""regionCapture.overlay.hint", defaultValue: "Drag to capture · Return"#
            )),
            "The ASK hint now promises a Return-to-skip. `keyDown` accepts Return only under the "
            + "Work purpose, so on Ask that sentence names a key press with no handler behind it."
        )
    }

    // MARK: - (3) Return skips, and only on Work

    func testReturnSkipsTheScreenshotOnlyOnTheWorkLane() throws {
        let body = try Self.captureFunction("keyDown")

        XCTAssertTrue(
            body.contains("event.keyCode==53") && body.contains("onCancel?()"),
            "Esc no longer cancels the overlay. One press has to get the user out of an accidental "
            + "hotkey on BOTH lanes — the Settings footer promises exactly that: \(body)"
        )
        XCTAssertTrue(
            body.contains("event.keyCode==36||event.keyCode==76"),
            "The skip no longer accepts both Return (36) and keypad Enter (76). A keypad Enter that "
            + "does nothing reads as a frozen overlay: \(body)"
        )

        let gate = try XCTUnwrap(
            body.range(of: "ifpurpose==.work,")?.lowerBound,
            "The Return handler is no longer gated on the Work purpose. On Ask a Return would "
            + "resolve the overlay with no image, and the request would go out picture-less with no "
            + "error anywhere: \(body)"
        )
        let skip = try XCTUnwrap(
            body.range(of: "onSkip?()", range: gate..<body.endIndex)?.lowerBound,
            "The Work branch no longer reports a skip: \(body)"
        )
        XCTAssertLessThan(gate, skip)
    }

    func testTheOverlayOffersSkipAsAnAccessibilityActionOnWorkOnly() throws {
        let source = try Self.squeezedSource()
        let arm = try RefusalLaneSource.trailingClosure(
            after: Self.squeezed("if purpose == .work"),
            in: source,
            path: Self.capturePath
        )

        XCTAssertFalse(
            arm.contains("keyCode"),
            "Control: this guard grabbed the keyDown branch instead of the overlay view's "
            + "construction — the file's shape moved and the anchor needs updating: \(arm)"
        )
        XCTAssertTrue(
            arm.contains("setAccessibilityCustomActions"),
            "The overlay no longer installs a custom accessibility action under the Work purpose. "
            + "Return-to-skip is a KEY PRESS: without this action a VoiceOver user driving by "
            + "gesture has no way to decline the screenshot at all: \(arm)"
        )
        XCTAssertTrue(
            arm.contains(Self.squeezed(
                #""regionCapture.overlay.skipAction", defaultValue: "Skip screenshot""#
            )),
            "The skip action lost its own catalog key or default, so the one control VoiceOver "
            + "users reach on this overlay cannot be translated: \(arm)"
        )
        XCTAssertEqual(
            Self.occurrences(of: "setAccessibilityCustomActions", in: source), 1,
            "A second `setAccessibilityCustomActions` appeared. Any install outside the "
            + "`purpose == .work` branch offers Ask a skip its flow cannot honour."
        )
    }

    // MARK: - (4) Continue-without-a-screenshot exists only where it means something

    func testOnlyTheWorkLaneIsOfferedAWayToContinueWithoutAScreenshot() throws {
        let alert = try Self.captureFunction("runPermissionAlert")
        XCTAssertTrue(
            alert.contains(Self.squeezed(
                """
                if offersSkip {
                    alert.addButton(withTitle: String(localized: LocalizedStringResource(
                        "regionCapture.permission.skipScreenshot",
                        defaultValue: "Continue Without Screenshot"
                """
            )),
            "The shared alert no longer gates its skip button on `offersSkip`, or the button's key "
            + "drifted. An unconditional third button hands the Ask lane a choice that resolves to "
            + "nothing, and the button-index mapping below it stops meaning what it reads: \(alert)"
        )
        XCTAssertTrue(
            alert.contains(Self.squeezed("return offersSkip ? .skip : .cancel")),
            "The second button no longer resolves by whether a skip was actually added. Read as a "
            + "skip when none was offered, a Cancel would start the microphone the user just "
            + "declined: \(alert)"
        )

        for offering in ["showScreenRecordingRationale", "showGrantNeedsRelaunchAlert"] {
            let body = try Self.captureFunction(offering)
            XCTAssertTrue(
                body.contains(Self.squeezed("offersSkip: purpose == .work")),
                "`\(offering)` no longer offers the skip on Work only. Dropped, Screen Recording "
                + "becomes a hard requirement for a voice note; widened to Ask, it offers a way out "
                + "that lane cannot take."
            )
        }

        let mic = try Self.captureFunction("showMicrophonePermissionAlert")
        XCTAssertTrue(
            mic.contains(Self.squeezed("offersSkip: false")),
            "The microphone alert started offering 'Continue Without Screenshot'. A missing "
            + "microphone stops the RECORDING, not the picture, so that button would offer to "
            + "continue with nothing at all: \(mic)"
        )

        let preflight = try Self.captureFunction("preflightPermissions")
        XCTAssertTrue(
            preflight.contains(Self.squeezed(
                """
                switch purpose {
                case .ask:
                    openPrivacyPane("Privacy_ScreenCapture")
                    return .unavailable
                case .work:
                    switch showScreenRecordingDeniedAlert() {
                """
            )),
            "The denied Screen Recording path no longer splits by lane. Ask must stay a bare "
            + "deep link exactly as it is today, and Work must get the alert that carries its third "
            + "choice — a shared path here silently changes one of the two: \(preflight)"
        )
    }

    // MARK: - Re-entrancy

    func testASecondPressMidFlowResolvesUnavailable() throws {
        let body = try Self.captureFunction("captureRegion")

        XCTAssertTrue(
            body.contains(Self.squeezed("guard !captureFlowActive else { return .unavailable }")),
            "The re-entrancy guard is gone or no longer answers `.unavailable`. A modal alert pumps "
            + "a nested run loop that still delivers the global hotkey, so the second press is real; "
            + "answering `.skipped` would start a microphone off a dropped duplicate, and "
            + "answering `.captured` is impossible: \(body)"
        )
    }

    // MARK: - Control

    /// The squeeze is what makes the assertions above indifferent to line
    /// breaking, and comment stripping is what stops this file's PROSE about a
    /// rule from satisfying a check on the code that implements it. Both are
    /// asserted here, or every `contains` in this suite is a claim about nothing.
    func testTheSqueezeIgnoresFormattingAndCommentsCannotSatisfyAGuard() throws {
        let wrapped = Self.squeezed("""
        func captureRegion(
            purpose: RegionCapturePurpose = .ask,
            requiresMicrophone: Bool = true
        ) async -> RegionCaptureOutcome {
        """)
        XCTAssertTrue(
            wrapped.contains(Self.squeezed(
                "func captureRegion(purpose: RegionCapturePurpose = .ask, "
                + "requiresMicrophone: Bool = true) async -> RegionCaptureOutcome"
            )),
            "Control: a wrapped signature must read the same as a one-line one."
        )

        let prose = Self.squeezed("""
        // Work adds a "Continue Without Screenshot" button and Return skips the shot.
        let x = 1
        """)
        XCTAssertFalse(prose.contains("ContinueWithoutScreenshot"),
                       "Control: a comment describing the button must not satisfy a check on the "
                       + "code that adds it.")
        XCTAssertFalse(prose.contains("Return"),
                       "Control: a comment naming the key must not satisfy the keyDown guard either.")
    }

    // MARK: - Source access

    /// Comment-stripped and whitespace-free, so indentation and line breaks
    /// cannot change what the code says.
    private static func squeezed(_ source: String) -> String {
        RefusalLaneSource.stripComments(source).filter { !$0.isWhitespace }
    }

    private static func squeezedSource() throws -> String {
        squeezed(try RefusalLaneSource.rawSource(at: capturePath))
    }

    /// One function's body from `RegionCaptureController`, squeezed. Scoping to
    /// a single function is what keeps an assertion from being satisfied by an
    /// unrelated statement elsewhere in the file — the whole meaning of the
    /// `offersSkip` checks is "in THIS alert".
    private static func captureFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: capturePath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: capturePath))
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }
}
