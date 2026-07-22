// Conduck
// GatewayAdapterBriefTests.swift
//
// Content lock for the "Conduck adapter v1" brief the custom-lane escape hatch
// copies to the clipboard (`GatewayAdapterBriefView.clipboardBrief`). The brief
// is pointer-first (it delegates to the hosted build brief, narrowed to stop
// before exposure/pairing — the app owns those) with a self-contained fallback
// aligned to contract revision 1.3, so its load-bearing points must not silently
// drift: the two raw `.md` URLs, the workflow-ownership boundary, the wire shape,
// the 1.3 image rules (verbatim historical disclosure, never-reject-historical),
// the frozen error-code vocabulary, the 285s cap, the 50 MiB body floor,
// loopback-only bind, and bearer auth. It also guards the security-critical
// NEGATIVES: never a wildcard bind, never the pairing command, and never the
// pre-1.3 image rule that permitted rejecting on historical images.

import XCTest
@testable import Conduck

final class GatewayAdapterBriefTests: XCTestCase {

    /// The brief must carry every load-bearing contract point verbatim.
    func testBriefContainsContractInvariants() {
        let brief = GatewayAdapterBriefView.clipboardBrief
        let required = [
            // Pointers + workflow ownership (the app owns exposure/pairing)
            "https://conduck.com/setup/adapter/build.md", // hosted build brief
            "https://conduck.com/setup/adapter/v1.md",    // full contract mirror
            "steps 1-9",                                   // narrowed scope
            "STOP before step 10",                         // stop before expose/pair
            "supervisor",                                  // always-on install stays in scope
            "conduck-connect",                             // doctor + later pairing tool

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

            // Error-code vocabulary (all seven frozen codes)
            "model_not_found",
            "context_too_long",
            "image_too_large",
            "overloaded",
            "upstream_timeout",
            "upstream_failure",
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

    /// Workflow-ownership negative: exposure/pairing belongs to the user via the
    /// app's guided flow — the brief must never hand the AI the pairing command.
    func testBriefNeverRunsPairing() {
        XCTAssertFalse(
            GatewayAdapterBriefView.clipboardBrief.contains("--generic"),
            "clipboardBrief must not contain the conduck-connect pairing command"
        )
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
}
