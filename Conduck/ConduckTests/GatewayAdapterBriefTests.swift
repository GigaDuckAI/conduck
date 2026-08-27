// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayAdapterBriefTests.swift
//
// Content lock for the "Conduck adapter v1" brief the custom-lane escape hatch
// copies to the clipboard (`GatewayAdapterBriefView.clipboardBrief`). The brief
// is pointer-first (it delegates to the hosted build brief, narrowed to stop
// before exposure/pairing — the app owns those) with a self-contained fallback
// aligned to a pinned contract revision, so its load-bearing points must not
// silently drift: the two raw `.md` URLs, the workflow-ownership boundary, the COMPLETE
// runnable adapter-check invocation (download + `CI=1` + `CONDUCK_TOKEN` +
// explicit loopback URL — a bare `--check-adapter` blocks on an interactive
// prompt, and one without `CI=1` hangs on a PASS), the wire shape,
// the image rules (verbatim historical disclosure, never-reject-historical),
// the frozen error-code vocabulary, the 285s cap, the 50 MiB body floor,
// loopback-only bind, and bearer auth. It also guards the security-critical
// NEGATIVES: never a wildcard bind, never the pairing command, never a hosted-brief
// step number, and never the pre-1.3 image rule that permitted rejecting on
// historical images.

import Foundation
import XCTest
@testable import Conduck

final class GatewayAdapterBriefTests: XCTestCase {

    /// Every in-app setup surface uses the direct setup action. Gateway
    /// detection informs the script's menu; the app never forces a hidden lane.
    func testInAppSetupCommandUsesCanonicalSetupFlag() {
        XCTAssertEqual(
            Constants.conduckConnectSetupCommandShort,
            "curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh && bash conduck-connect.sh --setup"
        )
        for retired in ["--generic", "--doctor", "--compat", " check server", " check adapter"] {
            XCTAssertFalse(
                Constants.conduckConnectSetupCommandShort.contains(retired),
                "setup command must not contain retired CLI spelling: \(retired)"
            )
        }
    }

    /// The brief must carry every load-bearing contract point verbatim.
    func testBriefContainsContractInvariants() {
        let brief = GatewayAdapterBriefView.clipboardBrief
        let required = [
            // Pointers + workflow ownership (the app owns exposure/pairing)
            "https://conduck.com/setup/adapter/build.md", // hosted build brief
            "https://conduck.com/setup/adapter/v1.md",    // full contract mirror
            "supervisor",                                  // always-on install stays in scope
            // Adapter check in COMPLETE runnable form — a bare `--check-adapter`
            // blocks on an interactive URL prompt, fatal for a headless agent.
            "curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh",
            "CI=1 CONDUCK_TOKEN=\"$TOKEN\" bash conduck-connect.sh --check-adapter http://127.0.0.1:8480",
            "CI=1 CONDUCK_TOKEN=\"$TOKEN\" bash conduck-connect.sh --check-adapter --deep http://127.0.0.1:8480",
            "if one somehow does, answer no",               // belt-and-braces if CI=1 is dropped

            // Wire + security
            "/v1/chat/completions",                        // the turn route
            "\"data\":[{\"id\":",                          // /v1/models shape
            "within 15 seconds",                           // models-route deadline
            "stream\": false",                             // Conduck always sends false
            "stream\": true",                              // tolerate, answer synchronous JSON
            "Never return tool_calls",                     // no tool_calls, ever
            "127.0.0.1",                                    // loopback-only bind
            "Authorization: Bearer",                        // required auth
            "285",                                          // turn deadline (seconds)
            "50 MiB",                                       // body-cap floor

            // Conversation semantics
            "always role \"user\"",                        // final element = current turn
            "bounded and may slide",                       // window semantics, fresh turn per request
            "never de-duplicate by message content",       // content dedup forbidden

            // Images (rev 1.3: current-turn vs historical split)
            "image_unsupported",                           // current-turn honest rejection code
            "never reject a request because an earlier message contains an image",
            "An image was attached in this earlier message, but this adapter cannot inspect it. Do not infer its contents.",

            // Error-code vocabulary (all eight frozen codes; image_unsupported is
            // asserted under Images above)
            "model_not_found",
            "context_too_long",
            "image_too_large",
            "body_too_large",
            "overloaded",
            "upstream_timeout",
            "upstream_failure",

            // Revision 1.10 clauses (one distinctive substring per moved clause,
            // so the pin cannot read 1.10 while the string quietly loses one)
            "outside any queue you serialize chat through",   // item 2: models route
            "never write the answer yourself",                 // item 3: answers-by-doing
            "not an inline data: URI",                         // item 4: no remote fetch
            "The user sent an image with no accompanying text.", // item 4: verbatim carrier
            "Accepting that much is not forwarding it",        // item 6: floor ≠ forward
            "Connection: close on every response",             // item 7: simplest reuse policy
            "confine the engine",                              // item 9: @path conservative end
            "stopped at its own step cap",                     // item 10: length semantics
        ]
        for needle in required {
            XCTAssertTrue(
                brief.contains(needle),
                "clipboardBrief is missing required substring: \(needle)"
            )
        }
    }

    /// Security-critical negative: the adapter binds loopback only, so the brief
    /// must never tell the AI to bind the wildcard address.
    func testBriefNeverBindsWildcard() {
        XCTAssertFalse(
            GatewayAdapterBriefView.clipboardBrief.contains("0.0.0.0"),
            "clipboardBrief must not instruct a 0.0.0.0 (wildcard) bind"
        )
    }

    /// Workflow-ownership negative: exposure/pairing belongs to the USER via the
    /// app's guided flow — the brief must never hand the AI the pairing command.
    ///
    /// This brief is pasted into an autonomous coding agent, which acts on what it
    /// is given. The brief names exposure and pairing in prose ("I'll handle them
    /// myself through Conduck's guided setup") and deliberately supplies NO runnable
    /// invocation for them, in any spelling — first-person phrasing states intent,
    /// but the absent command is the actual guard. `--check-adapter` stays (that IS
    /// the AI's job); anything that would set up, expose, or pair must not appear.
    func testBriefNeverRunsPairing() {
        let brief = GatewayAdapterBriefView.clipboardBrief
        for forbidden in ["--setup", "--generic", "--expose", "--pair"] {
            XCTAssertFalse(
                brief.contains(forbidden),
                "clipboardBrief must not hand the AI the pairing/exposure invocation: \(forbidden)"
            )
        }
        // The prose hand-off must still be present, so the AI knows the step exists
        // and that someone else owns it — silence would invite it to improvise.
        XCTAssertTrue(
            brief.contains("Conduck's guided setup"),
            "clipboardBrief must still name the user-owned exposure/pairing step in prose"
        )
    }

    /// `CI=1` is not optional for an autonomous agent. Without it a check that
    /// PASSES goes on to ask whether to continue into exposure and pairing, and
    /// waits for an answer the AI is not allowed to give — and it asks AFTER
    /// printing its result, so the run looks finished and then hangs forever.
    /// Every check invocation the brief hands over must carry it.
    func testEveryAdapterCheckInvocationSetsCI() {
        let checkLines = GatewayAdapterBriefView.clipboardBrief
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("--check-adapter") }
        XCTAssertFalse(
            checkLines.isEmpty,
            "clipboardBrief must hand over a runnable adapter-check invocation"
        )
        for line in checkLines {
            XCTAssertTrue(
                line.hasPrefix("CI=1 "),
                "adapter-check invocation must set CI=1 or a PASS hangs waiting: \(line)"
            )
        }
    }

    /// The hosted build brief's step NUMBERS live in another repo, and nothing on
    /// this side guards that a given number still means what the brief claims. Cite
    /// none of them: describe the boundary in words. (A shifted number once put the
    /// operator handoff — the port and token the very next screen of the guided flow
    /// asks for — on the far side of the STOP.)
    func testBriefCitesNoHostedStepNumbers() throws {
        let brief = GatewayAdapterBriefView.clipboardBrief
        let stepNumber = try NSRegularExpression(pattern: "\\bsteps?\\s+\\d", options: [.caseInsensitive])
        XCTAssertEqual(
            stepNumber.numberOfMatches(in: brief, range: NSRange(brief.startIndex..., in: brief)),
            0,
            "clipboardBrief must not cite hosted-brief step numbers — state the boundary in words"
        )
    }

    /// The handoff is INSIDE the narrowed scope, not past it: the user runs
    /// `conduck-connect` on the next screen and needs the adapter's port and token
    /// to do it. Both paths must ask for the hand-back before they say STOP.
    func testBriefHandsBackCredentialsBeforeStopping() {
        let brief = GatewayAdapterBriefView.clipboardBrief
        for needle in [
            "port, bearer token, working folder and supervisor details", // best path
            "handed me its port and token",                              // either path
        ] {
            XCTAssertTrue(
                brief.contains(needle),
                "clipboardBrief must require the operator hand-off before STOP: \(needle)"
            )
        }
    }

    /// The public CLI has one canonical spelling per action. The brief must
    /// not keep any removed aliases or command-form spellings alive.
    func testBriefUsesOnlyCanonicalCLI() {
        let brief = GatewayAdapterBriefView.clipboardBrief
        for retired in ["--generic", "--doctor", "--compat", "check adapter", "check server"] {
            XCTAssertFalse(
                brief.contains(retired),
                "clipboardBrief must not contain retired CLI spelling: \(retired)"
            )
        }
    }

    /// Revision lock: the pre-1.3 image rule ("say so in the reply or return an
    /// error") permitted rejecting a request over a HISTORICAL image — the exact
    /// poisoned-conversation failure revision 1.3 forbids. It must never return.
    func testBriefHasNoStaleImageRule() {
        XCTAssertFalse(
            GatewayAdapterBriefView.clipboardBrief.contains("say so in the reply or return an error"),
            "clipboardBrief carries the pre-1.3 image rule, which permits rejecting on historical images"
        )
    }

    // MARK: - Revision pin

    /// The brief's fallback list is a COPY of the published contract's adapter
    /// half, and its alignment is recorded in one source comment
    /// (`aligned to contract revision <n.n>`). A comment cannot be read through
    /// `@testable import`, so this reads the source file — the same way the site's
    /// post-build verifier reads its own per-file markers — and compares the pin
    /// against `CONTRACT_REVISION`, the one place the current revision lives.
    ///
    /// This exists because the pin drifted once already, unseen: the site's
    /// `verify-contract-artifacts.mjs` deliberately leaves the app out of its
    /// revision sweep on the stated grounds that the app "carries no pinned
    /// revision literal to compare" — which the comment below makes false — so a
    /// contract bump could ship with the app still handing developers the previous
    /// revision's instructions.
    ///
    /// The website lives in the surrounding monorepo, NOT in this repository, so a
    /// standalone checkout of the app has nothing to compare against and SKIPS,
    /// mirroring the verifier's own posture toward files outside its repo. The
    /// skip names what went unverified rather than passing quietly — a silent skip
    /// here would be indistinguishable from agreement, which is the failure this
    /// test is for.
    func testClipboardBriefRevisionPinMatchesPublishedContract() throws {
        // #filePath → .../GigaDuck/Conduck/Conduck/ConduckTests/<thisFile>
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectContainer = testsDirectory.deletingLastPathComponent() // .../Conduck/Conduck
        let viewSourceURL = projectContainer
            .appending(path: "Conduck/Views/Settings/GatewayAdapterBriefView.swift")

        let viewSource = try XCTUnwrap(
            try? String(contentsOf: viewSourceURL, encoding: .utf8),
            "Could not read \(viewSourceURL.path) — update this guard's path derivation."
        )
        let pinned = try XCTUnwrap(
            Self.firstCapturedRevision(in: viewSource, pattern: #"aligned to contract revision (\d+\.\d+)"#),
            "GatewayAdapterBriefView.swift no longer states which contract revision the "
                + "fallback brief is aligned to — restore the pin, don't drop it."
        )

        // .../GigaDuck/Conduck/Conduck → .../GigaDuck (monorepo root), where the
        // website sits beside the app repository when both are checked out.
        let monorepoRoot = projectContainer
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractsURL = monorepoRoot.appending(path: "website/src/lib/adapter-contracts.ts")
        guard let contractsSource = try? String(contentsOf: contractsURL, encoding: .utf8) else {
            throw XCTSkip(
                "No website source at \(contractsURL.path) — the clipboard brief's pin "
                    + "(revision \(pinned)) was NOT verified against the published contract."
            )
        }
        let published = try XCTUnwrap(
            Self.firstCapturedRevision(in: contractsSource, pattern: #"CONTRACT_REVISION = '(\d+\.\d+)'"#),
            "Could not read CONTRACT_REVISION from \(contractsURL.path)."
        )

        XCTAssertEqual(
            pinned, published,
            "The clipboard brief claims alignment to contract revision \(pinned) but the "
                + "published contract is \(published). Re-read the contract's changelog, move "
                + "whatever it requires in `clipboardBrief`, then bump the pin."
        )
    }

    /// First capture group of `pattern` in `text`, or nil.
    private static func firstCapturedRevision(in text: String, pattern: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }
}
