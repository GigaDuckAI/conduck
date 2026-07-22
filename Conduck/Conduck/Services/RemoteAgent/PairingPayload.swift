// Conduck
// PairingPayload.swift
//
// Onboarding/Settings gateway pairing — parser for the setup string emitted
// by the `conduck-connect` server wizard (QR payload == paste string):
//
//   conduck-setup:v1:<base64(minified JSON)>
//
// CONTRACT OWNER: `spec.md` "Gateway Setup & Pairing (`conduck-connect` +
// QR import)" — the JSON shape is LOCKED there; this file only PARSES it.
// Mirrors the tolerant-dict-decode posture of
// `RemoteAgentBroadcastEnvelope.decode(from:)`: unknown keys anywhere are
// ignored (forward-compat), required-field failures reject the whole
// payload, optional hints degrade to nil.
//
// PRIVACY (non-negotiable — see the spec's Privacy & Security section): the raw pairing string
// embeds the gateway bearer token + file-server credential. NEVER log /
// echo the raw string, the decoded JSON, the token, or the credential —
// parse errors carry NO payload content by design (`PairingParseError` is
// a bare enum).
//
// Pure Foundation — compiles for iOS AND macOS (no UIKit/AppKit). NOT a
// Watch-target member (pairing import is an iPhone/iPad/Mac flow).

import Foundation

/// Why a pairing string failed to parse. Deliberately coarse — the UI maps
/// these to user-facing copy; none of the cases carry payload content (the
/// raw string embeds secrets and must never leak through an error).
enum PairingParseError: Error, Equatable {
    /// Missing / wrong `"conduck-setup:"` prefix — this isn't a pairing
    /// code at all (lets the scanner ignore unrelated QR codes silently).
    case notAPairingCode
    /// Prefix matched but the version segment isn't `"v1"`, OR the JSON
    /// `"v"` field is present and != 1 — a NEWER `conduck-connect` minted
    /// this; the UI tells the user to update the app, not "bad code".
    case unsupportedVersion
    /// Bad base64 / bad JSON / missing-or-invalid required field / bearer
    /// without token / custom without nonempty name / bad certFP /
    /// missing `"v"`.
    case malformed
    /// Gateway or fileServer URL parses but its scheme isn't https — https
    /// is mandatory (`spec.md` Architectural Invariants); surfaced as its
    /// own case so the UI can say WHY instead of a generic "bad code".
    case insecureURL
}

/// Decoded pairing payload — everything Settings needs to configure a
/// gateway (and optionally its file server) in one import.
struct PairingPayload: Equatable, Sendable {
    /// Which gateway slot this payload targets: a built-in backend
    /// (OpenClaw / Hermes) or a user-named custom OpenAI-compatible one.
    enum Kind: Equatable, Sendable {
        case builtin(RemoteAgentBackend)
        case custom(name: String)
    }

    /// How the gateway is exposed — a HINT for setup-UI copy (e.g. "this
    /// gateway rides your tailnet"), never load-bearing for transport
    /// behavior. Unknown future values decode to nil, not an error.
    enum Transport: String, Sendable {
        case tailscale, funnel, cloudflare, selfsigned
        case publicCert = "public"
    }

    /// Optional agent file-transfer server minted alongside the gateway.
    struct FileServer: Equatable, Sendable {
        let url: URL
        /// Machine-minted shared credential — nonempty by contract.
        let credential: String
        /// Pinned SPKI SHA-256 (lowercase 64-hex) — `conduck-connect` emits it
        /// when the self-signed file host differs from the gateway host; optional
        /// otherwise.
        let certFP: String?
    }

    let kind: Kind
    /// Gateway base URL — https-only, host required.
    let url: URL
    /// `.bearer` (default — fail closed, matching
    /// `RemoteAgentAuthScheme.default`) or an explicit keyless `.none`.
    let authScheme: RemoteAgentAuthScheme
    /// Bearer token — present iff `authScheme == .bearer` (a stray token
    /// under `.none` is DROPPED so keyless stays an explicit choice).
    let token: String?
    /// Pinned SPKI SHA-256, normalized to lowercase 64-hex (input may
    /// carry `:` separators / uppercase — `openssl` fingerprint style).
    let certFP: String?
    /// Optional model override for the converse `"model"` field.
    let model: String?
    let fileServer: FileServer?
    let transport: Transport?

    // MARK: - Parsing

    /// Parse a raw pairing string (QR scan result or pasted text).
    /// Surrounding whitespace/newlines are tolerated; base64 with stripped
    /// padding is re-padded. Never logs / echoes any part of the input.
    static func parse(_ string: String) -> Result<PairingPayload, PairingParseError> {
        do {
            return .success(try parseOrThrow(string))
        } catch let error as PairingParseError {
            return .failure(error)
        } catch {
            // Unreachable — parseOrThrow only throws PairingParseError —
            // but Swift's untyped `throws` demands the arm; fail safe.
            return .failure(.malformed)
        }
    }

    private static let prefix = "conduck-setup:"

    private static func parseOrThrow(_ string: String) throws -> PairingPayload {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            throw PairingParseError.notAPairingCode
        }

        // Split the remainder into <version> ":" <base64>. Base64 never
        // contains ":" so the FIRST colon is the unambiguous separator.
        let body = trimmed.dropFirst(prefix.count)
        let versionSegment: Substring
        let base64Segment: Substring
        if let colon = body.firstIndex(of: ":") {
            versionSegment = body[..<colon]
            base64Segment = body[body.index(after: colon)...]
        } else {
            versionSegment = body
            base64Segment = ""
        }
        guard versionSegment == "v1" else {
            throw PairingParseError.unsupportedVersion
        }

        // Re-pad stripped base64 (QR minifiers / manual copies drop "=").
        var base64 = String(base64Segment)
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard
            let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any]
        else {
            throw PairingParseError.malformed
        }

        // "v" must be PRESENT (missing → malformed: the wizard always
        // writes it) and == 1 (other Int → a newer schema → unsupported).
        guard let versionValue = dict["v"] else {
            throw PairingParseError.malformed
        }
        guard let version = versionValue as? Int else {
            throw PairingParseError.malformed
        }
        guard version == 1 else {
            throw PairingParseError.unsupportedVersion
        }

        guard let gateway = dict["gateway"] as? [String: Any] else {
            throw PairingParseError.malformed
        }

        // kind — built-in raw value or "custom" + required nonempty name.
        guard let kindRaw = gateway["kind"] as? String else {
            throw PairingParseError.malformed
        }
        let kind: Kind
        if let backend = RemoteAgentBackend(rawValue: kindRaw) {
            // v1 permits only pairable builtins (openclaw/hermes). A hosted-model
            // backend (openrouter: fixed URL, no pairing) must not be configurable
            // by QR — its raw value is malformed here, not a valid kind.
            guard RemoteAgentBackendRegistry.lookup(id: backend).pairingSupported else {
                throw PairingParseError.malformed
            }
            kind = .builtin(backend)
        } else if kindRaw == "custom" {
            guard
                let name = (gateway["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else {
                throw PairingParseError.malformed
            }
            kind = .custom(name: name)
        } else {
            throw PairingParseError.malformed
        }

        let url = try requireHTTPSURL(gateway["url"])

        // auth — absent defaults to .bearer (fail closed, same posture as
        // `RemoteAgentAuthScheme.from(rawValue:)`). Bearer REQUIRES a
        // nonempty token; under .none a stray token is dropped so keyless
        // stays an explicit, token-free state.
        let authScheme = RemoteAgentAuthScheme.from(rawValue: gateway["auth"] as? String)
        let token: String?
        switch authScheme {
        case .bearer:
            guard let bearerToken = gateway["token"] as? String, !bearerToken.isEmpty else {
                throw PairingParseError.malformed
            }
            token = bearerToken
        case .none:
            token = nil
        }

        let certFP = try normalizedCertFP(gateway["certFP"])

        let model: String? = {
            guard
                let raw = (gateway["model"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { return nil }
            return raw
        }()

        // fileServer — optional block; when present its url + credential
        // are required (the wizard never emits a half-configured block).
        var fileServer: FileServer?
        if let fileServerValue = dict["fileServer"] {
            guard let fsDict = fileServerValue as? [String: Any] else {
                throw PairingParseError.malformed
            }
            let fsURL = try requireHTTPSURL(fsDict["url"])
            guard let credential = fsDict["credential"] as? String, !credential.isEmpty else {
                throw PairingParseError.malformed
            }
            let fsCertFP = try normalizedCertFP(fsDict["certFP"])
            fileServer = FileServer(url: fsURL, credential: credential, certFP: fsCertFP)
        }

        // transport — pure hint: unknown raw value → nil, never an error.
        let transport = (dict["transport"] as? String).flatMap(Transport.init(rawValue:))

        return PairingPayload(
            kind: kind,
            url: url,
            authScheme: authScheme,
            token: token,
            certFP: certFP,
            model: model,
            fileServer: fileServer,
            transport: transport
        )
    }

    /// Required URL field: must be a string, parse as a URL WITH a host
    /// (else `.malformed`), and carry exactly the https scheme (a parsed
    /// non-https URL → `.insecureURL` so the UI can name the real problem).
    private static func requireHTTPSURL(_ value: Any?) throws -> URL {
        guard
            let urlString = value as? String,
            let url = URL(string: urlString),
            let scheme = url.scheme,
            url.host != nil
        else {
            throw PairingParseError.malformed
        }
        guard scheme.lowercased() == "https" else {
            throw PairingParseError.insecureURL
        }
        return url
    }

    /// Optional certFP field: nil/absent passes through; otherwise must be
    /// a string that — after lowercasing + stripping `:` separators
    /// (`openssl` fingerprint style) — is exactly 64 hex chars.
    private static func normalizedCertFP(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let raw = value as? String else {
            throw PairingParseError.malformed
        }
        let normalized = raw.lowercased().replacingOccurrences(of: ":", with: "")
        // ASCII-only hex gate — `Character.isHexDigit` also accepts
        // fullwidth variants, which must NOT slip into a pinned digest.
        let hexDigits = Set("0123456789abcdef")
        guard
            normalized.count == 64,
            normalized.allSatisfy({ hexDigits.contains($0) })
        else {
            throw PairingParseError.malformed
        }
        return normalized
    }
}
