// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsExplainerTests.swift
//
// Coverage for the pure Diagnostics helpers: every AppError code maps to a
// non-empty plain-English cause + fix, the opaque/provider-message codes NEVER
// surface reconstructed provider text (privacy), provider IDs normalize to their
// archetype (no UUID/label leak), and every code has a stable copy-report slug.

import XCTest
@testable import Conduck

final class DiagnosticsExplainerTests: XCTestCase {

    /// Every live AppError code (1–75 minus the reserved 27 gap, plus 99).
    private let allCodes: [Int] = Array(1...75).filter { $0 != 27 } + [99]

    // MARK: - explain(code:)

    func testEveryCodeYieldsNonEmptyCauseAndFix() {
        for code in allCodes {
            let (cause, fix) = DiagnosticsExplainer.explain(code: code)
            XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "code \(code) produced an empty cause")
            XCTAssertFalse(fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "code \(code) produced an empty fix")
        }
    }

    func testConfigFixableCodesGiveSpecificCause() {
        // A representative config-fixable set should describe the actual problem,
        // not collapse to the generic fallback cause.
        let generic = DiagnosticsExplainer.explain(code: 10).cause  // opaque → generic
        for code in [12, 23, 26, 30, 44, 46, 51] {
            let cause = DiagnosticsExplainer.explain(code: code).cause
            XCTAssertNotEqual(cause, generic, "config code \(code) should have a specific cause")
        }
    }

    /// Privacy guard: opaque / provider-message codes must resolve to the generic
    /// cause — reconstructing them with `message: nil` must never surface live
    /// provider text on screen or in the copy block.
    func testOpaqueCodesUseGenericCause() {
        let generic = DiagnosticsExplainer.explain(code: 99).cause
        for code in [1, 6, 7, 9, 10, 25, 99] {
            XCTAssertEqual(DiagnosticsExplainer.explain(code: code).cause, generic,
                           "opaque code \(code) must use the generic cause, not provider text")
        }
    }

    // MARK: - explain(code:context:) — the Diagnostics gateway row

    // The row this section guards is the CONNECTION checklist's per-gateway row,
    // whose detail is `DiagnosticsExplainer.explain(...).fix` (see
    // `DiagnosticsRunner.probeGateway`). It is the highest-visibility rendering
    // of this taxonomy in the app: Diagnostics output is what users paste into
    // support tickets and GitHub issues, so a remedy naming a machine the reader
    // does not run leaves a permanent public record of it.
    //
    // `explain` takes only a code, and a code carries no lane — so before the
    // context parameter existed this row could render nothing but the neutral
    // (self-hosted) wording, and an OpenRouter 404 told a user with no URL field
    // to check the Gateway URL. The rules below are `RemoteAgentRecoveryCopyLaneTests`'
    // rules 2 and 3, re-asserted THROUGH `explain` — that file proves the copy
    // dispatches, this one proves the row actually asks it to.

    /// The gateway-class codes a Connection row can render. Listed by number so a
    /// new gateway verdict has to be added here deliberately.
    private static let gatewayRowCodes: [Int] = [
        12, 19, 26, 28, 29, 31, 52, 55, 56, 57, 58, 59, 60, 62, 71, 72, 73,
    ]

    /// The four lanes, in the shape `RemoteAgentRecoveryCopyLaneTests` uses.
    /// `custom` stands in for the whole heterogeneous `custom_<uuid>` bucket.
    private struct Lane {
        let name: String
        let ref: RemoteAgentRef
        var context: RemoteAgentFailureContext { RemoteAgentFailureContext.resolve(ref) }
    }

    private static let customRef = RemoteAgentRef.custom(
        UUID(uuidString: "6D1C4A0B-77E5-49F2-9A38-2B4C6E8F0A15")!
    )

    private let lanes: [Lane] = [
        Lane(name: "openclaw", ref: .builtin(.openclaw)),
        Lane(name: "hermes", ref: .builtin(.hermes)),
        Lane(name: "openrouter", ref: .builtin(.openrouter)),
        Lane(name: "custom", ref: DiagnosticsExplainerTests.customRef),
    ]

    /// Phrases that are only true when the reader administers the machine at the
    /// other end. Same list as `RemoteAgentRecoveryCopyLaneTests`, on purpose: one
    /// vocabulary, asserted at both the copy layer and the surface that renders it.
    private static let selfHostedOnlyImperatives = [
        "gateway",
        "your server",
        "the gateway url",
        "server's base address",
        "logs",
        "is running",
        "restart",
        "config file",
        "in front of it",
    ]

    /// Instructions to CHANGE the model. The bare noun is deliberately absent —
    /// a row may legitimately say the server chose the model.
    private static let modelChangeImperatives = [
        "pick a different",
        "pick a model",
        "switch to a model",
        "a different model",
        "the model name in settings",
        "set a model",
        "choose a model",
    ]

    func testGatewayRowAnswersOnEveryLane() {
        for code in Self.gatewayRowCodes {
            for lane in lanes {
                let (cause, fix) = DiagnosticsExplainer.explain(code: code, context: lane.context)
                XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "code \(code) produced an empty cause on \(lane.name)")
                XCTAssertFalse(fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "code \(code) produced an empty fix on \(lane.name)")
            }
        }
    }

    /// THE failure this parameter exists for: a lane whose URL the app owns being
    /// told to check its gateway's logs or correct a Gateway URL it has no field
    /// for — printed into a report the user then pastes in public.
    func testHiddenURLLanesNeverGetASelfHostedRemedyOnTheGatewayRow() {
        let hidden = lanes.filter { $0.context.hidesURLField }
        // Non-vacuity: if no lane hides the field, the descriptors or the
        // resolver broke and this rule is hollow.
        XCTAssertFalse(hidden.isEmpty,
                       "No lane reports `hidesURLField` — the resolver or the descriptors broke.")

        for code in Self.gatewayRowCodes {
            for lane in hidden {
                let (cause, fix) = DiagnosticsExplainer.explain(code: code, context: lane.context)
                for phrase in Self.selfHostedOnlyImperatives {
                    XCTAssertFalse(
                        fix.localizedCaseInsensitiveContains(phrase),
                        "code \(code)'s Diagnostics fix says “\(phrase)” on \(lane.name), which runs no server of the reader's. Got: \(fix)"
                    )
                    XCTAssertFalse(
                        cause.localizedCaseInsensitiveContains(phrase),
                        "code \(code)'s Diagnostics cause says “\(phrase)” on \(lane.name), which runs no server of the reader's. Got: \(cause)"
                    )
                }
            }
        }
    }

    /// The rule a hosted-vs-self-hosted flag gets exactly backwards: OpenClaw and
    /// Hermes are SELF-HOSTED and still hide the model field, so a model-change
    /// remedy on their row names a control on no screen.
    func testModelUnsupportedLanesNeverGetAModelChangeRemedyOnTheGatewayRow() {
        let hidden = lanes.filter { !$0.context.userCanChooseModel }
        XCTAssertFalse(hidden.isEmpty,
                       "No lane reports `model == .unsupported` — OpenClaw and Hermes both should.")

        for code in Self.gatewayRowCodes {
            for lane in hidden {
                let fix = DiagnosticsExplainer.explain(code: code, context: lane.context).fix
                for phrase in Self.modelChangeImperatives {
                    XCTAssertFalse(
                        fix.localizedCaseInsensitiveContains(phrase),
                        "code \(code)'s Diagnostics fix says “\(phrase)” on \(lane.name), where Conduck HIDES the model field. Got: \(fix)"
                    )
                }
            }
        }
    }

    /// Proves the context REACHES `AppError` rather than being accepted and
    /// dropped — the exact defect being fixed, which every rule above would still
    /// pass through if `explain` quietly ignored its parameter (the hosted arms
    /// happen to be the ones that avoid the banned phrases).
    func testTheContextActuallyChangesTheGatewayRowCopy() {
        let hosted = RemoteAgentFailureContext.resolve(.builtin(.openrouter))
        // 59 is the leak this rework exists for: "Check the Gateway URL is your
        // server's base address" rendered on a lane with no URL field.
        XCTAssertNotEqual(DiagnosticsExplainer.explain(code: 59, context: hosted).fix,
                          DiagnosticsExplainer.explain(code: 59).fix,
                          "The hosted lane's 404 remedy is identical to the neutral one — `explain` is dropping its context.")
        // 55 is the arm a lane flag inverts: the model remedy must survive on the
        // lane that HAS a model field and vanish on the two that hide it.
        let selfHosted = RemoteAgentFailureContext.resolve(.builtin(.openclaw))
        XCTAssertNotEqual(DiagnosticsExplainer.explain(code: 55, context: hosted).fix,
                          DiagnosticsExplainer.explain(code: 55, context: selfHosted).fix,
                          "55 renders the same fix with and without a model field — the dispatch was removed.")
    }

    /// Back-compat for the ~13 call sites deliberately left unthreaded (the STT,
    /// TTS and file-lane rows, where a gateway ref would name the wrong machine).
    /// The defaulted parameter must behave EXACTLY as the old signature did.
    func testDefaultedContextEqualsTheNeutralWording() {
        for code in allCodes + Self.gatewayRowCodes {
            let defaulted = DiagnosticsExplainer.explain(code: code)
            let neutral = DiagnosticsExplainer.explain(code: code, context: .neutral)
            XCTAssertEqual(defaulted.cause, neutral.cause,
                           "code \(code): the defaulted cause drifted from the neutral context.")
            XCTAssertEqual(defaulted.fix, neutral.fix,
                           "code \(code): the defaulted fix drifted from the neutral context.")
        }
    }

    // MARK: - archetype(forProviderID:)

    func testArchetypeStripsPerUUIDSuffix() {
        XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: "custom-openai_A1B2C3"), "custom-openai")
        XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: "custom-openai-tts_A1B2C3"), "custom-openai-tts")
    }

    func testArchetypePassesThroughBuiltInIDs() {
        for id in ["mistral-voxtral", "apple-on-device", "openrouter-stt", "apple-tts"] {
            XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: id), id,
                           "built-in id \(id) has no UUID suffix and must pass through unchanged")
        }
    }

    // MARK: - slug(forCode:)

    func testEveryCodeHasNonEmptyKebabSlug() {
        for code in allCodes {
            let slug = DiagnosticsExplainer.slug(forCode: code)
            XCTAssertFalse(slug.isEmpty, "code \(code) has an empty slug")
            XCTAssertFalse(slug.contains(" "), "slug for code \(code) should be kebab (no spaces): \(slug)")
        }
    }

    /// The fallback is for codes that do not exist, not for codes nobody got
    /// round to naming. `"code 75 (error-75)"` in a pasted report is a slug that
    /// tells the reader nothing, and it is exactly what a live code with no
    /// table row produces — silently, since the assertion above only checks the
    /// string is non-empty and space-free, which `"error-75"` also is.
    func testNoLiveCodeFallsBackToTheOpaqueSlug() {
        for code in allCodes {
            XCTAssertNotEqual(DiagnosticsExplainer.slug(forCode: code), "error-\(code)",
                              "code \(code) has no row in `codeSlugs`, so the copyable report names it "
                              + "`error-\(code)` — a marker that carries none of the meaning the slug exists "
                              + "to carry.")
        }
    }

    func testUnknownCodeSlugFallsBack() {
        XCTAssertEqual(DiagnosticsExplainer.slug(forCode: 1234), "error-1234")
    }
}
