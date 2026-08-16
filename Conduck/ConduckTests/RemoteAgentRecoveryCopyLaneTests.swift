// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentRecoveryCopyLaneTests.swift
//
// Locks the CAPABILITY DISPATCH in `AppError.errorDescription(in:)` and
// `AppError.recoverySuggestion(in:)` against all four lanes at once: the two
// self-hosted built-ins, the hosted-model lane, and a custom ref — and locks the
// two halves to ONE context, which is a separate property from either being
// right on its own.
//
// Why this file exists rather than a code comment. The defect it guards is not
// a crash and not a wrong value — it is a sentence that is TRUE on the lane its
// author had in mind and FALSE on the three they did not. Nothing fails, the
// suite stays green, and a user who runs no server is told to read their
// server's logs. That decays back in silently and fast: the website's own
// declared vocabulary rule was violated ~40 times inside the single file that
// declared it. The only durable defence is an executable one.
//
// The rules asserted, and why each is the right question:
//
//   1. NON-EMPTY on every lane. A capability branch that forgets an arm returns
//      nil and the single-line surfaces render the cause with no way out.
//
//   2. NO SELF-HOSTED IMPERATIVE where `hidesURLField`. That flag means the app
//      owns the endpoint, so the reader stood up no server, cannot restart one,
//      cannot read its logs, and has no URL field to correct. Any remedy naming
//      those is describing a machine that does not exist.
//
//   3. NO MODEL-CHANGE IMPERATIVE where `RemoteAgentModelPolicy == .unsupported`.
//      OpenClaw and Hermes choose the model server-side and Conduck HIDES the
//      field, so "pick a different model" names a control that is on no screen.
//      This is the rule a hosted-vs-self-hosted flag gets exactly backwards —
//      codes 55 and 56 are correct for the HOSTED lane and wrong for the two
//      self-hosted ones — which is why the dispatch is on capability.
//
//   3b. THE CAUSE ANSWERS FOR THE SAME LANE AS THE REMEDY. Rules 1-3 look only
//      at the remedy, and a sweep that parameterises one half and forgets the
//      other passes all three while shipping a banner that argues with itself:
//      "Your gateway answered with HTTP 418 … That came from the provider or the
//      network between you." Both halves are individually defensible; together
//      they name two different machines. So the cause is held to the same
//      phrase rules, and `descriptionWithRecovery(in:)` is asserted to be an
//      exact join of the two halves of ONE context.
//
//   4. PARITY with `RemoteAgentBackendRegistry`. `RemoteAgentFailureContext`
//      resolves without the descriptor registry because `AppError` compiles into
//      the Watch target and the registry does not. That duplication is only safe
//      while it is checked, so every field is compared descriptor-by-descriptor.
//
// Scope is the EXPLICIT code list below — the arms this rework rewrote. It is
// deliberately not "every case in the enum": the certificate families ship one
// shared server-side remedy across all four transport lanes on purpose (one
// cause must not ship four remedies), and sweeping them in here would demand a
// hosted paraphrase the taxonomy has decided against. Adding a lane-dispatched
// arm means adding its code here.

import XCTest
@testable import Conduck

final class RemoteAgentRecoveryCopyLaneTests: XCTestCase {

    // MARK: - The four lanes

    /// The lanes every gateway-class remedy must survive. `custom` stands in for
    /// the whole `custom_<uuid>` bucket, which is HETEROGENEOUS by construction
    /// (Ollama, LiteLLM, vLLM, a home-built adapter), so no copy reaching it may
    /// assume more than "the user typed this address".
    private struct Lane {
        let name: String
        let ref: RemoteAgentRef
        var context: RemoteAgentFailureContext { RemoteAgentFailureContext.resolve(ref) }
    }

    private static let customRef = RemoteAgentRef.custom(
        UUID(uuidString: "0F5B7C9E-2A41-4D6B-9C31-8E7A5D0B1234")!
    )

    private let lanes: [Lane] = [
        Lane(name: "openclaw", ref: .builtin(.openclaw)),
        Lane(name: "hermes", ref: .builtin(.hermes)),
        Lane(name: "openrouter", ref: .builtin(.openrouter)),
        Lane(name: "custom", ref: RemoteAgentRecoveryCopyLaneTests.customRef),
    ]

    /// The arms this rework rewrote to dispatch on capability. Every one of them
    /// shipped self-hosted-only copy to every lane before.
    private let dispatchedErrors: [AppError] = [
        .remoteAgentNotConfigured,          // 12
        .remoteAgentUnreachable,            // 19
        .remoteAgentAuthFailed,             // 26
        .remoteAgentTimeout,                // 28
        .remoteAgentServerError,            // 29
        .remoteAgentInvalidResponse,        // 31
        .remoteAgentVisionUnsupported,      // 32
        .remoteAgentImageTooLarge,          // 33
        .remoteAgentOutOfCredits,           // 52
        .remoteAgentModelUnavailable,       // 55
        .remoteAgentContextTooLong,         // 56
        .remoteAgentRateLimited,            // 57
        .remoteAgentEndpointUnexpectedResponse, // 58
        .remoteAgentEndpointNotFound,       // 59
        .remoteAgentModelRequired,          // 60
        .remoteAgentEndpointWrongEnvelope,  // 62
        .remoteAgentUnexpectedStatus(status: 418), // 71
        .remoteAgentServiceUnavailable,     // 72
        .remoteAgentNotEstablished,         // 73
    ]

    // MARK: - Rule 1: every lane gets a remedy at all

    func testEveryDispatchedArmAnswersOnEveryLane() {
        for error in dispatchedErrors {
            for lane in lanes {
                let remedy = error.recoverySuggestion(in: lane.context)
                XCTAssertNotNil(
                    remedy,
                    "Code \(error.errorCode) returned nil on \(lane.name) — the single-line surfaces then render the cause with no way out."
                )
                XCTAssertFalse(
                    (remedy ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Code \(error.errorCode) returned empty copy on \(lane.name)."
                )
            }
        }
    }

    // MARK: - Rule 2: no server the reader does not have

    /// Phrases that are only true when the reader administers the machine at the
    /// other end. Matched case-insensitively as substrings, so a reworded arm
    /// that keeps the idea keeps tripping the rule.
    ///
    /// "your server", not the bare word "server": a hosted arm is allowed to say
    /// the provider's servers had a problem, which is a statement of fact rather
    /// than an instruction to go fix one.
    private static let selfHostedOnlyImperatives = [
        "gateway",
        "your server",
        "your own server",
        "the gateway url",
        "server's base address",
        "logs",
        "is running",
        "restart",
        "config file",
        "in front of it",
    ]

    func testHiddenURLLanesNeverGetASelfHostedImperative() {
        let hidden = lanes.filter { $0.context.hidesURLField }
        // Non-vacuity: the whole rule is worthless if no lane actually hides the
        // field, which is exactly what a mis-edited descriptor would produce.
        XCTAssertFalse(hidden.isEmpty,
                       "No lane reports `hidesURLField` — the resolver or the descriptor broke, and this rule is now hollow.")

        for error in dispatchedErrors {
            for lane in hidden {
                let remedy = error.recoverySuggestion(in: lane.context) ?? ""
                for phrase in Self.selfHostedOnlyImperatives {
                    XCTAssertFalse(
                        remedy.localizedCaseInsensitiveContains(phrase),
                        """
                        Code \(error.errorCode) says “\(phrase)” on \(lane.name), a lane whose URL the app owns. \
                        The reader operates no server, so this describes a machine that does not exist. Got: \(remedy)
                        """
                    )
                }
            }
        }
    }

    // MARK: - Rule 3: no model field where there is no model field

    /// Instructions to CHANGE the model. The bare word "model" is deliberately
    /// absent: an arm may legitimately state that the server chose the model, and
    /// banning the noun would force a paraphrase that says less.
    private static let modelChangeImperatives = [
        "pick a different",
        "pick a model",
        "switch to a model",
        "a different model",
        "the model name in settings",
        "set a model",
        "choose a model",
        "a model that accepts",
    ]

    func testModelUnsupportedLanesNeverGetAModelChangeImperative() {
        let hidden = lanes.filter { !$0.context.userCanChooseModel }
        XCTAssertFalse(hidden.isEmpty,
                       "No lane reports `model == .unsupported` — OpenClaw and Hermes both should, and this rule is now hollow.")

        for error in dispatchedErrors {
            for lane in hidden {
                let remedy = error.recoverySuggestion(in: lane.context) ?? ""
                for phrase in Self.modelChangeImperatives {
                    XCTAssertFalse(
                        remedy.localizedCaseInsensitiveContains(phrase),
                        """
                        Code \(error.errorCode) says “\(phrase)” on \(lane.name), where Conduck HIDES the model field \
                        (`model == .unsupported`). The instruction names a control on no screen. Got: \(remedy)
                        """
                    )
                }
            }
        }
    }

    // MARK: - The two arms a lane flag gets backwards

    /// 55 and 56 are the reason the dispatch is on capability rather than on
    /// hosted-vs-self-hosted. Both are CORRECT for OpenRouter — it requires an
    /// explicit model and shows the field — and WRONG for OpenClaw and Hermes.
    /// A lane flag would have inverted exactly these two.
    func testModelArmsFollowTheModelPolicyNotTheLane() throws {
        let hosted = RemoteAgentFailureContext.resolve(.builtin(.openrouter))
        let selfHosted = RemoteAgentFailureContext.resolve(.builtin(.openclaw))

        let hostedModelUnavailable = try XCTUnwrap(AppError.remoteAgentModelUnavailable.recoverySuggestion(in: hosted))
        XCTAssertTrue(hostedModelUnavailable.localizedCaseInsensitiveContains("model"),
                      "OpenRouter shows a model field — 55 must point at it. Got: \(hostedModelUnavailable)")

        let selfHostedContextTooLong = try XCTUnwrap(AppError.remoteAgentContextTooLong.recoverySuggestion(in: selfHosted))
        XCTAssertFalse(selfHostedContextTooLong.localizedCaseInsensitiveContains("bigger context window"),
                       "OpenClaw hides the model field — offering a bigger-context model is a dead end. Got: \(selfHostedContextTooLong)")

        // …and the two arms must not have collapsed into one shared sentence,
        // which is how a "fix" that deletes the dispatch would still pass rules
        // 1-3 above.
        let selfHostedModelUnavailable = try XCTUnwrap(AppError.remoteAgentModelUnavailable.recoverySuggestion(in: selfHosted))
        XCTAssertNotEqual(hostedModelUnavailable, selfHostedModelUnavailable,
                          "55 must still differ by model policy — an identical string means the dispatch was removed.")
    }

    // MARK: - Rule 4: the Watch-side resolver still matches the descriptors

    /// `RemoteAgentFailureContext` maps built-ins itself instead of calling the
    /// registry, because `AppError` compiles into the Watch target where
    /// `RemoteAgentBackendMetadata.swift` is not a member. That is a duplication,
    /// and duplication is only safe while something checks it.
    func testFailureContextMatchesTheBackendDescriptors() {
        for descriptor in RemoteAgentBackendRegistry.allKnown {
            let context = descriptor.id.failureContext
            XCTAssertEqual(context.category, descriptor.category,
                           "\(descriptor.id.rawValue): category drifted from its descriptor.")
            XCTAssertEqual(context.model, descriptor.model,
                           "\(descriptor.id.rawValue): model policy drifted from its descriptor.")
            XCTAssertEqual(context.hidesURLField, descriptor.hidesURLField,
                           "\(descriptor.id.rawValue): hidesURLField drifted from its descriptor.")
            XCTAssertEqual(context.fileTransferSupported, descriptor.fileTransferSupported,
                           "\(descriptor.id.rawValue): fileTransferSupported drifted from its descriptor.")
        }
    }

    // MARK: - The neutral context is still today's copy

    /// A call site with genuinely no ref must degrade to the wording that shipped
    /// before capability dispatch existed — not to something new and untested.
    /// `recoverySuggestion` (the `LocalizedError` property) IS that path, and
    /// Shortcuts + `errorUserInfo` read it.
    func testNeutralContextEqualsTheParameterlessProperty() {
        for error in dispatchedErrors {
            XCTAssertEqual(error.recoverySuggestion,
                           error.recoverySuggestion(in: .neutral),
                           "Code \(error.errorCode): the protocol property must answer for the neutral context.")
            XCTAssertEqual(error.descriptionWithRecovery(),
                           error.descriptionWithRecovery(in: .neutral),
                           "Code \(error.errorCode): the no-ref rendering must answer for the neutral context.")
        }
    }

    /// A `nil` ref resolves to neutral; a ref resolves to its own lane. The
    /// optional parameter exists for call sites with no gateway in hand (the STT
    /// lane, a file-server verdict), never as an invitation to skip threading one.
    func testNilRefResolvesToNeutralAndARefDoesNot() {
        XCTAssertEqual(RemoteAgentFailureContext.resolve(nil), .neutral)
        XCTAssertNotEqual(RemoteAgentFailureContext.resolve(.builtin(.openrouter)), .neutral)
        // A custom is not the hosted lane, however heterogeneous its contents:
        // the user typed the address, which is the fact every "check the address"
        // remedy needs.
        XCTAssertFalse(RemoteAgentFailureContext.resolve(Self.customRef).hidesURLField)
        XCTAssertTrue(RemoteAgentFailureContext.resolve(Self.customRef).userCanChooseModel)
    }

    // MARK: - The single-line surfaces carry the dispatched half

    /// `descriptionWithRecovery(for:)` is what the Watch banner, the notification
    /// body and the composers render. If it dropped the context, every rule above
    /// would still pass while the shipping string stayed wrong.
    func testDescriptionWithRecoveryCarriesTheLaneRemedy() throws {
        let hostedRef = RemoteAgentRef.builtin(.openrouter)
        let rendered = AppError.remoteAgentEndpointNotFound.descriptionWithRecovery(for: hostedRef)
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("Gateway URL"),
                       "59 rendered the self-hosted URL remedy on a lane with no URL field. Got: \(rendered)")
        let remedy = try XCTUnwrap(AppError.remoteAgentEndpointNotFound.recoverySuggestion(for: hostedRef))
        XCTAssertTrue(rendered.hasSuffix(remedy),
                      "The single-line form must end in the lane's own remedy. Got: \(rendered)")
    }

    // MARK: - Rule 5: the cause and the remedy answer for the SAME lane

    /// The defect this rule exists for is not a wrong string — it is two right
    /// strings resolved INDEPENDENTLY. `descriptionWithRecovery` read the cause
    /// off the parameterless property while passing the context to the remedy, so
    /// a hosted-lane reader who hit an unmapped status got:
    ///
    ///     "Your gateway answered with HTTP 418, which Conduck doesn't recognise.
    ///      That came from the provider or the network between you. Try again."
    ///
    /// Cause names a gateway, remedy names a provider, in one banner. Every
    /// per-lane rule above passed the whole time, because every rule above only
    /// ever looked at the remedy.
    ///
    /// Asserting the exact join is what closes it: the rendered string must be the
    /// two halves of ONE context, so a future call site cannot reintroduce the
    /// split by reaching for a property instead of a method.
    func testCauseAndRemedyAreResolvedInTheSameContext() throws {
        for error in dispatchedErrors {
            for lane in lanes {
                let cause = try XCTUnwrap(
                    error.errorDescription(in: lane.context),
                    "Code \(error.errorCode) has no cause on \(lane.name)."
                )
                let remedy = try XCTUnwrap(
                    error.recoverySuggestion(in: lane.context),
                    "Code \(error.errorCode) has no remedy on \(lane.name)."
                )
                XCTAssertEqual(
                    error.descriptionWithRecovery(in: lane.context),
                    "\(cause) \(remedy)",
                    """
                    Code \(error.errorCode) on \(lane.name) renders a cause and a remedy that were \
                    not resolved together. That is how a banner ends up naming a gateway in one \
                    sentence and a provider in the next.
                    """
                )
            }
        }
    }

    /// Rule 2's phrase list, applied to the CAUSE half. Same question, same
    /// answer: a lane whose URL the app owns has no server for the sentence to
    /// name, whichever half of the copy the sentence sits in.
    func testHiddenURLLanesNeverGetASelfHostedCause() throws {
        let hidden = lanes.filter { $0.context.hidesURLField }
        XCTAssertFalse(hidden.isEmpty,
                       "No lane reports `hidesURLField` — the resolver or the descriptor broke, and this rule is now hollow.")

        for error in dispatchedErrors {
            for lane in hidden {
                let cause = try XCTUnwrap(error.errorDescription(in: lane.context))
                for phrase in Self.selfHostedOnlyImperatives {
                    XCTAssertFalse(
                        cause.localizedCaseInsensitiveContains(phrase),
                        """
                        Code \(error.errorCode)'s CAUSE says “\(phrase)” on \(lane.name), a lane whose \
                        URL the app owns. Got: \(cause)
                        """
                    )
                }
            }
        }
    }

    // MARK: - Watch length ceiling

    /// The character count each code's copy shipped at BEFORE capability
    /// dispatch — the ceiling every lane's arm must stay under.
    ///
    /// MEASURED constraint, not a style rule. The Watch in-thread error banner
    /// holds roughly 38 characters over two lines, and three certificate
    /// verdicts at 101/124/129 characters already clip inside it. Most codes
    /// here are wrist-reachable through `RemoteAgentStatusMap.unified` or the
    /// body-aware classifier, so splitting one arm into several must not be a
    /// back door for LONGER copy on any of them — a lane whose remedy grew is a
    /// lane whose remedy now truncates.
    ///
    /// A number only ever goes DOWN. Raising one is not a fix for a failing
    /// assertion; it is the assertion doing its job.
    private static let priorCopyLength: [Int: Int] = [
        12: 59,
        19: 161,
        26: 150,
        28: 135,
        29: 39,
        31: 80,
        32: 65,
        33: 108,
        52: 47,
        55: 58,
        56: 68,
        57: 68,
        58: 145,
        59: 75,
        60: 65,
        62: 108,
        71: 89,
        72: 102,
        73: 104,
    ]

    func testNoLaneCopyGrewPastWhatTheWristAlreadyTruncates() throws {
        for error in dispatchedErrors {
            let ceiling = try XCTUnwrap(
                Self.priorCopyLength[error.errorCode],
                "Code \(error.errorCode) joined the dispatched set with no length ceiling recorded."
            )
            for lane in lanes {
                let remedy = error.recoverySuggestion(in: lane.context) ?? ""
                XCTAssertLessThanOrEqual(
                    remedy.count, ceiling,
                    """
                    Code \(error.errorCode) on \(lane.name) is \(remedy.count) characters against a ceiling of \(ceiling). \
                    The wrist banner truncates at roughly 38 characters over two lines, so growth here silently cuts \
                    the actionable half off the end. Got: \(remedy)
                    """
                )
            }
        }
    }

    /// The same ceiling for the CAUSE half, expressed against the neutral wording
    /// rather than a recorded table — the cause is what a notification TITLE and
    /// the wrist banner's first line carry, and the neutral string is what every
    /// lane's arm is a variation on.
    ///
    /// The direction is deliberate and one-way: splitting an arm per lane is a
    /// licence to say something MORE TRUE, never something longer. A lane whose
    /// cause grew is a lane whose banner now truncates, and on the wrist what
    /// falls off the end is the tail — the part that says what to do.
    func testNoLaneCauseGrewPastTheNeutralWording() throws {
        for error in dispatchedErrors {
            let neutral = try XCTUnwrap(error.errorDescription(in: .neutral))
            for lane in lanes {
                let cause = try XCTUnwrap(error.errorDescription(in: lane.context))
                XCTAssertLessThanOrEqual(
                    cause.count, neutral.count,
                    """
                    Code \(error.errorCode)'s cause on \(lane.name) is \(cause.count) characters against \
                    the neutral wording's \(neutral.count). Got: \(cause)
                    """
                )
            }
        }
    }
}
