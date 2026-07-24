// Conduck
// PairingPayloadExport.swift
//
// The INVERSE of `PairingPayload.parse`: builds the `conduck-setup:v1:<base64>`
// setup string FROM a configured gateway ref's effective stored config, so an
// already-paired device can re-show the same QR / paste string for a NEW device
// (e.g. an Android phone with a byte-compatible importer) without touching the
// server.
//
// CONTRACT OWNER: `spec.md` "Gateway Setup & Pairing" — "Pairing payload v1
// (LOCKED wire contract)". This emitter MUST reproduce the `conduck-connect`
// server wizard's python emission (the standalone `conduck-connect` repo's
// `conduck-connect.sh` `emit_payload`, `json.dumps(p, separators=(",", ":"))`,
// `ensure_ascii=True`)
// BYTE-FOR-BYTE for identical values, and its output MUST re-import cleanly
// through `PairingPayload.parse` — both are enforced by golden-vector +
// round-trip tests (`PairingPayloadExportTests`).
//
// Why hand-rolled and not `JSONEncoder`: `JSONEncoder` gives no stable
// insertion order, escapes "/" by default, and never emits `\uXXXX` for
// non-ASCII — three ways it would diverge from the python emission. The
// `pythonJSONString` encoder below matches python's `json.dumps` exactly:
// escape `" \` + control chars, `\uXXXX`-escape EVERY code unit outside the
// printable-ASCII range (0x20–0x7E, so U+007F and up), never escape "/".
//
// PRIVACY (non-negotiable — see the spec's Privacy & Security section): the produced string embeds
// the gateway bearer token + file-server credential. NEVER log / echo / persist
// it or any field. Fail closed: a `.bearer` gateway whose token read fails
// throws `.tokenUnavailable` rather than emitting a keyless (token-free) code
// that would silently strip auth — the exact inverse of the parser's
// keyless-never-inferred posture.
//
// Pure Foundation — compiles for iOS AND macOS (no UIKit/AppKit). NOT a Watch
// member (pairing export is an iPhone/iPad/Mac flow, like the import parser).

import Foundation

enum PairingPayloadExport {

    /// Why an export could not be produced. The UI maps these to copy; none
    /// carries payload content.
    enum ExportError: Error, Equatable {
        /// The ref is not QR-configurable (a hosted-model backend like
        /// OpenRouter — `pairingSupported == false`; its lane is set up via its
        /// own key flow, not pairing). Mirrors the parser's reject of
        /// `kind == "openrouter"`.
        case notExportable
        /// No stored URL (or, for a custom, no roster entry) — nothing to export.
        case notConfigured
        /// `.bearer` gateway but the token could not be read (empty slot OR a
        /// Keychain read failure). Fail closed — never emit a keyless code.
        case tokenUnavailable
    }

    // MARK: - Structured input (mirrors the wire contract's field set)

    /// The gateway half. `kind` maps to the wire `"kind"` string
    /// (`openclaw`/`hermes`/`custom`); a custom carries its user-given `name`.
    struct Gateway: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A pairing-supported built-in (openclaw / hermes). OpenRouter is
            /// unrepresentable here on purpose — the builder rejects it.
            case builtin(RemoteAgentBackend)
            case custom(name: String)

            /// The wire `"kind"` value.
            var wireValue: String {
                switch self {
                case .builtin(let backend): return backend.rawValue
                case .custom: return "custom"
                }
            }

            /// The `"name"` value — custom only (built-ins omit the key).
            var name: String? {
                if case .custom(let name) = self { return name }
                return nil
            }
        }

        let kind: Kind
        let url: String
        let authScheme: RemoteAgentAuthScheme
        /// Present iff `.bearer` (a keyless gateway omits the token key).
        let token: String?
        /// Optional model override — omitted when nil/empty (built-ins omit it).
        let model: String?
        /// Pinned SPKI SHA-256 hex — omitted unless self-signed.
        let certFP: String?
    }

    /// The optional agent file-server half.
    struct FileServer: Equatable, Sendable {
        let url: String
        let credential: String
        let certFP: String?
    }

    /// A complete v1 payload ready to serialize.
    struct Payload: Equatable, Sendable {
        let gateway: Gateway
        /// The `conduck-connect` wizard ALWAYS emits `transport` (top-level, a
        /// user path choice), so this emitter does too — a raw
        /// `PairingPayload.Transport` value. The parser tolerates unknown/absent
        /// values, but emitting it keeps byte-parity with the wizard.
        let transport: String
        /// Included iff the gateway has a configured file server (url +
        /// credential both present) — matches the wizard's `if FS_URL and
        /// FS_CRED`.
        let fileServer: FileServer?
    }

    // MARK: - Serialize (pure, byte-exact)

    /// The setup-string prefix (mirrors `PairingPayload.prefix` + `"v1:"`).
    static let stringPrefix = "conduck-setup:v1:"

    /// Serialize a payload to `conduck-setup:v1:<base64(minified JSON)>`. Pure +
    /// deterministic — the golden-vector tests assert exact equality against the
    /// bash wizard's output. Key order is FIXED to the wizard's python insertion
    /// order: gateway `{kind, url, auth, name?, token?, model?, certFP?}`;
    /// top-level `{v, gateway, transport, fileServer?}`; fileServer
    /// `{url, credential, certFP?}`.
    ///
    /// The `fileServer` block is emitted ONLY when the payload carries one whose
    /// `url` AND `credential` are both non-empty — matching the wizard's
    /// `if FS_URL and FS_CRED` python truthiness. A non-nil `FileServer` with an
    /// empty `url` or `credential` serializes byte-identically to `fileServer ==
    /// nil` (the block is omitted); the contract holds for every representable
    /// input, not just the ones `makePayload` happens to construct.
    static func serialize(_ payload: Payload) -> String {
        let gateway = payload.gateway

        var gatewayJSON = "{"
        gatewayJSON += "\"kind\":" + pythonJSONString(gateway.kind.wireValue)
        gatewayJSON += ",\"url\":" + pythonJSONString(gateway.url)
        gatewayJSON += ",\"auth\":" + pythonJSONString(gateway.authScheme.rawValue)
        if let name = gateway.kind.name, !name.isEmpty {
            gatewayJSON += ",\"name\":" + pythonJSONString(name)
        }
        if let token = gateway.token, !token.isEmpty {
            gatewayJSON += ",\"token\":" + pythonJSONString(token)
        }
        if let model = gateway.model, !model.isEmpty {
            gatewayJSON += ",\"model\":" + pythonJSONString(model)
        }
        if let certFP = gateway.certFP, !certFP.isEmpty {
            gatewayJSON += ",\"certFP\":" + pythonJSONString(certFP)
        }
        gatewayJSON += "}"

        var json = "{"
        json += "\"v\":1"
        json += ",\"gateway\":" + gatewayJSON
        json += ",\"transport\":" + pythonJSONString(payload.transport)
        if let fileServer = payload.fileServer,
           !fileServer.url.isEmpty, !fileServer.credential.isEmpty {
            var fileServerJSON = "{"
            fileServerJSON += "\"url\":" + pythonJSONString(fileServer.url)
            fileServerJSON += ",\"credential\":" + pythonJSONString(fileServer.credential)
            if let certFP = fileServer.certFP, !certFP.isEmpty {
                fileServerJSON += ",\"certFP\":" + pythonJSONString(certFP)
            }
            fileServerJSON += "}"
            json += ",\"fileServer\":" + fileServerJSON
        }
        json += "}"

        let base64 = Data(json.utf8).base64EncodedString()
        return stringPrefix + base64
    }

    /// Encode a Swift string as a JSON string literal byte-identical to python's
    /// `json.dumps(s, ensure_ascii=True)`: wrap in quotes; escape `"` `\` and the
    /// named control chars; `\uXXXX`-escape every UTF-16 code unit OUTSIDE the
    /// printable-ASCII range 0x20–0x7E (so U+007F and up, including surrogate
    /// pairs for astral chars — iterating `.utf16` yields those units directly);
    /// and DO NOT escape "/". Lowercase hex, 4 digits, matching python.
    static func pythonJSONString(_ string: String) -> String {
        var out = "\""
        for unit in string.utf16 {
            switch unit {
            case 0x22: out += "\\\""   // "
            case 0x5C: out += "\\\\"   // \
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            default:
                if unit < 0x20 || unit > 0x7E {
                    out += String(format: "\\u%04x", Int(unit))
                } else {
                    // Safe: 0x20–0x7E is always a valid scalar.
                    out.unicodeScalars.append(Unicode.Scalar(unit)!)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Build from stored config

    /// Assemble a `Payload` from a configured ref's effective stored config
    /// (`SettingsManager` + Keychain). Async — every read is an actor hop.
    ///
    /// Throws `.notExportable` for a hosted-model backend (OpenRouter),
    /// `.notConfigured` when the URL/roster is missing, `.tokenUnavailable` when
    /// a `.bearer` gateway's token can't be read (fail closed).
    ///
    /// Privacy: the token + credential are read into the returned value only;
    /// nothing is logged. The caller (`SettingsViewModel+PairingExport`) owns the
    /// value's short lifetime.
    static func makePayload(for ref: RemoteAgentRef) async throws -> Payload {
        let manager = SettingsManager.shared

        // kind (+ custom name / roster-stored model). OpenRouter and any other
        // non-pairable built-in are refused here — the parser rejects them on
        // the far side too, so an unexportable ref can never mint a code.
        let kind: Gateway.Kind
        let model: String?
        switch ref {
        case .builtin(let backend):
            guard RemoteAgentBackendRegistry.lookup(id: backend).pairingSupported else {
                throw ExportError.notExportable
            }
            kind = .builtin(backend)
            // Self-hosted built-ins (OpenClaw/Hermes) pick the model server-side
            // — it never rides the wire. (OpenRouter, the only built-in that
            // carries a model, is already rejected above.)
            model = nil
        case .custom(let id):
            guard let gateway = await manager.customGateway(id: id) else {
                throw ExportError.notConfigured
            }
            kind = .custom(name: gateway.name)
            // A custom's optional model override lives on the roster entry.
            model = gateway.model
        }

        guard let url = await manager.getRemoteAgentURL(for: ref) else {
            throw ExportError.notConfigured
        }

        let authScheme = await manager.getRemoteAgentAuthScheme(for: ref)
        let token: String?
        switch authScheme {
        case .bearer:
            guard let stored = await manager.getRemoteAgentToken(for: ref), !stored.isEmpty else {
                throw ExportError.tokenUnavailable
            }
            token = stored
        case .none:
            token = nil
        }

        let certFP = await manager.getRemoteAgentCertFingerprint(for: ref)

        // Transport: the stored per-ref hint when a pairing left one; otherwise a
        // safe default the parser round-trips. A pinned (self-signed) gateway →
        // `selfsigned`, so an importing device inherits the gateway pin for a
        // same-host file server (see `SettingsViewModel+PairingImport`
        // fileServer-pin logic); everything else → `public` (publicly-trusted
        // cert, no device-side install, no special import behavior). Chosen over
        // omitting the field so the wizard byte-parity and the file-lane pin
        // inheritance both hold for a hand-configured, never-paired gateway.
        let transport: String
        if let hint = await manager.getRemoteAgentTransportHint(for: ref), !hint.isEmpty {
            transport = hint
        } else if let certFP, !certFP.isEmpty {
            transport = PairingPayload.Transport.selfsigned.rawValue
        } else {
            transport = PairingPayload.Transport.publicCert.rawValue
        }

        let gateway = Gateway(
            kind: kind,
            url: url.absoluteString,
            authScheme: authScheme,
            token: token,
            model: model,
            certFP: certFP
        )

        // File server: emitted iff BOTH url + credential exist (the wizard's
        // `if FS_URL and FS_CRED`); its pin rides only when one is stored.
        var fileServer: FileServer?
        if let fsURL = await manager.getFileServerURL(for: ref),
           let credential = await manager.getFileServerCredential(for: ref), !credential.isEmpty {
            fileServer = FileServer(
                url: fsURL.absoluteString,
                credential: credential,
                certFP: await manager.getFileServerCertFingerprint(for: ref)
            )
        }

        return Payload(gateway: gateway, transport: transport, fileServer: fileServer)
    }

    /// Convenience: build + serialize in one hop. Throws the same `ExportError`s
    /// as `makePayload`.
    static func makeSetupCode(for ref: RemoteAgentRef) async throws -> String {
        serialize(try await makePayload(for: ref))
    }
}
