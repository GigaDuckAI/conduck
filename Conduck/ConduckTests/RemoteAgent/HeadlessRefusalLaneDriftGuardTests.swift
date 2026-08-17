// SPDX-License-Identifier: Apache-2.0

// Conduck
// HeadlessRefusalLaneDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the one question every capture lane has to ask in the
// same order: BEFORE refusing a capture on the default gateway's verdict, does
// this capture continue a live conversation instead?
//
// Why a guard and not review. The rule lives in `SharedInboxRouting.resolveOrMint`
// — pointer first, default second — and every pre-flight is a SECOND statement of
// it, written so a refusal can happen before the microphone rather than after it.
// A pre-flight that forgets the pointer arm compiles, reads as ordinary gateway
// plumbing in a diff, and breaks no runtime test: the lanes are App Intents,
// `#if os(macOS)` coordinators and a separate watchOS target, none of which the
// iOS-Simulator suite can drive end to end. It also fails in the worst possible
// place — a capture waved through before the mic and refused after it, with the
// words already spoken. Two consecutive rounds fixed one lane and left the
// others, which is what makes this a source-scanning problem: the property is
// about how the code is WRITTEN.
//
// It reaches the WATCH, which no other test in this suite can. The wrist is a
// separate target that links none of `SharedInboxRouting`, so its rule is a
// documented sibling rather than a call — and a sibling with no shared compiler
// between it and its twin is exactly the thing that drifts. Both sit in the
// project container, so one scan sees both.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS GUARD CHECKS (on comment-stripped source)
//
//   Rule 1 — every IMPLICIT lane asks first. A lane that resolves its own
//     destination (no human picked a thread) must reach its live-continuation
//     helper at a source offset BEFORE the first refusal it can throw.
//
//   Rule 2 — the registry is EXHAUSTIVE. Any shipping file that refuses with
//     `AppError.remoteAgentDefaultNeedsSetup` must be classified here. A new lane
//     therefore cannot be added silently; it fails until someone states which
//     kind it is.
//
//   Rule 0 — the NEGATIVE CONTROL. A guard nobody has seen fail reads as
//     coverage, so the ordering check is driven over synthetic sources that do
//     and do not satisfy it.

import XCTest
@testable import Conduck

final class HeadlessRefusalLaneDriftGuardTests: XCTestCase {

    /// How a file that can refuse a capture is allowed to reach that refusal.
    private enum LaneKind {
        /// The destination is resolved by the app, not chosen by the user — the
        /// Action Button, the bundled Shortcut, the menu-bar hotkey, the wrist.
        /// `gate` must appear before `refusal`.
        case implicit(gate: String, refusal: String)

        /// The user named the target before anything was recorded (a CarPlay list
        /// row, a share-sheet pick). The default's verdict is the right question
        /// there BY CONSTRUCTION: nothing is being continued, because the user
        /// asked for a specific thread or a specific new chat.
        case explicitTarget(reason: String)

        /// Not a lane at all — it declares the error or renders it.
        case notALane(reason: String)
    }

    /// Paths relative to the project container (`.../Conduck/Conduck`).
    private static let lanes: [String: LaneKind] = [
        // The bundled Shortcut's first action — the one refusal that genuinely
        // lands before the microphone.
        "Conduck/Intents/CheckNetworkIntent.swift": .implicit(
            gate: "SharedInboxRouting.liveQuickCaptureCanContinue",
            refusal: "case .brokenDefault"
        ),
        // GigaAction itself. Its refusal arrives AFTER the mic, so a verdict the
        // pre-flight above already waved through costs the user spoken words.
        "Conduck/Intents/ConverseIntent.swift": .implicit(
            gate: "SharedInboxRouting.liveQuickCaptureCanContinue",
            refusal: "case .brokenDefault"
        ),
        // The router — THE rule, which every pre-flight above restates.
        "Conduck/Services/RemoteAgent/SharedInboxRouting.swift": .implicit(
            gate: "resolveQuickCaptureConversation(",
            refusal: "case .brokenDefault"
        ),
        // CarPlay: the driver picks a row. `newChatPlan` runs only in the
        // no-conversation branch, so the default IS the destination there.
        "Conduck/CarPlay/CarPlaySceneDelegate.swift": .explicitTarget(
            reason: "the driver picks the thread or a new chat from the list before anything records"
        ),
        "Conduck/CarPlay/CarPlayRecordingService.swift": .explicitTarget(
            reason: "mints only on the session ref the driver's own pick froze"
        ),
        "Conduck/Models/AppError.swift": .notALane(reason: "declares the error"),
        "Conduck/Services/RemoteAgent/BackgroundRemoteAgent.swift": .notALane(
            reason: "posts the notification a lane's refusal already decided"
        ),
    ]

    /// The two lanes whose refusal is not spelled `remoteAgentDefaultNeedsSetup`
    /// — so Rule 2 cannot find them — but which decide exactly the same thing.
    /// Listed explicitly, which is the point: they are the two that drifted.
    private static let extraImplicitLanes: [String: LaneKind] = [
        // The wrist. A separate target, so its rule is a documented sibling of
        // `liveQuickCaptureCanContinue` rather than a call to it.
        "ConduckWatch Watch App/Services/WatchRecordingService.swift": .implicit(
            gate: "Self.liveCaptureCanContinue(",
            refusal: "if let refusal = headlessGatewayRefusal("
        ),
        // The macOS menu bar. Its readiness FLAG is what the four press guards
        // refuse on, so the live-continuation question has to be answered before
        // that flag is committed.
        "Conduck/MenuBar/MenuBarCoordinator.swift": .implicit(
            gate: "SharedInboxRouting.liveQuickCaptureCanContinue",
            refusal: "isQuickCaptureReady = quickReady"
        ),
    ]

    // MARK: - Rule 1 — every implicit lane asks before it refuses

    func testEveryImplicitLaneAsksTheLiveContinuationQuestionFirst() throws {
        let all = Self.lanes.merging(Self.extraImplicitLanes) { current, _ in current }
        var checked = 0
        for (path, kind) in all {
            guard case .implicit(let gate, let refusal) = kind else { continue }
            let source = try RefusalLaneSource.source(at: path)
            guard let gateAt = source.range(of: gate)?.lowerBound else {
                return XCTFail("\(path) no longer asks `\(gate)`. A lane that refuses on the default's "
                               + "verdict alone refuses captures the router would have appended to a "
                               + "live conversation.")
            }
            guard let refusalAt = source.range(of: refusal)?.lowerBound else {
                return XCTFail("\(path) no longer contains `\(refusal)` — update this registry to name "
                               + "whatever it refuses with now, rather than deleting the row.")
            }
            XCTAssertLessThan(gateAt, refusalAt,
                              "\(path) refuses before it asks whether this capture continues a live "
                              + "conversation. Pointer first, default second — that is the order "
                              + "`SharedInboxRouting.resolveOrMint` resolves in, and a pre-flight that "
                              + "inverts it refuses chats that were never going to be minted.")
            checked += 1
        }
        XCTAssertEqual(checked, 5, "Five implicit lanes are registered; the loop must have walked all of them.")
    }

    /// The wrist's sibling rule has to state WHY it is a copy, or the next reader
    /// deletes one of the two halves as redundant.
    func testTheWristExplainsWhyItsRuleIsASiblingRatherThanACall() throws {
        // The RAW source: this is the one check about what the file SAYS, and
        // the explanation lives in its doc comment by design.
        let source = try RefusalLaneSource.rawSource(
            at: "ConduckWatch Watch App/Services/WatchRecordingService.swift")
        XCTAssertTrue(source.contains("liveQuickCaptureCanContinue"),
                      "The wrist's helper must name its phone-side twin, or the two are only related by "
                      + "accident.")
        XCTAssertTrue(source.contains("separate target"),
                      "…and must say why it cannot simply call it.")
    }

    // MARK: - Rule 2 — the registry is exhaustive

    func testEveryFileThatRefusesACaptureIsClassified() throws {
        let container = RefusalLaneSource.projectContainerURL
        guard let walker = FileManager.default.enumerator(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }
        var unclassified: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.path.replacingOccurrences(of: container.path + "/", with: "")
            // Tests state the rule; they do not implement it.
            guard !path.contains("Tests/") else { continue }
            let source = RefusalLaneSource.stripComments(try String(contentsOf: url, encoding: .utf8))
            guard source.contains("remoteAgentDefaultNeedsSetup") else { continue }
            guard Self.lanes[path] == nil else { continue }
            unclassified.append(path)
        }
        XCTAssertTrue(unclassified.isEmpty,
                      "New capture-refusal site(s) with no entry in this guard: \(unclassified). "
                      + "Classify each one — an implicit lane has to ask the live-continuation question "
                      + "before it refuses; an explicit-target lane has to say why it is exempt.")

        // …and the registry must not rot into a list of files that moved away.
        for path in Self.lanes.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(path).path),
                          "Registered path \(path) no longer exists — a stale row silently exempts nothing.")
        }
    }

    // MARK: - Rule 0 — the negative control

    /// The ordering check must genuinely fail on an inverted lane, or Rule 1 is
    /// an assertion nobody has ever seen bite.
    func testTheOrderingCheckDistinguishesAskFirstFromRefuseFirst() throws {
        let asksFirst = """
        let can = await SharedInboxRouting.liveQuickCaptureCanContinue(defaultRef: snap.defaultRef)
        if !can { switch snap.resolution { case .brokenDefault: throw x } }
        """
        let refusesFirst = """
        switch snap.resolution { case .brokenDefault: throw x }
        let can = await SharedInboxRouting.liveQuickCaptureCanContinue(defaultRef: snap.defaultRef)
        """
        let gate = "SharedInboxRouting.liveQuickCaptureCanContinue"
        let refusal = "case .brokenDefault"

        let good = try XCTUnwrap(asksFirst.range(of: gate)?.lowerBound)
        let goodRefusal = try XCTUnwrap(asksFirst.range(of: refusal)?.lowerBound)
        XCTAssertLessThan(good, goodRefusal, "Control: the compliant shape must pass.")

        let bad = try XCTUnwrap(refusesFirst.range(of: gate)?.lowerBound)
        let badRefusal = try XCTUnwrap(refusesFirst.range(of: refusal)?.lowerBound)
        XCTAssertGreaterThan(bad, badRefusal,
                             "Control: the drifted shape must be distinguishable, or Rule 1 asserts nothing.")
    }

    /// Comment stripping is what keeps a lane's own PROSE about the rule from
    /// standing in for the code that implements it — every one of these files
    /// discusses the pointer arm at length in its header.
    func testCommentStrippingRemovesProseThatWouldSatisfyTheGate() throws {
        let source = """
        // We ask SharedInboxRouting.liveQuickCaptureCanContinue here.
        /* and again: liveQuickCaptureCanContinue */
        switch snap.resolution { case .brokenDefault: throw x }
        """
        let stripped = RefusalLaneSource.stripComments(source)
        XCTAssertFalse(stripped.contains("liveQuickCaptureCanContinue"),
                       "A header that DESCRIBES the rule must never satisfy a check on whether the code "
                       + "DOES it — which is exactly how the two drifted lanes read as correct.")
        XCTAssertTrue(stripped.contains("case .brokenDefault"))
    }

}

// MARK: - Source access

/// Reading the project's own sources, shared by both guards in this file.
///
/// Free of `XCTest` on purpose: an `XCTUnwrap` here would record its failure
/// against whichever instance happened to own the helper rather than the test
/// that called it, and a guard whose failures land in the wrong place is worse
/// than no guard.
enum RefusalLaneSource {

    enum Failure: Error, CustomStringConvertible {
        case missingFile(String)
        case missingFunction(name: String, path: String)

        var description: String {
            switch self {
            case .missingFile(let path):
                return "Missing \(path) — update this guard's path derivation."
            case .missingFunction(let name, let path):
                return "No `func \(name)` in \(path) — update this guard."
            }
        }
    }

    /// `.../Conduck/Conduck` — the Xcode project container holding all targets'
    /// sources, watchOS included. Derived from this file's compile-time absolute
    /// path, so it is independent of the runner's working directory.
    static var projectContainerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../RemoteAgent
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Comment-stripped, for every check about what the code DOES.
    static func source(at relativePath: String) throws -> String {
        stripComments(try rawSource(at: relativePath))
    }

    /// Comments intact, for the one check about what the code SAYS.
    static func rawSource(at relativePath: String) throws -> String {
        let url = projectContainerURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missingFile(relativePath)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of a `func` named `name`, brace-matched from its opening `{`.
    /// Scoping an assertion to ONE function is what keeps a guard from being
    /// satisfied by an unrelated statement elsewhere in a 1,500-line view.
    static func body(ofFunction name: String, in source: String, path: String) throws -> String {
        guard let declaration = source.range(of: "func \(name)("),
              let opening = source.range(of: "{", range: declaration.upperBound..<source.endIndex) else {
            throw Failure.missingFunction(name: name, path: path)
        }
        var index = opening.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    /// Strip `//` line comments and `/* … */` blocks. String literals are not
    /// modelled: none of these files carries a `//` inside a literal, and the
    /// strict direction of a miss would be a FALSE FAILURE, which someone reads.
    static func stripComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}

// MARK: - The landing sites

/// SOURCE DRIFT GUARD over the other half of a headless refusal: where it puts
/// the user once the app opens.
///
/// `GatewayFixRoute.consumeIfStillBroken()` is a ONE-SHOT read-and-clear, and
/// each platform root has a presentation surface that must not be torn down
/// underneath a half-finished edit. Those two facts fix the order: guard that the
/// surface can be presented, THEN claim. Reversed, the route is spent and the app
/// navigates nowhere; without the guard at all, assigning a fresh route id over a
/// presented sheet destroys the gateway editor and any bearer token being pasted
/// into it. The two roots failed in OPPOSITE directions for the same input —
/// iOS destructively, macOS inertly — which is precisely the shape a reviewer
/// reads past, because each looks locally reasonable on its own.
///
/// Neither root is reachable from a test: `ContentView` needs a mounted SwiftUI
/// hierarchy and `MainWindowView` is `#if os(macOS)` and never compiled by this
/// suite at all. So the order is asserted where it is written.
final class GatewayFixRouteLandingDriftGuardTests: XCTestCase {

    /// Both roots: the presentation guard precedes the one-shot claim.
    ///
    /// macOS's token carries its `settingsJustOpened` exemption, and must: the
    /// window root opens Settings itself one statement before it consumes the
    /// route, so a bare `!showingSettings` there refuses every fix request that
    /// arrives with a deferred menu-bar "Settings…". Pinning the whole expression
    /// is what stops the exemption being widened into a plain bypass.
    func testBothRootsGuardThePresentationBeforeSpendingTheRoute() throws {
        let roots: [(path: String, guardToken: String)] = [
            ("Conduck/ContentView.swift", "guard settingsRoute == nil"),
            ("Conduck/Views/Conversation/MainWindowView.swift",
             "guard settingsJustOpened || !showingSettings"),
        ]
        for root in roots {
            let source = try RefusalLaneSource.source(at: root.path)
            let body = try RefusalLaneSource.body(ofFunction: "consumeGatewayFixRoute", in: source, path: root.path)
            let guardAt = try XCTUnwrap(
                body.range(of: root.guardToken)?.lowerBound,
                "\(root.path): `consumeGatewayFixRoute` no longer guards on whether its surface can be "
                + "presented. Without it a background refusal tears down a live gateway editor."
            )
            let claimAt = try XCTUnwrap(
                body.range(of: "GatewayFixRoute.consumeIfStillBroken")?.lowerBound,
                "\(root.path): `consumeGatewayFixRoute` no longer claims the route at all."
            )
            XCTAssertLessThan(guardAt, claimAt,
                              "\(root.path): the claim happens before the guard, so a route that cannot be "
                              + "presented is SPENT and the user is navigated nowhere. Guard first.")
        }
    }

    /// The macOS settings host applies a deep-linked category on `.onAppear`
    /// only, and it is a full-window mode swap that does not remount — so a
    /// deep-link arriving while it is open needs the live-change reaction the
    /// file already established for the Troubleshoot hand-off.
    func testTheMacSettingsHostReactsToALiveCategoryDeepLink() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Settings/MacSettingsView.swift")
        XCTAssertTrue(source.contains(".onChange(of: initialCategory)"),
                      "Without it a category deep-link that arrives while Settings is already open is a "
                      + "dead no-op — the route is spent and nothing on screen moves.")
        XCTAssertTrue(source.contains(".onChange(of: initialFocus)"),
                      "Control: the idiom this mirrors must still be here, or the two have been merged "
                      + "and this assertion is checking a ghost.")
    }

    /// …and reacting is not enough on its own. `.onChange` fires on CHANGE, so a
    /// slot the shell holds until Settings exits makes a REPEAT deep-link to the
    /// category already sitting there write the same value and fire nothing —
    /// inert in exactly the case the reaction above was added for. The slot has
    /// to be emptied on delivery, which needs a binding rather than a `let`.
    func testTheMacSettingsHostConsumesTheCategorySlotSoARepeatDeepLinkLands() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Settings/MacSettingsView.swift")
        XCTAssertTrue(source.contains("@Binding var initialCategory: Category?"),
                      "A `let` cannot be emptied, so the host could not make a repeat deep-link a change.")
        // Twice, deliberately: once on first appear and once on the live
        // `.onChange` path. Clearing only on appear leaves the repeat-deep-link
        // case — the one this is about — exactly as inert as before.
        let clears = source.components(separatedBy: "self.initialCategory = nil").count - 1
        XCTAssertEqual(clears, 2,
                       "The slot must be emptied on BOTH delivery paths — first appear and the live "
                       + "`.onChange` — or the second request for the same category is silent.")
    }

    /// The deep-link path writes `pendingSelection`, which is the value the shared
    /// discard alert's two branches are chosen by. Writing it while the alert is
    /// already up flips what the user's Discard means between reading it and
    /// tapping it. The sidebar's path to the same state is `.disabled` for exactly
    /// this reason; the deep-link needs the same answer.
    func testTheMacSettingsCategoryDeepLinkDefersToALiveDiscardConfirm() throws {
        let source = try RefusalLaneSource.source(at: "Conduck/Views/Settings/MacSettingsView.swift")
        let reaction = try XCTUnwrap(
            source.range(of: ".onChange(of: initialCategory)")?.upperBound,
            "The live-category reaction is gone; this guard is checking a ghost."
        )
        // The window between the reaction and the alert it must not disturb.
        let alertAt = try XCTUnwrap(source.range(of: ".alert(", range: reaction..<source.endIndex)?.lowerBound)
        let reactionBody = String(source[reaction..<alertAt])
        XCTAssertTrue(reactionBody.contains("guard !showingDiscardConfirm"),
                      "A deep-link that writes `pendingSelection` under a presented discard alert flips "
                      + "the alert's branch under the user's finger. Match the sidebar's own guard.")
        let guardAt = try XCTUnwrap(reactionBody.range(of: "guard !showingDiscardConfirm")?.lowerBound)
        let writeAt = try XCTUnwrap(reactionBody.range(of: "pendingSelection = category")?.lowerBound)
        XCTAssertLessThan(guardAt, writeAt,
                          "The guard has to precede the write, or it guards nothing.")
    }

    /// An armed-but-unpresentable route is not lost, it is DEFERRED — and a
    /// deferral nobody ever collects is the same as a drop. Both roots leave the
    /// route armed when a Settings surface is already up, so both must re-run the
    /// claim when that surface goes away. Written identically on the two roots,
    /// because the last two rounds' bugs were both one root doing half of this.
    func testBothRootsReconsumeTheRouteWhenSettingsGoesAway() throws {
        // iOS: the sheet's own dismissal handler.
        let iOSPath = "Conduck/ContentView.swift"
        let iOSSource = try RefusalLaneSource.source(at: iOSPath)
        let dismissBody = try RefusalLaneSource.body(
            ofFunction: "handleSettingsDismiss", in: iOSSource, path: iOSPath)
        XCTAssertTrue(dismissBody.contains("consumeGatewayFixRoute()"),
                      "\(iOSPath): `handleSettingsDismiss` never re-runs the claim, so a user who accepts a "
                      + "refusal's offer while sitting in Settings taps Done and lands nowhere.")

        // macOS: the mode swap's `onDone` closure. Not a `func`, so it is scoped
        // by its own brace-matched literal rather than `body(ofFunction:)`.
        let macPath = "Conduck/Views/Conversation/MainWindowView.swift"
        let macSource = try RefusalLaneSource.source(at: macPath)
        let onDone = try XCTUnwrap(
            macSource.range(of: "onDone: {"),
            "\(macPath): the Settings host no longer takes an `onDone` closure; update this guard."
        )
        let closeAt = try XCTUnwrap(
            macSource.range(of: "},", range: onDone.upperBound..<macSource.endIndex)?.lowerBound)
        XCTAssertTrue(macSource[onDone.upperBound..<closeAt].contains("consumeGatewayFixRoute()"),
                      "\(macPath): the `onDone` closure never re-runs the claim, so the macOS root drops "
                      + "the deferred route its iOS twin collects. Both roots or neither.")
    }

    /// The macOS window root opens Settings itself immediately before consuming
    /// the route, so the exemption that lets the claim through has to be SET by
    /// that same block. A `settingsJustOpened` that is never true is a comment
    /// promising behaviour the code does not have — which is exactly what the
    /// unqualified guard was.
    func testTheMacRootExemptsTheSettingsItJustOpenedFromItsOwnGuard() throws {
        let path = "Conduck/Views/Conversation/MainWindowView.swift"
        let source = try RefusalLaneSource.source(at: path)
        let body = try RefusalLaneSource.body(ofFunction: "onAppear", in: source, path: path)
        let openedAt = try XCTUnwrap(
            body.range(of: "settingsJustOpened = true")?.lowerBound,
            "`onAppear`'s deferred-settings block no longer records that it opened Settings, so the "
            + "consume below refuses every fix request that arrives with a deferred menu-bar Settings."
        )
        let consumeAt = try XCTUnwrap(
            body.range(of: "consumeGatewayFixRoute(settingsJustOpened:")?.lowerBound,
            "`onAppear` no longer passes the exemption, so the claim reads a flag the block above set "
            + "and drops the more specific ask."
        )
        XCTAssertLessThan(openedAt, consumeAt,
                          "The flag must be set before it is passed, or it is always false.")
    }
}
