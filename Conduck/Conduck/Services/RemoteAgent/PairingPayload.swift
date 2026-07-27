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
// a bare enum). Both URLs are additionally held to `EndpointURLPolicy`
// (https + real host + no `user:password@`), because a pairing string is
// UNTRUSTED input — anyone can hand-craft one — and both URLs land verbatim
// in App-Group UserDefaults + iCloud KVS on import. For the same reason the
// two free-form display strings (`gateway.name`, `gateway.model`) are held to
// `sanitizedDisplayText`: they persist AND render, so control/bidi scalars and
// unbounded length are rejected at parse time rather than downstream.
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
    /// missing `"v"` / a URL with no host or carrying `user:password@`
    /// userinfo (`EndpointURLPolicy` — both URLs, no exceptions) / a
    /// display string (`name`, `model`) carrying control or bidi scalars
    /// or exceeding its length cap (`sanitizedDisplayText`).
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
            kind = .custom(name: try sanitizedDisplayText(name, maxLength: maxNameLength))
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

        let model: String?
        if
            let rawModel = (gateway["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawModel.isEmpty
        {
            model = try sanitizedDisplayText(rawModel, maxLength: maxModelLength)
        } else {
            model = nil
        }

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

    /// Required URL field: must be a string that parses, and then satisfy
    /// `EndpointURLPolicy` — https, a non-empty host, and no `user:password@`
    /// userinfo. BOTH URLs in the payload go through it; there is deliberately
    /// no per-field opt-out (see `EndpointURLPolicy` for why the gateway URL is
    /// not an exception, and what capability that removes).
    ///
    /// The policy's rejection maps onto the two error cases so the UI can name
    /// the real problem: a non-https URL is `.insecureURL` ("this code points
    /// somewhere unencrypted"), everything else is `.malformed`.
    ///
    /// Rejecting the whole payload (rather than dropping the offending half) is
    /// the honest outcome: a half-import leaves the user with a silently
    /// file-less setup and no reason given, whereas `.malformed` renders as "this
    /// setup code is damaged or incomplete — re-run conduck-connect", which
    /// points the user at the one place that can mint a code this parser accepts.
    ///
    /// The APP is authoritative about what it will store; it does not assume the
    /// wizard already agrees. `conduck-connect` enforces the same rule on some
    /// arms (its `--show-code` profile validation and `--check-adapter` host
    /// check both refuse userinfo) but NOT on its interactive URL prompt, so a
    /// wizard-minted code carrying userinfo is reachable today and lands here as
    /// `.malformed`. Aligning the wizard is tracked separately — do not weaken
    /// this parser on the assumption that it has happened.
    private static func requireHTTPSURL(_ value: Any?) throws -> URL {
        guard
            let urlString = value as? String,
            let url = URL(string: urlString)
        else {
            throw PairingParseError.malformed
        }
        guard let rejection = EndpointURLPolicy.rejection(for: url) else { return url }
        switch rejection {
        case .notHTTPS:
            throw PairingParseError.insecureURL
        case .noHost, .carriesUserinfo:
            throw PairingParseError.malformed
        }
    }

    // Length caps for the two free-form display strings. `conduck-connect`
    // bounds NEITHER — both come from a bare `ask` prompt (`read -r`, no
    // truncation), and the model id is explicitly left whole on the way out of
    // the `/v1/models` probe ("a long-but-legitimate id must survive intact").
    // So the caps cannot be derived from a wizard limit; they are chosen wide
    // enough that no answer a human types at those prompts can hit them, while
    // still bounding the rendered surface:
    //
    // * name 120 — the prompt asks for "a short name … (shown in the app)" and
    //   `SettingsViewModel.saveRemoteAgent` keeps only `prefix(40)` on persist,
    //   so 120 is 3× the bound the name is stored under. The cap exists because
    //   the UNTRUNCATED string still renders once, verbatim, in the import
    //   sheet's `PairingImportBlock.kindMismatch` error — the one place a
    //   hostile name reaches the user before any truncation applies.
    // * model 200 — model ids are machine-minted and legitimately long (HF-style
    //   `hf.co/<org>/<repo>-GGUF:Q4_K_M` paths run ~50-80 chars); 200 leaves
    //   room for the worst realistic id and still refuses a kilobyte of text.
    //
    // Both sit far under what a QR code can even carry: the wizard's encoder
    // tops out at QR version 40 (~2.9 KB binary, ~2.2 KB of JSON after base64
    // expansion), which the whole payload — URLs, token, credential, digests —
    // must share. A field near either cap is already implausible on the wire.
    private static let maxNameLength = 120
    private static let maxModelLength = 200

    /// Gate for a free-form display string that survives import: rejects when
    /// it carries a scalar that can spoof or corrupt rendered text, or when it
    /// is absurdly long. Input is already whitespace-trimmed.
    ///
    /// REJECT, never strip. These strings are persisted as the custom gateway's
    /// roster name / model override and shown back in Settings, selectors and
    /// nav titles; silently mutating one would make the imported gateway's
    /// identity differ from what the operator read in their terminal, which is
    /// the same confusion the sanitizer exists to prevent. A code the real
    /// wizard minted never contains any of these, so rejection costs nothing.
    ///
    /// Scans `unicodeScalars`, NOT `Character`: a grapheme cluster hides a
    /// control scalar behind its base character (`"a\u{0000}"` is ONE
    /// `Character`), so a Character-level scan would pass the payload through.
    private static func sanitizedDisplayText(_ text: String, maxLength: Int) throws -> String {
        guard
            text.unicodeScalars.count <= maxLength,
            !text.unicodeScalars.contains(where: isDisplayHostile)
        else {
            throw PairingParseError.malformed
        }
        return text
    }

    /// Scalars barred from any imported display string. Deliberately a
    /// denylist of *rendering-control* scalars, not an allowlist of scripts —
    /// gateway names are legitimately non-ASCII ("Küchen-Gateway", 日本語,
    /// emoji) and over-rejecting them is the worse failure.
    private static func isDisplayHostile(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 controls + DEL + C1 controls. C0 carries the ESC that starts an
        // ANSI sequence and the CR/LF that forge extra lines; C1 is the 8-bit
        // form of the same set and is equally terminal-actionable.
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true
        // Bidi marks / embeddings / overrides / isolates: LRM, RLM, LRE, RLE,
        // PDF, LRO, RLO, and the isolate family. RLO in particular reverses
        // everything after it, so "evil" can render as the trusted name the
        // user expects — the classic display-spoof primitive.
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        // LINE / PARAGRAPH SEPARATOR — not in `.newlines` for every API that
        // touches this string, but break single-line labels the same way LF
        // does, letting one name occupy several rendered rows.
        case 0x2028, 0x2029:
            return true
        default:
            return false
        }
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
