// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentBackendMetadata.swift
//
// Settings: Personal AI. UI-display + CAPABILITY layer for the
// built-in Personal AI gateways. Mirrors `STTProviderMetadata`'s separation
// of concerns: `RemoteAgentBackend` (data; locked raw values; persisted) vs.
// `RemoteAgentBackendMetadata` (display + capability policies; freely
// editable; not persisted).
//
// The capability policies (endpoint / authentication / model / pairing /
// file-transfer / trust / category) are what let the SHARED gateway editor
// (`RemoteAgentConfigBody`) and the Settings list render the right form per
// backend WITHOUT scattering `if backend == .openrouter` checks. OpenClaw and
// Hermes encode their existing behavior (user-typed URL, selectable auth,
// no model field, pairing + file-transfer supported); OpenRouter — a
// third-party HOSTED-MODEL backend — encodes a stripped, preconfigured form
// (fixed URL, locked bearer, required model, no pairing, no file transfer).
// Adding a future hosted preset (Groq / Together / Fireworks) is one more
// descriptor row, no editor churn.
//
// `RemoteAgentBackendRegistry.all` is the source of truth for which backends
// render. Hermes + OpenRouter are filtered behind their feature flags so the
// rows light up with zero Settings churn.

import Foundation

// MARK: - Capability policies

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

/// Where the gateway URL comes from.
enum RemoteAgentEndpointPolicy: Sendable, Equatable {
    /// User types the URL (OpenClaw / Hermes / custom). The editor shows the
    /// Gateway URL field.
    case editable
    /// App-supplied, authoritative URL the user never types (OpenRouter). The
    /// editor HIDES the URL field; `getRemoteAgentURL` returns this value and
    /// pairing/KVS cannot override it.
    case fixed(URL)
}

/// How auth is configured in the editor.
enum RemoteAgentAuthPolicy: Sendable, Equatable {
    /// Bearer/keyless toggle shown (default `.bearer`) — for a gateway that may
    /// run keyless on a private network (OpenClaw / Hermes / custom).
    case selectable
    /// Toggle hidden, scheme forced — OpenRouter is always bearer, never
    /// keyless, so the keyless toggle is noise.
    case locked(RemoteAgentAuthScheme)
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

/// TLS trust posture. Both cases REQUIRE system trust — a certificate this
/// device rejects is refused either way. They differ only in whether the user
/// may add a pin ON TOP of that, which can only ever narrow what is accepted.
enum RemoteAgentTrustPolicy: Sendable, Equatable {
    /// System trust required, plus an OPTIONAL user-typed fingerprint that
    /// narrows acceptance to one certificate — the user's own server
    /// (OpenClaw / Hermes / custom).
    case optionalUserPin
    /// System trust required, no pin UI (OpenRouter). A hosted provider rotates
    /// its leaf certificates, so letting a user pin one would arm a future break.
    case systemTrustOnly
}

/// How "Test Connection" forms its pass/fail VERDICT. Self-hosted gateways
/// require auth on `/v1/models`, so listing models IS the key check. But
/// OpenRouter's `/v1/models` is PUBLIC (returns 200 for any/no key), so it
/// cannot validate the key — its verdict must come from an authenticated
/// endpoint (`/v1/key`: 401 on a bad key, 200 on a good one). Model-suggestion
/// discovery is a SEPARATE concern that ALWAYS hits `/v1/models` (public
/// listing is fine there); this policy governs only the verdict probe.
enum RemoteAgentConnectionProbe: Sendable, Equatable {
    /// GET `/v1/models`; 2xx → valid (self-hosted/custom — auth-gated there).
    case modelList
    /// GET `<path>` (an auth-gated endpoint); 401 → invalid (OpenRouter → `/v1/key`).
    case authValidated(path: String)

    /// The body shape a PASSING probe must return. Derived from the probe case
    /// itself (rather than stored as an independent descriptor field) so a path
    /// and its expected envelope can never drift into an invalid pairing.
    ///
    /// A 2xx is NOT sufficient on its own: OpenClaw with its chat endpoint
    /// disabled serves the Control-UI **HTML at HTTP 200**, so a status-only
    /// verdict reads a dead gateway as "Connected" (the trap `conduck-connect`
    /// guards with its own `models_is_json` check).
    var expectedBodyShape: RemoteAgentProbeBodyShape {
        switch self {
        case .modelList: return .modelListEnvelope
        case .authValidated: return .keyEnvelope
        }
    }
}

/// The JSON envelope a Test Connection probe must find in a 2xx body before it
/// may report success.
///
/// **Deliberately STRICT — `data` only.** The tolerant shapes (`{"models":[…]}`,
/// a bare array) that `RemoteAgentClient.parseModelIDs` accepts for model
/// *discovery* must NOT be accepted for the verdict: LM Studio's NATIVE
/// `/api/v1/models` returns a `{"models":[…]}` envelope while its native chat
/// route is not `/v1/chat/completions`. Accepting `models` here would green-light
/// a base URL whose chat route doesn't exist — recreating the exact false-green
/// this check exists to kill. Discovery stays tolerant (it degrades to free-text);
/// the verdict does not.
enum RemoteAgentProbeBodyShape: Sendable, Equatable {
    /// OpenAI `/v1/models`: a top-level `data` ARRAY. An EMPTY array is
    /// structurally valid (the route exists) — the caller reports it as
    /// connected-but-advertising-no-models rather than failing.
    case modelListEnvelope
    /// OpenRouter `/v1/key`: a top-level `data` OBJECT.
    case keyEnvelope
}

/// Where a self-hosted backend's credentials actually live on the server — the
/// provenance answer for a user setting up BY HAND (the guided flow gets this
/// from `conduck-connect`, which reads these paths itself).
///
/// Only STABLE facts belong here: config paths, config keys, default ports,
/// health routes. Version-fragile material (the exact `docker compose`
/// invocation, systemd unit names, CLI subcommand shapes) is deliberately
/// EXCLUDED — it rots, and `docsURL` covers it.
struct GatewayCredentialSource: Sendable {
    /// The config file holding the runtime token (`~/.openclaw/openclaw.json`).
    let configPath: String
    /// The key inside that file (`gateway.auth.token`).
    let tokenKey: String
    /// The port the gateway listens on locally.
    let defaultPort: Int
    /// A liveness route the user can open in a browser to check the server.
    let healthPath: String
    /// What that liveness route actually proves — PER LANE, because it differs:
    /// OpenClaw's `/healthz` rides the always-on gateway and answers even with the
    /// AI endpoint off, but Hermes's `/v1/health` lives INSIDE the API server that
    /// `API_SERVER_ENABLED` gates, so "no answer" means the API server itself is
    /// off (the exact caveat below). A single shared sentence was true for OpenClaw
    /// and false for Hermes.
    let healthBody: LocalizedStringResource
    /// Who CREATED the token, and therefore what the user is actually doing at the
    /// config file — the one thing the help sheet cannot say generically. OpenClaw
    /// generates a token during onboarding, so the user is HUNTING for a value that
    /// already exists; Hermes generates nothing, so the user is SETTING one. Sending a
    /// Hermes user to "copy the value stored under this key" sends them looking for a
    /// key that isn't there.
    let tokenBody: LocalizedStringResource
    /// Lane-specific gotchas a hand-configuring user must know — e.g. that
    /// OpenClaw's compose `.env` token is only an onboarding SEED and can drift
    /// from the value the gateway actually checks.
    let caveats: [LocalizedStringResource]
}

// MARK: - Backend descriptor

/// UI metadata + capability policies for a single built-in Personal AI
/// gateway backend. Display strings are freely editable; the persistent raw
/// value lives on `RemoteAgentBackend.rawValue`.
struct RemoteAgentBackendMetadata: Identifiable, Sendable {
    /// The locked backend identity. `id` equals `RemoteAgentBackend.rawValue`
    /// so SwiftUI `Picker` rows can use it as their selection tag.
    let id: RemoteAgentBackend

    /// Human-readable name for picker rows + section headers.
    let displayName: String

    /// Port-hint shown in the URL field's footer ("port 18789"). Empty for a
    /// fixed-endpoint backend (the URL field — and its footer — is hidden).
    let defaultPortHint: String

    /// Setup docs URL — opened from the "Set up gateway" footer link.
    let docsURL: URL

    /// Placeholder inside the bearer-token / API-key field when empty.
    let tokenPlaceholder: String

    /// Row LABEL for the token field ("Bearer token" vs "API key").
    let tokenLabel: String

    /// The prefix this provider's keys are known to carry ("sk-or-"). Powers a
    /// SOFT hint on an auth failure — a truncated paste is the commonest cause of
    /// a 401 on a hosted lane, and the shape says so before the user goes hunting
    /// in a dashboard for a key that was fine.
    ///
    /// ADVISORY ONLY — never gates the probe or the button. A key with an
    /// unexpected shape still validates normally if the provider accepts it, so a
    /// future format change degrades to "no hint", never to a false rejection.
    /// `nil` for self-hosted backends: the user mints their own token, so there is
    /// no shape to expect.
    let tokenPrefixHint: String?

    /// Placeholder inside the URL `TextField` (full URL form). Unused when
    /// `endpoint == .fixed` (the field is hidden).
    let urlPlaceholder: String

    // Capability policies (drive the shared editor + the Settings list).

    /// Self-hosted agent vs third-party hosted model.
    let category: RemoteAgentCategory
    /// User-typed vs app-fixed URL.
    let endpoint: RemoteAgentEndpointPolicy
    /// Selectable bearer/keyless vs locked scheme.
    let authentication: RemoteAgentAuthPolicy
    /// Whether/how the `model` field is offered.
    let model: RemoteAgentModelPolicy
    /// TLS trust posture.
    let trust: RemoteAgentTrustPolicy
    /// Whether `conduck-connect` QR / paste-setup-code import applies.
    let pairingSupported: Bool
    /// Whether the agent file-server (file transfer) applies. Hosted-model
    /// backends have no working directory, so this is false (the composer's
    /// file-transfer affordances are suppressed).
    let fileTransferSupported: Bool

    /// How Test Connection forms its pass/fail verdict. Model-suggestion
    /// discovery is independent of this (always `/v1/models`).
    let connectionProbe: RemoteAgentConnectionProbe

    /// Where this backend's credentials live on the server — powers the editor's
    /// "Where do I find these?" help. `nil` for a hosted backend (nothing to find
    /// on a server you don't run) and for customs (we can't know their layout).
    let credentialSource: GatewayCredentialSource?

    /// The LIKELY cause + fix when the probe reaches the host but the AI route
    /// answers with the wrong shape (`.remoteAgentEndpointUnexpectedResponse`
    /// or `.remoteAgentEndpointWrongEnvelope`).
    /// Both flagship self-hosted backends ship their OpenAI endpoint DISABLED,
    /// which is the single commonest reason a hand-configured gateway fails.
    ///
    /// Worded as a likelihood, never an assertion: the same symptom can come
    /// from a reverse-proxy login page or a Cloudflare Access interstitial, so
    /// the error itself states the symptom and this only suggests the cause.
    let endpointDisabledRemedy: LocalizedStringResource?

    // MARK: Convenience accessors (keep editor/consumer call sites clean)

    /// The app-fixed URL, when this backend has one.
    var fixedURL: URL? {
        if case .fixed(let url) = endpoint { return url }
        return nil
    }

    /// True when the editor should HIDE the Gateway URL field.
    var hidesURLField: Bool { fixedURL != nil }

    /// The forced auth scheme, when the toggle is hidden.
    var lockedAuthScheme: RemoteAgentAuthScheme? {
        if case .locked(let scheme) = authentication { return scheme }
        return nil
    }

    /// True when the editor should SHOW the bearer/keyless toggle.
    var showsAuthToggle: Bool { lockedAuthScheme == nil }

    /// True when the editor should SHOW the model field for a built-in.
    var showsModelField: Bool { model != .unsupported }

    /// True when a model MUST be set.
    var requiresModel: Bool { model == .required }

    /// The path Test Connection GETs to decide pass/fail. `.modelList` →
    /// `/v1/models`; `.authValidated` → its auth-gated path (`/v1/key`).
    var verdictProbePath: String {
        switch connectionProbe {
        case .modelList: return Constants.remoteAgentModelsProbePath
        case .authValidated(let path): return path
        }
    }

    /// The JSON envelope a 2xx probe body must carry to count as a PASS.
    var verdictBodyShape: RemoteAgentProbeBodyShape { connectionProbe.expectedBodyShape }

    /// True when Test Connection validates the key against a dedicated auth
    /// endpoint (rather than `/v1/models`) — drives the "API key valid" success
    /// label (the probe proves auth, NOT funding or model usability).
    var probesAuthDirectly: Bool {
        if case .authValidated = connectionProbe { return true }
        return false
    }
}

/// Registry of built-in Personal AI gateway backends. Hermes + OpenRouter are
/// gated behind their feature flags — flipping a flag lights up the row with
/// no Settings code changes.
enum RemoteAgentBackendRegistry {

    /// Master list of every built-in backend the registry knows about. `.all`
    /// filters by feature flag. Tests use this list to assert ID-parity with
    /// `RemoteAgentBackend.allCases`.
    static let allKnown: [RemoteAgentBackendMetadata] = [
        RemoteAgentBackendMetadata(
            id: .openclaw,
            displayName: "OpenClaw",
            defaultPortHint: "port \(Constants.openclawDefaultPort)",
            docsURL: URL(string: "https://docs.openclaw.ai/start/getting-started")!,
            tokenPlaceholder: "Bearer token",
            tokenLabel: "Bearer token",
            // Self-hosted: the user mints the token, so there is no shape to expect.
            tokenPrefixHint: nil,
            // NOT a `.local`/internal-port form. `conduck-connect` exposes the
            // gateway over HTTPS and prints a routable host (typically a tailnet
            // MagicDNS name, no port); meanwhile our own `HostReachabilityClass`
            // classifies a `.local` host as needing the iOS Local Network grant
            // AND unreachable from a standalone Watch. A `.local:18789` example
            // therefore taught the one topology the product steers away from.
            // The port fact now lives in `credentialSource` (the "Where do I find
            // these?" help), which is also what finally consumes `defaultPortHint`.
            urlPlaceholder: "https://your-gateway.example.com",
            category: .selfHostedAgent,
            endpoint: .editable,
            authentication: .selectable,
            model: .unsupported,
            trust: .optionalUserPin,
            pairingSupported: true,
            fileTransferSupported: true,
            connectionProbe: .modelList,
            credentialSource: GatewayCredentialSource(
                configPath: "~/.openclaw/openclaw.json",
                tokenKey: "gateway.auth.token",
                defaultPort: Constants.openclawDefaultPort,
                healthPath: "/healthz",
                healthBody: LocalizedStringResource(
                    "gateway.credentialSource.openclaw.healthBody",
                    defaultValue: "To check the server is alive at all, open this route in a browser — it answers even when the AI endpoint is switched off:"
                ),
                tokenBody: LocalizedStringResource(
                    "gateway.credentialSource.openclaw.tokenBody",
                    defaultValue: "OpenClaw generated a token for you when you installed it — you don't have to invent one. Open this file on your server and copy the value stored under this key — the real secret, and if it shows a ${…} placeholder, paste the value it points to, not the placeholder:"
                ),
                caveats: [
                    // The trap `conduck-connect` calls out explicitly: the compose
                    // `.env` value is only an onboarding SEED and can drift from the
                    // token the gateway actually checks. Copying from the obvious
                    // place yields a plausible token that silently fails auth.
                    LocalizedStringResource(
                        "gateway.credentialSource.openclaw.caveat.envSeed",
                        defaultValue: "Don't copy the token from the Docker .env file — that value is only a setup seed and can drift. Use gateway.auth.token in openclaw.json."
                    )
                ]
            ),
            endpointDisabledRemedy: LocalizedStringResource(
                "gateway.endpointDisabled.openclaw",
                defaultValue: "OpenClaw ships with its OpenAI chat endpoint switched OFF. Turn on gateway.http.endpoints.chatCompletions.enabled on your server, then restart the gateway."
            )
        ),
        RemoteAgentBackendMetadata(
            id: .hermes,
            displayName: "Hermes",
            defaultPortHint: "port \(Constants.hermesDefaultPort)",
            docsURL: URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/quickstart")!,
            tokenPlaceholder: "Bearer token",
            tokenLabel: "Bearer token",
            // Self-hosted: the user mints the token, so there is no shape to expect.
            tokenPrefixHint: nil,
            urlPlaceholder: "https://your-gateway.example.com",
            category: .selfHostedAgent,
            endpoint: .editable,
            authentication: .selectable,
            model: .unsupported,
            trust: .optionalUserPin,
            pairingSupported: true,
            fileTransferSupported: true,
            connectionProbe: .modelList,
            credentialSource: GatewayCredentialSource(
                configPath: "~/.hermes/.env",
                tokenKey: "API_SERVER_KEY",
                defaultPort: Constants.hermesDefaultPort,
                healthPath: "/v1/health",
                healthBody: LocalizedStringResource(
                    "gateway.credentialSource.hermes.healthBody",
                    defaultValue: "To check the server is alive at all, open this route in a browser. If this route doesn't answer, the API server itself is off — see the note below:"
                ),
                tokenBody: LocalizedStringResource(
                    "gateway.credentialSource.hermes.tokenBody",
                    defaultValue: "Hermes does not generate a token — you choose it yourself. Open this file on your server and copy the value stored under this key; if the key isn't there, add it with a long random value of your own and restart Hermes."
                ),
                caveats: [
                    LocalizedStringResource(
                        "gateway.credentialSource.hermes.caveat.apiServer",
                        defaultValue: "Hermes's setup wizard does NOT turn its API server on. Set API_SERVER_ENABLED=true in the same file, then restart Hermes."
                    )
                ]
            ),
            endpointDisabledRemedy: LocalizedStringResource(
                "gateway.endpointDisabled.hermes",
                defaultValue: "Hermes ships with its OpenAI API server switched OFF. Set API_SERVER_ENABLED=true in ~/.hermes/.env, then restart Hermes."
            )
        ),
        RemoteAgentBackendMetadata(
            id: .openrouter,
            displayName: "OpenRouter",
            defaultPortHint: "",
            docsURL: URL(string: "https://openrouter.ai/docs/quickstart")!,
            tokenPlaceholder: "sk-or-…",
            tokenLabel: "API key",
            tokenPrefixHint: "sk-or-",
            urlPlaceholder: Constants.openRouterBaseURLString,
            category: .hostedModel,
            endpoint: .fixed(URL(string: Constants.openRouterBaseURLString)!),
            authentication: .locked(.bearer),
            model: .required,
            trust: .systemTrustOnly,
            pairingSupported: false,
            fileTransferSupported: false,
            connectionProbe: .authValidated(path: Constants.openRouterKeyProbePath),
            // Hosted: there is no server of yours to find a token on (the key comes
            // from the OpenRouter dashboard — already linked in the Connection
            // footer), and no endpoint of yours that could be switched off.
            credentialSource: nil,
            endpointDisabledRemedy: nil
        ),
    ]

    /// The backends to render right now. Hermes hides until
    /// `FeatureFlags.remoteAgentHermesEnabled`; OpenRouter until
    /// `FeatureFlags.remoteAgentOpenRouterEnabled`.
    static var all: [RemoteAgentBackendMetadata] {
        allKnown.filter { metadata in
            switch metadata.id {
            case .openclaw: return true
            case .hermes: return FeatureFlags.remoteAgentHermesEnabled
            case .openrouter: return FeatureFlags.remoteAgentOpenRouterEnabled
            }
        }
    }

    /// Look up metadata for a backend. Falls back to OpenClaw on miss (matches
    /// `STTProviderRegistry`'s default-fallback posture — keeps the UI
    /// renderable on a forward-compat raw value).
    static func lookup(id: RemoteAgentBackend) -> RemoteAgentBackendMetadata {
        allKnown.first(where: { $0.id == id }) ?? allKnown[0]
    }
}
