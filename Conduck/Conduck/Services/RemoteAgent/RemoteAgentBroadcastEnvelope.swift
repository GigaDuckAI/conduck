// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentBroadcastEnvelope.swift
//
// Settings: Personal AI. Atomic WCSession payload carrying
// { backend, url, token, fingerprint, activeSessionID, monotonic timestamp }
// from iPhone → Watch. Mirrors `STTBroadcastEnvelope` shape + posture:
//
//   - Envelope-only — `applicationContext` does NOT carry remote-agent
//     state (would torn-read against the queued `transferUserInfo`).
//   - Plist-compatible dict shape so `WCSession.transferUserInfo` accepts
//     it without a JSON encode hop.
//   - Monotonic `timestamp` lets the Watch discard older envelopes that
//     arrive out of order after a queue drain.
//   - Tolerant decoder: missing optional fields → nil, malformed required
//     fields → return nil rather than crash.
//
// Privacy invariant (spec §Cross-Device Sync): the bearer token crosses
// WCSession in the envelope. This is by explicit spec design — "STT key
// (and gateway token) arrive via `WCSession.transferUserInfo`"
// — the Watch needs the token to issue converse requests directly.
// Never log the token. The Watch persists it to Keychain via
// `WatchIdentityResolver` so cold-launch survives (same posture as the
// STT key).

import Foundation

/// Atomic Personal AI gateway envelope sent via `WCSession.transferUserInfo`.
struct RemoteAgentBroadcastEnvelope: Codable, Sendable {
    /// The user-selected backend reference, serialized as a `RemoteAgentRef`
    /// `rawString` ("openclaw" / "hermes" / "custom_<uuid>"). A built-in still
    /// serializes to its EXACT locked raw value, so a one-release-old Watch that
    /// gates this key through `RemoteAgentBackend(rawValue:)` still decodes
    /// built-in subs (and correctly drops custom subs whose ref it can't parse —
    /// graceful degradation). Customs round-trip as `"custom_<uuid>"`.
    let backendRef: String

    /// The gateway base URL the user saved in Settings (no path suffix;
    /// `RemoteAgentClient` appends `/v1/chat/completions` /
    /// `/v1/models` itself).
    let url: URL

    /// The custom gateway's user-given name. Nil for built-ins (the Watch
    /// derives a built-in name from `RemoteAgentBackend.displayName`). Encoder
    /// omits the dict key when nil — same omit-nil posture as `token`. The Watch
    /// persists it into its custom-gateway roster so the badge / Ask chooser can
    /// label the gateway. Never empty-string sentinel.
    let name: String?

    /// The optional model name sent as the converse `"model"` field. Nil for
    /// built-ins (gateway default). Encoder omits the dict key when nil. The
    /// Watch threads it into its converse body for customs that set it.
    let model: String?

    /// The custom gateway's badge palette color id (`RemoteAgentBadgePalette`).
    /// Nil for built-ins (they have reserved hues). Encoder omits when nil. The
    /// Watch persists it into its roster so the badge color is deterministic.
    let colorID: String?

    /// The custom gateway's badge monogram (1–2 chars). Nil for built-ins
    /// (they use their `shortCode`) and nil-when-derived for customs. Encoder
    /// omits when nil. The Watch persists it into its roster for the badge.
    let monogram: String?

    /// Bearer token for the gateway. Optional, NOT empty-string sentinel
    /// — matches the `STTBroadcastEnvelope.apiKey` posture so a future
    /// keyless backend (`.custom` without auth) can broadcast with
    /// `nil` rather than `""`. Encoder omits dict key when nil; decoder
    /// `dict["token"] as? String` returns nil natively → forward/back-
    /// compat. Never logged.
    let token: String?

    /// How the Watch authenticates to this gateway — `.bearer` (use `token`) or
    /// `.none` (keyless, omit the header). EXPLICIT on the wire so the Watch goes
    /// keyless ONLY on an intentional `.none`, never because a `token` happened to
    /// arrive nil (a transient iPhone Keychain read failure must NOT silently
    /// delete the Watch's stored token). Always encoded; decode defaults a missing
    /// key to `.bearer` (fail closed — an un-upgraded sender stays authenticated).
    let authScheme: RemoteAgentAuthScheme

    /// Optional pinned cert SHA-256 hex (lowercase). When nil, the Watch
    /// (and iPhone) fall through to default ATS chain validation. See
    /// `RemoteAgentTrustEvaluator.spkiDER(from:)` for the digest recipe.
    let certFingerprintHex: String?

    /// Whether agent file transfer is READY for THIS gateway — the iPhone's
    /// `SettingsManager.fileTransferReadySnapshot(for:) != nil` gate (URL +
    /// credential present AND the staged test passed), the SAME gate every
    /// capable dispatch surface uses. The iPhone is the source of truth (the
    /// wrist can't evaluate readiness — the file-server credential never syncs
    /// to it). The Watch READS it to decide the per-turn file-delivery
    /// instruction on its (spoken) converse turns: file upload / download is
    /// still an iPhone/iPad/Mac capability (no wrist affordance — attachments
    /// render as a plain `[File attached]` placeholder), but a capable device
    /// that later opens the thread renders a download chip for the watch turn
    /// via the retroactive output-scan, so the instruction is worth sending.
    /// A stale `true` (the ref's readiness dropped after this envelope) is a
    /// bounded degradation: at worst a promised chip only ever materializes
    /// after a retro-scan finds a real file — never a crash or credential
    /// exposure.
    ///
    /// Always encoded (a plain Bool, unlike the omit-nil optionals above). The
    /// decoder defaults a MISSING key to `false` so an un-upgraded sender (one
    /// that never wrote `fileTransferAvailable`) degrades to "not ready" — the
    /// wrist then omits the delivery clause but still sends the spoken clause —
    /// rather than stranding the envelope; same tolerant posture as every other
    /// field.
    let fileTransferAvailable: Bool

    /// The `SettingsManager.FileTransferSnapshot.durableLaneID` of THIS ref's
    /// READY lane — the one-way SHA-256 over `baseURL + credential` that names
    /// the durable server namespace. The wrist stamps it onto the agent reply it
    /// persists (`Message.outputScanLaneID` + `outputScanDone = false`), and
    /// that stamp is what makes a Watch-originated turn eligible for the
    /// retroactive output scan a capable device runs when the thread is next
    /// opened. The wrist mints the turn's `outputBoxKey` itself — naming a
    /// folder needs no credential — but the eligibility predicate demands BOTH,
    /// so without this identity a wrist turn stays permanently invisible to the
    /// scan even though its request named a folder on the wire.
    ///
    /// Couriered rather than derived: the file-server CREDENTIAL never syncs to
    /// the wrist, so the Watch cannot compute this digest itself, and shipping
    /// the credential to compute it would widen the secret surface for no gain.
    /// The digest carries no secret (one-way, and the envelope already carries
    /// the raw gateway bearer token, a strictly larger exposure).
    ///
    /// Paired with `fileTransferAvailable` from the SAME snapshot read on the
    /// iPhone, so the flag and the identity can never describe different lanes.
    /// Omit-nil on the wire (like `token`): nil = no READY lane for this ref, and
    /// a MISSING key decodes to nil — an un-upgraded sender therefore lands
    /// exactly today's behavior (turn dispatched, never stamped, never scanned)
    /// rather than stranding the envelope. Never logged.
    let fileTransferLaneID: String?

    /// Whether THIS gateway's file-server can LIST a collection — the iPhone's
    /// `FileTransferSnapshot.returnCapable`, read from the SAME lane snapshot as
    /// the two fields above.
    ///
    /// THE WRIST CANNOT MEASURE THIS AND MUST NOT GUESS. It holds no file-server
    /// credential by design, so it issues no absence witness and has no way to
    /// discover that a server refuses `PROPFIND` — yet it still NAMES a
    /// per-dispatch output folder on every spoken turn, because naming a path
    /// needs no credential. On a lane that can never list a folder, that name is
    /// worse than useless: the agent writes files into a directory nothing can
    /// ever read, the turn is persisted pointing at it, and a capable device
    /// that later opens the thread runs the retroactive scan and shows a "we
    /// couldn't read your file server" fault for a limitation the user was
    /// already told about in Settings. So the phone, which CAN measure it,
    /// couriers the answer.
    ///
    /// Always encoded (a plain Bool, like `fileTransferAvailable`). A MISSING key
    /// decodes to `true` — capable — and the polarity is deliberate in both
    /// directions:
    ///   - A missing key means an un-upgraded SENDER, i.e. exactly the state
    ///     where today's wrist behaviour is correct. Defaulting `false` would
    ///     switch wrist file return off across every paired watch mid-upgrade,
    ///     on lanes that are perfectly capable, for want of a key nobody wrote.
    ///   - It matches the app-wide polarity for this capability: incapability is
    ///     established only by a structural refusal the server itself stated
    ///     (`FileTransferTestResult.returnCapable`), never by an absence.
    /// The cost of a wrong `true` is bounded — one named folder nobody fills;
    /// the cost of a wrong `false` is a working feature vanishing silently.
    let fileTransferReturnCapable: Bool

    /// Whether THIS gateway may put files on the device automatically — the
    /// iPhone's `FileTransferSnapshot.autoDeliver`.
    ///
    /// RESERVED: nothing consults it — not on the wrist, and not on the iPhone
    /// before it broadcasts (see the snapshot field's own doc, which is where the
    /// reason it exists with no reader is written down). Couriered now for the
    /// reason `fileTransferAvailable` is couriered — the wrist cannot evaluate the
    /// permission itself, since the file-server credential never syncs there — so
    /// the reader that arrives later needs no envelope change, which is the
    /// expensive kind of change to make late.
    ///
    /// Omit-nil on the wire; a MISSING key decodes to nil, which every reader
    /// treats as "unstated, use the default" rather than as `false`. That keeps
    /// an un-upgraded sender at the default instead of switching automatic
    /// delivery off across a whole paired watch on the first envelope.
    let fileTransferAutoDeliver: Bool?

    /// How a delivered file's name is treated on THIS gateway — the iPhone's
    /// `FileTransferSnapshot.filenamePolicy`. Reserved on the same terms as
    /// `fileTransferAutoDeliver` — read by nothing on either side — so a later
    /// policy change never has to widen this envelope again. Omit-nil, and nil
    /// means "unstated, use the default".
    let fileTransferFilenamePolicy: String?

    /// Active conversation session ID (`spec.md "Settings & Storage"`).
    /// Optional — nil means no live session (first turn after backend /
    /// URL change clears it). Cross-device session continuity:
    /// the Watch adopts the iPhone's active session so a conversation
    /// started on iPhone can continue on Watch within the active-session window.
    let activeSessionID: String?

    /// Monotonic sender-side timestamp
    /// (`Date().timeIntervalSinceReferenceDate`). Watch persists the
    /// highest seen timestamp and discards any envelope with
    /// `timestamp <= lastRemoteAgentEnvelopeTimestamp` — defeats out-of-
    /// order queue drains after wake.
    let timestamp: TimeInterval

    /// Explicit memberwise init so `fileTransferAvailable` can default to
    /// `false` — a synthesized memberwise init can't carry a per-param default.
    /// The default keeps EVERY pre-existing construction site (envelope
    /// round-trip tests, any not-yet-rewired caller) compiling additively while
    /// the iPhone broadcaster + `decode(from:)` pass the real per-ref value.
    /// Writing this init does NOT suppress the synthesized `Codable` conformance
    /// (no custom `init(from:)` / `encode(to:)` is declared) — the WCSession path
    /// rides `encodedDict()` / `decode(from:)`, not `Codable`, anyway.
    init(
        backendRef: String,
        url: URL,
        name: String?,
        model: String?,
        colorID: String?,
        monogram: String?,
        token: String?,
        authScheme: RemoteAgentAuthScheme = .bearer,
        certFingerprintHex: String?,
        fileTransferAvailable: Bool = false,
        fileTransferLaneID: String? = nil,
        // Defaulted `true` for the reason the decoder defaults a missing wire
        // key that way: an un-stated capability is not a proven incapability,
        // and every not-yet-rewired construction site must keep today's
        // behaviour rather than silently disable wrist file return.
        fileTransferReturnCapable: Bool = true,
        fileTransferAutoDeliver: Bool? = nil,
        fileTransferFilenamePolicy: String? = nil,
        activeSessionID: String?,
        timestamp: TimeInterval
    ) {
        self.backendRef = backendRef
        self.url = url
        self.name = name
        self.model = model
        self.colorID = colorID
        self.monogram = monogram
        self.token = token
        self.authScheme = authScheme
        self.certFingerprintHex = certFingerprintHex
        self.fileTransferAvailable = fileTransferAvailable
        // Normalize at the BOUNDARY so a malformed value can never reach the
        // wire, the Watch's durable slots, or a persisted `outputScanLaneID`.
        // Every construction site (broadcaster + decoder) funnels through here.
        self.fileTransferLaneID = Self.sanitizedLaneID(fileTransferLaneID)
        self.fileTransferReturnCapable = fileTransferReturnCapable
        self.fileTransferAutoDeliver = fileTransferAutoDeliver
        self.fileTransferFilenamePolicy = fileTransferFilenamePolicy
        self.activeSessionID = activeSessionID
        self.timestamp = timestamp
    }

    /// Accept a lane id ONLY in its canonical shape — exactly 64 lowercase hex
    /// characters, the fixed output of `FileTransferSnapshot.durableLaneID`'s
    /// SHA-256 — else nil ("no lane"). The id is an OPAQUE identity token that
    /// is compared for equality and nothing else, so anything off-shape is
    /// already useless; rejecting it here bounds what a malformed / hostile
    /// payload can push into Watch `UserDefaults`, task metadata, and Core Data.
    /// Length is version-stable: the domain-separation tag lives INSIDE the
    /// hashed input (`conduck.file-lane.v1\0`), so a future lane-id revision
    /// changes the digest, never its shape.
    private static func sanitizedLaneID(_ raw: String?) -> String? {
        // Explicit ASCII alphabet rather than `Character.isHexDigit`, which also
        // accepts full-width Unicode digit forms — a look-alike id would be
        // stored and compared but could never match a real digest.
        let hex = Set("0123456789abcdef")
        guard let raw, raw.count == 64, raw.allSatisfy({ hex.contains($0) }) else {
            return nil
        }
        return raw
    }

    /// Plist-compatible dict for `WCSession.transferUserInfo`.
    /// Omits optional keys entirely when nil — keyless / sessionless
    /// envelopes MUST NOT broadcast empty strings, which the decode path
    /// would round-trip as `Optional.some("")` rather than `nil` and
    /// trigger drift on the Watch side.
    func encodedDict() -> [String: Any] {
        var dict: [String: Any] = [
            "backend": backendRef,
            "url": url.absoluteString,
            "timestamp": timestamp,
            // Always-present plain Bool (no omit-nil dance — it's not optional).
            // The Watch reads it to decide the `[File attached]` placeholder vs a
            // (never-present) upload/download affordance.
            "fileTransferAvailable": fileTransferAvailable,
            // Always-present (like `fileTransferAvailable`) so the keyless posture
            // is explicit on the wire — never inferred from a nil `token`.
            "authScheme": authScheme.rawValue,
            // Always-present plain Bool, NOT omit-nil: "absent" already means
            // "un-upgraded sender" on this wire, and a capable lane must not
            // encode identically to one.
            "fileTransferReturnCapable": fileTransferReturnCapable,
        ]
        if let token {
            dict["token"] = token
        }
        if let name {
            dict["name"] = name
        }
        if let model {
            dict["model"] = model
        }
        if let colorID {
            dict["colorID"] = colorID
        }
        if let monogram {
            dict["monogram"] = monogram
        }
        if let certFingerprintHex {
            dict["certFingerprintHex"] = certFingerprintHex
        }
        // Omit-nil (not a false-ish sentinel): "key absent" is the SAME signal
        // an un-upgraded sender produces, so both roads lead to "no lane".
        if let fileTransferLaneID {
            dict["fileTransferLaneID"] = fileTransferLaneID
        }
        // Omit-nil for the same reason: "key absent" must read as "unstated",
        // never as an explicit `false`/empty policy, so an un-upgraded sender
        // and a sender with nothing to say produce the identical wire.
        if let fileTransferAutoDeliver {
            dict["fileTransferAutoDeliver"] = fileTransferAutoDeliver
        }
        if let fileTransferFilenamePolicy {
            dict["fileTransferFilenamePolicy"] = fileTransferFilenamePolicy
        }
        if let activeSessionID {
            dict["activeSessionID"] = activeSessionID
        }
        return dict
    }

    /// Decode from the `[String: Any]` payload received on the Watch side.
    /// Returns nil if a required field (`backend`, `url`, `timestamp`)
    /// is missing, wrong-typed, or unparseable — the receiver MUST treat
    /// nil as "ignore this envelope" rather than crashing (forward-compat
    /// with future schema additions). Optional fields tolerate
    /// missing / wrong-typed by yielding nil for that field only.
    static func decode(from dict: [String: Any]) -> RemoteAgentBroadcastEnvelope? {
        guard
            let backendRef = dict["backend"] as? String,
            !backendRef.isEmpty,
            let urlString = dict["url"] as? String,
            let url = URL(string: urlString),
            let timestamp = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }
        // NOTE: the required guard no longer routes `backendRef` through
        // `RemoteAgentBackend(rawValue:)` — it accepts ANY non-empty ref string
        // ("openclaw" / "hermes" / "custom_<uuid>") so customs round-trip. The
        // ref is parsed downstream (`RemoteAgentRef(rawString:)`); an unparseable
        // ref resolves to `remoteAgentNotConfigured` (no reroute), not a decode
        // failure that would strand the whole envelope.
        let token = dict["token"] as? String
        // Missing / unrecognized → `.bearer` (fail closed): an un-upgraded sender
        // that never wrote `authScheme` stays authenticated, and the Watch never
        // goes keyless except on an explicit `"none"`.
        let authScheme = RemoteAgentAuthScheme.from(rawValue: dict["authScheme"] as? String)
        let name = dict["name"] as? String
        let model = dict["model"] as? String
        let colorID = dict["colorID"] as? String
        let monogram = dict["monogram"] as? String
        let fingerprint = dict["certFingerprintHex"] as? String
        // Default a MISSING key to `false` (back-compat: an un-upgraded sender
        // never wrote this) rather than failing the decode — same tolerant
        // posture as the optional fields, but the field itself is non-optional.
        let fileTransferAvailable = dict["fileTransferAvailable"] as? Bool ?? false
        // Missing key (un-upgraded sender) OR an off-shape value → nil: the
        // wrist simply never stamps a lane on that turn, which is the
        // pre-upgrade behavior, not a decode failure that would strand the
        // whole envelope. Shape enforcement happens in `init`.
        let fileTransferLaneID = dict["fileTransferLaneID"] as? String
        // Missing OR wrong-typed → `true` (capable). See the field's doc: the
        // absence of a statement is not a proven incapability, and reading it as
        // one would switch off wrist file return across a whole paired watch the
        // first time an older iPhone broadcast arrived.
        let fileTransferReturnCapable = dict["fileTransferReturnCapable"] as? Bool ?? true
        // Missing OR wrong-typed → nil ("unstated"), never a coerced default.
        // A reader that needs a value applies its own default, so an
        // un-upgraded sender and a hostile type both land on today's behaviour.
        let fileTransferAutoDeliver = dict["fileTransferAutoDeliver"] as? Bool
        let fileTransferFilenamePolicy = dict["fileTransferFilenamePolicy"] as? String
        let sessionID = dict["activeSessionID"] as? String
        return RemoteAgentBroadcastEnvelope(
            backendRef: backendRef,
            url: url,
            name: name,
            model: model,
            colorID: colorID,
            monogram: monogram,
            token: token,
            authScheme: authScheme,
            certFingerprintHex: fingerprint,
            fileTransferAvailable: fileTransferAvailable,
            fileTransferLaneID: fileTransferLaneID,
            fileTransferReturnCapable: fileTransferReturnCapable,
            fileTransferAutoDeliver: fileTransferAutoDeliver,
            fileTransferFilenamePolicy: fileTransferFilenamePolicy,
            activeSessionID: sessionID,
            timestamp: timestamp
        )
    }
}

/// Full multi-gateway Watch support. Broadcasts ALL
/// configured gateways to the Watch in a single `WCSession.transferUserInfo`
/// payload (under `Constants.remoteAgentMultiEnvelopeKey`) so a Watch
/// conversation routes to ITS bound backend, not just the iPhone's default.
///
/// Lives in this file (already Watch-opted-in via Approach A) to avoid
/// pbxproj target-membership surgery.
///
/// Posture (identical to the single envelope):
///   - Plist-compatible dict shape — `backends` is an array of the per-backend
///     `RemoteAgentBroadcastEnvelope.encodedDict()` dicts; `defaultBackend` is
///     a raw-value string; `timestamp` is the monotonic sender stamp.
///   - Tolerant decoder: missing required field (`backends` / `defaultBackend`
///     / `timestamp`) → nil (receiver ignores). Unknown extra keys ignored.
///     Each sub-dict decodes via `RemoteAgentBroadcastEnvelope.decode`; a
///     malformed sub-dict is dropped (not fatal) so a future per-backend
///     schema addition can't strand a whole upgraded Watch.
///   - Per-backend bearer tokens ride inside each sub-envelope (same wire
///     posture as the single envelope — never logged, persisted to Watch
///     Keychain on receipt, NEVER written to KVS).
struct RemoteAgentMultiBroadcastEnvelope: Codable, Sendable {
    /// One sub-envelope per CONFIGURED ref (carries that ref's
    /// url / token / cert / name / model / activeSessionID). Order matches
    /// `SettingsManager.configuredRemoteAgentRefs()` — built-ins first (stable
    /// `RemoteAgentBackend.allCases` order), then customs (registry order).
    let backends: [RemoteAgentBroadcastEnvelope]

    /// The **Watch-effective default** ref a freshly-minted (Watch-originated)
    /// headless conversation binds to, serialized as a `RemoteAgentRef`
    /// `rawString` ("openclaw" / "hermes" / "custom_<uuid>"). This is the
    /// iPhone's Watch-specific override when set (the Watch keeps no settings
    /// UI — the override is chosen on the iPhone), else the iPhone's own
    /// device-local default ("Follow iPhone"). The iPhone self-heals a dangling
    /// override before sending, so this is always a currently-configured ref. A
    /// custom default round-trips here (decode no longer gates on
    /// `RemoteAgentBackend`). The Watch clears its OWN active-conversation
    /// pointer when it accepts a newer envelope whose value differs from the
    /// stored one (mirrors the iPhone setter's local-clear).
    let defaultBackendRef: String

    /// Monotonic sender-side timestamp. The Watch discards any multi-envelope
    /// with `timestamp <= lastRemoteAgentEnvelopeTimestamp` — same guard the
    /// single envelope uses (shared high-water mark).
    let timestamp: TimeInterval

    /// The **Watch-effective `SessionContinuationPolicy`** (raw value) the Watch
    /// applies to its OWN headless quick-capture pointer — the iPhone's Watch
    /// override when set, else the iPhone's own per-device policy ("Follow
    /// iPhone"). Optional for back-compat: an old iPhone never sends it (decodes
    /// to nil → the Watch keeps its prior cached value / `.minutes30` default),
    /// and an old Watch ignores the key. Encoded only when non-nil (omit-nil
    /// posture, like the per-backend optional fields).
    let sessionPolicy: String?

    /// EXPLICIT teardown flag: the user forgot their LAST gateway, so the Watch
    /// must purge every per-ref slot AND every stored token rather than keep
    /// serving a gateway the user believes they disconnected.
    ///
    /// This is a dedicated field and NOT `backends.isEmpty` for one decisive
    /// reason: `decode` drops malformed sub-dicts (forward-compat), so a future
    /// per-backend schema change an older Watch cannot parse ALSO decodes to an
    /// empty `backends` array. Treating that as teardown would turn a
    /// compatibility gap into credential destruction. Destruction requires this
    /// flag to be present and true — nothing else.
    ///
    /// Optional for back-compat, same omit-nil posture as `sessionPolicy`: an
    /// old iPhone never sends it, an old Watch ignores it. Encoded only when
    /// true, so a normal envelope carries no extra key.
    let clearAll: Bool?

    /// Whether `defaultBackendRef` is a gateway the USER actually chose, as
    /// opposed to the compatibility fallback the iPhone projects when no pointer
    /// is stored at all.
    ///
    /// The ref slot alone cannot express "nothing chosen" — it is required
    /// non-empty, and the fallback it carries may itself be configured, in which
    /// case the wrist would read a gateway the user never picked as the chosen
    /// default and send every headless capture there, permanently binding each
    /// conversation to it. This flag is the wrist's only way to tell the two
    /// apart, and it is the reason the wrist refuses instead of guessing.
    ///
    /// Optional with the same omit-nil posture as `sessionPolicy` / `clearAll`,
    /// and `nil` reads as CHOSEN: an old iPhone never sends the key, an old Watch
    /// ignores it, and both keep behaving exactly as they do without it. Encoded
    /// only when `false`, so an ordinary envelope carries no extra key.
    let defaultBackendChosen: Bool?

    /// Explicit memberwise init so the optional tail fields can default to nil —
    /// every existing construction site (and every test) predates them and must
    /// keep compiling as a normal, non-destructive envelope naming a chosen
    /// default.
    init(
        backends: [RemoteAgentBroadcastEnvelope],
        defaultBackendRef: String,
        timestamp: TimeInterval,
        sessionPolicy: String?,
        clearAll: Bool? = nil,
        defaultBackendChosen: Bool? = nil
    ) {
        self.backends = backends
        self.defaultBackendRef = defaultBackendRef
        self.timestamp = timestamp
        self.sessionPolicy = sessionPolicy
        self.clearAll = clearAll
        self.defaultBackendChosen = defaultBackendChosen
    }

    /// Plist-compatible dict for `WCSession.transferUserInfo`. `backends` is
    /// encoded as an array of per-backend dicts (each via the single
    /// envelope's `encodedDict()`), preserving its omit-nil-keys posture.
    func encodedDict() -> [String: Any] {
        var dict: [String: Any] = [
            "backends": backends.map { $0.encodedDict() },
            "defaultBackend": defaultBackendRef,
            "timestamp": timestamp,
        ]
        if let sessionPolicy { dict["sessionPolicy"] = sessionPolicy }
        if clearAll == true { dict["clearAll"] = true }
        // Encoded only for the unusual answer. "Chosen" is both the default
        // reading and what every older build assumes, so saying it costs a key
        // on every envelope and changes nothing.
        if defaultBackendChosen == false { dict["defaultBackendChosen"] = false }
        return dict
    }

    /// Decode from the `[String: Any]` payload received on the Watch side.
    /// Returns nil if a required field (`backends` array, `defaultBackend`,
    /// `timestamp`) is missing / wrong-typed / unparseable. A malformed
    /// individual sub-dict is silently dropped (forward-compat). An empty
    /// `backends` array is permitted (decodes to a value with `backends == []`)
    /// — the receiver treats "no configured backends" as "keep prior state /
    /// clear", not "crash".
    static func decode(from dict: [String: Any]) -> RemoteAgentMultiBroadcastEnvelope? {
        guard
            let rawBackends = dict["backends"] as? [[String: Any]],
            let defaultBackendRef = dict["defaultBackend"] as? String,
            !defaultBackendRef.isEmpty,
            let timestamp = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }
        // `defaultBackendRef` accepts ANY non-empty ref string (built-in OR
        // `"custom_<uuid>"`) — no `RemoteAgentBackend(rawValue:)` gate, so a
        // custom default round-trips. The Watch parses it via
        // `RemoteAgentRef(rawString:)`.
        let backends = rawBackends.compactMap { RemoteAgentBroadcastEnvelope.decode(from: $0) }
        // `sessionPolicy` is OPTIONAL (back-compat): a missing / non-string value
        // decodes to nil so an old-iPhone envelope doesn't strand an upgraded
        // Watch. A non-empty string round-trips verbatim; the Watch validates it
        // against `SessionContinuationPolicy(rawValue:)` at apply time.
        let sessionPolicy = (dict["sessionPolicy"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Teardown is honored ONLY as an explicit `true` alongside an empty RAW
        // array. Requiring `rawBackends.isEmpty` (not `backends.isEmpty`) is the
        // point: a sender that claims teardown while shipping sub-envelopes is
        // self-contradictory, and a receiver that dropped every sub-dict as
        // malformed must not read its own parse failure as an instruction to
        // destroy credentials. Either contradiction resolves to the
        // non-destructive reading.
        let clearAll: Bool? = (dict["clearAll"] as? Bool) == true && rawBackends.isEmpty ? true : nil
        // Only an explicit `false` means anything; a missing or wrong-typed value
        // decodes to nil, which the receiver reads as "chosen" — the pre-existing
        // behaviour, so an old iPhone's envelope is unaffected.
        let defaultBackendChosen: Bool? = (dict["defaultBackendChosen"] as? Bool) == false ? false : nil
        return RemoteAgentMultiBroadcastEnvelope(
            backends: backends,
            defaultBackendRef: defaultBackendRef,
            timestamp: timestamp,
            sessionPolicy: sessionPolicy,
            clearAll: clearAll,
            defaultBackendChosen: defaultBackendChosen
        )
    }
}
