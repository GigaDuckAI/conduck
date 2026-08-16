// SPDX-License-Identifier: Apache-2.0

// Conduck
// PersonalAIVocabularyTests.swift
//
// LOCKS THE TWO WORDS lane-agnostic running copy may not use.
//
//   "gateway" — Conduck's sense of the word (a stateful always-on machine that
//     runs an agent and owns tools and a filesystem) is close to the OPPOSITE
//     of the industry's ("AI gateway" / "LLM gateway" is an established product
//     category meaning a ROUTING PROXY in front of providers — LiteLLM, Portkey,
//     Cloudflare AI Gateway, and OpenRouter itself). It is RETAINED, correctly,
//     on the self-hosted setup and troubleshooting screens, where it matches the
//     `openclaw.json` keys the user hand-edits (`gateway.auth.token`,
//     `gateway.port`). It must not appear in a string that also reaches a user
//     who runs no server.
//
//   "personal AI" — the adjective asserts ownership and privacy that OpenRouter,
//     a shared third-party routing service, cannot back, in a product whose whole
//     proposition is privacy. It survives as the Settings SECTION NAME, which is
//     a navigation landmark two external contracts point at (the App Review notes
//     and `conduck-connect`'s `src/80-pairing.inc.sh`), and nowhere else.
//
// These are RUNTIME assertions on the shipped strings, deliberately not a source
// scan: the defect is the string a user reads, and a catalogued English value
// beats the `defaultValue:` in source, so scanning source would check the wrong
// artifact.
//
// SCOPE — both halves of the copy, not just the remedy. `errorDescription(in:)`
// and `recoverySuggestion(in:)` dispatch on the same capability snapshot, and the
// sweep below covers EVERY gateway-class cause rather than the handful that
// happened to be lane-agnostic already. That widening is the point: a rule scoped
// to the strings someone had just fixed can only ever confirm itself, and the
// codes it left out were precisely the ones still naming a gateway. The
// per-lane REMEDY rules, plus the assertion that a cause and its remedy resolve
// in one context, live in `RemoteAgentRecoveryCopyLaneTests`.

import XCTest
@testable import Conduck

final class PersonalAIVocabularyTests: XCTestCase {

    /// The `AppError` CAUSES that ship ONE sentence to all four lanes — no
    /// capability branch at all, because none of them has a lane-sensitive word
    /// to branch on. Every one is rendered verbatim on surfaces that hold no ref
    /// (a notification body, a Watch banner, a spoken CarPlay line), so they name
    /// the CLASS and nothing narrower.
    private static let laneAgnosticCauses: [AppError] = [
        .remoteAgentNotConfigured,
        .remoteAgentUnreachable,
        .remoteAgentAuthFailed,
        .remoteAgentTimeout,
        .remoteAgentServerError,
        .remoteAgentInvalidResponse
    ]

    /// EVERY gateway-class cause, not just the undispatched six.
    ///
    /// Restricting the sweep to the six was the hole this list closes: the codes
    /// left out were exactly the ones still saying "your gateway" — an unmapped
    /// status, a connection that never opened, an oversized image, the four route
    /// verdicts and the photo refusal — so the guard passed while nine strings
    /// asserted a machine a hosted-lane reader does not run. A rule whose scope is
    /// the set already known to be clean can only ever confirm itself.
    ///
    /// The list is by CODE so a new gateway verdict has to be added deliberately;
    /// `testEveryGatewayCauseIsAccountedFor` fails if one is minted and forgotten.
    private static let everyGatewayCause: [AppError] = [
        .remoteAgentNotConfigured,                  // 12
        .remoteAgentUnreachable,                    // 19
        .remoteAgentAuthFailed,                     // 26
        .remoteAgentTimeout,                        // 28
        .remoteAgentServerError,                    // 29
        .remoteAgentInvalidResponse,                // 31
        .remoteAgentVisionUnsupported,              // 32
        .remoteAgentImageTooLarge,                  // 33
        .remoteAgentOutOfCredits,                   // 52
        .remoteAgentModelUnavailable,               // 55
        .remoteAgentContextTooLong,                 // 56
        .remoteAgentRateLimited,                    // 57
        .remoteAgentEndpointUnexpectedResponse,     // 58
        .remoteAgentEndpointNotFound,               // 59
        .remoteAgentModelRequired,                  // 60
        .remoteAgentEndpointWrongEnvelope,          // 62
        .remoteAgentUnexpectedStatus(status: 418),  // 71 — the numbered variant
        .remoteAgentUnexpectedStatus(status: nil),  // 71 — the reconstructed one
        .remoteAgentServiceUnavailable,             // 72
        .remoteAgentNotEstablished,                 // 73
    ]

    /// The three CERTIFICATE verdicts, held out of the sweep above and locked by
    /// a different rule below.
    ///
    /// Their cause and remedy are a matched PAIR governed by `CertificateTrustCopy`:
    /// one cause must not ship four remedies, so all four transport lanes render
    /// the same server-side instruction verbatim. Dispatching the cause alone
    /// would produce exactly the split this whole file exists to prevent — a
    /// hosted-shaped cause in front of a self-hosted remedy — and dispatching
    /// both is a decision about the certificate taxonomy, not about vocabulary.
    ///
    /// Reachability, stated so the exemption is not mistaken for a clean bill:
    /// 30 and 67 both require a saved pin, and the hosted lane is
    /// `.systemTrustOnly` and never pins, so neither can arrive there. 63 CAN —
    /// an intercepting corporate middlebox is a live route to it — and its copy
    /// says "your gateway's certificate" on a lane with no gateway. That is a
    /// known, deliberate scope line, matching `RemoteAgentRecoveryCopyLaneTests`.
    private static let certificateCauses: [AppError] = [
        .remoteAgentCertMismatch,       // 30
        .remoteAgentCertUntrusted,      // 63
        .remoteAgentCertKeyUnpinnable,  // 67
    ]

    /// The lanes whose reader operates no server, resolved from the same
    /// capability snapshot the copy layer dispatches on.
    private static let hiddenURLContexts: [(name: String, context: RemoteAgentFailureContext)] = [
        ("openrouter", RemoteAgentFailureContext.resolve(.builtin(.openrouter)))
    ]

    func testLaneAgnosticCausesNameNeitherAGatewayNorAPersonalAI() throws {
        for error in Self.laneAgnosticCauses {
            let cause = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(cause.isEmpty, "Code \(error.errorCode) must still say something.")
            XCTAssertFalse(cause.localizedCaseInsensitiveContains("gateway"),
                           "Code \(error.errorCode) reaches a user who runs no server: \(cause)")
            XCTAssertFalse(cause.localizedCaseInsensitiveContains("personal AI"),
                           "Code \(error.errorCode) claims a privacy posture the hosted lane can't back: \(cause)")
        }
    }

    /// Non-vacuity for the rule above: these strings DO name the class, so a
    /// future rewrite that empties them out cannot pass by saying nothing.
    func testLaneAgnosticCausesStillNameTheClass() throws {
        for error in Self.laneAgnosticCauses {
            let cause = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(cause.contains("AI"),
                          "Code \(error.errorCode) must still name what failed: \(cause)")
        }
    }

    // MARK: - The widened rule: no cause names a server the reader does not run

    /// The whole gateway family, on the lane where the word is provably false.
    func testNoGatewayCauseAssertsAGatewayOnAHiddenURLLane() throws {
        // Non-vacuity: the rule is hollow if no lane actually hides the field,
        // which is exactly what a mis-edited descriptor would produce.
        XCTAssertFalse(Self.hiddenURLContexts.isEmpty)
        for (name, context) in Self.hiddenURLContexts {
            XCTAssertTrue(context.hidesURLField,
                          "\(name) stopped reporting `hidesURLField` — this rule is now hollow.")
        }

        for error in Self.everyGatewayCause {
            for (name, context) in Self.hiddenURLContexts {
                let cause = try XCTUnwrap(
                    error.errorDescription(in: context),
                    "Code \(error.errorCode) returned no cause on \(name)."
                )
                XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "Code \(error.errorCode) must still say something on \(name).")
                XCTAssertFalse(
                    cause.localizedCaseInsensitiveContains("gateway"),
                    """
                    Code \(error.errorCode) says “gateway” on \(name), a lane whose URL the app \
                    owns. The reader stood up no server, so the sentence names a machine that \
                    does not exist — and on six of these codes the REMEDY beside it already says \
                    the failure came from the provider. Got: \(cause)
                    """
                )
                XCTAssertFalse(
                    cause.localizedCaseInsensitiveContains("personal AI"),
                    "Code \(error.errorCode) claims a privacy posture \(name) can't back: \(cause)"
                )
            }
        }
    }

    /// The certificate exemption is a DECISION, not a gap that grew. Both halves
    /// of those three verdicts are lane-INVARIANT: identical on every lane. If a
    /// future edit dispatches one half, this fails and the exemption above has to
    /// be re-argued rather than silently inherited.
    func testCertificateCausesAndRemediesAreDeliberatelyLaneInvariant() throws {
        let lanes: [(String, RemoteAgentFailureContext)] = [
            ("openclaw", RemoteAgentFailureContext.resolve(.builtin(.openclaw))),
            ("hermes", RemoteAgentFailureContext.resolve(.builtin(.hermes))),
            ("openrouter", RemoteAgentFailureContext.resolve(.builtin(.openrouter))),
            ("custom", RemoteAgentFailureContext.custom),
        ]
        for error in Self.certificateCauses {
            let cause = try XCTUnwrap(error.errorDescription(in: .neutral))
            let remedy = try XCTUnwrap(error.recoverySuggestion(in: .neutral))
            for (name, context) in lanes {
                XCTAssertEqual(error.errorDescription(in: context), cause,
                               "Code \(error.errorCode)'s cause diverged on \(name); the certificate taxonomy ships one wording per cause.")
                XCTAssertEqual(error.recoverySuggestion(in: context), remedy,
                               "Code \(error.errorCode)'s remedy diverged on \(name); one cause must not ship four remedies.")
            }
        }
    }

    /// Every gateway-class code is either swept or explicitly exempt. Without
    /// this, a newly-minted verdict joins the enum, says "your gateway", and no
    /// rule in this file ever looks at it.
    func testEveryGatewayCauseIsAccountedFor() {
        let covered = Set((Self.everyGatewayCause + Self.certificateCauses).map { $0.errorCode })
        // The gateway-class numeric slots, from `AppError`'s own taxonomy comments.
        let gatewayCodes: Set<Int> = [12, 19, 26, 28, 29, 30, 31, 32, 33, 52,
                                      55, 56, 57, 58, 59, 60, 62, 63, 67, 71, 72, 73]
        XCTAssertEqual(
            gatewayCodes.subtracting(covered), [],
            "A gateway verdict exists that neither the sweep nor the certificate exemption names."
        )
        XCTAssertEqual(
            covered.subtracting(gatewayCodes), [],
            "A code listed here is no longer a gateway verdict — stale rows make the sweep look wider than it is."
        )
    }

    // MARK: - The Personal AI list's capability axis

    /// The three section headers state a FACT about the lane instead of asking
    /// the reader to file their own software under a category ("Full agent
    /// gateways" / "Hosted model" / "Custom gateways" set "model" and "gateway"
    /// beside each other as sibling names for one kind of thing).
    func testSectionHeadersAreCapabilityLinesNotCategories() {
        let headers = [
            String(localized: GatewayGroupCopy.fullAgentHeader),
            String(localized: GatewayGroupCopy.hostedModelHeader),
            String(localized: GatewayGroupCopy.customHeader)
        ]
        XCTAssertEqual(Set(headers).count, 3, "The three headers must stay distinct.")
        for header in headers {
            XCTAssertFalse(header.isEmpty)
            XCTAssertFalse(header.localizedCaseInsensitiveContains("gateway"),
                           "A picker header is read BEFORE the user has chosen a lane: \(header)")
        }
    }

    /// The per-row line runs on the same axis as `RemoteAgentFailureContext`,
    /// which is what the error layer dispatches recovery copy on — so the picker
    /// and the failure message cannot disagree about what a lane is. Three
    /// buckets, three distinct answers.
    func testRowCapabilitySubtitlesDifferPerLaneAndNameNoGateway() {
        let subtitles = [
            RemoteAgentRef.builtin(.openclaw),
            RemoteAgentRef.builtin(.openrouter),
            RemoteAgentRef.custom(UUID())
        ].map { String(localized: GatewayGroupCopy.capabilitySubtitle(for: $0)) }

        XCTAssertEqual(Set(subtitles).count, 3,
                       "A subtitle that collapses across lanes tells the user nothing: \(subtitles)")
        for subtitle in subtitles {
            XCTAssertFalse(subtitle.isEmpty)
            XCTAssertFalse(subtitle.localizedCaseInsensitiveContains("gateway"),
                           "Row subtitles render above the hosted lane too: \(subtitle)")
        }

        // Hermes is the openclaw twin — same capability snapshot, so the same
        // line. This is the assertion that fails if a future descriptor edit
        // moves one of them off the self-hosted profile without moving the copy.
        XCTAssertEqual(String(localized: GatewayGroupCopy.capabilitySubtitle(for: .builtin(.hermes))),
                       subtitles[0])
    }
}
