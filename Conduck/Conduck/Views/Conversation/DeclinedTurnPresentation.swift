// SPDX-License-Identifier: Apache-2.0

// Conduck
// DeclinedTurnPresentation.swift
//
// The ONE pure classifier behind every declined/failed-turn surface:
// the persistent inline error row under the failed user bubble AND the
// offscreen toast derive from the SAME presentation, so the two can never
// drift (row says "declined", toast says "couldn't" — never a mix).
//
// Copy is FROZEN by the adapter-standard v1.3 consensus. Vocabulary rule:
// **"gateway", never "model"** — the client cannot attribute a decline to the
// adapter vs the engine behind it, and blaming "the model" was measurably
// wrong (a vision-capable engine behind a text-only adapter).
//
// Confidence: a persisted WIRE code (`failureWireCode`, revision-1.3
// vocabulary, validated through `AdapterWireCode`) earns the confident copy
// ("declined" / "is blocking"); a regex-heuristic classification keeps the
// hedged copy ("couldn't use" / "may be blocking"). The poisoned variant
// additionally requires the dispatch-time fact that the failed request
// actually carried historical image parts.
//
// The `hint` is the ONE thing on this surface that does not come from the
// gateway's verdict: a turn that went out carrying attachments and no words is a
// fact about Conduck's own request, and an agent handed a file with nothing to
// answer can legitimately produce no text — which a gateway that refuses to
// return a blank reply reports as a server failure. It is a footnote, gated to
// the generic arm and to reply-production failures, and it says "some agents",
// never "your gateway".
//
// The generic arm renders CAUSE AND REMEDY (`descriptionWithRecovery`), not the
// cause alone: the failed-turn row is where a user meets a delivery failure, and
// half the taxonomy's failures are fixed somewhere the row is the only pointer
// to — a certificate the device refused is fixed on the SERVER, and a pinned
// key that disagreed with a trusted chain carries an interception warning that
// lives entirely in the remedy half. Rendering `errorDescription` alone dropped
// exactly the sentence the user has to act on.

import Foundation

/// Value describing how one failed user turn presents: title/body for the
/// inline row, the toast line, and which actions apply. Pure function of the
/// persisted record fields — no view or store dependencies (unit-testable).
struct DeclinedTurnPresentation: Equatable {
    enum Kind: Equatable {
        /// This turn's own photo was declined by the gateway.
        case photoDeclined(confident: Bool)
        /// A text-only turn failed with a photo-class error while the request
        /// carried (or may have carried) an earlier photo — the poisoned chat.
        case historyBlocked(confident: Bool)
        /// Everything else — generic delivery failure (legacy rows included).
        case generic
    }

    /// Whether this turn carried attachments and NO words — the one shape the
    /// client can describe from its own outbound request, with no guess about
    /// the gateway involved.
    ///
    /// Modelled as a type rather than a bare `Bool` because the call site's
    /// derivation is two facts folded together (attachments present, text empty
    /// after trimming), and a truth table reads wrong when both live in an
    /// argument named after only one of them.
    enum WordlessTurn: Equatable {
        /// The turn had words, or had no attachments — nothing to say.
        case absent
        /// Attachments, and not one character of user text.
        case present

        /// Derive from the persisted turn. Lives HERE rather than in the view so
        /// the trimming rule is testable — a view can't be asked what it decided.
        ///
        /// `attachmentCount` is EVERY attachment, server references included: a
        /// file uploaded to the file server is exactly the shape this describes,
        /// and it is the one the vision arms deliberately exclude (only an inline
        /// image can be declined for vision).
        ///
        /// Trimmed, so a stray space the user cannot see doesn't silence the
        /// footnote on a turn that is empty in every way that matters.
        static func of(text: String, attachmentCount: Int) -> WordlessTurn {
            guard attachmentCount > 0,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .absent }
            return .present
        }
    }

    let kind: Kind
    /// Inline row title.
    let title: String
    /// Inline row body.
    let body: String
    /// A FOOTNOTE under the body, or nil — never a diagnosis.
    ///
    /// Set only where the client knows something the gateway never told it: this
    /// turn went out carrying a file and no question. An agent handed a file with
    /// nothing to answer can legitimately produce no text at all, and a gateway
    /// that refuses to return a blank reply reports that as a server failure —
    /// which reaches the user as an infrastructure message naming the one thing
    /// they cannot fix.
    ///
    /// It says "some agents", never "your gateway", and it is gated to the
    /// failure classes where the gateway's own program answered and something
    /// went wrong producing a reply. Everything else — a refused certificate, a
    /// rejected token, a device that is offline — has nothing to do with whether
    /// the user typed a question, and a hint there sends someone to chase a fault
    /// that isn't theirs. Same rule the rest of this surface follows: the row
    /// never claims a cause it cannot see.
    let hint: String?
    /// Toast line (shown only when the failed row is offscreen).
    let toast: String
    /// "Try again" applies. Rides `AppError.isRetryable`, so the affordance
    /// exists only where re-firing the stored turn can reach a different
    /// verdict. A terminal refusal — a certificate this device won't accept, a
    /// rejected token, a URL that isn't an AI endpoint — sends the identical
    /// request into the identical refusal, so the button is a promise the app
    /// cannot keep; the row's remedy is the way out, not the retry. A legacy
    /// row with no persisted code stays retryable: unknown is not terminal.
    let offersRetry: Bool
    /// "Resend without photo" applies (photo-declined turns with other
    /// resendable content).
    let offersResendWithoutPhoto: Bool
    /// "Keep chatting without photos" applies (poisoned chat).
    let offersKeepChattingWithoutPhotos: Bool
    /// Diagnostics deep-link code when the failure class is troubleshootable.
    let troubleshootCode: Int?

    /// Build the presentation for a failed user turn.
    ///
    /// - Parameters:
    ///   - failureCode: persisted `AppError.errorCode` (nil = legacy row).
    ///   - failureWireCode: persisted adapter wire code string (validated
    ///     through `AdapterWireCode` here — unknown strings mean no code).
    ///   - turnHasOwnImages: the turn itself carries user-side photo
    ///     attachments.
    ///   - hadHistoryImages: dispatch-time fact — the failed request carried
    ///     historical image parts (nil = unknown → hedged poisoned copy).
    ///   - hasResendableNonPhotoContent: text / text-files / server-file refs
    ///     exist, so "Resend without photo" would send something.
    ///   - wordlessTurn: the turn carried attachments and no user text — the
    ///     `hint` precondition.
    ///   - ref: the gateway this turn was bound to. Optional and trailing so a
    ///     caller with no binding still compiles, but the generic arm's body IS
    ///     the reconstructed error's remedy, so without it a user who runs no
    ///     server is told to read their server's logs.
    static func classify(
        failureCode: Int?,
        failureWireCode: String?,
        turnHasOwnImages: Bool,
        hadHistoryImages: Bool?,
        hasResendableNonPhotoContent: Bool,
        wordlessTurn: WordlessTurn,
        ref: RemoteAgentRef? = nil
    ) -> DeclinedTurnPresentation {
        let wireCode = failureWireCode.flatMap(AdapterWireCode.init(rawValue:))
        let isVisionClass = failureCode == AppError.remoteAgentVisionUnsupported.errorCode
        // Reconstruct ONCE — the retry gate applies to EVERY kind, and the
        // generic arm below reuses the same value for its copy + Diagnostics
        // slot. Nil = legacy row: no taxonomy to gate on, so retry stays on.
        let reconstructed = failureCode.map { AppError.from(errorCode: $0, message: nil) }
        let offersRetry = reconstructed?.isRetryable ?? true

        if isVisionClass, turnHasOwnImages {
            let confident = wireCode == .imageUnsupported
            return DeclinedTurnPresentation(
                kind: .photoDeclined(confident: confident),
                title: confident
                    ? String(localized: "declinedTurn.photo.title.confident", defaultValue: "Photo declined")
                    : String(localized: "declinedTurn.photo.title.hedged", defaultValue: "No reply"),
                body: confident
                    ? String(localized: "declinedTurn.photo.body.confident",
                             defaultValue: "No reply was created. You can keep chatting with text, or try again after enabling photo support.")
                    : String(localized: "declinedTurn.photo.body.hedged",
                             defaultValue: "This gateway couldn't use the photo, so no reply was created."),
                // A photo sent with no caption IS a wordless turn, and this arm
                // is reached precisely when the gateway said why it failed. It
                // already names the cause and the fix, so a second, weaker guess
                // underneath would only dilute it.
                hint: nil,
                toast: confident
                    ? String(localized: "declinedTurn.photo.toast.confident", defaultValue: "This gateway declined the photo.")
                    : String(localized: "declinedTurn.photo.toast.hedged", defaultValue: "This gateway couldn't use the photo."),
                offersRetry: offersRetry,
                offersResendWithoutPhoto: hasResendableNonPhotoContent,
                offersKeepChattingWithoutPhotos: false,
                troubleshootCode: nil
            )
        }

        if isVisionClass, !turnHasOwnImages {
            // Poisoned chat. Confident copy needs BOTH the wire code and the
            // dispatch-time proof that the request carried an earlier photo;
            // anything less stays hedged ("may be") — the trigger is
            // deliberately error-class-specific (never size rejections).
            let confident = wireCode == .imageUnsupported && hadHistoryImages == true
            return DeclinedTurnPresentation(
                kind: .historyBlocked(confident: confident),
                title: confident
                    ? String(localized: "declinedTurn.history.title.confident", defaultValue: "Chat blocked by an earlier photo")
                    : String(localized: "declinedTurn.history.title.hedged", defaultValue: "This chat may be blocked by an earlier photo"),
                body: confident
                    ? String(localized: "declinedTurn.history.body.confident",
                             defaultValue: "This gateway rejected the message because this chat contains a photo. Keep chatting without earlier photos to continue this conversation.")
                    : String(localized: "declinedTurn.history.body.hedged",
                             defaultValue: "This text message failed with the same photo-related error. Keep chatting without earlier photos, or start a new chat."),
                // Same reason as the arm above — and this one is about an EARLIER
                // photo, so "you didn't type anything" would point at the wrong
                // turn entirely.
                hint: nil,
                toast: confident
                    ? String(localized: "declinedTurn.history.toast.confident", defaultValue: "An earlier photo is blocking this chat.")
                    : String(localized: "declinedTurn.history.toast.hedged", defaultValue: "An earlier photo may be blocking this chat."),
                offersRetry: offersRetry,
                offersResendWithoutPhoto: false,
                offersKeepChattingWithoutPhotos: true,
                troubleshootCode: nil
            )
        }

        // Generic (incl. legacy nil-code rows): the row still explains what it
        // can. A known code reuses the AppError's own static copy — cause AND
        // remedy, because the row is the whole story for this turn; a nil code
        // gets the neutral line. `descriptionWithRecovery` drops the generic
        // "Try again." rather than appending it, so a terminal refusal never
        // picks up a retry invitation the row deliberately no longer offers.
        // Troubleshoot rides along when Diagnostics can actually reason about
        // the class.
        let body = reconstructed?.descriptionWithRecovery(for: ref)
            ?? String(localized: "declinedTurn.generic.body", defaultValue: "This message wasn't delivered.")
        let hint: String? = (wordlessTurn == .present && Self.gatewayAnsweredAndFailed(reconstructed))
            ? String(localized: "declinedTurn.wordless.hint",
                     defaultValue: "This message had no text. Some agents reply with nothing when they get a file but no question — send it again with a question.")
            : nil
        return DeclinedTurnPresentation(
            kind: .generic,
            title: String(localized: "declinedTurn.generic.title", defaultValue: "No reply"),
            body: body,
            hint: hint,
            // The TOAST stays one line. It exists to be read in a glance when the
            // row is offscreen, and a second sentence is the one thing that
            // surface cannot afford; the hint waits on the row itself.
            toast: body,
            offersRetry: offersRetry,
            offersResendWithoutPhoto: false,
            offersKeepChattingWithoutPhotos: false,
            troubleshootCode: (reconstructed?.isTroubleshootable == true) ? failureCode : nil
        )
    }

    /// Whether the failure means *the gateway's own program answered and
    /// something went wrong while producing a reply* — the only class where an
    /// empty prompt is a plausible contributor, and therefore the only class the
    /// `hint` may appear under.
    ///
    /// A nil error is a LEGACY row with no persisted code, and it stays silent.
    /// `offersRetry` defaults such a row to retryable because re-firing costs
    /// nothing; a hint is a different promise — it points somewhere — and
    /// pointing on an unknown class is a guess.
    ///
    /// Timeouts are deliberately absent even though an agent given no
    /// instruction could plausibly spin: a timeout already tells a complete
    /// story, and every code added here widens what the footnote claims until it
    /// reads as noise on failures it has nothing to do with.
    ///
    /// Compared by `errorCode` against the cases themselves — never a literal
    /// number, which would silently rot if the taxonomy renumbers.
    private static func gatewayAnsweredAndFailed(_ error: AppError?) -> Bool {
        guard let code = error?.errorCode else { return false }
        return [
            AppError.apiFailure(message: "").errorCode,
            AppError.remoteAgentServerError.errorCode,
            AppError.remoteAgentUnexpectedStatus(status: nil).errorCode,
            AppError.remoteAgentServiceUnavailable.errorCode,
        ].contains(code)
    }
}
