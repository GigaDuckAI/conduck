// SPDX-License-Identifier: Apache-2.0

// Conduck
// StagedRemoteAgentToken.swift
//
// The gateway editor's token INTENT — what Save / Test Connection / certificate
// trust should use as the bearer credential, without the View ever holding a
// secret it didn't type. The editor is a buffered form: everything in its
// Connection section commits on Save and nowhere else, and the OpenRouter
// voice-key reuse has to obey the same contract (staged as intent, resolved to
// the actual key VM-side at commit/probe time — the raw key never enters a View).
//
// Resolution happens ONLY inside `SettingsViewModel` (Keychain reads live
// there); Views construct these cases and pass them down.

import Foundation

/// Which credential a gateway commit/probe should use.
enum StagedRemoteAgentToken: Equatable {
    /// Nothing typed this session — use the ref's saved Keychain token (a
    /// re-test / re-save of an already-configured gateway). For a keyless
    /// (`.none` auth scheme) gateway this resolves to "no token" by design.
    case stored

    /// The editor buffer's freshly-typed value. Non-empty by the time the
    /// caller passes it (an empty buffer means `.stored`).
    case typed(String)

    /// OpenRouter lane only: reuse the saved OpenRouter VOICE key
    /// (`stt.apiKey.openrouter-stt`) as the gateway token. COPY semantics —
    /// the two Keychain slots stay independent after the commit. Resolved
    /// from the Keychain at Save/Test time, never surfaced to the View.
    case reuseVoiceKey
}
