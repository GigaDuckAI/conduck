// SPDX-License-Identifier: Apache-2.0

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
// "For identical values" is what makes the file lane's delivery properties
// (`folderCapable`, `autoDeliver`, `filenamePolicy`) compatible with that
// parity claim: the wizard states none of them, this emitter omits every key it
// has no value for, and a payload stating none serializes to exactly the bytes
// the wizard produces. The keys are additions under the contract's
// compatible-addition rule — added, never repurposed.
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
    }

    /// The optional agent file-server half.
    struct FileServer: Equatable, Sendable {
        let url: String
        let credential: String
        /// The server's nested-PUT verdict, stated only when this device measured it
        /// and measured it FALSE (see `makePayload`). Nil omits the key, which the
        /// parser reads as "unstated" — the importing device keeps its own default
        /// and settles the question with its own probe.
        let folderCapable: Bool?
        /// The gateway's automatic-delivery permission — stated only to RESTRICT
        /// (`false`). Nil omits the key.
        let autoDeliver: Bool?
        /// The gateway's delivered-filename policy token, stated only when it is not
        /// the app's default. Nil omits the key.
        let filenamePolicy: String?

        /// Explicit memberwise init so the three delivery properties default to nil
        /// — the golden vectors are written against the two-field block and must
        /// keep serializing to the same bytes, which is the whole point of pinning
        /// them; a synthesized memberwise init cannot default a `let`.
        init(
            url: String,
            credential: String,
            folderCapable: Bool? = nil,
            autoDeliver: Bool? = nil,
            filenamePolicy: String? = nil
        ) {
            self.url = url
            self.credential = credential
            self.folderCapable = folderCapable
            self.autoDeliver = autoDeliver
            self.filenamePolicy = filenamePolicy
        }
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
    /// order: gateway `{kind, url, auth, name?, token?, model?}`; top-level
    /// `{v, gateway, transport, fileServer?}`; fileServer `{url, credential,
    /// folderCapable?, autoDeliver?, filenamePolicy?}`.
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
            // The three delivery properties are OMITTED when nil, never emitted as
            // `null`: the contract's conditional fields are absent rather than null
            // (`PAYLOAD.md`), and the parser reads absence as "unstated, keep the
            // importing device's own default". Omission is also what keeps byte
            // parity with the wizard, which states none of them — a payload that
            // carries no delivery properties serializes to exactly the bytes the
            // golden vectors pin.
            if let folderCapable = fileServer.folderCapable {
                fileServerJSON += ",\"folderCapable\":" + (folderCapable ? "true" : "false")
            }
            if let autoDeliver = fileServer.autoDeliver {
                fileServerJSON += ",\"autoDeliver\":" + (autoDeliver ? "true" : "false")
            }
            if let filenamePolicy = fileServer.filenamePolicy, !filenamePolicy.isEmpty {
                fileServerJSON += ",\"filenamePolicy\":" + pythonJSONString(filenamePolicy)
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

        // `getRemoteAgentURL` already resolves through the storage read fence,
        // so an inadmissible stored value arrives here as nil. Re-asserting
        // `EndpointURLPolicy` keeps the contract LOCAL: this emitter must never
        // mint a code carrying a `user:password@` URL, whatever the fence does
        // — a setup code is the one artifact that carries a URL off the device
        // and onto another one (and onto a screen, as a QR).
        guard let url = await manager.getRemoteAgentURL(for: ref),
              EndpointURLPolicy.isAdmissible(url) else {
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

        // Transport: the stored per-ref hint when a pairing left one; otherwise
        // `public`. Chosen over omitting the field so wizard byte-parity holds
        // for a hand-configured, never-paired gateway too.
        //
        // A LOCALLY STORED CERTIFICATE PIN NEVER RIDES OUT. It is a per-device
        // tightening the user typed in for a certificate THIS device already
        // trusts; the importing device has its own trust store and decides for
        // itself, against the live server. Exporting the pin would push one
        // device's private narrowing onto another as if it were a fact about
        // the server — and would break that device on ordinary renewal.
        let transport: String
        if let hint = await manager.getRemoteAgentTransportHint(for: ref), !hint.isEmpty {
            transport = hint
        } else {
            transport = PairingPayload.Transport.publicCert.rawValue
        }

        let gateway = Gateway(
            kind: kind,
            url: url.absoluteString,
            authScheme: authScheme,
            token: token,
            model: model
        )

        // File server: emitted iff BOTH url + credential exist (the wizard's
        // `if FS_URL and FS_CRED`).
        //
        // Read as ONE snapshot rather than field-by-field. A code is a self-contained
        // artifact the user hands to another device, so a lane assembled from a URL
        // read before a Settings edit and a credential read after it would mint a
        // mixed-generation code that authenticates nowhere — and the failure would
        // surface on the scanning device, days later, with nothing to point at.
        //
        // A DELIVERY PROPERTY IS STATED ONLY WHEN IT DEVIATES FROM THE APP'S OWN
        // DEFAULT, and only when this device is entitled to state it:
        //
        // * `folderCapable` — emitted only when `testedLocally`, i.e. when a staged
        //   Test Connection ON THIS DEVICE measured the server's nested-PUT
        //   behaviour, and then only for the `false` verdict. `available` is the
        //   wrong gate on both ends: it can arrive from a peer through iCloud KVS
        //   (no measurement here at all) and it drops to false on a later
        //   reachability failure that leaves a perfectly good folder verdict
        //   standing. `true` is the app's own default for an unprobed lane, so
        //   stating it adds nothing the importer would not already assume.
        // * `autoDeliver` — emitted only for `false`, the restrictive state. A code
        //   is attacker-craftable input, so the importer refuses to let one GRANT
        //   the permission (see `SettingsViewModel+PairingImport`); emitting `true`
        //   would put a claim on the wire that no importer will honour.
        // * `filenamePolicy` — emitted only when the stored policy is not
        //   `Constants.fileServerFilenamePolicyPreserve`. That is never, while the
        //   vocabulary has one member; the rule is written now so the day a second
        //   policy exists the code carries it without another wire revision.
        //
        // The READINESS verdict itself never rides out, and the lane's certificate
        // pin has no field to ride in (same doctrine as the gateway pin above): the
        // scanning device may be on a different network and evaluates the chain in
        // its own trust store, so it earns Ready with its own staged test.
        var fileServer: FileServer?
        if let lane = await manager.fileTransferSnapshot(for: ref),
           EndpointURLPolicy.isAdmissible(lane.baseURL),
           !lane.credential.isEmpty {
            let measured = await manager.getFileServerTestedLocally(for: ref)
            fileServer = FileServer(
                url: lane.baseURL.absoluteString,
                credential: lane.credential,
                folderCapable: (measured && !lane.folderCapable) ? false : nil,
                autoDeliver: lane.autoDeliver ? nil : false,
                filenamePolicy: lane.filenamePolicy == Constants.fileServerFilenamePolicyPreserve
                    ? nil
                    : lane.filenamePolicy
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
