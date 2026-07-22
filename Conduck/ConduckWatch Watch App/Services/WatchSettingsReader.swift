import Foundation

/// Lightweight settings reader for watchOS.
/// Reads directly from iCloud KVS (App Groups UserDefaults don't sync between devices).
/// Falls back to WCSession receivedApplicationContext for additional settings.
///
/// Scope: STT preset + preferred-language only. Personalization
/// fields (fullName, addresses, custom vocabulary) are stripped —
/// Conduck has no Smart-Context / vocabulary surface.
@Observable
final class WatchSettingsReader {
    static let shared = WatchSettingsReader()

    private let kvs = NSUbiquitousKeyValueStore.default

    /// Watch-local App Group UserDefaults — durable across cold launch. Holds
    /// the cert fingerprint (which iOS keeps per-device, NOT in KVS), so
    /// a cold ControlWidget launch can pin without a live envelope.
    private let appGroupDefaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard

    // MARK: - Cached settings

    /// Active STT preset ID. Updated ONLY via
    /// `updateActiveSTT(presetID:apiKey:timestamp:)` — the WCSession
    /// `applicationContext` path no longer touches this; the envelope is
    /// the only source (WCSession atomicity). Initial value is
    /// the V1 default until the first envelope arrives.
    private(set) var activePresetID: String = Constants.sttActivePresetIDDefault

    /// Preferred transcription language hint (ISO 639-1). Optional — STT provider
    /// auto-detects when nil.
    var preferredLanguage: String?

    /// Active preset's optional custom model override (Feature 1 — Custom STT).
    /// Updated ONLY via `updateActiveSTT(...)` from an `STTBroadcastEnvelope`
    /// (the iPhone is the single source — no separate Watch KVS read, which
    /// would reopen the torn-read race against the atomic envelope). Nil = the
    /// provider's pinned default model. `WatchSTTRequest` reads this so a Gemini
    /// override rewrites the upload URL and a Qwen override changes the body tag.
    /// Mirrored to the Watch App Group so a cold ControlWidget launch (which
    /// rehydrates `activePresetID` from KVS before the first live envelope) can
    /// still resolve the override device-locally.
    private(set) var activeCustomModel: String?

    /// In-memory cache of the active STT preset's API key. Populated when iPhone
    /// broadcasts via WCSession `transferUserInfo`. **NOT persisted here** — the
    /// canonical store is the Watch Keychain owned by `WatchIdentityResolver`
    /// (account = `Constants.sttApiKeyKeychainAccount(for: activePresetID)`).
    /// This property exists as a fast in-memory lookup for hot paths; callers
    /// that need authoritative retrieval (e.g., cold-launch ControlWidget) should
    /// hit `WatchIdentityResolver.getSTTAPIKey(forPresetID:)`.
    ///
    /// Watch caches ONE key — the active provider's only — never a
    /// per-preset dict. iPhone re-broadcasts whenever the active preset
    /// switches.
    var apiKey: String?

    /// Highest monotonic timestamp observed in an STT envelope from iPhone.
    /// `updateActiveSTT(presetID:apiKey:timestamp:)` rejects any envelope
    /// with `timestamp <= lastEnvelopeTimestamp` — defeats out-of-order
    /// queue drains after wake.
    private(set) var lastEnvelopeTimestamp: TimeInterval = 0

    // MARK: - TTS cached state (cloud Text-to-Speech)
    //
    // The active TTS provider + its shared API key + the optional voice override
    // ride the SAME atomic `STTBroadcastEnvelope` as the STT triple, committed
    // under the SAME monotonic-timestamp guard (`updateActiveSTT(...)`), so no
    // reader observes a torn STT/TTS state. The other agent's `WatchReplySpeaker`
    // reads these three properties to fetch cloud TTS on the wrist (falling back
    // to Apple's synthesizer on any failure).

    /// Active TTS provider id (matches `TTSProvider.id`). Defaults to
    /// `Constants.ttsActiveProviderIDDefault` (`apple-tts`) until the first
    /// envelope arrives. Mirrored to the Watch App Group for cold-launch
    /// resolution (parity with `activePresetID`).
    private(set) var activeTTSProviderID: String = Constants.ttsActiveProviderIDDefault

    /// Optional TTS voice override (`tts.voice.<id>`). Nil = the provider's
    /// pinned `defaultVoice`. Mirrored to the Watch App Group for cold launch.
    private(set) var ttsVoice: String?

    /// Optional per-provider TTS MODEL override (`tts.customModel.<id>`). Nil =
    /// the provider's pinned `model`. Rides the SAME atomic envelope as
    /// `ttsVoice`; `WatchReplySpeaker` passes it to `WatchTTSClient.synthesize`
    /// so the wrist sends the override instead of `provider.model`. Mirrored to
    /// the Watch App Group for cold launch.
    private(set) var ttsCustomModel: String?

    /// In-memory cache of the active TTS provider's API key (read from the
    /// vendor's SHARED `stt.apiKey.<…>` slot on the iPhone). **NOT persisted**
    /// here — like the STT `apiKey`, it lives only in memory; nil for keyless
    /// Apple TTS. Privacy invariant: never log or print.
    private(set) var ttsApiKey: String?

    // MARK: - Remote Agent (Personal AI) cached state
    //
    // In-memory cache hydrated by `updateRemoteAgent(...)` when iPhone
    // broadcasts a `RemoteAgentBroadcastEnvelope`. Persistent storage
    // for the bearer token lives in Watch Keychain (via
    // `WatchIdentityResolver.setRemoteAgentToken(_:)`) so cold-launch
    // ControlWidget paths survive without an iPhone round-trip.

    /// Active Personal AI gateway backend ref (single-envelope mirror), as a
    /// `rawString` ("openclaw" / "hermes" / "custom_<uuid>"). Hydrated at init
    /// from iCloud KVS (durable across cold launch — iOS dual-writes it),
    /// then refreshed by the live envelope. Non-nil on a cold ControlWidget
    /// launch when the gateway is configured. The legacy
    /// `remoteAgentBackend` computed accessor (per-ref section below) derives a
    /// `RemoteAgentBackend?` from this for built-in-only readers.
    private(set) var remoteAgentBackendRef: String?

    /// Active Personal AI gateway base URL. Hydrated at init from iCloud KVS
    /// (durable across cold launch — iOS dual-writes it), then refreshed
    /// by the live envelope.
    private(set) var remoteAgentURL: URL?

    /// Optional pinned SHA-256 fingerprint (lowercase hex) for the gateway's
    /// leaf cert. Nil = default ATS chain validation. Hydrated at init from the
    /// Watch App Group UserDefaults (iOS keeps it per-device, not in KVS;
    /// the Watch persists its own copy when the envelope arrives), so a cold
    /// ControlWidget launch pins correctly without a live envelope.
    private(set) var remoteAgentCertFingerprint: String?

    /// Active conversation session ID
    /// (`spec.md "Settings & Storage"`). Nil = no live session. Cross-
    /// device continuity: Watch adopts whatever the iPhone broadcasts so
    /// a conversation started on iPhone can continue on Watch within the
    /// session-continuation policy window.
    private(set) var remoteAgentActiveSession: String?

    /// Highest monotonic timestamp observed in a Personal AI envelope.
    /// `updateRemoteAgent(...)` / `updateRemoteAgents(multi:)` reject any
    /// envelope with `timestamp <= lastRemoteAgentEnvelopeTimestamp` — defeats
    /// out-of-order queue drains after wake. SHARED high-water mark across the
    /// single + multi envelopes so a stale single-envelope drain can't clobber
    /// a fresher multi-envelope and vice versa.
    private(set) var lastRemoteAgentEnvelopeTimestamp: TimeInterval = 0

    // MARK: - Remote Agent — Per-Ref cached state (custom-gateways)
    //
    // Decision D — full multi-gateway Watch support, extended to custom gateways.
    // The Watch receives ALL configured gateways (built-ins + customs) via the
    // `RemoteAgentMultiBroadcastEnvelope` and routes each conversation to ITS
    // bound REF. URL + cert + name + model are cached per ref STRING
    // ("openclaw" / "hermes" / "custom_<uuid>"); the per-ref bearer token lives
    // in Watch Keychain (`WatchIdentityResolver.getRemoteAgentToken(for: String)`).
    //
    // Cold-launch durability: per-ref URL is mirrored to iCloud KVS + Watch App
    // Group (iOS dual-writes URL); per-ref cert is Watch App Group only
    // (iOS keeps cert per-device, not KVS); the custom ROSTER (name/model/badge)
    // is persisted as `[CustomGateway]` JSON under `customGatewaysRegistryKey`
    // in the Watch App Group — this IS the known-customs index used to clear
    // dropped per-ref slots. `remoteAgentDefaultBackendRef` mirrors the iPhone
    // default pointer (KVS + App Group).

    /// Per-ref cached gateway base URLs (keyed by `rawString`). Hydrated by
    /// `updateRemoteAgents(multi:)` and the cold-launch durable-store rehydrate.
    private(set) var remoteAgentURLs: [String: URL] = [:]

    /// Per-ref cached pinned SHA-256 cert fingerprints (lowercase hex).
    /// Absent key = default ATS chain validation for that ref.
    private(set) var remoteAgentCertFingerprints: [String: String] = [:]

    /// Per-ref cached optional model name (customs only; built-ins absent → nil,
    /// gateway default). Threaded into the Watch converse body when present.
    private(set) var remoteAgentModels: [String: String] = [:]

    /// Per-ref cached auth scheme (`.bearer` / `.none`). Absent key resolves to
    /// `.bearer` (fail closed). A `.none` ref is keyless — sendable on URL alone,
    /// no Authorization header. Set ONLY from an explicit envelope `authScheme`,
    /// never inferred from a missing token.
    private(set) var remoteAgentAuthSchemes: [String: RemoteAgentAuthScheme] = [:]

    /// Per-ref cached file-transfer READINESS (the iPhone's
    /// `fileTransferReadySnapshot(for:) != nil` gate, couriered in each
    /// sub-envelope's `fileTransferAvailable`). Absent key = not ready (false).
    /// The wrist can't evaluate readiness itself (the file-server credential
    /// never syncs to it), so this cache IS its only source. Read at converse
    /// time by `WatchAudioUploader.uploadConverse` to decide whether the
    /// (spoken) turn carries the per-turn file-delivery instruction — a capable
    /// device that later opens the thread renders the download chip via the
    /// retroactive output-scan. Rebuilt ATOMICALLY per multi-envelope so a ref
    /// dropped (or gone not-ready) on the iPhone never retains a stale `true`.
    private(set) var remoteAgentFileTransferReadyByRef: [String: Bool] = [:]

    /// The custom-gateway roster received via the multi-envelope and persisted to
    /// the Watch App Group (`customGatewaysRegistryKey`). Source of truth for a
    /// custom's name / model / badge AND the known-customs index for clearing
    /// dropped per-ref slots. Empty for a built-ins-only install.
    private(set) var customGateways: [CustomGateway] = []

    /// Default ref a freshly-minted (Watch-originated) conversation binds to when
    /// no per-conversation backend is known, as a `rawString`. Hydrated from KVS
    /// / App Group on cold launch, refreshed by the multi-envelope. Falls back to
    /// `Constants.remoteAgentDefaultBackendDefault` (`.openclaw`) when unset.
    private(set) var remoteAgentDefaultBackendRef: String?

    /// Active Personal AI gateway backend (single-envelope mirror). Kept for the
    /// legacy single-config readers; derived from `remoteAgentBackendRef`.
    var remoteAgentBackend: RemoteAgentBackend? {
        guard let raw = remoteAgentBackendRef,
              case .builtin(let backend)? = RemoteAgentRef(rawString: raw) else { return nil }
        return backend
    }

    /// The default ref a Watch-minted conversation should bind to, as a
    /// `rawString`. Reads the hydrated/broadcast `remoteAgentDefaultBackendRef`,
    /// falling back to the reference gateway default. Mirrors
    /// `SettingsManager.defaultRemoteAgentRef().rawString`.
    var defaultBackendRef: String {
        remoteAgentDefaultBackendRef ?? Constants.remoteAgentDefaultBackendDefault.rawValue
    }

    /// All refs currently configured ON THIS WATCH (cached URL + Keychain token
    /// present), built-ins first (`RemoteAgentBackend.allCases` order) then
    /// customs (roster order). Parity with the iOS
    /// `SettingsManager.configuredRemoteAgentRefs()`. Drives the in-app "Ask"
    /// gateway chooser: ≥2 → present a picker; 1 → straight to record.
    func configuredBackendRefs() -> [String] {
        var refs: [String] = RemoteAgentBackend.allCases
            .map(\.rawValue)
            .filter { remoteAgentConfig(for: $0) != nil }
        for gateway in customGateways {
            let ref = gateway.ref.rawString
            if remoteAgentConfig(for: ref) != nil {
                refs.append(ref)
            }
        }
        return refs
    }

    // MARK: - In-app "Ask" pending new-conversation backend hint
    //
    // One-shot, device-local intent set by the in-app "Ask" button before
    // `startRecording()`. `resolveActiveConversationAndBackend()` consumes it
    // FIRST: present → mint a NEW conversation bound to that backend (always-new
    // + gateway choice); absent → existing headless policy fallthrough. Persisted
    // to the Watch App Group (NOT iCloud KVS) because the converse hop can be
    // re-entered in a relaunched process via the background-STT-fallback delegate
    // — an in-memory flag would be lost and the turn would silently fall back to
    // the default gateway (violating the no-silent-reroute invariant). App-Group
    // (not KVS) so this transient intent never syncs to another device.

    /// Set the pending in-app new-conversation ref hint (a `rawString`).
    /// Privacy/routing: device-local only. A custom ref ("custom_<uuid>") must
    /// survive intact, so the value is the raw ref string — NOT enum-filtered.
    func setPendingInAppNewConversationBackend(_ ref: String) {
        appGroupDefaults.set(ref, forKey: Constants.remoteAgentPendingInAppNewConversationBackendKey)
    }

    /// Read THEN remove the pending hint (one-shot). Returns the ref string if a
    /// hint was present, else nil. Removing on read guarantees a single
    /// consumption — a second consume returns nil. No `RemoteAgentRef(rawString:)`
    /// gate here — a "custom_<uuid>" ref must round-trip; the routing caller
    /// validates configuration downstream (nil config → not-configured, no reroute).
    func consumePendingInAppNewConversationBackend() -> String? {
        guard let raw = appGroupDefaults.string(forKey: Constants.remoteAgentPendingInAppNewConversationBackendKey) else {
            return nil
        }
        appGroupDefaults.removeObject(forKey: Constants.remoteAgentPendingInAppNewConversationBackendKey)
        return raw
    }

    /// Clear the pending hint without consuming its value. Called on every
    /// reset-to-idle path (cancel / converse-hop error) so a cancelled in-app
    /// Ask can't leave a stale hint for a later headless trigger to consume.
    func clearPendingInAppNewConversationBackend() {
        appGroupDefaults.removeObject(forKey: Constants.remoteAgentPendingInAppNewConversationBackendKey)
    }

    private init() {
        loadFromiCloudKVS()
        observeChanges()
    }

    // MARK: - Public API

    /// Update settings from WCSession application context.
    /// Tolerant decoder — unknown keys ignored, missing keys leave
    /// existing cached value untouched.
    ///
    /// **STT preset is NOT updated here** — the iPhone no longer broadcasts
    /// `sttActivePresetIDKVSKey` via applicationContext (WCSession
    /// atomicity). The envelope path (`updateActiveSTT(...)`) is the only
    /// source for active preset + API key. This method handles
    /// `preferredLanguage` and the "Enable on Watch" master switch (both
    /// non-secret, idempotent).
    func updateFromContext(_ context: [String: Any]) {
        if let lang = context[Constants.sttPreferredLanguageKVSKey] as? String, !lang.isEmpty {
            preferredLanguage = lang
        }
        // "Enable on Watch" master switch — the low-latency copy
        // (`PhoneSessionManager.setWatchEnabled` dual-writes iCloud KVS +
        // applicationContext). Persist to the App-Group mirror (read FIRST by
        // `refreshWatchEnabledCache()`) so a laggy KVS sync can never roll a
        // delivered toggle back, then commit the render-path cache. Latest-
        // value semantics — no timestamp guard (applicationContext is a
        // single latest snapshot).
        if let enabled = context[Constants.watchEnabledKey] as? Bool {
            appGroupDefaults.set(enabled, forKey: Constants.watchEnabledKey)
            watchEnabledCache = enabled
        }
    }

    /// Watch App Group key for the active preset's custom model override.
    /// Device-local (NOT iCloud KVS): the iPhone broadcasts the override inside
    /// the atomic `STTBroadcastEnvelope`, and we persist the accepted value here
    /// only so a cold ControlWidget launch (which rehydrates `activePresetID`
    /// from KVS) resolves the same override before the first live envelope. A
    /// separate KVS read would reopen the torn-read race the envelope closes.
    private static let activeCustomModelKey = "watch.activeCustomModel"

    /// Watch App Group keys for the active TTS provider + voice override
    /// (cold-launch durability). Device-local (NOT iCloud KVS): the iPhone
    /// broadcasts the TTS triple inside the atomic `STTBroadcastEnvelope`, and
    /// we persist the accepted provider/voice here only so a cold ControlWidget
    /// launch resolves the same TTS state before the first live envelope. The
    /// TTS API key stays in-memory only (parity with the STT `apiKey`).
    private static let activeTTSProviderIDKey = "watch.activeTTSProviderID"
    private static let ttsVoiceKey = "watch.ttsVoice"
    private static let ttsCustomModelKey = "watch.ttsCustomModel"

    /// Watch App Group key for the persisted remote-agent monotonic high-water
    /// timestamp. Device-local (NOT iCloud KVS): `lastRemoteAgentEnvelopeTimestamp`
    /// must survive a Watch process restart so an OLD queued `transferUserInfo`
    /// envelope replayed after relaunch can't regress the effective default. The
    /// in-memory property is hydrated from this slot at first read (before any
    /// queued envelope is applied) and re-persisted whenever an envelope is
    /// accepted — the discard guard then compares against the persisted value.
    private static let lastRemoteAgentEnvelopeTimestampKey = "watch.lastRemoteAgentEnvelopeTimestamp"

    /// Atomic update for { activePresetID, apiKey, activeCustomModel, the TTS
    /// triple, lastEnvelopeTimestamp } triggered by an incoming
    /// `STTBroadcastEnvelope`. Rejects out-of-order envelopes via the monotonic-
    /// timestamp guard (returns `false` if the supplied timestamp is not strictly
    /// greater than the highest seen so far). On accept, updates all fields
    /// together so no caller can observe a torn state (presetID-B + key-A, or
    /// STT-B + TTS-A).
    ///
    /// `customModel` + the TTS args are additive (defaulted nil) so the
    /// pre-Custom-STT / pre-TTS call shapes stay valid; the live
    /// `WatchSessionManager` path threads the envelope's fields through.
    ///
    /// Returns `true` if the envelope was applied; `false` if it was rejected
    /// as stale.
    @discardableResult
    func updateActiveSTT(
        presetID: String,
        apiKey: String?,
        customModel: String? = nil,
        ttsProviderID: String? = nil,
        ttsApiKey: String? = nil,
        ttsVoice: String? = nil,
        ttsCustomModel: String? = nil,
        timestamp: TimeInterval
    ) -> Bool {
        guard timestamp > lastEnvelopeTimestamp else { return false }
        self.activePresetID = presetID
        // `apiKey` is optional — nil means the active
        // provider is keyless (Apple on-device). We clear the cached
        // in-memory key on nil so any post-switch consult observes the
        // correct "no key for this active provider" state.
        self.apiKey = apiKey
        // Feature 1 (Custom STT): apply the per-preset model override inside the
        // same monotonic guard so it's part of the atomic commit. Empty/nil →
        // clear (provider's pinned default applies). Mirror to the Watch App
        // Group for cold-launch durability.
        let normalizedModel = (customModel?.isEmpty == false) ? customModel : nil
        self.activeCustomModel = normalizedModel
        if let normalizedModel {
            appGroupDefaults.set(normalizedModel, forKey: Self.activeCustomModelKey)
        } else {
            appGroupDefaults.removeObject(forKey: Self.activeCustomModelKey)
        }
        // TTS: commit the TTS triple under the SAME monotonic guard. A legacy
        // envelope carries no TTS fields (`ttsProviderID == nil`) — fall back to
        // the default so an un-upgraded iPhone never strands the wrist on a stale
        // cloud TTS provider. API key is in-memory only; provider + voice mirror
        // to the App Group for cold launch.
        let resolvedTTSProviderID = (ttsProviderID?.isEmpty == false)
            ? ttsProviderID!
            : Constants.ttsActiveProviderIDDefault
        self.activeTTSProviderID = resolvedTTSProviderID
        appGroupDefaults.set(resolvedTTSProviderID, forKey: Self.activeTTSProviderIDKey)
        self.ttsApiKey = ttsApiKey
        let normalizedVoice = (ttsVoice?.isEmpty == false) ? ttsVoice : nil
        self.ttsVoice = normalizedVoice
        if let normalizedVoice {
            appGroupDefaults.set(normalizedVoice, forKey: Self.ttsVoiceKey)
        } else {
            appGroupDefaults.removeObject(forKey: Self.ttsVoiceKey)
        }
        // Per-provider TTS MODEL override — committed under the SAME guard
        // (parity with `ttsVoice` / the STT `customModel`). Empty/nil → clear
        // (the provider's pinned `model` applies). Mirror to the App Group for
        // cold-launch durability.
        let normalizedTTSModel = (ttsCustomModel?.isEmpty == false) ? ttsCustomModel : nil
        self.ttsCustomModel = normalizedTTSModel
        if let normalizedTTSModel {
            appGroupDefaults.set(normalizedTTSModel, forKey: Self.ttsCustomModelKey)
        } else {
            appGroupDefaults.removeObject(forKey: Self.ttsCustomModelKey)
        }
        self.lastEnvelopeTimestamp = timestamp
        return true
    }

    /// Atomic update for { remoteAgentBackend, remoteAgentURL,
    /// remoteAgentCertFingerprint, remoteAgentActiveSession,
    /// lastRemoteAgentEnvelopeTimestamp } triggered by an incoming
    /// `RemoteAgentBroadcastEnvelope`. Rejects out-of-order envelopes via
    /// the monotonic-timestamp guard (returns `false` if the supplied
    /// timestamp is not strictly greater than the highest seen so far).
    /// On accept, all five fields update together so no caller observes
    /// a torn state (URL-B + fingerprint-A).
    ///
    /// **Token persistence is NOT this method's job** — Keychain write
    /// lives in `WatchSessionManager.didReceiveUserInfo` via
    /// `WatchIdentityResolver.setRemoteAgentToken(_:)`. Splitting these
    /// keeps the in-memory cache synchronous and the Keychain side-
    /// effect async, mirroring the STT split.
    ///
    /// Returns `true` if the envelope was applied; `false` if it was
    /// rejected as stale.
    @discardableResult
    func updateRemoteAgent(
        backend: RemoteAgentBackend,
        url: URL,
        fingerprint: String?,
        authScheme: RemoteAgentAuthScheme = .bearer,
        sessionID: String?,
        timestamp: TimeInterval
    ) -> Bool {
        guard timestamp > lastRemoteAgentEnvelopeTimestamp else { return false }
        let ref = RemoteAgentRef.builtin(backend).rawString
        self.remoteAgentBackendRef = ref
        self.remoteAgentURL = url
        self.remoteAgentCertFingerprint = fingerprint
        self.remoteAgentActiveSession = sessionID
        self.lastRemoteAgentEnvelopeTimestamp = timestamp
        // Persist the accepted high-water so a relaunch rejects an OLD queued
        // envelope replay (the discard guard above compares against this value).
        appGroupDefaults.set(timestamp, forKey: Self.lastRemoteAgentEnvelopeTimestampKey)

        // Cold-launch durability: persist url + backend + fingerprint to the
        // Watch App Group UserDefaults so a fresh ControlWidget process resolves
        // the gateway with no live envelope. URL + backend ALSO arrive via
        // iCloud KVS (iOS dual-write), but persisting them here too means the
        // Watch is correct even before KVS syncs to it. Fingerprint has no other
        // durable Watch source (iOS keeps it per-device, not in KVS).
        appGroupDefaults.set(backend.rawValue, forKey: Constants.remoteAgentBackendKey)
        appGroupDefaults.set(url.absoluteString, forKey: Constants.remoteAgentURLKey)
        if let fingerprint, !fingerprint.isEmpty {
            appGroupDefaults.set(fingerprint, forKey: Constants.remoteAgentCertFingerprintKey)
        } else {
            appGroupDefaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        }

        // Also seed the PER-REF caches + App-Group slots for this single
        // backend so multi-aware routing (`remoteAgentConfig(for:)`) resolves it
        // even on a legacy-iPhone (single-envelope) install. The single envelope
        // is built-in-only (an un-upgraded iPhone has no customs), so this only
        // ever seeds a built-in ref. The token is seeded into the per-ref
        // Keychain slot by the caller (`WatchSessionManager`).
        remoteAgentURLs[ref] = url
        appGroupDefaults.set(url.absoluteString, forKey: Constants.remoteAgentURLKey(for: backend))
        if let fingerprint, !fingerprint.isEmpty {
            remoteAgentCertFingerprints[ref] = fingerprint
            appGroupDefaults.set(fingerprint, forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
        } else {
            remoteAgentCertFingerprints[ref] = nil
            appGroupDefaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
        }
        // Seed the per-ref auth scheme too (symmetry with the multi path) so a
        // legacy single-envelope `.none` resolves keyless on the wrist rather than
        // reading the fail-closed `.bearer` default + nil token → not-sendable.
        remoteAgentAuthSchemes[ref] = authScheme
        appGroupDefaults.set(authScheme.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: backend))
        // The single envelope carries no default pointer; treat its backend as
        // the default for a legacy install (matches the iPhone single-gateway
        // world where the only configured backend IS the default).
        if remoteAgentDefaultBackendRef == nil {
            remoteAgentDefaultBackendRef = ref
            appGroupDefaults.set(ref, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        }
        return true
    }

    /// Full multi-gateway Watch support. Atomic update
    /// from an incoming `RemoteAgentMultiBroadcastEnvelope`: store EVERY
    /// configured backend's URL + cert (in-memory per-backend caches + App-Group
    /// persistence per backend, mirroring the single-field persistence) plus the
    /// default-backend pointer. Rejects out-of-order envelopes via the SHARED
    /// monotonic high-water mark (returns `false` if `timestamp` is not strictly
    /// greater than the highest seen so far across single + multi envelopes).
    ///
    /// **Token persistence is NOT this method's job** — per-backend Keychain
    /// writes live in `WatchSessionManager.didReceiveUserInfo` via
    /// `WatchIdentityResolver.setRemoteAgentToken(_:for:)`, mirroring the
    /// single-envelope split. Also refreshes the single-envelope mirror fields
    /// (`remoteAgentBackend` / `remoteAgentURL` / `remoteAgentCertFingerprint`)
    /// to the DEFAULT backend so any legacy single-config reader stays coherent.
    ///
    /// Returns `true` if applied; `false` if rejected as stale.
    @discardableResult
    func updateRemoteAgents(multi envelope: RemoteAgentMultiBroadcastEnvelope) -> Bool {
        guard envelope.timestamp > lastRemoteAgentEnvelopeTimestamp else { return false }

        // Rebuild the per-ref caches from this envelope (authoritative snapshot of
        // "all configured refs"). A ref dropped from the configured set on iPhone
        // disappears from these caches + its App-Group slots, so a Watch route to
        // a now-unconfigured ref resolves nil. The custom display fields (name /
        // model / colorID / monogram) ride each sub-envelope and rebuild the
        // local roster below.
        var newURLs: [String: URL] = [:]
        var newCerts: [String: String] = [:]
        var newModels: [String: String] = [:]
        var newAuthSchemes: [String: RemoteAgentAuthScheme] = [:]
        var newFileTransferReady: [String: Bool] = [:]
        var newCustoms: [CustomGateway] = []
        for sub in envelope.backends {
            let ref = sub.backendRef
            newURLs[ref] = sub.url
            // Per-ref file-transfer readiness (the iPhone's ready-gate value).
            // Only the refs in THIS envelope populate the map, so a ref dropped
            // (or gone not-ready) on the iPhone is absent below → false; the
            // atomic reassignment of `remoteAgentFileTransferReadyByRef` at the
            // end drops any stale `true` for an omitted ref.
            newFileTransferReady[ref] = sub.fileTransferAvailable
            if let fp = sub.certFingerprintHex, !fp.isEmpty {
                newCerts[ref] = fp
            }
            if let model = sub.model, !model.isEmpty {
                newModels[ref] = model
            }
            // EXPLICIT auth scheme (default `.bearer` on the wire) — keyless is
            // honored only via this field, never inferred from a missing token.
            newAuthSchemes[ref] = sub.authScheme
            // Reconstruct the roster entry for a custom sub-envelope (built-ins
            // carry nil name and are skipped). The name is REQUIRED for a custom
            // (the iPhone builder always sets it); a nameless custom sub is
            // treated as malformed and dropped from the roster (its config still
            // routes via the per-ref slots, but it can't badge/label).
            if case .custom(let id)? = RemoteAgentRef(rawString: ref), let name = sub.name {
                newCustoms.append(CustomGateway(
                    id: id,
                    name: name,
                    model: sub.model,
                    colorID: sub.colorID,
                    monogram: sub.monogram
                ))
            }
        }

        // Known-customs reconciliation: clear App-Group URL/cert slots + Watch
        // Keychain token for any custom ref in the OLD roster that is ABSENT from
        // the NEW envelope (the user deleted that gateway on iPhone). Built-ins
        // are enumerable via `allCases` below; customs are not, so the persisted
        // roster is the only index of which custom slots might linger.
        let newCustomRefs = Set(newCustoms.map { $0.ref.rawString })
        for oldGateway in customGateways {
            let ref = oldGateway.ref.rawString
            guard !newCustomRefs.contains(ref) else { continue }
            appGroupDefaults.removeObject(forKey: Constants.remoteAgentURLKey(for: oldGateway.ref))
            appGroupDefaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: oldGateway.ref))
            appGroupDefaults.removeObject(forKey: Constants.remoteAgentAuthSchemeKey(for: oldGateway.ref))
            appGroupDefaults.removeObject(forKey: Constants.fileTransferAvailableKey(for: oldGateway.ref))
            Task { await WatchIdentityResolver.shared.clearRemoteAgentToken(for: ref) }
        }

        // Persist per-BUILT-IN url + cert to the Watch App Group (cold-launch
        // durability). Walk ALL built-in cases so a built-in removed from
        // `envelope.backends` has its stale App-Group slots cleared too.
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend).rawString
            if let url = newURLs[ref] {
                appGroupDefaults.set(url.absoluteString, forKey: Constants.remoteAgentURLKey(for: backend))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.remoteAgentURLKey(for: backend))
            }
            if let fp = newCerts[ref] {
                appGroupDefaults.set(fp, forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: backend))
            }
            if let scheme = newAuthSchemes[ref] {
                appGroupDefaults.set(scheme.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: backend))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.remoteAgentAuthSchemeKey(for: backend))
            }
            // Per-ref readiness (cold-launch durability, same App-Group key
            // family the iPhone uses; on the wrist it is written ONLY from the
            // envelope, never locally). Present → write; absent → clear the
            // stale slot so a removed / no-longer-ready built-in doesn't
            // resurrect `true` on the next cold hydrate.
            if let ready = newFileTransferReady[ref] {
                appGroupDefaults.set(ready, forKey: Constants.fileTransferAvailableKey(for: .builtin(backend)))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.fileTransferAvailableKey(for: .builtin(backend)))
            }
        }

        // Persist per-CUSTOM url + cert to the Watch App Group (cold-launch
        // durability). Customs present in the new envelope write their slots; the
        // dropped ones were cleared in the reconciliation loop above.
        for gateway in newCustoms {
            let ref = gateway.ref.rawString
            if let url = newURLs[ref] {
                appGroupDefaults.set(url.absoluteString, forKey: Constants.remoteAgentURLKey(for: gateway.ref))
            }
            if let fp = newCerts[ref] {
                appGroupDefaults.set(fp, forKey: Constants.remoteAgentCertFingerprintKey(for: gateway.ref))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: gateway.ref))
            }
            if let scheme = newAuthSchemes[ref] {
                appGroupDefaults.set(scheme.rawValue, forKey: Constants.remoteAgentAuthSchemeKey(for: gateway.ref))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.remoteAgentAuthSchemeKey(for: gateway.ref))
            }
            if let ready = newFileTransferReady[ref] {
                appGroupDefaults.set(ready, forKey: Constants.fileTransferAvailableKey(for: gateway.ref))
            } else {
                appGroupDefaults.removeObject(forKey: Constants.fileTransferAvailableKey(for: gateway.ref))
            }
        }

        // Persist the custom roster (App Group JSON) — the known-customs index for
        // the next reconciliation + the cold-launch source for badge/label.
        persistCustomGatewaysToAppGroup(newCustoms)

        remoteAgentURLs = newURLs
        remoteAgentCertFingerprints = newCerts
        remoteAgentModels = newModels
        remoteAgentAuthSchemes = newAuthSchemes
        // ATOMIC replacement — a ref omitted from this envelope (deleted or gone
        // not-ready on the iPhone) drops out of the map entirely, so
        // `remoteAgentFileTransferReady(for:)` returns false for it rather than
        // retaining a stale `true`.
        remoteAgentFileTransferReadyByRef = newFileTransferReady
        customGateways = newCustoms

        // Effective-default change → clear this Watch's OWN active-conversation
        // pointer (mirrors the iPhone `setDefaultRemoteAgentRef` local clear): the
        // envelope's `defaultBackendRef` is the WATCH-EFFECTIVE default (iPhone
        // already folds in any Watch-specific override). When it DIFFERS from the
        // currently-stored ref, the next headless capture must mint a FRESH thread
        // on the new default instead of reviving the old thread on its prior bound
        // gateway within the continuation TTL (defeats an A→B→A-within-TTL revival).
        // Compared against the stored value BEFORE overwriting so a same-value
        // re-delivery never clears (no spurious thread reset). The pointer is the
        // Watch's own per-device App-Group state, disjoint from the iPhone's.
        let oldDefaultRef = remoteAgentDefaultBackendRef
        remoteAgentDefaultBackendRef = envelope.defaultBackendRef
        appGroupDefaults.set(envelope.defaultBackendRef, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        if oldDefaultRef != envelope.defaultBackendRef {
            clearActiveConversation()
        }

        // Cache the Watch-effective session-continuation policy (iPhone's
        // override or its own per-device value) into this Watch's App Group,
        // read FIRST by `sessionContinuationPolicy()`. Replaces the old live-KVS
        // courier. Validate the raw value before persisting (forward-compat: an
        // unknown raw is ignored, leaving the prior cached value intact). A
        // nil `sessionPolicy` (old iPhone) leaves the cache untouched.
        if let rawPolicy = envelope.sessionPolicy,
           SessionContinuationPolicy(rawValue: rawPolicy) != nil {
            appGroupDefaults.set(rawPolicy, forKey: Constants.sessionContinuationPolicyKey)
        }

        // Adopt the activeSessionID from the default ref's sub-envelope (the
        // session pointer is global, Decision A — every sub-envelope carries the
        // same value; read the default's, falling back to any present).
        let defaultSub = envelope.backends.first { $0.backendRef == envelope.defaultBackendRef }
        remoteAgentActiveSession = (defaultSub ?? envelope.backends.first)?.activeSessionID

        // Keep the single-envelope mirror fields coherent for any legacy reader
        // (points at the default ref's config).
        if let dSub = defaultSub ?? envelope.backends.first {
            remoteAgentBackendRef = dSub.backendRef
            remoteAgentURL = dSub.url
            remoteAgentCertFingerprint = dSub.certFingerprintHex
        }

        lastRemoteAgentEnvelopeTimestamp = envelope.timestamp
        // Persist the accepted high-water (parity with the single-envelope path)
        // so a relaunch rejects an OLD queued multi-envelope replay.
        appGroupDefaults.set(envelope.timestamp, forKey: Self.lastRemoteAgentEnvelopeTimestampKey)
        return true
    }

    /// Persist the received custom-gateway roster to the Watch App Group under
    /// `customGatewaysRegistryKey` (the iPhone uses the SAME key in its own App
    /// Group). This is BOTH the cold-launch source for a custom's name / model /
    /// badge AND the known-customs index used by the next `updateRemoteAgents`
    /// to clear dropped per-ref slots. NEVER written to KVS (the roster carries
    /// no secrets, but mirroring the iPhone App-Group-first posture keeps the
    /// Watch coherent without a sync round-trip).
    private func persistCustomGatewaysToAppGroup(_ list: [CustomGateway]) {
        if list.isEmpty {
            appGroupDefaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        } else if let data = try? JSONEncoder().encode(list) {
            appGroupDefaults.set(data, forKey: Constants.customGatewaysRegistryKey)
        }
    }

    /// Routing resolver. Returns the `(url, token, cert, model)` tuple for
    /// a SPECIFIC ref (a `rawString`), or nil when that ref is not configured on
    /// this Watch (no cached URL OR no Keychain token). The routing caller maps
    /// nil to the existing "not configured" error path (Decision B — no silent
    /// reroute to default). Token is read from the per-ref Watch Keychain slot;
    /// cert from the per-ref cache (nil = ATS default trust); model from the
    /// per-ref model cache (nil for built-ins → gateway default; omitted from the
    /// converse body).
    func remoteAgentConfig(for ref: String) -> (url: URL, token: String, authScheme: RemoteAgentAuthScheme, cert: String?, model: String?)? {
        guard let url = remoteAgentURLs[ref] else { return nil }
        let scheme = remoteAgentAuthSchemes[ref] ?? .bearer
        let storedToken = WatchIdentityResolver.getRemoteAgentToken(for: ref)
        // `.bearer` requires a non-empty token (fail closed — keyless is NEVER
        // inferred from a missing token); `.none` (keyless) routes on URL alone.
        if scheme.requiresToken, (storedToken?.isEmpty ?? true) {
            return nil
        }
        return (url, storedToken ?? "", scheme, remoteAgentCertFingerprints[ref], remoteAgentModels[ref])
    }

    /// Whether the gateway bound to `ref` (a `rawString`) has a READY file lane,
    /// per the iPhone-couriered per-ref cache. Absent key → false (a ref never
    /// broadcast, or one whose readiness was dropped and REPLACED out of the map
    /// by a newer multi-envelope). The Watch converse dispatch reads this to
    /// gate the per-turn file-delivery instruction on its spoken turns.
    func remoteAgentFileTransferReady(for ref: String) -> Bool {
        remoteAgentFileTransferReadyByRef[ref] ?? false
    }

    /// Resolve the pinned cert fingerprint for a gateway by HOST.
    /// The background converse `URLSession` is shared across backends, so its
    /// per-challenge trust handler can't capture a single backend's cert; it
    /// matches the challenge's `protectionSpace.host` against the per-backend
    /// URL caches to find the right pin. Falls back to the single-config
    /// `remoteAgentCertFingerprint` (covers a legacy install whose per-backend
    /// cache rebuild hasn't populated yet). Nil = ATS default trust.
    func remoteAgentCertFingerprint(forHost host: String) -> String? {
        // EDGE: two gateways fronted on the SAME host differing only by port is
        // an unsupported self-signed-pin case — `URL.host` ignores the port, so
        // the first matching ref's pin wins. Distinct hosts is the documented
        // pinning recipe.
        for (ref, url) in remoteAgentURLs where url.host == host {
            if let cert = remoteAgentCertFingerprints[ref] {
                return cert
            }
        }
        // Legacy single-config fallback (same host).
        if remoteAgentURL?.host == host {
            return remoteAgentCertFingerprint
        }
        return nil
    }

    // MARK: - Active-conversation pointer (PER-DEVICE — Watch App Group)
    //
    // Mirrors the iOS `SettingsManager.resolveActiveConversationID(now:)` /
    // `recordActiveConversation(_:)` semantics. The pointer is PER-DEVICE by
    // design: it lives in the Watch's App-Group UserDefaults (shared with the
    // widget-extension process for cold ControlWidget launches), NOT iCloud
    // KVS — a Mac/iPhone-side write must never steer which thread the wrist
    // continues, and vice versa. (The old KVS placement documented a
    // cross-device-convergence goal that was wrong by design AND never worked:
    // iOS never mirrored these keys to KVS.) Written by IMPLICIT (headless)
    // captures only — the pinned in-thread composer is EXPLICIT and must not
    // retarget the quick lane. The pointer selects which `Conversation`
    // a Watch capture appends to within the session-continuation policy
    // window; past it the caller mints a fresh conversation. NEVER sent on
    // the wire. Key strings match the iOS Constants for greppability,
    // but the stores are disjoint by construction (each device's App Group is
    // local to it). The policy below still arrives via the iPhone-only KVS
    // courier — iPhone and Watch deliberately share ONE policy value.

    /// Resolve the active conversation pointer for a Watch capture, gated by the
    /// user's session-continuation policy (`sessionContinuationPolicy()`). Returns
    /// the stored `Conversation.id` IFF a pointer exists AND the policy says to
    /// continue; otherwise nil (the caller mints a fresh conversation and records
    /// it). Mirrors the iOS `SettingsManager.resolveActiveConversationID(now:)`:
    /// the two extremes (`alwaysNew` / `alwaysContinue`) are branched, NOT compared
    /// arithmetically, and the timed cases clamp `elapsed` to 0 so a backward clock
    /// jump can't flip the decision.
    /// `now` is injectable for deterministic reasoning; production passes `Date()`.
    func resolveActiveConversationID(now: Date = Date()) -> UUID? {
        guard let raw = appGroupDefaults.string(forKey: Constants.remoteAgentActiveConversationIDKey),
              let id = UUID(uuidString: raw) else {
            return nil
        }
        let lastActivity = appGroupDefaults.double(forKey: Constants.remoteAgentActiveConversationActivityKey)
        // `double(forKey:)` returns 0 for a missing key — treat 0 as "no valid
        // stamp" so an ID written without a timestamp is never resolved fresh.
        guard lastActivity > 0 else { return nil }
        // Delegate to the policy's shared pure resolver — the same branch the iOS
        // `SettingsManager` uses, so the two surfaces can never drift.
        return sessionContinuationPolicy()
            .resolvedConversationID(id: id, lastActivity: lastActivity, now: now)
    }

    /// Record a successful Watch turn against `conversationID`, stamping the
    /// pointer's `lastActivityAt` to `now` so the next capture inside the TTL
    /// window continues this thread. Uses `timeIntervalSinceReferenceDate` to
    /// match `resolveActiveConversationID(now:)`. CALLER CONTRACT: implicit
    /// (headless) turns only — explicit (pinned-composer) turns must not
    /// retarget the quick lane (see the section comment above).
    func recordActiveConversation(_ conversationID: UUID, now: Date = Date()) {
        appGroupDefaults.set(conversationID.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)
        appGroupDefaults.set(now.timeIntervalSinceReferenceDate, forKey: Constants.remoteAgentActiveConversationActivityKey)
        // Hygiene: scrub the pre-redesign KVS copies of these keys (the
        // pointer used to live in iCloud KVS). Nothing reads them anymore;
        // idempotent removes keep stale values out of KVS audits and the
        // 1 MB quota.
        kvs.removeObject(forKey: Constants.remoteAgentActiveConversationIDKey)
        kvs.removeObject(forKey: Constants.remoteAgentActiveConversationActivityKey)
    }

    /// Clear this Watch's OWN active-conversation pointer (both App-Group keys).
    /// Called when an accepted multi-envelope changes the Watch-effective default
    /// ref — mirroring the iOS `SettingsManager.setDefaultRemoteAgentRef` local
    /// clear so the next headless capture mints a FRESH thread on the new default
    /// instead of reviving the prior thread on its old bound gateway within the
    /// continuation TTL. App-Group only (the pointer never lived in live KVS);
    /// idempotent (a no-pointer state stays a no-op).
    func clearActiveConversation() {
        appGroupDefaults.removeObject(forKey: Constants.remoteAgentActiveConversationIDKey)
        appGroupDefaults.removeObject(forKey: Constants.remoteAgentActiveConversationActivityKey)
    }

    // MARK: - Session-continuation policy

    /// Watch read of the session-continuation policy. Falls back to
    /// `SessionContinuationPolicy.default` (`.minutes30`) when no value is stored
    /// or the stored raw value is unknown (forward-compat). The iPhone owns this
    /// preference (its Watch override, else its own per-device value); it is
    /// delivered Watch-ward in the multi-gateway broadcast envelope's
    /// `sessionPolicy` slot and cached by `updateRemoteAgents(multi:)` into the
    /// App Group, so a cold-launch ControlWidget converse path resolves the
    /// active-conversation pointer without an iPhone round-trip. Mirrors the iOS
    /// `SettingsManager.getSessionContinuationPolicy()` and the read-priority of
    /// `readRepliesAloud()`.
    func sessionContinuationPolicy() -> SessionContinuationPolicy {
        // App-Group (envelope-couriered) is PRIMARY. iCloud KVS is a one-time
        // legacy seed for the first cold launch right after the update (before
        // any new-format envelope arrives) — the iPhone no longer writes it.
        if let raw = appGroupDefaults.string(forKey: Constants.sessionContinuationPolicyKey),
           let value = SessionContinuationPolicy(rawValue: raw) {
            return value
        }
        if let raw = kvs.string(forKey: Constants.sessionContinuationPolicyKey),
           let value = SessionContinuationPolicy(rawValue: raw) {
            return value
        }
        return SessionContinuationPolicy.default
    }

    // MARK: - "Enable on Watch" master switch

    /// Cached "Enable on Watch" flag backing `isWatchEnabled()`. Stored (and
    /// `@Observable`-tracked) so the launchpad's per-render reads are pure
    /// memory — a live probe would be a cross-process KVS read on every body
    /// evaluation. Default ON (a never-written flag reads as ON).
    private var watchEnabledCache = true

    /// Whether the agent surface is enabled on this Watch. Default ON when the
    /// iPhone has never written the flag. iPhone writes `Constants.watchEnabledKey`
    /// to iCloud KVS + applicationContext; the Watch suppresses the
    /// ControlWidget/record action when this returns false. Pure memory read —
    /// the cache refreshes via `loadFromiCloudKVS` (init + the KVS external-
    /// change observer), `updateFromContext` (the low-latency courier), and
    /// `WatchSessionManager.applyEnvelopePayload` (KVS-observer-miss heal).
    func isWatchEnabled() -> Bool { watchEnabledCache }

    /// Recompute the cached master switch from durable stores. iCloud KVS
    /// FIRST (the uncached read this cache replaced was KVS-only, and the
    /// iPhone's `setWatchEnabled` ALWAYS writes KVS but can only courier the
    /// applicationContext while `WCSession` is `.activated` — so a mirror-first
    /// read would let a stale mirror permanently shadow a KVS-only toggle; no
    /// envelope carries this flag, so nothing would ever heal it). The
    /// App-Group mirror (written by `updateFromContext`) covers only the
    /// install where KVS never syncs at all (`ubiquityIdentityToken` is nil on
    /// watchOS); the courier itself writes `watchEnabledCache` directly, so a
    /// fresh delivery wins the instant it lands regardless of KVS lag.
    func refreshWatchEnabledCache() {
        if kvs.object(forKey: Constants.watchEnabledKey) != nil {
            watchEnabledCache = kvs.bool(forKey: Constants.watchEnabledKey)
        } else if appGroupDefaults.object(forKey: Constants.watchEnabledKey) != nil {
            watchEnabledCache = appGroupDefaults.bool(forKey: Constants.watchEnabledKey)
        } else {
            // A never-written flag must read as ON, not the `bool(forKey:)`-
            // default of false — so probe object presence first.
            watchEnabledCache = true
        }
    }

    // MARK: - Read replies aloud (wrist toggle, iPhone-hosted)

    /// Whether replies to headless (ControlWidget/Action Button) and in-app
    /// Ask captures auto-speak on arrival / on notification-tap open. Default
    /// OFF when the iPhone has never written the flag (presence-probe first —
    /// here a never-written flag must read as OFF, the opposite polarity of
    /// `isWatchEnabled`). composer sends never consult this (in-chat hard rule).
    ///
    /// Source priority: the **WCSession-delivered App-Group mirror** is primary
    /// (reliable — `WatchSessionManager.applyEnvelopePayload` writes it on every
    /// broadcast + settings-pull, the same channel STT/gateway settings ride);
    /// iCloud KVS is the cold-launch fallback only. KVS-alone was the original
    /// courier and proved unreliable on watchOS (the flag often never arrived →
    /// arrival auto-speak silently stayed OFF). Presence-probe BOTH layers so a
    /// never-written flag still reads as OFF.
    func readRepliesAloud() -> Bool {
        if appGroupDefaults.object(forKey: Constants.watchReadRepliesAloudKey) != nil {
            return appGroupDefaults.bool(forKey: Constants.watchReadRepliesAloudKey)
        }
        if kvs.object(forKey: Constants.watchReadRepliesAloudKey) == nil { return false }
        return kvs.bool(forKey: Constants.watchReadRepliesAloudKey)
    }

    /// Persist the WCSession-couriered "Replies on Apple Watch" toggle to the
    /// App-Group mirror (read FIRST by `readRepliesAloud()`). Called from
    /// `WatchSessionManager.applyEnvelopePayload` on every broadcast / pull, so
    /// both ON and OFF land reliably without waiting on iCloud KVS.
    func cacheReadRepliesAloud(_ speak: Bool) {
        appGroupDefaults.set(speak, forKey: Constants.watchReadRepliesAloudKey)
    }

    // MARK: - First-run welcome (one-time, Watch-local)

    /// Whether the one-time Watch welcome (`WatchOnboardingView`) has already
    /// been shown+dismissed on this install. App-Group ONLY — device-local
    /// first-run state, never couriered from the iPhone and never mirrored to
    /// iCloud KVS (the wrist is the sole writer, and KVS is unreliable on
    /// watchOS). Defaults false (unseen) via the bare `bool(forKey:)` read — a
    /// never-written flag correctly reads as "not yet seen".
    func hasSeenOnboarding() -> Bool {
        appGroupDefaults.bool(forKey: Constants.watchOnboardingSeenKey)
    }

    /// Mark the one-time Watch welcome as seen so it never shows again. Called
    /// ONLY from the "Got it" tap (never on mere appearance), so a killed or
    /// interrupted first launch re-shows the screen.
    func markOnboardingSeen() {
        appGroupDefaults.set(true, forKey: Constants.watchOnboardingSeenKey)
    }

    // MARK: - iCloud KVS

    private func loadFromiCloudKVS() {
        // Read locally cached values (no synchronize — avoids blocking main thread).
        // `preferredLanguage` stays UNguarded — non-secret latest-value courier;
        // the envelope never carries it, so there is no fresher state to stomp.
        if let lang = kvs.string(forKey: Constants.sttPreferredLanguageKVSKey), !lang.isEmpty {
            preferredLanguage = lang
        }

        // "Enable on Watch" master switch — latest-value semantics like
        // `preferredLanguage` (no envelope carries it, so no timestamp guard);
        // recomputed here so the KVS external-change observer path refreshes
        // the render-path cache.
        refreshWatchEnabledCache()

        // Cold-launch hydration — guarded by `lastEnvelopeTimestamp == 0` (no
        // envelope applied THIS process) so an observer-fired mid-session reload
        // can never stomp a fresher envelope value with KVS's eventually-
        // consistent copy.
        if lastEnvelopeTimestamp == 0 {
            // Active preset ID: the KVS slot is a cold-launch mirror only — the
            // atomic envelope is the sole live source (WCSession
            // atomicity). Hydrating it unguarded used to let a KVS-change
            // reload roll an applied envelope's preset back to the stale
            // synced value (parity fix with the customModel/TTS hydrates below).
            if let presetID = kvs.string(forKey: Constants.sttActivePresetIDKVSKey), !presetID.isEmpty {
                activePresetID = presetID
            }

            // Feature 1 (Custom STT): rehydrate the active preset's custom model
            // override from the Watch App Group (where the last accepted envelope
            // mirrored it) so a fresh ControlWidget process resolves the override
            // before any live envelope arrives.
            let stored = appGroupDefaults.string(forKey: Self.activeCustomModelKey)
            activeCustomModel = (stored?.isEmpty == false) ? stored : nil

            // TTS cold-launch hydration: rehydrate the active TTS provider +
            // voice override from the Watch App Group (where the last accepted
            // envelope mirrored them) so a fresh ControlWidget process resolves
            // the same TTS state before any live envelope arrives. The TTS API
            // key is in-memory only (no durable Watch source) — a cold-launch
            // TTS path falls back to Apple's synthesizer until the first
            // envelope re-delivers the key, matching the STT in-memory posture.
            let storedTTS = appGroupDefaults.string(forKey: Self.activeTTSProviderIDKey)
            activeTTSProviderID = (storedTTS?.isEmpty == false)
                ? storedTTS!
                : Constants.ttsActiveProviderIDDefault
            let storedVoice = appGroupDefaults.string(forKey: Self.ttsVoiceKey)
            ttsVoice = (storedVoice?.isEmpty == false) ? storedVoice : nil
            let storedTTSModel = appGroupDefaults.string(forKey: Self.ttsCustomModelKey)
            ttsCustomModel = (storedTTSModel?.isEmpty == false) ? storedTTSModel : nil
        }

        // Cold-launch hydration: resolve the remote-agent config from durable
        // stores so a fresh ControlWidget process has URL+backend+fingerprint
        // before any live envelope arrives. Only hydrate fields the live envelope
        // hasn't already set (`lastRemoteAgentEnvelopeTimestamp == 0` = no
        // envelope this process), so a KVS-change reload never clobbers a fresher
        // envelope. Backend + URL: iCloud KVS (iOS dual-write) with the
        // Watch-local App Group copy as a same-device fallback before KVS syncs.
        // Fingerprint: Watch App Group only (iOS keeps it per-device).
        //
        // ORDER: this config hydrate runs BEFORE the persisted-high-water
        // rehydrate below, because both share the `== 0` guard — bumping the
        // high-water first would make this branch see a non-zero value and skip
        // cold-launch config resolution.
        if lastRemoteAgentEnvelopeTimestamp == 0 {
            hydrateRemoteAgentFromDurableStores()
        }

        // Persisted high-water hydration: rehydrate the remote-agent monotonic
        // timestamp from the Watch App Group AFTER the durable-store config
        // hydrate (so its `== 0` guard above still fires) but BEFORE any queued
        // envelope is applied — a queued `transferUserInfo` envelope is delivered
        // only after this singleton finishes constructing. This makes a relaunch
        // after an accepted envelope reject an OLD queued replay that would
        // otherwise regress the effective default. Only hydrate while the
        // in-memory value is still 0 (no envelope accepted this process) so an
        // observer-fired reload can't reset a fresher in-memory high-water; the
        // accept paths re-persist this slot, so it is never staler than memory.
        if lastRemoteAgentEnvelopeTimestamp == 0 {
            let storedHighWater = appGroupDefaults.double(forKey: Self.lastRemoteAgentEnvelopeTimestampKey)
            if storedHighWater > lastRemoteAgentEnvelopeTimestamp {
                lastRemoteAgentEnvelopeTimestamp = storedHighWater
            }
        }

        // Trigger sync in background — observer reloads when new data arrives
        Task.detached {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// Cold-launch hydration of the remote-agent config from durable stores
    /// (iCloud KVS for url/backend, Watch App Group for fingerprint). Idempotent;
    /// only fills fields that are still unset so it can't stomp envelope updates.
    private func hydrateRemoteAgentFromDurableStores() {
        if remoteAgentBackendRef == nil {
            // Single-envelope mirror is built-in-only on a legacy install; the
            // multi-aware mirror below can be a custom ref. The legacy
            // `remoteAgentBackendKey` slot only ever held a built-in raw value.
            let rawBackend = kvs.string(forKey: Constants.remoteAgentBackendKey)
                ?? appGroupDefaults.string(forKey: Constants.remoteAgentBackendKey)
            if let rawBackend, RemoteAgentRef(rawString: rawBackend) != nil {
                remoteAgentBackendRef = rawBackend
            }
        }
        // Cold-launch hydrate the custom roster from the Watch App Group FIRST so
        // the per-custom URL/cert hydration below has the known-customs index.
        if customGateways.isEmpty,
           let data = appGroupDefaults.data(forKey: Constants.customGatewaysRegistryKey),
           let list = try? JSONDecoder().decode([CustomGateway].self, from: data) {
            customGateways = list
        }
        if remoteAgentURL == nil {
            let rawURL = kvs.string(forKey: Constants.remoteAgentURLKey)
                ?? appGroupDefaults.string(forKey: Constants.remoteAgentURLKey)
            if let rawURL, !rawURL.isEmpty, let url = URL(string: rawURL) {
                remoteAgentURL = url
            }
        }
        if remoteAgentCertFingerprint == nil {
            let fp = appGroupDefaults.string(forKey: Constants.remoteAgentCertFingerprintKey)
            if let fp, !fp.isEmpty {
                remoteAgentCertFingerprint = fp
            }
        }

        // Per-ref cold-launch hydration. Rebuild the per-ref
        // URL + cert + model caches from durable stores (per-ref URL: iCloud KVS,
        // iOS dual-write — built-ins only — → Watch App Group fallback before KVS
        // syncs; per-ref cert: Watch App Group only; model: the roster). Built-ins
        // come from `allCases`; customs from the roster hydrated above. Only fill
        // when the caches are still empty (no multi-envelope this process) so a
        // KVS-change reload can't stomp a fresher envelope.
        if remoteAgentURLs.isEmpty {
            var urls: [String: URL] = [:]
            var certs: [String: String] = [:]
            var models: [String: String] = [:]
            var schemes: [String: RemoteAgentAuthScheme] = [:]
            var ready: [String: Bool] = [:]
            // Built-in refs (URL dual-written to KVS by iOS; App Group fallback).
            for backend in RemoteAgentBackend.allCases {
                let ref = RemoteAgentRef.builtin(backend).rawString
                let rawURL = kvs.string(forKey: Constants.remoteAgentURLKey(for: backend))
                    ?? appGroupDefaults.string(forKey: Constants.remoteAgentURLKey(for: backend))
                if let rawURL, !rawURL.isEmpty, let url = URL(string: rawURL) {
                    urls[ref] = url
                }
                if let fp = appGroupDefaults.string(forKey: Constants.remoteAgentCertFingerprintKey(for: backend)),
                   !fp.isEmpty {
                    certs[ref] = fp
                }
                if let rawScheme = appGroupDefaults.string(forKey: Constants.remoteAgentAuthSchemeKey(for: backend)) {
                    schemes[ref] = RemoteAgentAuthScheme.from(rawValue: rawScheme)
                }
                // Readiness: Watch App Group only (the envelope-couriered copy,
                // written above). Absent → not persisted; leave the key out so
                // `remoteAgentFileTransferReady(for:)` defaults false.
                if let r = appGroupDefaults.object(forKey: Constants.fileTransferAvailableKey(for: .builtin(backend))) as? Bool {
                    ready[ref] = r
                }
            }
            // Custom refs (URL + cert in the Watch App Group only — the multi
            // envelope is the sole source; iOS does not KVS-write custom URLs to
            // the Watch's store. Model comes from the roster entry).
            for gateway in customGateways {
                let ref = gateway.ref.rawString
                if let rawURL = appGroupDefaults.string(forKey: Constants.remoteAgentURLKey(for: gateway.ref)),
                   !rawURL.isEmpty, let url = URL(string: rawURL) {
                    urls[ref] = url
                }
                if let fp = appGroupDefaults.string(forKey: Constants.remoteAgentCertFingerprintKey(for: gateway.ref)),
                   !fp.isEmpty {
                    certs[ref] = fp
                }
                if let model = gateway.model, !model.isEmpty {
                    models[ref] = model
                }
                if let rawScheme = appGroupDefaults.string(forKey: Constants.remoteAgentAuthSchemeKey(for: gateway.ref)) {
                    schemes[ref] = RemoteAgentAuthScheme.from(rawValue: rawScheme)
                }
                if let r = appGroupDefaults.object(forKey: Constants.fileTransferAvailableKey(for: gateway.ref)) as? Bool {
                    ready[ref] = r
                }
            }
            remoteAgentURLs = urls
            remoteAgentCertFingerprints = certs
            remoteAgentModels = models
            remoteAgentAuthSchemes = schemes
            remoteAgentFileTransferReadyByRef = ready
        }
        if remoteAgentDefaultBackendRef == nil {
            // DEVICE-LOCAL: the Watch default now comes from the couriered +
            // persisted envelope (`updateRemoteAgents` writes the Watch-effective
            // default to the App Group), NOT a live KVS read — mirroring the
            // iPhone's device-local posture. Read the App Group ONLY here so a
            // LATE iCloud-KVS write (from another device's old global default)
            // can't change THIS Watch's default after a relaunch.
            var rawDefault = appGroupDefaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey)
            // Legacy seed (AT MOST ONCE): the very first launch of this build on a
            // Watch that pre-dates device-local persistence has no App-Group value
            // yet but may carry the old KVS-synced default. Read KVS once, then
            // immediately mirror it into the App Group so every subsequent read —
            // including observer-fired reloads — is App-Group-only and a later KVS
            // write never steers the default again.
            if rawDefault == nil,
               let kvsDefault = kvs.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
               RemoteAgentRef(rawString: kvsDefault) != nil {
                appGroupDefaults.set(kvsDefault, forKey: Constants.remoteAgentDefaultBackendKVSKey)
                rawDefault = kvsDefault
            }
            // Accept any valid ref string (built-in OR custom) — no enum gate, so
            // a custom default round-trips on cold launch.
            if let rawDefault, RemoteAgentRef(rawString: rawDefault) != nil {
                remoteAgentDefaultBackendRef = rawDefault
            }
        }
    }

    private func observeChanges() {
        // Deliberately NOT gated on `FileManager.default.ubiquityIdentityToken`:
        // that token tracks iCloud DRIVE availability, and iCloud Drive doesn't
        // exist on watchOS — so it is ALWAYS nil there, which made the old
        // guard dead-code this observer on every Watch (KVS changes never
        // triggered a reload). NSUbiquitousKeyValueStore itself is supported
        // on watchOS 9+; observing on a device without iCloud is harmless
        // (the notifications simply never fire).
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] _ in
            self?.loadFromiCloudKVS()
        }
    }
}
