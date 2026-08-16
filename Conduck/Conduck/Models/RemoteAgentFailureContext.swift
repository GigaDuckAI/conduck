// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentFailureContext.swift
//
// The CAPABILITY snapshot an error message needs before its remedy can be
// true. `AppError.recoverySuggestion` used to be written for one lane — a
// self-hosted agent server the user administers — and handed verbatim to every
// other. A user on the hosted lane operates no server, so "check the gateway
// logs" and "check the Gateway URL" describe a machine that does not exist.
//
// The dispatch is on CAPABILITY, never on hosted-vs-self-hosted, because the
// two disagree. `.remoteAgentModelUnavailable` and `.remoteAgentContextTooLong`
// tell the user to change the model — correct on the hosted lane, and WRONG on
// OpenClaw/Hermes, which declare `model == .unsupported` and whose model field
// Conduck hides entirely. A lane flag gets exactly those two backwards; the
// model POLICY gets them right. So each arm asks the narrowest question it can:
//
//   `hidesURLField`        — is there a server of the user's at the other end?
//                            (false for every lane where the user typed a URL)
//   `model`                — can the user change the model from inside Conduck?
//   `fileTransferSupported`— is there a working directory / file lane at all?
//   `category`             — the Settings-list grouping, for copy that needs it
//
// Home of `RemoteAgentCategory` + `RemoteAgentModelPolicy` (the descriptor's own
// capability vocabulary) because THIS file is a member of the Watch target and
// `RemoteAgentBackendMetadata.swift` is not — `AppError` is shared, so the types
// its copy dispatches on have to be shared too. `RemoteAgentBackendRegistry`
// remains the source of truth for the built-in descriptors; the mapping below is
// locked against it field-by-field in `RemoteAgentRecoveryCopyLaneTests`, so a
// descriptor edit that this file does not follow fails the suite instead of
// shipping copy for the wrong machine.

import Foundation

// MARK: - Capability policies (shared vocabulary)

/// Whether a backend is the user's OWN self-hosted agent server or a
/// third-party hosted-model service. Drives the Settings list section
/// ("Your AI gateways" vs "Hosted models") + the never-auto-default posture.
enum RemoteAgentCategory: Sendable, Equatable {
    /// OpenClaw / Hermes / custom gateways — the user's own always-on server.
    case selfHostedAgent
    /// OpenRouter — a third-party cloud aggregator. Data goes direct to the
    /// provider; surfaced under a distinct "Hosted models" section.
    case hostedModel
}

/// Whether the backend takes an explicit `model` field on the wire.
enum RemoteAgentModelPolicy: Sendable, Equatable {
    /// Built-in agents pick their own model server-side (OpenClaw / Hermes) —
    /// the model field is hidden and `model` is omitted from the request.
    case unsupported
    /// User may set one (custom gateways like Ollama/vLLM).
    case optional
    /// Must be set (OpenRouter requires a `model` in every request).
    case required
}

// MARK: - The snapshot

/// The capability facts a failure message may consult. A value type rather than
/// the descriptor itself so the Watch — which has `RemoteAgentRef` and
/// `RemoteAgentBackend` but not the app's descriptor registry — can resolve one.
struct RemoteAgentFailureContext: Sendable, Equatable {
    let category: RemoteAgentCategory
    let model: RemoteAgentModelPolicy
    /// The app owns the endpoint and the user never typed a URL. The honest
    /// proxy for "there is no server of yours at the other end": a lane with a
    /// fixed URL is one the user did not stand up and cannot restart, read logs
    /// on, or put a proxy in front of.
    let hidesURLField: Bool
    let fileTransferSupported: Bool

    /// True when the user administers whatever answers at the other end — or at
    /// minimum chose its address, which is the part every "check the address"
    /// remedy actually needs. Custom refs land here by construction: they are
    /// heterogeneous (Ollama, LiteLLM, vLLM, a home-built adapter), so no copy
    /// may assume more about them than "you typed this URL".
    var userSuppliedTheAddress: Bool { !hidesURLField }

    /// True when Conduck shows the user a model field they can act on. FALSE for
    /// OpenClaw/Hermes, where the model is a server-side decision and the field
    /// is hidden — the single fact that makes "pick a different model" a dead
    /// end rather than a remedy.
    var userCanChooseModel: Bool { model != .unsupported }

    /// The context to assume when no ref is in hand. Deliberately the
    /// self-hosted shape: it reproduces the wording every surface shipped before
    /// capability dispatch existed, so a call site that cannot name the failing
    /// AI degrades to today's copy rather than to something new and untested.
    static let neutral = RemoteAgentFailureContext(
        category: .selfHostedAgent,
        model: .optional,
        hidesURLField: false,
        fileTransferSupported: true
    )

    /// Resolve the context for the ref that failed. `nil` → `.neutral`.
    static func resolve(_ ref: RemoteAgentRef?) -> RemoteAgentFailureContext {
        guard let ref else { return .neutral }
        switch ref {
        case .builtin(let backend):
            return backend.failureContext
        case .custom:
            return .custom
        }
    }

    /// Every user-defined OpenAI-compatible endpoint. HETEROGENEOUS by
    /// construction — it could be Ollama on a desk, a LiteLLM router, or a
    /// hosted provider someone pointed a custom row at — so the only facts
    /// asserted are the two Conduck can prove: the user typed the address, and
    /// the model field is theirs to set. `fileTransferSupported` is true to match
    /// `DiagnosticsRunner.isFileCapable`, which treats customs as file-capable
    /// because an OpenAI-compatible server MAY carry file tools.
    static let custom = RemoteAgentFailureContext(
        category: .selfHostedAgent,
        model: .optional,
        hidesURLField: false,
        fileTransferSupported: true
    )
}

extension RemoteAgentBackend {
    /// The capability snapshot for a built-in. Mirrors
    /// `RemoteAgentBackendRegistry.lookup(id:)` field-for-field; the parity is
    /// test-locked rather than expressed as a call, because this property has to
    /// resolve on the Watch, where the registry is not compiled in.
    var failureContext: RemoteAgentFailureContext {
        switch self {
        case .openclaw, .hermes:
            return RemoteAgentFailureContext(
                category: .selfHostedAgent,
                model: .unsupported,
                hidesURLField: false,
                fileTransferSupported: true
            )
        case .openrouter:
            return RemoteAgentFailureContext(
                category: .hostedModel,
                model: .required,
                hidesURLField: true,
                fileTransferSupported: false
            )
        }
    }
}

extension RemoteAgentRef {
    /// Convenience for the call sites that hold a ref and want the copy for it.
    var failureContext: RemoteAgentFailureContext { RemoteAgentFailureContext.resolve(self) }
}
