// SPDX-License-Identifier: Apache-2.0

// Conduck
// AdapterWireCode.swift
//
// The adapter-contract v1 (revision 1.3) stable error-code vocabulary — the
// `code` field of the OpenAI-shape error envelope. Clients key on the code;
// the prose `message` is free-form. Frozen by the public contract
// (conduck.com/setup/adapter/v1): adding a case requires a contract revision.
//
// IN the Watch target (pbxproj membership exception): `RemoteAgentClient` is
// watch-shared and its classifier references these types. The Watch UI still
// renders from the persisted primitive fields only.

import Foundation

/// One of the seven frozen wire codes. Constructed via `init(rawValue:)` from
/// the error body's `error.code` — an unknown string yields nil (treated as
/// no code; regex heuristics take over), so arbitrary server text can never
/// masquerade as a confident classification.
enum AdapterWireCode: String, Sendable, CaseIterable {
    case imageUnsupported = "image_unsupported"
    case modelNotFound = "model_not_found"
    case contextTooLong = "context_too_long"
    case imageTooLarge = "image_too_large"
    case overloaded = "overloaded"
    case upstreamTimeout = "upstream_timeout"
    case upstreamFailure = "upstream_failure"

    /// The internal `AppError` this code classifies to — same taxonomy the
    /// regex heuristics target, so downstream surfaces (banner, Diagnostics,
    /// the persisted `failureCode`) need no new cases.
    /// `nonisolated`: classification runs on URLSession delegate queues.
    nonisolated var appError: AppError {
        switch self {
        case .imageUnsupported: return .remoteAgentVisionUnsupported
        case .modelNotFound: return .remoteAgentModelUnavailable
        case .contextTooLong: return .remoteAgentContextTooLong
        case .imageTooLarge: return .remoteAgentImageTooLarge
        case .overloaded: return .remoteAgentRateLimited
        case .upstreamTimeout: return .remoteAgentTimeout
        case .upstreamFailure: return .remoteAgentServerError
        }
    }
}

/// A remote-agent failure whose classification is worth carrying past the
/// throw boundary: the mapped `AppError` PLUS the structured wire code when
/// the adapter sent one (nil = regex-heuristic classification). Thrown by
/// `RemoteAgentClient.decodeReply` for body-classified errors so the failure
/// writers can persist the classification on the message record;
/// catch it BEFORE `catch let error as AppError`.
struct ClassifiedRemoteAgentFailure: Error, Sendable {
    let appError: AppError
    let wireCode: AdapterWireCode?
}

extension ClassifiedRemoteAgentFailure: LocalizedError {
    /// Forward the mapped error's copy so a generic
    /// `error.localizedDescription` site shows the same string it would have
    /// shown for the bare `AppError` — never a type name.
    nonisolated var errorDescription: String? { appError.errorDescription }
    nonisolated var recoverySuggestion: String? { appError.recoverySuggestion }
}

extension Error {
    /// The `AppError` inside this error, unwrapping either carrier — for
    /// handlers that only need the taxonomy case and not the wire code.
    /// `nonisolated`: failure writers run on delegate queues and store actors
    /// alike.
    ///
    /// TWO CARRIERS, ONE TAXONOMY. `ClassifiedRemoteAgentFailure` is thrown by
    /// the body classifier both send paths share;
    /// `RemoteAgentSendFailure` is what the FOREGROUND client throws once it
    /// also carries the turn's reported metadata and timing. Neither is an
    /// `AppError`, and a handler that missed one would silently bucket a
    /// precisely classified failure as `.remoteAgentUnreachable` — which is how
    /// a user gets "check your server is running" for a rejected token.
    nonisolated var unwrappedAppError: AppError? {
        if let classified = self as? ClassifiedRemoteAgentFailure { return classified.appError }
        if let sendFailure = self as? RemoteAgentSendFailure { return sendFailure.appError }
        return self as? AppError
    }

    /// The adapter-contract wire code inside this error, from either carrier;
    /// nil when the classification came from the status map, the regex
    /// heuristics, or the transport. The twin of `unwrappedAppError`, and for
    /// the same reason: the two carriers must be asked as one.
    nonisolated var unwrappedWireCode: AdapterWireCode? {
        if let classified = self as? ClassifiedRemoteAgentFailure { return classified.wireCode }
        if let sendFailure = self as? RemoteAgentSendFailure { return sendFailure.wireCode }
        return nil
    }
}

extension ConversationStore.TurnFailureClassification {
    /// Build the persisted classification from an arbitrary thrown converse
    /// error — THE one mapping every failure writer uses, so no catch arm can
    /// drop the wire code by hand-building the fields: either carrier
    /// (`ClassifiedRemoteAgentFailure`, `RemoteAgentSendFailure`) contributes
    /// code + wire code, a bare `AppError` contributes its code, anything else
    /// buckets to `remoteAgentUnreachable`.
    ///
    /// Both halves read through the `Error` extensions above rather than
    /// downcasting here, so a third carrier is taught to the app in one place
    /// instead of two that can disagree.
    init(from error: Error, hadHistoryImages: Bool?) {
        let appError = error.unwrappedAppError ?? .remoteAgentUnreachable
        self.init(
            failureCode: appError.errorCode,
            wireCode: error.unwrappedWireCode?.rawValue,
            hadHistoryImages: hadHistoryImages
        )
    }
}
