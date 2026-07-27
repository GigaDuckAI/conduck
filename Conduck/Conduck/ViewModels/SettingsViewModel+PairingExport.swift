// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+PairingExport.swift
//
// The reveal-side companion to `SettingsViewModel+PairingImport`: prepares the
// `conduck-setup:v1` setup code for an already-configured gateway (so a NEW
// device can scan it) and runs a non-mutating live preflight so the sheet can
// warn when the gateway isn't answering right now. The build itself lives in the
// pure `PairingPayloadExport`; these thin MainActor entry points map its typed
// errors to UI outcomes and reuse the editor's Test Connection machinery.
//
// PRIVACY (non-negotiable — spec.md "Privacy & Security"): the prepared string embeds
// the gateway token + file-server credential. It is returned to the sheet and
// held there only while revealed — NEVER logged, echoed, or written to disk.
// The preflight reads the token to authenticate its probe but never surfaces it;
// failure collapses to a boolean "didn't answer", carrying no payload content.

import Foundation

/// Outcome of preparing a setup code for reveal.
enum PairingExportPreparation: Equatable {
    /// The code is ready to render as a QR / paste string.
    case ready(code: String)
    /// The code could not be built — the sheet stays blank and explains why.
    case failed(PairingExportFailure)
}

/// Why a setup code could not be prepared. Maps `PairingPayloadExport.ExportError`
/// to a UI-facing case; none carries payload content.
enum PairingExportFailure: Equatable {
    /// `.bearer` gateway whose token couldn't be read (Keychain locked / empty).
    /// Fail-closed — never reveal a keyless code that would silently drop auth.
    case tokenUnavailable
    /// The gateway isn't fully configured (no stored URL / roster entry).
    case notConfigured
    /// The ref isn't QR-configurable (a hosted-model backend like OpenRouter).
    /// The entry point guards this out; the guard here is defense in depth.
    case notExportable
    case unknown
}

/// Result of the non-mutating live preflight probe.
enum PairingExportPreflight: Equatable {
    /// The gateway answered — the code should work on a device that can reach it.
    case reachable
    /// The gateway didn't answer just now (offline, unreachable, or an error) —
    /// the sheet shows a soft warning but still lets the user reveal.
    case unreachable
}

extension SettingsViewModel {

    /// Build the exportable setup code for `ref` from its effective stored config
    /// (`SettingsManager` + Keychain). Fail-closed on an unreadable bearer token.
    /// Privacy: the returned string embeds the token — the caller owns its short
    /// lifetime; this method logs nothing.
    func preparePairingExportCode(for ref: RemoteAgentRef) async -> PairingExportPreparation {
        do {
            let code = try await PairingPayloadExport.makeSetupCode(for: ref)
            return .ready(code: code)
        } catch let error as PairingPayloadExport.ExportError {
            switch error {
            case .tokenUnavailable: return .failed(.tokenUnavailable)
            case .notConfigured: return .failed(.notConfigured)
            case .notExportable: return .failed(.notExportable)
            }
        } catch {
            return .failed(.unknown)
        }
    }

    /// Probe the gateway with its PERSISTED config (`GET /v1/models` via the
    /// shared Test Connection path) so the sheet can warn when the gateway isn't
    /// answering. NON-mutating: touches no `@Published` validation state (unlike
    /// `retestRemoteAgent`) — a reveal must not rewrite the editor's status row.
    /// Never blocks the reveal; any failure (incl. an untrusted cert) → `.unreachable`.
    func preflightPairingExport(for ref: RemoteAgentRef) async -> PairingExportPreflight {
        guard let url = await SettingsManager.shared.getRemoteAgentURL(for: ref) else {
            return .unreachable
        }
        let authScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)
        let token: String
        if authScheme.requiresToken {
            token = await SettingsManager.shared.getRemoteAgentToken(for: ref) ?? ""
        } else {
            token = ""
        }
        let fingerprint = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: ref)
        // Status-map carrier — a custom rides `.openclaw`, matching
        // `runPairingGatewayTest`. Every pairable gateway probes `/v1/models`
        // with the model-list envelope (the defaults), so no descriptor lookup.
        let carrierBackend: RemoteAgentBackend = {
            if case .builtin(let backend) = ref { return backend }
            return .openclaw
        }()
        do {
            let outcome = try await RemoteAgentClient.shared.testConnection(
                backend: carrierBackend,
                url: url,
                token: token,
                authScheme: authScheme,
                fingerprint: fingerprint
            )
            // `.untrustedCert` (isSuccess == false) → warn: a device without the
            // pin may fail, so the code "may not work" — reveal anyway.
            return outcome.isSuccess ? .reachable : .unreachable
        } catch {
            return .unreachable
        }
    }
}
