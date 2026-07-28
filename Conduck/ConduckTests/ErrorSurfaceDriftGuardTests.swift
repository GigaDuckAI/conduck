// SPDX-License-Identifier: Apache-2.0

// Conduck
// ErrorSurfaceDriftGuardTests.swift
//
// SOURCE DRIFT GUARD for the two halves of an `AppError` as the user meets it:
// the CAUSE (`errorDescription`) and the REMEDY (`recoverySuggestion`), and the
// question of whether a failure may be retried at all (`isRetryable`).
//
// Why a guard and not review: five consecutive review rounds found the SAME
// defect in a surface nobody had enumerated — a view rendered `errorDescription`
// alone, or drew a Retry control without asking `isRetryable`. Each round fixed
// the instances it found; nothing stopped the next one. Both mistakes compile,
// both read as ordinary error plumbing in a diff, and neither breaks a runtime
// test — no test can see a view that forgot to CALL something. That is what
// makes this a source-scanning problem: the property is about how the code is
// WRITTEN.
//
// What is actually lost when the remedy half is dropped, which is why this is a
// security guard and not a copy guard:
//
//   • pin mismatch (codes 30/35/43/47) — the sentence "the connection may be
//     intercepted" lives ENTIRELY in `recoverySuggestion`. Rendering the cause
//     alone turns the app's one interception warning into a bland "doesn't match
//     the fingerprint you pinned", which reads as a configuration nit.
//   • untrusted chain (63-66) — the cause names no fix. The three free routes to
//     a publicly trusted certificate are all in the remedy, so the cause alone
//     is a dead end.
//   • pin not computable (67-70) — the remedy carries "the certificate itself is
//     fine and this device trusts it". Without it the user hunts a server fault
//     that does not exist.
//
// All three are TERMINAL (`isRetryable == false`), which is the other half of
// this file: a Retry control on any of them re-fires into the identical refusal,
// and its spinner buries the one sentence the user needed to read.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS GUARD CHECKS (on comment-stripped, release-only source)
//
//   Rule 1 — no shipping site renders an `AppError`'s CAUSE alone.
//     Flags a read of `.errorDescription` (or `.localizedDescription` on a value
//     whose text names an `AppError` CARRIER) on a DYNAMIC error value. The fix is
//     `descriptionWithRecovery`, which exists for exactly this and drops the
//     generic "Try again." rather than appending it — so a terminal refusal
//     never gains a retry invitation it cannot honour.
//
//   Rule 2 — no SwiftUI view draws a Retry control without a gate.
//     Every SwiftUI/`Views/` FILE drawing a control whose literal label is
//     "Retry" / "Try again" must appear in `retrySurfaces`, and for a `.gated`
//     entry each DECLARATION drawing one must name the gate. Unclassified files,
//     ungated declarations, a cross-file gate whose decision file stopped
//     READING `isRetryable`, and stale rows all fail — so the registry cannot
//     rot into a checklist.
//     Its reach is narrower than the registry's name suggests, and the two
//     bounds are stated here because they are load-bearing: it sees only files
//     that import SwiftUI or live under `Views/`, and only controls wearing the
//     literal label. `retrySurfaces` is therefore "every SwiftUI file that draws
//     a LABELLED retry", not "every surface that can offer one". Rule 2b covers
//     the rest.
//
//   Rule 2b — no catch-all SPEAKS a retry it cannot honour.
//     The surfaces that reach a driver, a wrist and a lock screen have no
//     labelled control: CarPlay speaks its invitation and a notification body
//     prints it, so Rule 2 is blind to all of them by construction. Rule 2b
//     reads the invitation as PROSE ("try again", "retry") and looks where the
//     defect forms — the CATCH-ALL arm of a switch over an `AppError`, the one
//     arm whose contents nobody chose, which every terminal verdict added to the
//     taxonomy later inherits in silence. An invitation there must be split on
//     `isRetryable`. A `?? "… try again."` fallback is not reported: it renders
//     only when no typed error stood behind the failure, and unknown is not
//     terminal.
//
//   Rule 3 — the compensating controls behind the cause-only exceptions still
//     exist. A surface allowed to show the cause alone (a space-bound tile) is
//     allowed it only because the remedy is reachable somewhere else; Rule 3
//     asserts that somewhere-else is still there, statement-scoped, so the trade
//     cannot be silently cancelled by deleting the half keeping it honest.
//
//   Rule 0 — the NEGATIVE CONTROL. A guard nobody has seen fail reads as
//     coverage. Rule 0 drives each MATCHER the four rules decide on — the
//     cause-half read, arm scoping and catch-all classification, the retry label
//     and the retry prose, the gate-name and real-read matchers — against
//     synthetic input where the answer is known, including the exact shapes of
//     the defects this file was written to stop, so a scanner broken by a
//     source-layout change fails there rather than quietly reporting "no drift".
//     Two of its assertions pin a LIMIT rather than a guarantee (the bare
//     `error.localizedDescription`, and the line-window comparison escape (c)
//     replaced); both say so where they stand, because a negative control that
//     asserts a false premise turns a hole into an endorsement.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE ESCAPE HATCHES, AND WHY EACH IS DRAWN WHERE IT IS
//
//   (a) DECLARATION lines (`var errorDescription`). Defining the cause half is
//       not rendering it.
//   (b) SAME-STATEMENT pairing. A statement that reads `recoverySuggestion` or
//       `descriptionWithRecovery` alongside the cause is already whole.
//   (c) ROUTING, scoped to the switch ARM. `AppError.errorDescription` is
//       legitimate in the `default:` arm of a switch whose OTHER arms hand the
//       certificate verdicts their remedy — the shape `BackgroundRemoteAgent`,
//       `AppleRelayPendingQueue`, `SettingsViewModel.friendlyGatewayMessage` and
//       `WatchRecordingService.terminalSTTMessage` all use. What earns the
//       escape depends on WHICH arm the read sits in, because the two arms are
//       not the same kind of thing:
//         • an ENUMERATED arm is judged on ITSELF — a `remedyBearingSources`
//           entry inside that arm, and still within `remedyProximityLines` so an
//           over-long arm cannot vouch end-to-end.
//         • a CATCH-ALL arm gets nothing from its neighbours, because its
//           neighbours are exactly the arms whose verdicts never reach it. It
//           passes only when EVERY certificate family is routed to a remedy in
//           an arm of its own, so none of them can fall through.
//       Arm membership replaced a ±N-line window, which was a proxy for it with
//       a hole a switch drives straight through: scanning a window for ANY
//       remedy token let ONE remedy-bearing arm vouch for every cause-only arm
//       around it, `default:` included. Rule 1 could then never see a MISSING
//       arm — and a verdict whose arm is deleted falls into `default:` and is
//       rendered cause-only, which is exactly how this defect ends a round.
//   (d) STATIC cases (`AppError.sttMissingAPIKey.errorDescription`). The defect
//       class is a surface rendering WHATEVER error arrives, where a certificate
//       verdict lands unseen. A named case is a copy choice the author can read
//       in full at the call site, and some of them (`.sttMissingAPIKey`) already
//       carry their instruction in the cause line — appending the remedy would
//       print it twice. Reviewed as copy, not as a taxonomy leak.
//   (e) LOG emits. `LoggingPrivacyDriftGuardTests` owns those, and it bans error
//       text in an always-compiled log outright.
//   (f) The per-site `causeOnlyExceptions` allow-list. Every entry names its
//       enclosing declaration and carries the argument for it.
//
// KNOWN LIMITS — the line is drawn here on purpose. Read this before trusting
// any clean result: everything below is a place the guard does NOT look, and a
// check believed to cover it is worse than no check at all.
//   • Escape (c) reads switch arms by INDENTATION and label text, not with a
//     parser. An arm ends at the next label or the first non-blank line indented
//     no deeper than its own label. Unusual formatting (a `case` body outdented
//     to its label, a switch inside a string literal) misreads the boundary.
//     Outside a switch — a `catch`, a plain body — there are no arms and the
//     bounded window is still the only notion of "the same decision" available,
//     with the proxy limit that implies.
//   • Escape (c)'s catch-all branch checks that the three CERTIFICATE families
//     are routed out of the catch-all. It does NOT check that every other
//     verdict with a remedy is: `.remoteAgentModelUnavailable` and
//     `.remoteAgentContextTooLong` reach `friendlyGatewayMessage`'s `default:`
//     and are rendered cause-only, and this guard passes them. That is a
//     deliberate scope line — the security claim in this file's opening is about
//     the three certificate families — not a statement that the remaining copy
//     is whole.
//   • The certificate-family check is NAME-driven: it looks for `CertUntrusted`,
//     `CertMismatch`, `CertKeyUnpinnable` in an arm's text, plus the whole-family
//     predicate `isCertificateVerdict`. A future lane whose case names break that
//     convention, or a second whole-family predicate, is invisible until added to
//     `certificateVerdictFamilies` / `certificateFamilyPredicates`.
//   • Rule 1 sees a `String` that was ALREADY reduced to a cause elsewhere as an
//     ordinary string. `AttachmentPreviewStrip`'s refused tile is exactly that,
//     which is why Rule 3 exists to hold its compensating control in place.
//   • Rule 1's receiver matcher is a HEURISTIC ON NAMES
//     (`errorShapedReceiverWords`). A cause-half read whose receiver is called
//     `err`, `e`, `problem`, `reason`, `cause` or `refusal` is invisible to it.
//     There is no live instance today; the substring match is not a proof of
//     coverage, and this is the guard's widest blind spot.
//   • `localizedDescription` counts only when the receiver names an `AppError`
//     CARRIER (`appErrorCarrierWords`). A bare `catch { error.localizedDescription }`
//     is NOT reported, and that is a blind spot rather than a safety property:
//     `ClassifiedRemoteAgentFailure` is a non-`AppError` `LocalizedError` that
//     FORWARDS `appError.errorDescription`, so a generic catch on a path that can
//     receive one prints the taxonomy's cause with the remedy dropped, under a
//     receiver naming no `AppError`. Reads that NAME the carrier are caught;
//     reads through an anonymous `error` are not. Widening it to every
//     `error.localizedDescription` was rejected: most are genuine system
//     messages, and a guard that cries wolf gets deleted.
//   • Rule 2 is doubly bounded, and the registry's name oversells it. It sees
//     only SwiftUI/`Views/` FILES, and only controls whose literal label is
//     "Retry" / "Try again". Every other user-facing surface — AppKit menus,
//     spoken prose, notification bodies — is outside it wholesale; Rule 2b picks
//     up the catch-all shape on those, and nothing covers a labelled AppKit
//     retry. Glyph-only detection was tried and dropped — `arrow.clockwise` is
//     also the app's Refresh/Run-again glyph. `UNNotificationAction` is not a
//     gap today because the app builds none; a first one would need adding here.
//   • Rule 2's gate check is DECLARATION-scoped, so a declaration drawing two
//     Retry controls passes when only one names the gate.
//     `DictationPopoverView.errorFooter` is exactly that shape, and its registry
//     entry carries the argument for why it is sound there. Branch-scoping was
//     rejected: a SwiftUI `if / else if` chain has no reliable textual boundary,
//     and the false positives would be the end of the rule.
//   • Rule 2b reads only CATCH-ALL arms. An enumerated arm that invites a retry
//     on a terminal verdict is a copy choice the author made case by case
//     (escape (d)), and is reviewed as copy, not caught here.
//   • A `.notErrorDriven` file is exempt WHOLESALE, so an error-driven Retry
//     added to one would pass. The classification is therefore about the file's
//     whole subject, and a file that grows a transport failure needs its entry
//     revisited — which is why every reason states what the control retries.
//   • Line-scoped, comment stripping is line-based, `#if` conditions are read
//     textually and anything ambiguous is treated as SHIPPING code — i.e. the
//     scanner errs strict. Same derivation and same limits as the sibling guards
//     (`LoggingPrivacyDriftGuardTests`, `MarkdownAttachmentPolicyDriftGuardTests`,
//     `RelayWireSourceDriftGuardTests`).
//
// Paths come from `#filePath`, so the scan is independent of the test runner's
// working directory. Both test bundles are excluded: test code never ships, and
// this file's own literals would otherwise self-trigger.

import XCTest

final class ErrorSurfaceDriftGuardTests: XCTestCase {

    // MARK: - The invariant, as data

    /// Reading either of these turns an error into words a user reads.
    /// `localizedDescription` is here because on a `LocalizedError` it IS
    /// `errorDescription` — the cause half wearing a Foundation name, which is
    /// how the half gets dropped without anyone typing `errorDescription`.
    private static let causeHalfProperties = ["errorDescription", "localizedDescription"]

    /// Expressions that carry the remedy. Naming any of them inside a
    /// declaration is what earns escape (c).
    ///
    /// `CertificateTrustCopy.` and `WatchNetworkFailureCopy.certificate` are in
    /// the list because the wrist and the wheel deliberately do NOT use
    /// `descriptionWithRecovery`: the full remedy names three server-side routes
    /// and would truncate on those screens, so they render the compact forms that
    /// keep the load-bearing sentence and delegate the rest to the phone. That is
    /// the remedy half doing its job, just sized for the surface.
    private static let remedyBearingSources = [
        "descriptionWithRecovery",
        "recoverySuggestion",
        "CertificateTrustCopy.",
        "WatchNetworkFailureCopy.certificate",
    ]

    /// A receiver is error-shaped when its text names one of these. Substring
    /// matching is deliberate — it catches `appError`, `(error as? AppError)?`
    /// and `failure?` without enumerating naming conventions, and it does NOT
    /// catch `UTType($0)?.localizedDescription`, which is a file-type label.
    ///
    /// This is a HEURISTIC on names, and it is the guard's widest blind spot —
    /// see KNOWN LIMITS. A cause-half read whose receiver is called `err`, `e`,
    /// `problem`, `reason`, `cause` or `refusal` is invisible to Rule 1.
    private static let errorShapedReceiverWords = ["error", "failure", "verdict", "classified"]

    /// Receiver texts that provably carry an `AppError`'s copy, which is what
    /// makes a `localizedDescription` read on one a dropped taxonomy half rather
    /// than a system message.
    ///
    /// `AppError` itself, plus the one carrier in the app that FORWARDS it:
    /// `ClassifiedRemoteAgentFailure` is a non-`AppError` `LocalizedError` whose
    /// `errorDescription` returns `appError.errorDescription` verbatim
    /// (`AdapterWireCode.swift`). A read on one prints the taxonomy's CAUSE
    /// while the receiver's name says no `AppError` at all — which is why the
    /// list is a list and not a single `contains("apperror")`.
    private static let appErrorCarrierWords = ["apperror", "classifiedremoteagentfailure", "classified"]

    /// Test bundles never ship. `Models/AppError.swift` DEFINES both halves —
    /// scanning it would flag `descriptionWithRecovery`'s own body, i.e. the one
    /// property this guard exists to push people towards.
    private static let excludedDirectoryNames: Set<String> = ["ConduckTests", "ConduckWatchTests"]
    private static let excludedFilePaths: Set<String> = ["Conduck/Models/AppError.swift"]

    // MARK: - Rule 1's allow-list

    /// A site that renders an `AppError`'s cause alone on purpose. Pinned to its
    /// enclosing DECLARATION rather than a line number, so ordinary edits above
    /// it do not invalidate the entry while a move to a different decision does.
    private struct CauseOnlyException {
        let path: String
        let declaration: String
        let reason: String
    }

    /// Keep this list SHORT. Every entry is a place the app tells a user what
    /// went wrong and not what to do about it, so the bar is "a certificate
    /// verdict provably cannot arrive here", never "this call site looks fine".
    private static let causeOnlyExceptions: [CauseOnlyException] = [
        CauseOnlyException(
            path: "ConduckWatch Watch App/Services/WatchRecordingService.swift",
            declaration: "startConverseHop",
            reason: """
            The exemption is DECLARATION-wide, so it must answer for the whole \
            `do` block, which wraps FOUR throwing calls — not just the upload:
            `resolveActiveConversationAndBackend`, `store.appendMessage` and \
            `ConversationHistoryAssembler.assemble` are store/identity-layer \
            calls that throw store-layer errors, none of which is a transport \
            verdict; `WatchAudioUploader.uploadConverse` throws only \
            `.remoteAgentInvalidResponse`, raised while BUILDING the request body \
            — before a connection exists. The converse hop's own TLS refusal \
            arrives on the background URLSession delegate, not out of this \
            `throw`, so no certificate verdict can reach this catch by any of the \
            four routes. The wrist's certificate copy is routed in \
            `terminalSTTMessage`, which renders the compact forms.
            """
        ),
        CauseOnlyException(
            path: "ConduckWatch Watch App/Services/WatchAudioUploader.swift",
            declaration: "handleSTTCompletion",
            reason: """
            Decode-only path: this catch wraps `STTResponseDecoder` / the JSON \
            body factory on a response that has ALREADY arrived, so the reachable \
            set is `.sttDecodingFailure` / `.noSpeechDetected`. A TLS refusal \
            fails the task long before there is a body to decode.
            """
        ),
    ]

    // MARK: - Rule 2's registry

    /// How a view that draws a Retry control decides whether to draw it.
    private enum RetryGate {
        /// Each declaration drawing a Retry control must name one of `tokens`.
        /// `decidedIn` names the file where the gate is actually COMPUTED — the
        /// guard checks that file still performs a REAL READ of `isRetryable`
        /// (member access on a value, in comment-stripped release code), so a
        /// cross-file gate cannot be hollowed out into a constant `true` while
        /// its doc comments go on describing the property it no longer asks.
        case gated(tokens: [String], decidedIn: String?, reason: String)
        /// No `AppError` reaches this control, so `isRetryable` is not its
        /// question. The reason must say what the control retries instead.
        case notErrorDriven(reason: String)
    }

    /// Every SwiftUI/`Views/` file that draws a control whose literal label is
    /// "Retry" / "Try again". A file that draws one and is NOT here fails Rule 2
    /// — that is the whole point: the next surface has to be classified rather
    /// than assumed.
    ///
    /// NOT "every surface that can offer a retry". Files outside SwiftUI never
    /// reach this registry, and a control labelled anything else is invisible to
    /// it; see KNOWN LIMITS, and Rule 2b for the prose surfaces.
    private static let retrySurfaces: [String: RetryGate] = [
        "Conduck/Views/Components/PendingRetryCard.swift": .gated(
            tokens: ["isRetryable"],
            decidedIn: nil,
            reason: """
            The home-screen card for a preserved recording. Its Retry re-runs the \
            SAME bytes against the SAME configuration, so a terminal refusal \
            (certificate, rejected key, wrong endpoint) can only be reached again.
            """
        ),
        "Conduck/Views/Conversation/AttachmentPreviewStrip.swift": .gated(
            tokens: [".refused"],
            decidedIn: "Conduck/Views/Conversation/StagedAttachment.swift",
            reason: """
            The tile's Retry belongs to `.failed` only; `.refused` is the terminal \
            twin and draws none. The gate token is the terminal STATE itself — if \
            a future edit collapses the two states back into one, `.refused` \
            disappears from this declaration and Rule 2 fires.
            """
        ),
        "Conduck/Views/Conversation/ConversationThreadView.swift": .gated(
            tokens: ["offersRetry"],
            decidedIn: "Conduck/Views/Conversation/DeclinedTurnPresentation.swift",
            reason: "The declined-turn row's Try again, gated on the presentation's `offersRetry`."
        ),
        "Conduck/Views/Settings/PairingImportSheet.swift": .gated(
            tokens: ["gatewayFailureIsRetryable"],
            decidedIn: "Conduck/ViewModels/PairingImportFlow.swift",
            reason: """
            The import sheet's recovery section. Re-running the connectivity \
            stages against a refused certificate reaches the identical verdict, so \
            the sheet says so instead of offering the button.
            """
        ),
        "Conduck/MenuBar/DictationPopoverView.swift": .gated(
            tokens: ["isRetryable"],
            decidedIn: nil,
            reason: """
            THREE Retry controls across TWO declarations, which is more than the \
            token match proves — read this before trusting it.
            `sendErrorActions` draws one, gated on `sendErrorIsRetryable(vm)`, \
            which rebuilds the verdict via `AppError.from(errorCode:).isRetryable`: \
            the popover is the macOS twin of the window's failed-turn row and \
            must not offer what the window withholds.
            `errorFooter` draws TWO in one `if / else if`. The second is gated on \
            `isRetryable && hasSavedRetryAudio`. The FIRST is not gated on \
            retryability at all — it is gated on `coordinator.hasPendingFailedTurn`, \
            and it replays a mint-failure hand-off that never touched the network, \
            so no `AppError` verdict is being second-guessed. Rule 2's gate check \
            is DECLARATION-scoped, so the token it finds in this declaration is \
            the second control's; the first rides on that. Sound only while the \
            branches stay mutually exclusive and the pending-turn branch stays \
            transport-free — `MenuBarCoordinator` clears `pendingFailedTurn` on \
            every fresh capture, which is what keeps them exclusive today. If \
            that branch ever replays a transport send, it needs its own gate and \
            this entry needs splitting.
            """
        ),
        "Conduck/Views/Settings/ProviderRow.swift": .notErrorDriven(
            reason: """
            THREE controls, two kinds. `appleAccessBody` and `appleStateBody` \
            each draw one that re-runs an Apple on-device MODEL DOWNLOAD, both \
            already withheld by the declaration's own `retryable` flag (the \
            structural failure — language unsupported — sets it false). \
            `stateBody` draws the third, which re-opens the API-key ENTRY FIELD \
            rather than re-firing anything. All three ride a download/entry state \
            flag; no `AppError` reaches any of them.
            """
        ),
        "Conduck/Views/Onboarding/HostedModelGatewayStepView.swift": .notErrorDriven(
            reason: """
            Re-runs a boolean liveness probe against OpenRouter — a hosted service \
            the user neither operates nor pins, so no certificate verdict exists \
            for this control to ignore.
            """
        ),
        "Conduck/Views/Conversation/ConversationListView.swift": .notErrorDriven(
            reason: "Reloads the LOCAL conversation store after a read failure; no transport, no `AppError`."
        ),
        "ConduckWatch Watch App/Views/WatchConversationListView.swift": .notErrorDriven(
            reason: "Reloads the LOCAL conversation store on the wrist; same as its phone twin."
        ),
        "ConduckWatch Watch App/Views/WatchNoteView.swift": .gated(
            tokens: ["canRetry"],
            decidedIn: nil,
            reason: """
            Gated on preserved audio actually existing — with none, the same \
            button honestly relabels itself Dismiss rather than promising a re-run \
            it cannot perform.
            """
        ),
    ]

    // MARK: - Rule 3's anchors

    /// A surface allowed to show a cause-only STRING because the remedy is
    /// reachable elsewhere. `anchors` are what make that "elsewhere" true; if one
    /// goes missing the trade has been cancelled and Rule 3 fails.
    private struct CompensatedCauseOnlySurface {
        let name: String
        let reason: String
        let anchors: [RemedyAnchor]
    }

    /// Where a remedy has to still be, for a cause-only surface to stay honest.
    ///
    /// `declaration` and `withinStatementAt` are what give the anchor teeth. Both
    /// were added because a mutation test walked through the weaker versions:
    /// a file-wide token search is satisfied by any unrelated `accessibilityLabel`
    /// elsewhere in a 500-line view, and a declaration-wide one is still satisfied
    /// by the `let refusalDetail = …` binding after its USE has been deleted. So
    /// the tokens must appear inside the STATEMENT that consumes them.
    private struct RemedyAnchor {
        let path: String
        /// nil = search the whole file.
        let declaration: String?
        /// nil = search the whole scope; otherwise the statement beginning at the
        /// first line containing this text.
        let withinStatementAt: String?
        let tokens: [String]
    }

    private static let compensatedCauseOnlySurfaces: [CompensatedCauseOnlySurface] = [
        CompensatedCauseOnlySurface(
            name: "AttachmentPreviewStrip — the refused server-file tile",
            reason: """
            DELIBERATE, and the one place in the app where cause-only is the right \
            answer: the tile is capped at 180pt and clips at two lines, so the \
            remedy cannot be shown there at ANY wording — the pin-mismatch \
            warning sits at the end of its remedy and would be the first thing \
            truncated away, which is worse than not starting. The full cause AND \
            remedy therefore ride the tile's accessibility label, which has no \
            width to run out of, and the visible line stays the refusal's own \
            canonical cause rather than a strip-local paraphrase. The trade is \
            only acceptable while that label exists, which is what the anchors \
            below hold in place.
            """,
            anchors: [
                // The tile still lifts `detail` (cause + remedy) out of `.refused`…
                RemedyAnchor(
                    path: "Conduck/Views/Conversation/AttachmentPreviewStrip.swift",
                    declaration: "serverFileTile",
                    withinStatementAt: nil,
                    tokens: [".refused", "refusalDetail"]
                ),
                // …and still SPENDS it on the accessibility label. Statement-scoped:
                // the binding surviving proves nothing if the label stopped reading it.
                RemedyAnchor(
                    path: "Conduck/Views/Conversation/AttachmentPreviewStrip.swift",
                    declaration: "serverFileTile",
                    withinStatementAt: ".accessibilityLabel(",
                    tokens: ["refusalDetail"]
                ),
                // And `detail` is still the WHOLE verdict, not a second copy of
                // the cause — otherwise the a11y label carries nothing extra.
                RemedyAnchor(
                    path: "Conduck/Views/Conversation/StagedAttachment.swift",
                    declaration: nil,
                    withinStatementAt: "return .refused(",
                    tokens: ["descriptionWithRecovery"]
                ),
            ]
        ),
    ]

    // MARK: - Source access

    /// `.../Conduck/Conduck` — the Xcode project container holding all targets'
    /// sources. Derived from this test file's compile-time absolute path, so it
    /// is independent of the runner's working directory.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: projectContainerURL().path + "/", with: "")
    }

    /// Every `.swift` file that compiles into a SHIPPING target.
    private func shippingSwiftFiles() throws -> [URL] {
        let container = projectContainerURL()
        guard let walker = FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }
        var files: [URL] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            guard Set(url.pathComponents).isDisjoint(with: Self.excludedDirectoryNames) else { continue }
            guard !Self.excludedFilePaths.contains(relativePath(url)) else { continue }
            files.append(url)
        }
        return files
    }

    /// SwiftUI/view code: a file that imports SwiftUI, or lives under a `Views/`
    /// directory. The second half matters — `StagedAttachment.swift` mints the
    /// strings the strip renders and imports no SwiftUI at all.
    private func isViewCode(path: String, source: String) -> Bool {
        source.contains("import SwiftUI") || path.contains("/Views/")
    }

    // MARK: - Scanner: release code

    /// Is this `#if` / `#elseif` directive DEBUG-conditioned? Read textually;
    /// `!DEBUG` and `||` both resolve to "not DEBUG-only", the strict direction.
    private func isDebugCondition(_ directiveLine: String) -> Bool {
        var condition = directiveLine
        if let commentStart = condition.range(of: "//") {
            condition = String(condition[..<commentStart.lowerBound])
        }
        guard condition.contains("DEBUG") else { return false }
        if condition.contains("!DEBUG") || condition.contains("! DEBUG") || condition.contains("||") {
            return false
        }
        return true
    }

    /// Comment-stripped lines that are NOT inside a DEBUG-conditioned region —
    /// the code that actually ships. Mirrors the sibling guards' `codeOnly`.
    private func releaseCodeLines(in source: String) -> [(number: Int, text: String)] {
        var result: [(number: Int, text: String)] = []
        var inBlockComment = false
        var regions: [(isDebugOnly: Bool, parentIsDebugOnly: Bool)] = []

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }

            // `#elseif` must be tested before `#else` — it shares that prefix.
            if trimmed.hasPrefix("#if") {
                let parent = regions.last?.isDebugOnly ?? false
                regions.append((isDebugOnly: parent || isDebugCondition(trimmed), parentIsDebugOnly: parent))
                continue
            }
            if trimmed.hasPrefix("#elseif") {
                if let last = regions.last {
                    regions[regions.count - 1] = (isDebugOnly: last.parentIsDebugOnly || isDebugCondition(trimmed),
                                                  parentIsDebugOnly: last.parentIsDebugOnly)
                }
                continue
            }
            if trimmed.hasPrefix("#else") {
                // The `#else` of a `#if DEBUG` is the RELEASE branch.
                if let last = regions.last {
                    regions[regions.count - 1] = (isDebugOnly: last.parentIsDebugOnly,
                                                  parentIsDebugOnly: last.parentIsDebugOnly)
                }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !regions.isEmpty { regions.removeLast() }
                continue
            }

            if regions.last?.isDebugOnly == true { continue }
            // Drop a trailing `// note` so line-scoped matching never reads a comment.
            result.append((number: offset + 1, text: strippingTrailingComment(line)))
        }
        return result
    }

    /// Remove a trailing `//` comment, ignoring one that sits inside a string
    /// literal (`"https://…"` is the shape that would otherwise truncate a line).
    private func strippingTrailingComment(_ line: String) -> String {
        var inString = false
        var previous: Character? = nil
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString, character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                return String(characters[..<index])
            }
            previous = character
            index += 1
        }
        return line
    }

    // MARK: - Scanner: declarations

    /// One `func` / `var` declaration and the line range it owns.
    private struct Declaration {
        let name: String
        let indent: Int
        let startLine: Int
        var endLine: Int
    }

    private static let declarationPattern =
        #"^(\s*)(?:@[A-Za-z]+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|open|static|final|class|nonisolated|override|lazy|weak|dynamic|mutating)\s+)*(?:func|var)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    /// Every declaration in a file, each ending where the next declaration at the
    /// same-or-shallower indentation begins. Approximate by design — indentation
    /// is cheaper and steadier than brace tracking, and a declaration boundary
    /// that lands a few lines late can only ever widen escape (c)'s window, which
    /// the header records as a known limit.
    private func declarations(in lines: [(number: Int, text: String)]) -> [Declaration] {
        guard let regex = try? NSRegularExpression(pattern: Self.declarationPattern) else { return [] }
        var found: [Declaration] = []
        for entry in lines {
            let ns = entry.text as NSString
            guard let match = regex.firstMatch(in: entry.text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 3 else { continue }
            found.append(Declaration(name: ns.substring(with: match.range(at: 2)),
                                     indent: ns.substring(with: match.range(at: 1)).count,
                                     startLine: entry.number,
                                     endLine: lines.last?.number ?? entry.number))
        }
        for index in found.indices {
            for later in found[(index + 1)...] where later.indent <= found[index].indent {
                found[index].endLine = later.startLine - 1
                break
            }
        }
        return found
    }

    /// The INNERMOST declaration containing `line` — the deepest indentation
    /// wins, so a nested helper is judged on its own body rather than its host's.
    private func enclosingDeclaration(ofLine line: Int, indent: Int, in declarations: [Declaration]) -> Declaration? {
        declarations
            .filter { $0.startLine <= line && line <= $0.endLine && $0.indent < indent }
            .max { ($0.indent, $0.startLine) < ($1.indent, $1.startLine) }
    }

    private func text(of declaration: Declaration, in lines: [(number: Int, text: String)]) -> String {
        lines.filter { $0.number >= declaration.startLine && $0.number <= declaration.endLine }
            .map(\.text)
            .joined(separator: "\n")
    }

    private func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// How far a remedy may sit from a cause-only read and still count as the
    /// same decision, OUTSIDE a switch (a `catch`, a plain body), and as a
    /// second bound inside an over-long arm.
    ///
    /// Bounded on purpose. Declaration scope alone is not enough: the moment a
    /// SwiftUI `body` gains ONE banner that uses `descriptionWithRecovery`, an
    /// unbounded escape (c) would wave through every other cause-only render in
    /// that same body — and a long `body` with several banners is exactly the
    /// surface this defect keeps reappearing on.
    private static let remedyProximityLines = 12

    // MARK: - Scanner: switch arms

    /// One `case …:` / `default:` label and the lines it owns.
    ///
    /// Arm membership is what escape (c) always MEANT — "the same decision" —
    /// and a line-count window was only ever a proxy for it. The proxy had a
    /// hole a switch drives straight through: scanning ±N lines for ANY
    /// remedy-bearing token lets ONE remedy-bearing arm vouch for every
    /// cause-only arm around it, `default:` included. Rule 1 then cannot see a
    /// MISSING arm — which is exactly how a terminal verdict ends up rendered
    /// cause-only, since a verdict nobody enumerated lands in `default:` and the
    /// enumerated neighbours go on vouching for it.
    private struct SwitchArm {
        let labelLine: Int
        let upperLine: Int
        /// `default:`, and the binding-only arms that are catch-alls wearing
        /// `case` clothes. A catch-all receives every verdict the author did not
        /// enumerate, so its neighbours cannot speak for it.
        let isCatchAll: Bool
        let text: String
    }

    /// `default:` / `case .some(let e):` / `case let other:` — an arm that names
    /// no enum case, so whatever the author forgot arrives here.
    ///
    /// `.some(` is unwrapped first: `case .some(let appError):` is `case let
    /// appError:` on an `Optional`, a catch-all in both shapes. A `where` clause
    /// calling a predicate reads as ENUMERATED, which is the strict direction —
    /// a predicate NARROWS an arm, so the arm is judged on its own contents.
    private func isCatchAllArmLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("default:") { return true }
        let unwrapped = trimmed.replacingOccurrences(of: ".some(", with: "(")
        return unwrapped.range(of: #"\.[a-z][A-Za-z0-9_]*"#, options: .regularExpression) == nil
    }

    /// Every switch arm inside a declaration.
    ///
    /// An arm ends at whichever comes first: the next label, or the first
    /// non-blank line indented no deeper than its own label — which is the
    /// switch's closing brace, and is what stops an arm bleeding into a `catch`
    /// block further down the same declaration.
    private func switchArms(in declaration: Declaration,
                            of lines: [(number: Int, text: String)]) -> [SwitchArm] {
        let body = lines.filter { $0.number >= declaration.startLine && $0.number <= declaration.endLine }
        var labels: [(number: Int, text: String, indent: Int)] = []
        for entry in body {
            let trimmed = entry.text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") || trimmed.hasPrefix("case.") || trimmed.hasPrefix("default:") else {
                continue
            }
            labels.append((entry.number, trimmed, indent(of: entry.text)))
        }

        var arms: [SwitchArm] = []
        for (index, label) in labels.enumerated() {
            var upper = index + 1 < labels.count ? labels[index + 1].number - 1 : declaration.endLine
            for entry in body where entry.number > label.number && entry.number <= upper {
                guard !entry.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if indent(of: entry.text) <= label.indent {
                    upper = entry.number - 1
                    break
                }
            }
            let text = body
                .filter { $0.number >= label.number && $0.number <= upper }
                .map(\.text)
                .joined(separator: "\n")
            arms.append(SwitchArm(labelLine: label.number,
                                  upperLine: upper,
                                  isCatchAll: isCatchAllArmLabel(label.text),
                                  text: text))
        }
        return arms
    }

    private func arm(containing line: Int, in arms: [SwitchArm]) -> SwitchArm? {
        arms.last { $0.labelLine <= line && line <= $0.upperLine }
    }

    /// The fragment every lane's case name shares, per certificate family.
    /// `remoteAgentCertMismatch`, `sttCustomCertMismatch`,
    /// `ttsCustomCertMismatch` and `fileTransferCertMismatch` all carry
    /// `CertMismatch`, so one fragment tests the whole family across lanes.
    private static let certificateVerdictFamilies = ["CertUntrusted", "CertMismatch", "CertKeyUnpinnable"]

    /// A predicate that stands in for all three families at once, so a switch
    /// may route them in ONE arm (`case .some(let e) where isCertificateVerdict(e)`)
    /// instead of enumerating twelve case names.
    private static let certificateFamilyPredicates = ["isCertificateVerdict"]

    /// Does this switch route EVERY certificate family to a remedy in an arm of
    /// its own — so no certificate verdict can reach the catch-all?
    ///
    /// This is what escape (c) claims when it waves through a cause-only
    /// `default:`, and now the claim is checked rather than approximated.
    /// Delete the `.remoteAgentCertKeyUnpinnable` arm and that family falls
    /// through to `default:`, where the cause alone is a dead end — under the
    /// old line-window this went unreported, because the arms left standing
    /// still put a remedy token within sight.
    private func routesEveryCertificateFamilyToARemedy(in declaration: Declaration,
                                                       of lines: [(number: Int, text: String)]) -> Bool {
        let remedyArms = switchArms(in: declaration, of: lines).filter { arm in
            Self.remedyBearingSources.contains { arm.text.contains($0) }
        }
        guard !remedyArms.isEmpty else { return false }
        if remedyArms.contains(where: { arm in
            Self.certificateFamilyPredicates.contains { arm.text.contains($0) }
        }) {
            return true
        }
        return Self.certificateVerdictFamilies.allSatisfy { family in
            remedyArms.contains { $0.text.contains(family) }
        }
    }

    /// Does the enclosing decision hand the certificate verdicts a remedy — in
    /// the SAME arm as this cause-only read, or, for a catch-all, in arms that
    /// keep them out of it entirely?
    private func routesCertificateVerdicts(near line: Int,
                                           in declaration: Declaration,
                                           of lines: [(number: Int, text: String)]) -> Bool {
        guard let arm = arm(containing: line, in: switchArms(in: declaration, of: lines)) else {
            // Not in a switch at all — a `catch`, a plain body. The bounded
            // window is the only notion of "the same decision" available.
            return remedyWithinProximity(of: line, lower: declaration.startLine, upper: declaration.endLine, of: lines)
        }
        if arm.isCatchAll {
            // Distance is meaningless here: a catch-all's neighbours are exactly
            // the arms whose verdicts never reach it. What earns the escape is
            // that the certificate families are routed OUT of it.
            return routesEveryCertificateFamilyToARemedy(in: declaration, of: lines)
        }
        // An enumerated arm is judged on its own contents — and still on the
        // distance bound, so an arm longer than the window cannot vouch
        // end-to-end for a read at the far side of it.
        return remedyWithinProximity(of: line, lower: arm.labelLine, upper: arm.upperLine, of: lines)
    }

    private func remedyWithinProximity(of line: Int,
                                       lower: Int,
                                       upper: Int,
                                       of lines: [(number: Int, text: String)]) -> Bool {
        let from = max(lower, line - Self.remedyProximityLines)
        let to = min(upper, line + Self.remedyProximityLines)
        let window = lines
            .filter { $0.number >= from && $0.number <= to }
            .map(\.text)
            .joined(separator: "\n")
        return Self.remedyBearingSources.contains { window.contains($0) }
    }

    // MARK: - Scanner: statements

    /// The full statement a line belongs to: the line itself plus following lines
    /// while its brackets stay unbalanced. Escape (b) reads the WHOLE statement,
    /// because `return error.recoverySuggestion\n  ?? error.errorDescription` is
    /// one decision written on two lines.
    private func statement(startingAt index: Int, in lines: [(number: Int, text: String)]) -> String {
        var text = lines[index].text
        var depth = netBracketDepth(of: lines[index].text)
        var cursor = index
        while depth > 0, cursor + 1 < lines.count {
            cursor += 1
            text += "\n" + lines[cursor].text
            depth += netBracketDepth(of: lines[cursor].text)
        }
        // A statement can also CONTINUE backwards (`?? error.errorDescription` on
        // its own line), so pull in the preceding line when this one opens with a
        // continuation operator.
        let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
        if index > 0, trimmed.hasPrefix("??") || trimmed.hasPrefix("?") || trimmed.hasPrefix(":") {
            text = lines[index - 1].text + "\n" + text
        }
        return text
    }

    private func netBracketDepth(of line: String) -> Int {
        var depth = 0
        for character in line {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
        }
        return depth
    }

    /// Is this line an emit on an `os.Logger` handle, `os_log`, `NSLog`, or the
    /// Watch spine? Log text is `LoggingPrivacyDriftGuardTests`' territory.
    private func isLogEmit(_ line: String) -> Bool {
        if line.contains("NSLog(") || line.contains("os_log(") || line.contains("WatchLog.") { return true }
        let pattern = #"(?:^|[^A-Za-z0-9_])(?:log|logger|Log|Logger)[A-Za-z0-9_.]*\.(?:debug|info|notice|log|error|warning|fault|critical|trace)\s*\("#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Scanner: the cause-half read

    /// A read of an error's cause half, with the receiver expression that
    /// produced it.
    private struct CauseHalfRead {
        let property: String
        let receiver: String
    }

    /// Every cause-half read on the line whose receiver is a DYNAMIC,
    /// error-shaped value. Declaration lines (`var errorDescription`) are not
    /// reads — escape (a).
    private func causeHalfReads(in line: String) -> [CauseHalfRead] {
        var reads: [CauseHalfRead] = []
        for property in Self.causeHalfProperties {
            var searchStart = line.startIndex
            while let found = line.range(of: ".\(property)", range: searchStart..<line.endIndex) {
                searchStart = found.upperBound
                // Escape (a): a declaration of the property, not a read of it.
                if line.contains("var \(property)") { continue }
                // `.errorDescriptionSomething` is a different symbol.
                if let next = line.indices.contains(found.upperBound) ? line[found.upperBound] : nil,
                   next.isLetter || next.isNumber || next == "_" { continue }

                let receiver = receiverExpression(endingAt: found.lowerBound, in: line)
                guard isErrorShaped(receiver) else { continue }
                // `localizedDescription` is Foundation-wide, so it is counted
                // only when the receiver names a value that provably carries an
                // `AppError`'s copy. A bare `error.localizedDescription` on an
                // unnamed receiver is NOT reported — not because it is safe, but
                // because the matcher cannot tell a system message from a
                // forwarded taxonomy cause. That is a documented BLIND SPOT (see
                // KNOWN LIMITS), not a clean bill of health.
                if property == "localizedDescription", !namesAnAppErrorCarrier(receiver) { continue }
                // Escape (d): a statically named case.
                guard !isStaticCaseReceiver(receiver) else { continue }
                reads.append(CauseHalfRead(property: property, receiver: receiver))
            }
        }
        return reads
    }

    /// The expression immediately left of `index` — identifier characters, dots
    /// and optional-chaining marks, plus a balanced trailing `(…)` / `[…]` so
    /// `(error as? AppError)?` comes back whole.
    private func receiverExpression(endingAt index: String.Index, in line: String) -> String {
        let characters = Array(line[line.startIndex..<index])
        var cursor = characters.count - 1
        var depth = 0
        while cursor >= 0 {
            let character = characters[cursor]
            if character == ")" || character == "]" { depth += 1 }
            else if character == "(" || character == "[" {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0 {
                let isReceiverCharacter = character.isLetter || character.isNumber
                    || character == "_" || character == "." || character == "?" || character == "!"
                if !isReceiverCharacter { break }
            }
            cursor -= 1
        }
        return String(characters[(cursor + 1)...])
    }

    private func isErrorShaped(_ receiver: String) -> Bool {
        let lowered = receiver.lowercased()
        return Self.errorShapedReceiverWords.contains { lowered.contains($0) }
    }

    private func namesAnAppErrorCarrier(_ receiver: String) -> Bool {
        let lowered = receiver.lowercased()
        return Self.appErrorCarrierWords.contains { lowered.contains($0) }
    }

    /// `AppError.remoteAgentUnreachable` — a named case, chosen at the call site.
    private func isStaticCaseReceiver(_ receiver: String) -> Bool {
        receiver.range(of: #"(?:^|[^A-Za-z0-9_])AppError\.[a-z][A-Za-z0-9_]*$"#,
                       options: .regularExpression) != nil
    }

    // MARK: - Scanner: the retry control

    /// Does this line label a control "Retry" / "Try again"? Whole-literal
    /// matching, so prose ("…try again in a moment.") and localisation KEYS
    /// (`settings.stt.provider.tryAgain`) do not count — only the words a button
    /// actually wears.
    private func drawsRetryLabel(_ line: String) -> Bool {
        stringLiterals(in: line).contains { literal in
            let normalized = literal.trimmingCharacters(in: .whitespaces).lowercased()
            return normalized == "retry" || normalized == "try again"
        }
    }

    /// Does this declaration body name one of the gate tokens?
    ///
    /// Case-INSENSITIVE, because `isRetryable` is a concept and the flags that
    /// carry it into a view are named for what they gate — `errorIsRetryable`,
    /// `sendErrorIsRetryable`, `gatewayFailureIsRetryable` — all of which
    /// capitalise the `I`. A case-sensitive match reports a correctly gated
    /// control, and a guard that reports correct code gets switched off.
    private func namesGate(_ tokens: [String], in declarationBody: String) -> Bool {
        let lowered = declarationBody.lowercased()
        return tokens.contains { lowered.contains($0.lowercased()) }
    }

    /// Line numbers where this source performs a REAL READ of `isRetryable` —
    /// member access on a value (`error?.isRetryable`, `!appError.isRetryable`),
    /// in comment-stripped release code.
    ///
    /// The three things this deliberately does NOT count, each of which a raw
    /// `source.contains("isRetryable")` counts and is satisfied by:
    ///   • COMMENTS. `PairingImportFlow` names `AppError.isRetryable` in three
    ///     doc comments. Delete both of its real reads and a raw substring check
    ///     still passes — the gate is hollow and the guard says it is fine. That
    ///     is why this runs over `releaseCodeLines` rather than the file text.
    ///   • The property's own DECLARATION. Defining `var isRetryable` is not
    ///     asking it.
    ///   • A longer identifier ENDING in the name. `gatewayFailureIsRetryable`
    ///     is the flag the view reads, not the taxonomy question behind it; a
    ///     file that kept the flag and stopped computing it from the taxonomy is
    ///     exactly the hollowing this check exists to catch. The leading-dot
    ///     requirement excludes it, and the trailing `(?![A-Za-z0-9_])` excludes
    ///     `.isRetryableSomething`.
    private func retryabilityReadLines(in source: String) -> [Int] {
        var hits: [Int] = []
        for entry in releaseCodeLines(in: source) {
            // Escape: the declaration of the property is not a read of it.
            if entry.text.range(of: #"(?:var|let|func)\s+isRetryable\b"#, options: .regularExpression) != nil {
                continue
            }
            // A dot preceded by something that can END an expression — an
            // identifier, a closing bracket, or an optional-chaining mark.
            if entry.text.range(of: #"[A-Za-z0-9_)\]?!]\s*\.\s*isRetryable(?![A-Za-z0-9_])"#,
                                options: .regularExpression) != nil {
                hits.append(entry.number)
            }
        }
        return hits
    }

    /// Does this literal INVITE a retry, as prose rather than as a label?
    ///
    /// Rule 2 asks "is this control labelled Retry"; this asks "does this
    /// sentence tell the user to try again". They are different questions
    /// because they are different surfaces: the wheel has no control at all —
    /// CarPlay SPEAKS its invitation — and a spoken "Try again." on a terminal
    /// verdict is the same broken promise as a Retry button on one, minus the
    /// button. Substring, not whole-literal: the invitation is embedded in a
    /// sentence ("Something went wrong. Try again.").
    private func invitesRetryInProse(_ literal: String) -> Bool {
        let normalized = literal.lowercased()
        return normalized.contains("try again") || normalized.contains("retry")
    }

    /// Is this invitation the `??` fallback of a statement that asked the
    /// taxonomy FIRST (`error.errorDescription ?? "… try again."`)?
    ///
    /// Such a line renders the invitation only when the taxonomy produced
    /// nothing at all — no typed error stood behind the failure — and "unknown
    /// is not terminal" is the app's stated convention everywhere else
    /// (`PairingImportFlow.retryable`, `StageStatus.failed`). An invitation that
    /// is the arm's WHOLE result is a different thing: it fires for every
    /// verdict nobody enumerated, terminal ones included.
    private func isNilCoalescedFallback(_ literal: String,
                                        at index: Int,
                                        in lines: [(number: Int, text: String)]) -> Bool {
        let whole = statement(startingAt: index, in: lines)
        guard let found = whole.range(of: literal) else { return false }
        return whole[..<found.lowerBound].contains("??")
    }

    private func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inString = false
        var previous: Character? = nil
        for character in line {
            if character == "\"" && previous != "\\" {
                if inString { literals.append(current); current = "" }
                inString.toggle()
            } else if inString {
                current.append(character)
            }
            previous = character
        }
        return literals
    }

    // MARK: - Rule 0: the scanner can actually fail

    /// NEGATIVE CONTROL, driven before any rule reads the tree. Every input here
    /// is synthetic and every answer is known, so a scanner broken by a
    /// source-layout change fails HERE rather than quietly reporting "no drift".
    /// The first block is the literal shape of the defects this file was written
    /// to stop.
    func testScannerFiresOnTheDefectShapesAndStaysQuietOnTheSafeOnes() throws {
        // 1. The exact composer-banner shape: cause alone, no remedy anywhere.
        let composerBanner = """
        @ViewBuilder
        private var errorBanner: some View {
            if case .error(let appError) = recorder.state {
                Text(appError.errorDescription ?? String(localized: "Something went wrong."))
                    .font(.caption)
            }
        }
        """
        let bannerLines = releaseCodeLines(in: composerBanner)
        let bannerDecls = declarations(in: bannerLines)
        let bannerHit = try XCTUnwrap(
            bannerLines.first { !causeHalfReads(in: $0.text).isEmpty },
            "Rule 1 went blind to `appError.errorDescription` in a view — the defect it exists to catch."
        )
        let bannerDecl = try XCTUnwrap(
            enclosingDeclaration(ofLine: bannerHit.number, indent: indent(of: bannerHit.text), in: bannerDecls),
            "Declaration mapping broke — escape (c) would swallow every finding."
        )
        XCTAssertEqual(bannerDecl.name, "errorBanner",
                       "Enclosing declaration resolved to `\(bannerDecl.name)`; allow-list entries are pinned by name.")
        XCTAssertFalse(
            routesCertificateVerdicts(near: bannerHit.number, in: bannerDecl, of: bannerLines),
            "Escape (c) fired on a declaration with no remedy in it — the guard would pass the defect."
        )

        // 1b. Escape (c) is BOUNDED. One fixed banner high in a long `body` must
        //     not vouch for a second, unfixed one far below it — that is how the
        //     defect would come back on a surface already "fixed once".
        var longBody = ["    private var body: some View {",
                        "        Text(appError.descriptionWithRecovery)"]
        longBody.append(contentsOf: repeatElement("        Spacer()", count: Self.remedyProximityLines + 4))
        longBody.append("        Text(uploadError.errorDescription ?? \"\")")
        longBody.append("    }")
        let longLines = releaseCodeLines(in: longBody.joined(separator: "\n"))
        let longDecls = declarations(in: longLines)
        let farHit = try XCTUnwrap(longLines.last { !causeHalfReads(in: $0.text).isEmpty })
        let farDecl = try XCTUnwrap(enclosingDeclaration(ofLine: farHit.number,
                                                         indent: indent(of: farHit.text),
                                                         in: longDecls))
        XCTAssertFalse(
            routesCertificateVerdicts(near: farHit.number, in: farDecl, of: longLines),
            "Escape (c) is unbounded — one remedy anywhere in a long `body` would vouch for every cause-only render in it."
        )
        XCTAssertTrue(
            routesCertificateVerdicts(near: 2, in: farDecl, of: longLines),
            "Escape (c) stopped seeing an adjacent remedy — the legitimate routing sites would all be reported."
        )

        // 2. …and the same shape with the remedy present stays quiet.
        let fixedBanner = releaseCodeLines(in: """
        private var errorBanner: some View {
            if case .error(let appError) = recorder.state {
                Text(appError.descriptionWithRecovery)
            }
        }
        """)
        XCTAssertTrue(fixedBanner.allSatisfy { causeHalfReads(in: $0.text).isEmpty },
                      "`descriptionWithRecovery` must not read as a cause-only render — the fix would look like the defect.")

        // 3. Receiver classification: what counts, and what must not.
        for receiver in ["appError", "error", "(error as? AppError)?", "failure?", "appError?"] {
            XCTAssertTrue(isErrorShaped(receiver), "Receiver `\(receiver)` stopped reading as error-shaped.")
        }
        XCTAssertFalse(isErrorShaped("UTType($0)?"),
                       "Receiver matcher is too loose — a UTType's file-type label is not an error's cause.")
        XCTAssertTrue(isStaticCaseReceiver("AppError.remoteAgentUnreachable"),
                      "Escape (d) broke — every statically named case would be reported.")
        XCTAssertFalse(isStaticCaseReceiver("(error as? AppError)?"),
                       "Escape (d) is too loose — a dynamic error would escape as if it were a named case.")

        // 4. The Foundation-name traps.
        XCTAssertFalse(causeHalfReads(in: "state = .error(message: appError.localizedDescription)").isEmpty,
                       "`localizedDescription` on an AppError IS the cause half; it must be caught.")
        XCTAssertFalse(causeHalfReads(in: "state = .error(message: classified.localizedDescription)").isEmpty,
                       """
                       A read on `ClassifiedRemoteAgentFailure` stopped counting. It is a non-`AppError` \
                       `LocalizedError` that FORWARDS `appError.errorDescription`, so this prints the \
                       taxonomy's cause under a name that mentions no `AppError`.
                       """)
        // NOT a safety property — a pinned LIMIT. A bare `error.localizedDescription`
        // goes unreported because the matcher cannot tell a system message from a
        // forwarded taxonomy cause, and the app HAS a forwarding type. This
        // assertion records where the line currently sits so that moving it is a
        // deliberate act; it must never be read as "this shape is fine".
        XCTAssertTrue(causeHalfReads(in: "state = .error(message: error.localizedDescription)").isEmpty,
                      """
                      Rule 1's `localizedDescription` scope changed. It is deliberately narrowed to \
                      receivers naming an `AppError` CARRIER, which leaves a bare \
                      `catch { error.localizedDescription }` unreported — see KNOWN LIMITS. If this now \
                      fires, the widening is the change under review, not a passing detail.
                      """)
        XCTAssertTrue(causeHalfReads(in: "nonisolated var errorDescription: String? { appError.errorDescription }").isEmpty,
                      "Escape (a) broke — a LocalizedError conformance is a definition, not a render.")

        // 5. Escape (b): one decision written across two lines.
        let pairedLines = releaseCodeLines(in: """
        return error.recoverySuggestion
            ?? error.errorDescription
            ?? fallback
        """)
        let pairedIndex = try XCTUnwrap(pairedLines.firstIndex { !causeHalfReads(in: $0.text).isEmpty })
        XCTAssertTrue(
            Self.remedyBearingSources.contains(where: { statement(startingAt: pairedIndex, in: pairedLines).contains($0) }),
            "Escape (b) broke — a statement that already carries the remedy would be reported as cause-only."
        )

        // 6. Rule 2's label matcher: buttons yes, prose and keys no.
        XCTAssertTrue(drawsRetryLabel(#"Text("Retry") // xcstrings"#))
        XCTAssertTrue(drawsRetryLabel(#"Label(LocalizedStringResource("settings.stt.provider.tryAgain", defaultValue: "Try again"),"#))
        XCTAssertFalse(drawsRetryLabel(#"defaultValue: "Couldn't send — try again in a minute.""#),
                       "Label matcher fired on prose; Rule 2 would drown in false positives and get deleted.")
        XCTAssertFalse(drawsRetryLabel(#"LocalizedStringResource("settings.stt.provider.tryAgain")"#),
                       "A localisation key alone is not a control label.")

        // 6b. Rule 2's gate matching. The flags a view actually holds capitalise
        //     the `I`, so a case-sensitive match would report gated controls —
        //     this is the shape that was caught the hard way while writing it.
        XCTAssertTrue(namesGate(["isRetryable"], in: "if errorIsRetryable {"),
                      "Gate matching went case-sensitive; every `…IsRetryable` flag would be reported as ungated.")
        XCTAssertTrue(namesGate(["isRetryable"], in: "guard sendErrorIsRetryable(vm) else"))
        XCTAssertFalse(namesGate(["isRetryable"], in: "Button(action: onRetry)"),
                       "Gate matching accepted a declaration that consults nothing — Rule 2 could not fire.")

        // 7. Comment and DEBUG handling — both would silently hide findings.
        let regions = releaseCodeLines(in: """
        #if DEBUG
        Text(appError.errorDescription)
        #endif
        Text(appError.errorDescription)
        """)
        XCTAssertEqual(regions.filter { !causeHalfReads(in: $0.text).isEmpty }.count, 1,
                       "DEBUG-region handling broke — either a compiled-out line is reported or a shipping one is not.")
        XCTAssertTrue(causeHalfReads(in: strippingTrailingComment(#"foo() // Text(appError.errorDescription)"#)).isEmpty,
                      "Trailing-comment stripping broke — comments would be scanned as code.")
        XCTAssertFalse(causeHalfReads(in: strippingTrailingComment(#"Text(appError.errorDescription) // xcstrings"#)).isEmpty,
                      "Trailing-comment stripping ate real code — findings would vanish.")

        // 8. Escape (c) is ARM-scoped, and a catch-all gets NO vouching from its
        //    neighbours. This is the shape the guard was blind to: in a routing
        //    switch, a ±N-line window lets one remedy-bearing arm speak for
        //    every cause-only arm around it, `default:` included — so Rule 1
        //    could never see a MISSING arm.
        let routedSwitch = """
        private func message(for error: AppError) -> String {
            switch error {
            case .remoteAgentCertUntrusted:
                return CertificateTrustCopy.untrustedRefusalWithRemedy
            case .remoteAgentCertMismatch:
                return CertificateTrustCopy.pinMismatchRefusalWithRemedy
            case .remoteAgentCertKeyUnpinnable:
                return CertificateTrustCopy.keyUnpinnableRefusalWithRemedy
            default:
                return error.errorDescription ?? fallback
            }
        }
        """
        let routedLines = releaseCodeLines(in: routedSwitch)
        let routedDecls = declarations(in: routedLines)
        let routedHit = try XCTUnwrap(routedLines.first { !causeHalfReads(in: $0.text).isEmpty })
        let routedDecl = try XCTUnwrap(enclosingDeclaration(ofLine: routedHit.number,
                                                            indent: indent(of: routedHit.text),
                                                            in: routedDecls))
        XCTAssertTrue(
            routesCertificateVerdicts(near: routedHit.number, in: routedDecl, of: routedLines),
            "Escape (c) stopped recognising a switch that routes all three certificate families — every legitimate routing site in the app would be reported."
        )

        //    The SAME switch with ONE family's arm deleted. That verdict now
        //    falls through to `default:` and is rendered cause-only, which for an
        //    unpinnable key deletes "the certificate itself is fine and this
        //    device trusts it". The escape must not fire.
        let missingArmSwitch = """
        private func message(for error: AppError) -> String {
            switch error {
            case .remoteAgentCertUntrusted:
                return CertificateTrustCopy.untrustedRefusalWithRemedy
            case .remoteAgentCertMismatch:
                return CertificateTrustCopy.pinMismatchRefusalWithRemedy
            default:
                return error.errorDescription ?? fallback
            }
        }
        """
        let missingLines = releaseCodeLines(in: missingArmSwitch)
        let missingDecls = declarations(in: missingLines)
        let missingHit = try XCTUnwrap(missingLines.first { !causeHalfReads(in: $0.text).isEmpty })
        let missingDecl = try XCTUnwrap(enclosingDeclaration(ofLine: missingHit.number,
                                                             indent: indent(of: missingHit.text),
                                                             in: missingDecls))
        XCTAssertFalse(
            routesCertificateVerdicts(near: missingHit.number, in: missingDecl, of: missingLines),
            "A certificate family lost its arm and fell through to `default:`, and escape (c) still vouched for it — the exact blindness this rule was rewritten to remove."
        )
        //    …and this is WHY the rewrite was needed: the line-window proxy it
        //    replaced passes the very same missing arm.
        XCTAssertTrue(
            remedyWithinProximity(of: missingHit.number,
                                  lower: missingDecl.startLine,
                                  upper: missingDecl.endLine,
                                  of: missingLines),
            "The line-window proxy no longer passes the missing arm, so the comparison this rule's rationale rests on is stale — re-derive it before trusting either."
        )

        // 9. Catch-all classification. A catch-all wearing `case` clothes is
        //    still a catch-all: `case .some(let appError):` names no case.
        XCTAssertTrue(isCatchAllArmLabel("default:"))
        XCTAssertTrue(isCatchAllArmLabel("case .some(let appError):"),
                      "`case .some(let x):` is `case let x:` on an Optional — a catch-all. Treating it as enumerated would let it inherit its neighbours' vouching.")
        XCTAssertTrue(isCatchAllArmLabel("case let other:"))
        XCTAssertFalse(isCatchAllArmLabel("case .remoteAgentTimeout, .requestTimeout:"),
                       "An enumerated arm read as a catch-all would be judged on its whole switch instead of on itself.")
        XCTAssertFalse(isCatchAllArmLabel("case .some(.networkError), .some(.decodingError):"),
                       "`.some(...)` wrapping named cases is still enumerated.")

        // 10. Rule 2b's prose matcher, and the `??` fallback it must NOT report.
        XCTAssertTrue(invitesRetryInProse("Something went wrong. Try again."))
        XCTAssertTrue(invitesRetryInProse("Your message wasn't delivered. Open Conduck to retry."))
        XCTAssertFalse(invitesRetryInProse("Check the gateway is running and accessible from this device."),
                       "Prose matcher fired on a remedy that invites nothing; Rule 2b would drown in false positives and get deleted.")
        let coalescedLines = releaseCodeLines(in: """
        return error.errorDescription
            ?? String(localized: "Unexpected error. Try again.")
        """)
        let coalescedIndex = try XCTUnwrap(coalescedLines.firstIndex {
            stringLiterals(in: $0.text).contains(where: invitesRetryInProse)
        })
        XCTAssertTrue(
            isNilCoalescedFallback("Unexpected error. Try again.", at: coalescedIndex, in: coalescedLines),
            "A `?? \"… try again.\"` fallback read as an unconditional invitation — Rule 2b would report the shape the app uses deliberately for an untyped failure."
        )
        let unconditionalLines = releaseCodeLines(in: #"    return String(localized: "Unexpected error. Try again.")"#)
        XCTAssertFalse(
            isNilCoalescedFallback("Unexpected error. Try again.", at: 0, in: unconditionalLines),
            "An UNCONDITIONAL invitation read as a fallback — Rule 2b could not fire on the defect it exists for."
        )

        // 11. The hollow-gate read matcher. A raw `contains("isRetryable")` is
        //     satisfied by the doc comments AROUND a gate and by the gate's own
        //     name, so it passes a gate whose real reads have all been deleted.
        //     Both halves below are that failure, pinned.
        XCTAssertEqual(
            retryabilityReadLines(in: """
            /// Whether re-running can reach a different verdict. Rides
            /// `AppError.isRetryable`, resolved where the `AppError` still exists.
            var gatewayFailureIsRetryable: Bool {
                if case .failed(_, let retryable) = stageStatus[.gateway] ?? .pending { return retryable }
                return true
            }
            """),
            [],
            "A gate hollowed out to a constant, with only its comments and its own name still naming `isRetryable`, counted as reading the taxonomy. That is the false promise this check was rewritten to stop making."
        )
        XCTAssertFalse(
            retryabilityReadLines(in: "stageStatus[.gateway] = .failed(message, retryable: error?.isRetryable ?? true)").isEmpty,
            "A REAL read stopped counting — every cross-file gate would be reported as hollow and the rule would be switched off."
        )
    }

    // MARK: - Rule 1: the remedy half never goes missing

    func testNoShippingSiteRendersAnErrorCauseWithoutItsRemedy() throws {
        var violations: [String] = []
        var fileCount = 0
        var readSiteCount = 0

        for url in try shippingSwiftFiles() {
            fileCount += 1
            let path = relativePath(url)
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.contains("errorDescription") || source.contains("localizedDescription") else { continue }

            let lines = releaseCodeLines(in: source)
            let decls = declarations(in: lines)

            for (index, entry) in lines.enumerated() {
                // Escape (e): log text belongs to the logging guard.
                guard !isLogEmit(entry.text) else { continue }
                let reads = causeHalfReads(in: entry.text)
                guard !reads.isEmpty else { continue }
                readSiteCount += reads.count

                // Escape (b): the statement already carries the remedy.
                let whole = statement(startingAt: index, in: lines)
                if Self.remedyBearingSources.contains(where: { whole.contains($0) }) { continue }

                let declaration = enclosingDeclaration(ofLine: entry.number,
                                                       indent: indent(of: entry.text),
                                                       in: decls)
                // Escape (c): the enclosing decision routes the certificate
                // verdicts to a remedy-bearing source, NEARBY.
                if let declaration, routesCertificateVerdicts(near: entry.number, in: declaration, of: lines) {
                    continue
                }
                // Escape (f): hand-audited, with the argument recorded.
                let declarationName = declaration?.name ?? "<file scope>"
                if Self.causeOnlyExceptions.contains(where: { $0.path == path && $0.declaration == declarationName }) {
                    continue
                }

                for read in reads {
                    violations.append("\(path):\(entry.number) — `\(read.receiver).\(read.property)` in `\(declarationName)`")
                }
            }
        }

        // Extractor sanity: LOWER BOUNDS, never exact counts — an exact count
        // teaches contributors to bump a number instead of reading the rule.
        XCTAssertGreaterThan(fileCount, 200,
                             "Only \(fileCount) Swift files scanned; expected the whole project container. Fix this guard's path derivation before trusting it.")
        XCTAssertGreaterThan(readSiteCount, 5,
                             "Only \(readSiteCount) cause-half reads found anywhere; the scanner is probably not reading source. Fix it before trusting a clean result.")

        XCTAssertTrue(
            violations.isEmpty,
            """
            An `AppError`'s CAUSE is rendered without its REMEDY:
            \(violations.joined(separator: "\n"))

            Use `AppError.descriptionWithRecovery` — it returns cause AND remedy \
            as one string and DROPS the generic "Try again.", so a terminal \
            refusal never picks up a retry invitation it cannot honour.

            This is not a copy nit. Three certificate verdicts keep the part the \
            user must act on in `recoverySuggestion` alone: the pin-mismatch \
            family's "the connection may be intercepted", the untrusted-chain \
            family's three server-side routes to a trusted certificate, and the \
            unpinnable-key family's "the certificate itself is fine and this \
            device trusts it". Rendering `errorDescription` alone deletes all \
            three, and the surface has no second slot to reach them.

            If this surface genuinely cannot show both — a space-bound tile whose \
            full text is on its accessibility label — add it to \
            `causeOnlyExceptions` with the enclosing declaration and the reason, \
            and anchor the compensating control in \
            `compensatedCauseOnlySurfaces` so it cannot be deleted later.
            """
        )
    }

    // MARK: - Rule 2: no Retry control without a gate

    func testEveryRetryControlConsultsARetryabilityGate() throws {
        var unclassified: [String] = []
        var ungated: [String] = []
        var hollowGates: [String] = []
        var stale = Set(Self.retrySurfaces.keys)
        var controlCount = 0
        var decisionReadCount = 0

        for url in try shippingSwiftFiles() {
            let path = relativePath(url)
            let source = try String(contentsOf: url, encoding: .utf8)
            guard isViewCode(path: path, source: source) else { continue }

            let lines = releaseCodeLines(in: source)
            let sites = lines.filter { drawsRetryLabel($0.text) }
            guard !sites.isEmpty else { continue }
            controlCount += sites.count
            stale.remove(path)

            guard let gate = Self.retrySurfaces[path] else {
                unclassified.append("\(path):\(sites[0].number)")
                continue
            }
            guard case .gated(let tokens, let decidedIn, _) = gate else { continue }

            let decls = declarations(in: lines)
            for site in sites {
                let declaration = enclosingDeclaration(ofLine: site.number,
                                                       indent: indent(of: site.text),
                                                       in: decls)
                let body = declaration.map { text(of: $0, in: lines) } ?? source
                if !namesGate(tokens, in: body) {
                    ungated.append("\(path):\(site.number) — `\(declaration?.name ?? "<file scope>")` names none of \(tokens)")
                }
            }

            // A cross-file gate is only a gate while the file that COMPUTES it
            // still READS `AppError.isRetryable` — in code, not in a comment
            // describing the property it used to read.
            if let decidedIn {
                let decisionURL = projectContainerURL().appendingPathComponent(decidedIn)
                let decisionSource = (try? String(contentsOf: decisionURL, encoding: .utf8)) ?? ""
                let reads = retryabilityReadLines(in: decisionSource)
                decisionReadCount += reads.count
                if reads.isEmpty {
                    hollowGates.append("\(path) → \(decidedIn) performs no real read of `isRetryable`")
                }
            }
        }

        XCTAssertGreaterThan(controlCount, 8,
                             "Only \(controlCount) Retry controls found; the label matcher is probably broken. Fix it before trusting a clean result.")
        // Non-vacuity for the hollow-gate matcher: a `retryabilityReadLines`
        // that matched NOTHING would report every cross-file gate as intact.
        XCTAssertGreaterThan(decisionReadCount, 2,
                             "Only \(decisionReadCount) real `isRetryable` reads found across every `decidedIn` file; the read matcher is probably broken. Fix it before trusting a clean result.")

        XCTAssertTrue(
            unclassified.isEmpty,
            """
            View(s) draw a Retry control that this guard has never been told about:
            \(unclassified.joined(separator: "\n"))

            Decide, and record the decision in `retrySurfaces`:
              • `.gated(tokens:decidedIn:reason:)` — an `AppError` reaches this \
            control, so it must be withheld when `AppError.isRetryable` is false. \
            Certificate refusals, rejected credentials and wrong-endpoint verdicts \
            are all terminal: the same request reaches the identical answer, and \
            the spinner buries the sentence the user needed.
              • `.notErrorDriven(reason:)` — no `AppError` reaches it (it reloads \
            a local store, re-runs a download, re-opens a field). Say which.
            """
        )

        XCTAssertTrue(
            ungated.isEmpty,
            """
            Retry control(s) whose enclosing declaration consults no retryability gate:
            \(ungated.joined(separator: "\n"))

            Gate the control on `AppError.isRetryable` — directly, or through the \
            flag this file is registered as using. Where only a numeric code is at \
            hand, `AppError.from(errorCode:message:).isRetryable` reconstructs the \
            verdict; that is the same round-trip the Troubleshoot affordances use.
            """
        )

        XCTAssertTrue(
            hollowGates.isEmpty,
            """
            A registered gate is no longer computed from `AppError.isRetryable`:
            \(hollowGates.joined(separator: "\n"))

            The view still consults its flag, so nothing looks wrong at the call \
            site — but the flag now answers a different question, or none.
            """
        )

        XCTAssertTrue(
            stale.isEmpty,
            """
            `retrySurfaces` names file(s) that no longer draw a Retry control:
            \(stale.sorted().joined(separator: "\n"))

            Delete the entry. A registry that keeps rows for surfaces that no \
            longer exist stops being read, and then stops being maintained.
            """
        )
    }

    // MARK: - Rule 2b: no catch-all SPEAKS a retry it cannot honour

    /// Rule 2 can only see a SwiftUI control wearing the word "Retry". The
    /// surfaces that reach a driver, a wrist and a lock screen do not have one:
    /// CarPlay speaks its invitation, and a notification body prints it. This
    /// rule reads the invitation as PROSE, and it reads it where the defect
    /// actually forms — the catch-all arm of a switch over an `AppError`.
    ///
    /// A catch-all receives every verdict the author did not enumerate. The
    /// arms above it are copy choices made case by case (escape (d)); the
    /// catch-all is the one arm nobody chose the contents of, so an unconditional
    /// "Try again." there is a promise made on behalf of verdicts that were never
    /// considered — including the terminal ones added to `AppError` later. That
    /// is not hypothetical: it is how a spoken retry invitation reached the
    /// wheel's terminal refusals in the first place.
    func testNoCatchAllArmInvitesARetryOnAVerdictItNeverConsidered() throws {
        var violations: Set<String> = []
        var catchAllArms: Set<String> = []
        var invitationCount = 0

        for url in try shippingSwiftFiles() {
            let path = relativePath(url)
            let source = try String(contentsOf: url, encoding: .utf8)
            // Only switches that route the taxonomy are in scope. A catch-all
            // over anything else is not answering "may this be retried".
            guard source.contains("AppError") else { continue }

            let lines = releaseCodeLines(in: source)
            for declaration in declarations(in: lines) {
                guard text(of: declaration, in: lines).contains("AppError") else { continue }

                for arm in switchArms(in: declaration, of: lines) where arm.isCatchAll {
                    catchAllArms.insert("\(path):\(arm.labelLine)")
                    // Counted BEFORE the gate check, so this measures the
                    // matcher's REACH rather than the tree's cleanliness — a
                    // floor that falls to zero the moment the last violation is
                    // fixed would be a floor nobody can keep.
                    let armIsGated = namesGate(["isRetryable"], in: arm.text)

                    for (index, entry) in lines.enumerated()
                    where entry.number >= arm.labelLine && entry.number <= arm.upperLine {
                        // Escape (e): log text belongs to the logging guard.
                        guard !isLogEmit(entry.text) else { continue }
                        for literal in stringLiterals(in: entry.text) where invitesRetryInProse(literal) {
                            invitationCount += 1
                            // The arm already asks the taxonomy — the split
                            // `CarPlayRecordingService.speakErrorAndEnd` makes,
                            // and the shape this rule wants.
                            guard !armIsGated else { continue }
                            guard !isNilCoalescedFallback(literal, at: index, in: lines) else { continue }
                            violations.insert(
                                "\(path):\(entry.number) — `\(declaration.name)`'s catch-all says “\(literal)”"
                            )
                        }
                    }
                }
            }
        }

        // Non-vacuity, both halves: the arm scanner must be finding catch-alls,
        // and the prose matcher must be finding invitations. Either at zero
        // would report a clean tree for the wrong reason.
        XCTAssertGreaterThan(catchAllArms.count, 3,
                             "Only \(catchAllArms.count) catch-all arms found in `AppError`-routing declarations; the switch-arm scanner is probably broken. Fix it before trusting a clean result.")
        XCTAssertGreaterThan(invitationCount, 2,
                             "The prose matcher found \(invitationCount) retry invitations across every catch-all in the app; it is probably broken. Fix it before trusting a clean result.")

        XCTAssertTrue(
            violations.isEmpty,
            """
            A catch-all arm invites a retry for every verdict nobody enumerated:
            \(violations.sorted().joined(separator: "\n"))

            The arms above a catch-all are copy choices, each made for a named \
            case. The catch-all is not: it answers for the cases the author \
            never saw, and every terminal verdict added to `AppError` after this \
            switch was written inherits it silently. A spoken or printed "Try \
            again." there is a promise the request cannot keep — the same \
            request reaches the identical refusal, and on CarPlay the sentence \
            is all the driver gets.

            Split the arm on the taxonomy instead of assuming, the way \
            `CarPlayRecordingService.speakErrorAndEnd` does:

                if error.isRetryable {
                    phrase = String(localized: "Something went wrong. Try again.")
                } else {
                    phrase = String(localized: "Something went wrong. Check Conduck on your iPhone.")
                }

            A `?? "… try again."` FALLBACK is already fine and is not reported: \
            it renders only when no typed error stood behind the failure at all, \
            and unknown is not terminal.
            """
        )
    }

    // MARK: - Rule 3: the compensating controls survive

    func testCauseOnlySurfacesStillReachTheirRemedySomewhereElse() throws {
        var missing: [String] = []

        for surface in Self.compensatedCauseOnlySurfaces {
            for anchor in surface.anchors {
                let url = projectContainerURL().appendingPathComponent(anchor.path)
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    missing.append("\(surface.name) — \(anchor.path) is gone")
                    continue
                }
                let lines = releaseCodeLines(in: source)
                var scopeRange = 0..<lines.count
                var place = anchor.path
                if let name = anchor.declaration {
                    guard let declaration = declarations(in: lines).first(where: { $0.name == name }),
                          let start = lines.firstIndex(where: { $0.number >= declaration.startLine }),
                          let end = lines.lastIndex(where: { $0.number <= declaration.endLine }),
                          start <= end else {
                        missing.append("\(surface.name) — `\(name)` is gone from \(anchor.path)")
                        continue
                    }
                    scopeRange = start..<(end + 1)
                    place += " → `\(name)`"
                }

                let scope: String
                if let statementAnchor = anchor.withinStatementAt {
                    guard let index = scopeRange.first(where: { lines[$0].text.contains(statementAnchor) }) else {
                        missing.append("\(surface.name) — `\(statementAnchor)` is gone from \(place)")
                        continue
                    }
                    scope = statement(startingAt: index, in: lines)
                    place += " → the `\(statementAnchor)` statement"
                } else {
                    scope = scopeRange.map { lines[$0].text }.joined(separator: "\n")
                }

                for token in anchor.tokens where !scope.contains(token) {
                    missing.append("\(surface.name) — `\(token)` is gone from \(place)")
                }
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            """
            A cause-only surface lost the compensating control that justified it:
            \(missing.joined(separator: "\n"))

            These surfaces are allowed to show the cause alone ONLY because the \
            remedy stays reachable another way — a full-text accessibility label \
            on a tile too narrow to render it. With that gone the surface simply \
            drops the remedy, which for a pin mismatch means dropping "the \
            connection may be intercepted" entirely.

            Either restore the anchor, or show the remedy visibly and delete the \
            entry from `compensatedCauseOnlySurfaces`.
            """
        )
    }
}
