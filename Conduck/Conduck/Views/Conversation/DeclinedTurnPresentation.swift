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

    let kind: Kind
    /// Inline row title.
    let title: String
    /// Inline row body.
    let body: String
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
    static func classify(
        failureCode: Int?,
        failureWireCode: String?,
        turnHasOwnImages: Bool,
        hadHistoryImages: Bool?,
        hasResendableNonPhotoContent: Bool
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
        let body = reconstructed?.descriptionWithRecovery
            ?? String(localized: "declinedTurn.generic.body", defaultValue: "This message wasn't delivered.")
        return DeclinedTurnPresentation(
            kind: .generic,
            title: String(localized: "declinedTurn.generic.title", defaultValue: "No reply"),
            body: body,
            toast: body,
            offersRetry: offersRetry,
            offersResendWithoutPhoto: false,
            offersKeepChattingWithoutPhotos: false,
            troubleshootCode: (reconstructed?.isTroubleshootable == true) ? failureCode : nil
        )
    }
}
