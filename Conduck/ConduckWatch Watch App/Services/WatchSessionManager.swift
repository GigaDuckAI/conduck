// SPDX-License-Identifier: Apache-2.0

import Foundation
import Combine
import WatchConnectivity

/// Sendable bridge for a WCSession / notification payload dictionary crossing
/// an isolation boundary. `[String: Any]` is not `Sendable`; these payloads
/// are plist-compatible by framework contract, so a binary-plist deep copy
/// carries them race-free and the receiving side re-materializes the
/// dictionary inside its own isolation. The shared envelope decoders
/// (`STTBroadcastEnvelope` etc.) are MainActor-isolated under the target's
/// default isolation, so domain decoding stays on the MainActor — only these
/// opaque bytes cross. `keyCount` rides along for metadata-only logging
/// (payload VALUES carry API keys/tokens and must never be logged).
nonisolated struct SendablePlistPayload: Sendable {
    private let plist: Data?
    let keyCount: Int

    init(_ payload: [String: Any]) {
        plist = try? PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        keyCount = payload.count
    }

    /// Re-materialize the dictionary. Nil only if the payload was not
    /// plist-clean — impossible by WCSession's own send-time validation, but
    /// the caller drops the payload (logged count-only) rather than crashing.
    func dictionary() -> [String: Any]? {
        guard let plist else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        )) as? [String: Any]
    }
}

/// Transport seam for the interactive settings pull. Owns BOTH the session
/// gate (activated + reachable) and the `sendMessage` round-trip, so the
/// whole reachability-dependent path is fake-able in ConduckWatchTests — a
/// fake that only wrapped the send would never be reached behind a live
/// `WCSession` gate.
protocol SettingsPullTransport {
    /// One pull round-trip. Returns the reply payload — possibly an EMPTY
    /// dict (nothing configured on the iPhone yet — valid, applies as a
    /// no-op) — or nil on not-activated / unreachable / send error.
    func performPull() async -> [String: Any]?
}

/// Production transport: `WCSession.default`. Exactly one of the two
/// `sendMessage` handlers fires, so the continuation resumes exactly once.
/// The handlers arrive on an arbitrary WCSession queue; the reply dict is
/// bridged across as `SendablePlistPayload` (same posture as the delegate
/// ingress) and re-materialized on the caller's side of the continuation.
struct WCSessionSettingsPullTransport: SettingsPullTransport {
    func performPull() async -> [String: Any]? {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return nil }
        let bridged: SendablePlistPayload? = await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                [AppleSpeechRelayCoordinator.Wire.kindKey: Constants.settingsPullMessageKind],
                replyHandler: { continuation.resume(returning: SendablePlistPayload($0)) },
                errorHandler: { _ in continuation.resume(returning: nil) }
            )
        }
        return bridged?.dictionary()
    }
}

/// Watch-side WCSession delegate for receiving identity and settings from the iPhone app.
///
/// Delegate conformances are `nonisolated` (the codebase's AV-delegate pattern
/// — see `WatchReplySpeaker`): WCSession delivers callbacks on its private
/// serial queue, and a MainActor-isolated conformance forces a synchronous
/// main-thread bridge per callback (the logged "unsafeForcedSync" hazard),
/// coupling WCSession's queue to main-thread saturation and vice versa. Each
/// callback does pure Sendable extraction on the framework queue, then hops
/// via `Task { @MainActor }` carrying only typed Sendable values; every state
/// mutation stays on the MainActor.
final class WatchSessionManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var isCompanionReachable = false

    /// Settings-pull transport (gate + `sendMessage` round-trip live behind
    /// it). Production always rides the WCSession default; ConduckWatchTests
    /// construct their own instance with a fake — such an instance never
    /// calls `activate()`, so it observes no live session.
    private let pullTransport: SettingsPullTransport

    init(pullTransport: SettingsPullTransport = WCSessionSettingsPullTransport()) {
        self.pullTransport = pullTransport
        super.init()
    }

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate (required)

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Pure Sendable extraction on WCSession's queue; all state work hops
        // below. The `receivedApplicationContext` identity probe also lives
        // inside the hop (its `Constants` key is MainActor-isolated under the
        // target's default isolation) — it reads the same `WCSession.default`
        // this delegate is wired to.
        let errorCode = (error as NSError?)?.code ?? 0
        let isReachable = session.isReachable

        Task { @MainActor in
            WatchLog.note(.session, "wc.activated", ["state": activationState.rawValue, "err": errorCode])
            self.isCompanionReachable = isReachable

            // Check if application context already has a user ID
            if let userID = WCSession.default.receivedApplicationContext[Constants.iCloudKVSUserIDKey] as? String,
               !userID.isEmpty {
                Task {
                    await WatchIdentityResolver.shared.didReceiveUserID(userID)
                }
            }

            // Settings pull, trigger (a): activation with the iPhone already
            // reachable. A fresh install otherwise sits on the apple-on-device
            // default until the lazy transferUserInfo queue drains; one
            // interactive round-trip resolves the real config now. Idempotent
            // (timestamp-guarded), so racing the queue drain is harmless.
            if activationState == .activated, isReachable {
                Task { _ = await self.pullSettingsFromPhone() }
            }
        }
    }

    // MARK: - Application Context (settings + identity from iPhone)

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let bridged = SendablePlistPayload(applicationContext)
        Task { @MainActor in
            WatchLog.note(.session, "wc.context", ["keys": bridged.keyCount])
            guard let context = bridged.dictionary() else {
                WatchLog.error(.session, "wc.context.bridgedrop", ["keys": bridged.keyCount])
                return
            }

            // Handle identity
            if let userID = context[Constants.iCloudKVSUserIDKey] as? String, !userID.isEmpty {
                Task {
                    await WatchIdentityResolver.shared.didReceiveUserID(userID)
                }
            }

            // Handle settings update
            WatchSettingsReader.shared.updateFromContext(context)
        }
    }

    // MARK: - Direct Messages (real-time identity request responses)

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Two unsolicited kinds arrive here, both on the INTERACTIVE channel,
        // both because latency is the point — and EACH reads its discriminator
        // through its OWN contract's key constant. The two constants hold the
        // same literal today, so one shared read would compile and behave
        // identically; it would also make a rename of either contract's key a
        // SILENT break of the other's interactive lane, with no compile error
        // and a wrong-branch fall-through at runtime. That is precisely the
        // failure mode the relay's duplicated wire strings already cost us once.
        let relayKind = message[AppleSpeechRelayCoordinator.Wire.kindKey] as? String
        let courierKind = message[AttachedFileCourierWire.kindKey] as? String

        // Agent-file courier, interactive lane. The iPhone sends every batch on
        // BOTH channels; this is the one that makes a file row appear in about a
        // second while the user is still looking at the thread. The queued copy
        // (`didReceiveUserInfo`) owns the delivery guarantee, and ingestion is
        // keyed on (message, stored key), so whichever arrives second is free.
        if courierKind == AttachedFileCourierWire.kindValue {
            let bridged = SendablePlistPayload(message)
            Task { @MainActor in
                guard let payload = bridged.dictionary() else {
                    WatchLog.error(.session, "wc.message.bridgedrop", ["keys": bridged.keyCount])
                    return
                }
                Self.ingestAgentFileCourier(payload, lane: "msg")
            }
            return
        }

        // Relay-reply ingress #2 (interactive channel). When the Watch is
        // reachable AND the request stamped `replySendMessageOK`, the iPhone
        // sends the transcript verdict via `sendMessage` for snappy delivery
        // instead of the queued `transferUserInfo` path. Same payload shape,
        // same handler as the userInfo route below — the coordinator
        // correlates by requestID either way, and the queue's claim-token
        // reconcile dedups if BOTH channels ever deliver the same reply.
        guard relayKind == AppleSpeechRelayCoordinator.Wire.replyKind else {
            // No other unsolicited-message kinds are defined for the Watch.
            return
        }
        let bridged = SendablePlistPayload(message)
        Task { @MainActor in
            WatchLog.note(.session, "wc.message", ["kind": "relay-reply", "keys": bridged.keyCount])
            guard let payload = bridged.dictionary() else {
                WatchLog.error(.session, "wc.message.bridgedrop", ["keys": bridged.keyCount])
                return
            }
            await AppleSpeechRelayCoordinator.shared.handleReply(payload)
        }
    }

    // MARK: - Interactive phone → watch messages (diagnostics pull)

    /// iPhone → Watch messages sent WITH a replyHandler land HERE — WCSession
    /// routes by the SENDER's replyHandler presence, so the relay-reply ships
    /// the phone sends with `replyHandler: nil` keep hitting the no-reply
    /// handler above; adding this overload steals nothing. Exactly one kind
    /// exists today: the Diagnostics `diagnostics-pull` health query (local
    /// reads only — versions, envelope high-waters, relay queue depth, the
    /// Watch's own permission STATUS; never a URL/token/name). Unknown kinds
    /// reply `[:]` IMMEDIATELY (a future phone asking something this build
    /// doesn't know must never dangle into its timeout); the phone reads a
    /// version-less `[:]` as "unsupported", not as a health report.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        // Pure Sendable extraction on the framework queue; the reply closure
        // crosses into the MainActor hop wrapped in a thread-safe ONE-SHOT
        // (`WatchOneShotReply`) so exactly one branch can ever deliver it.
        let kind = message[AppleSpeechRelayCoordinator.Wire.kindKey] as? String
        let reply = WatchOneShotReply(replyHandler)
        guard kind == Constants.watchDiagnosticsPullMessageKind else {
            reply.send([:])
            return
        }
        Task { @MainActor in
            let payload = await WatchDiagnosticsReporter.currentReply()
            WatchLog.note(.session, "wc.diagpull", ["keys": payload.count])
            reply.send(payload)
        }
    }

    // MARK: - UserInfo Queue (secret-class payloads, e.g. STT envelope)

    /// Receives queued payloads from iPhone (delivered once, survives wrist drops).
    /// iPhone's
    /// `PhoneSessionManager.broadcastToWatch()` uses `transferUserInfo` with the
    /// envelope key `Constants.sttActivePresetEnvelopeKey` carrying
    /// `{ presetID, apiKey, timestamp }` as the SOLE source of Watch STT state
    /// (`applicationContext` no longer carries `sttActivePresetIDKVSKey` —
    /// defeats the torn-read race between the two channels).
    ///
    /// Forward-compat: unknown envelope keys are ignored.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Apple-speech relay reply. Route to the coordinator
        // BEFORE any other shape-checks — relay replies are correlated by
        // requestID and don't carry envelope/identity keys; dispatching
        // first avoids redundant decode attempts on every reply.
        let isRelayReply = (userInfo[AppleSpeechRelayCoordinator.Wire.kindKey] as? String)
            == AppleSpeechRelayCoordinator.Wire.replyKind
        // Agent-file courier, QUEUED lane — the durable spine. This one delivers
        // even when the wrist was unreachable or asleep when the iPhone attached
        // the file, which is why it exists alongside the interactive lane above.
        let isFileCourier = (userInfo[AttachedFileCourierWire.kindKey] as? String)
            == AttachedFileCourierWire.kindValue
        let bridged = SendablePlistPayload(userInfo)
        Task { @MainActor in
            WatchLog.note(.session, "wc.userinfo", ["relay": isRelayReply, "keys": bridged.keyCount])
            guard let payload = bridged.dictionary() else {
                WatchLog.error(.session, "wc.userinfo.bridgedrop", ["keys": bridged.keyCount])
                return
            }
            if isRelayReply {
                await AppleSpeechRelayCoordinator.shared.handleReply(payload)
                return
            }
            if isFileCourier {
                Self.ingestAgentFileCourier(payload, lane: "userinfo")
                return
            }
            // Forward-compat: anything else falls through to the settings
            // decoder, which is key-driven and no-ops on a payload carrying none
            // of its keys. That is exactly how an OLDER wrist build absorbs a
            // courier batch it has never heard of — harmlessly.
            await self.applyEnvelopePayload(payload)
        }
    }

    // MARK: - Agent-file courier ingress

    /// Decode one courier batch, absorb it, and wake the UI.
    ///
    /// Posting `.conversationsDidChange` is the whole delivery mechanism on this
    /// side: `WatchConversationViewModel` observes it, coalesces the burst, and
    /// re-runs BOTH the list reload and — via `selectedConversationID` — the open
    /// thread's refresh, so a user already staring at the conversation sees the
    /// row appear without leaving and re-entering it. `MessageRecord` equality
    /// includes its attachments, so the merged thread genuinely differs and the
    /// view model's no-op skip does not swallow it.
    ///
    /// Gated on the inbox ACTUALLY changing, because the iPhone sends every batch
    /// on both channels: a re-delivery must not cost a store fetch or a repaint.
    /// PRIVACY: the breadcrumb is counts and a lane label only — never a stored
    /// key (an opaque server path token) and never a filename (user content).
    @MainActor
    private static func ingestAgentFileCourier(_ payload: [String: Any], lane: String) {
        let descriptors = AttachedFileCourierWire.decode(payload)
        guard !descriptors.isEmpty else {
            WatchLog.note(.session, "wc.agentfiles.empty", ["lane": lane])
            return
        }
        let changed = WatchAttachmentInbox.shared.ingest(descriptors)
        WatchLog.note(.session, "wc.agentfiles", [
            "lane": lane,
            "items": descriptors.count,
            "new": changed
        ])
        guard changed else { return }
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
    }

    /// Decode + apply a settings payload. Shared by BOTH ingress channels:
    /// the queued `transferUserInfo` delegate above and the interactive
    /// `pullSettingsFromPhone()` reply (the iPhone's pull handler returns the
    /// SAME payload shape its broadcast queues). Idempotent — every commit
    /// runs through the monotonic-timestamp guards, so replaying a payload
    /// (or racing the pull against a queue drain) can never regress state.
    ///
    /// Application is INLINE-awaited — no fire-and-forget hops: when this
    /// returns, Keychain + in-memory state are fully committed. Load-bearing
    /// for the pull path, whose callers resolve the active STT provider the
    /// moment the await completes. Ordering preserved from the pre-extraction
    /// delegate: Keychain write (durable side-effect) BEFORE the in-memory
    /// commit (hot-path cache). Stale-envelope rejection is `if`/`else`, not
    /// an early return — one stale envelope must not suppress the other keys
    /// riding the same payload.
    @MainActor
    func applyEnvelopePayload(_ payload: [String: Any]) async {
        let applyStarted = Date()
        // STT envelope (presetID + apiKey + monotonic timestamp).
        if let envelopeDict = payload[Constants.sttActivePresetEnvelopeKey] as? [String: Any],
           let envelope = STTBroadcastEnvelope.decode(from: envelopeDict) {
            // Drop-stale guard: discard envelopes older than the highest
            // seen so far. Defeats out-of-order delivery after queue
            // drain at wake.
            let lastSeen = WatchSettingsReader.shared.lastEnvelopeTimestamp
            if envelope.timestamp > lastSeen {
                // Persist key to per-preset Keychain slot first, then commit
                // the atomic in-memory triple-update. Keychain write is the
                // durable side-effect; in-memory state is the hot-path cache.
                //
                // Nil-handling: a nil `envelope.apiKey` means the
                // active provider is keyless (Apple on-device). Skip the
                // Keychain write entirely — we keep no slot for keyless
                // providers and the in-memory `apiKey` becomes nil. The
                // Apple-active path routes audio via `AppleSpeechRelayCoordinator`,
                // which doesn't consult any key.
                if let apiKey = envelope.apiKey {
                    await WatchIdentityResolver.shared.setSTTAPIKey(
                        apiKey,
                        forPresetID: envelope.presetID
                    )
                }
                _ = WatchSettingsReader.shared.updateActiveSTT(
                    presetID: envelope.presetID,
                    apiKey: envelope.apiKey,
                    customModel: envelope.customModel,
                    // TTS: thread the envelope's TTS triple through the SAME
                    // atomic commit (mirrors how `customModel` is threaded). The
                    // TTS API key is in-memory only — no separate Keychain write
                    // (the active TTS provider's key already round-trips via its
                    // SHARED STT slot when STT for that vendor is configured).
                    ttsProviderID: envelope.ttsProviderID,
                    ttsApiKey: envelope.ttsApiKey,
                    ttsVoice: envelope.ttsVoice,
                    ttsCustomModel: envelope.ttsCustomModel,
                    timestamp: envelope.timestamp
                )
            } else {
                #if DEBUG
                print("[Watch] Discarding stale STT envelope (ts=\(envelope.timestamp) <= last=\(lastSeen))")
                #endif
            }
        }

        // "Replies on Apple Watch" auto-speak toggle. A plain bool (no monotonic
        // timestamp needed — latest WCSession write wins, FIFO-ordered), couriered
        // here so it reaches the wrist reliably instead of via KVS-only (which is
        // a laggy cold-launch fallback on watchOS). Persist to the App-Group mirror
        // that `WatchSettingsReader.readRepliesAloud()` now reads first.
        if let readAloud = payload[Constants.watchReadRepliesAloudKey] as? Bool {
            WatchSettingsReader.shared.cacheReadRepliesAloud(readAloud)
        }

        // Full multi-gateway Watch support. MULTI-gateway
        // envelope: ALL configured backends + the default pointer. Preferred
        // over the legacy single envelope so a Watch conversation routes to ITS
        // bound backend. Decode FIRST; if present + newer, persist EVERY
        // backend's per-backend token (Watch Keychain) before committing the
        // in-memory multi-config — so cold-launch routing sees a coherent
        // (token, URL, cert) triple per backend. NEVER write tokens to KVS.
        //
        // The `multiHandled` flag suppresses the legacy single-envelope branch
        // below when the multi key is present (avoids a redundant single update
        // that the shared high-water mark would reject anyway, plus keeps the
        // single-config mirror coherent with the multi snapshot).
        var multiHandled = false
        if let multiDict = payload[Constants.remoteAgentMultiEnvelopeKey] as? [String: Any],
           let multiEnvelope = RemoteAgentMultiBroadcastEnvelope.decode(from: multiDict) {
            multiHandled = true
            let lastSeen = WatchSettingsReader.shared.lastRemoteAgentEnvelopeTimestamp
            if multiEnvelope.timestamp > lastSeen {
                // Persist each ref's token to its per-ref Watch Keychain slot
                // (keyed by `sub.backendRef` — built-in OR custom). Keyless is
                // driven by the EXPLICIT `authScheme == .none`, NEVER by a missing
                // token: a transient iPhone Keychain read failure broadcasts a
                // `.bearer` sub with a nil token, and clearing on that would
                // permanently delete the Watch's stored token. So:
                //   • `.none`  → keyless: clear any stale token.
                //   • `.bearer` + token → persist it.
                //   • `.bearer` + nil token → PRESERVE the existing token.
                // Refs absent from `backends` keep whatever they had; a DELETED
                // custom's stale slots are cleared by `updateRemoteAgents`.
                if multiEnvelope.clearAll == true {
                    // TEARDOWN — the user forgot their last gateway. Order is
                    // INVERTED versus the write path below, deliberately: the
                    // commit is what re-checks and advances the high-water mark
                    // atomically, so doing it FIRST means an out-of-order
                    // teardown is rejected before it can destroy anything. The
                    // write path can safely persist tokens first (a token
                    // without config is inert); a destructive apply cannot —
                    // this method awaits, and the main actor is reentrant across
                    // those awaits, so a newer full envelope can interleave. Old
                    // ordering would let a stale teardown delete credentials the
                    // newer envelope had just installed.
                    //
                    // Capture the doomed refs BEFORE the commit — it replaces
                    // the roster and the URL map that name them.
                    //
                    // The roster is NOT a sufficient index. A custom sub-envelope
                    // arriving without a name is dropped from the roster as
                    // malformed, yet the write path below still stored its token
                    // under its per-ref account — so enumerating the roster
                    // alone would leave a live bearer token behind a Forget the
                    // user believes wiped everything. `remoteAgentURLs` holds
                    // every ref that was ever configured here, named or not.
                    let doomedRefs = Set(
                        WatchSettingsReader.shared.customGateways.map(\.ref.rawString)
                    ).union(WatchSettingsReader.shared.remoteAgentURLs.keys)
                        .union(RemoteAgentBackend.allCases.map { RemoteAgentRef.builtin($0).rawString })
                    if WatchSettingsReader.shared.updateRemoteAgents(multi: multiEnvelope) {
                        // Every per-ref slot, then the legacy single account.
                        // Built-ins are cleared here and NOT on ordinary
                        // per-ref absence: absence of one ref among many is
                        // ambiguous (a transient iPhone Keychain failure drops a
                        // ref from the configured set), whereas `clearAll` is
                        // minted only from a recorded user Forget.
                        //
                        // Committing first defuses a teardown that is stale AT
                        // the commit. It cannot defuse one that goes stale
                        // AFTER it: this loop awaits, the main actor is
                        // reentrant across those awaits, and a newer envelope
                        // that interleaves installs tokens this loop would then
                        // delete — leaving a gateway with a URL, an auth scheme
                        // and no token, which fails closed until the next
                        // broadcast. So re-read the high-water mark before every
                        // clear and abandon the teardown the moment a newer
                        // envelope has landed.
                        for ref in doomedRefs {
                            guard WatchSettingsReader.shared.lastRemoteAgentEnvelopeTimestamp
                                    == multiEnvelope.timestamp else { break }
                            await WatchIdentityResolver.shared.clearRemoteAgentToken(for: ref)
                        }
                        if WatchSettingsReader.shared.lastRemoteAgentEnvelopeTimestamp
                            == multiEnvelope.timestamp {
                            await WatchIdentityResolver.shared.clearRemoteAgentToken()
                        }
                    }
                } else {
                    for sub in multiEnvelope.backends {
                        if sub.authScheme == .none {
                            await WatchIdentityResolver.shared.clearRemoteAgentToken(for: sub.backendRef)
                        } else if let token = sub.token, !token.isEmpty {
                            await WatchIdentityResolver.shared.setRemoteAgentToken(token, for: sub.backendRef)
                        }
                    }
                    _ = WatchSettingsReader.shared.updateRemoteAgents(multi: multiEnvelope)
                }
            } else {
                #if DEBUG
                print("[Watch] Discarding stale RemoteAgent MULTI envelope (ts=\(multiEnvelope.timestamp) <= last=\(lastSeen))")
                #endif
            }
        }

        // Compat fallback — legacy SINGLE Remote Agent envelope.
        // Only consulted when the multi key is ABSENT (older iPhone that hasn't
        // shipped the multi broadcast yet). Atomic update of backend + URL +
        // fingerprint + activeSessionID, with bearer token persisted separately
        // to Watch Keychain (both the legacy single account AND the per-backend
        // account, so a later multi-aware route finds the token either way).
        // Mirrors the STT envelope shape: monotonic-timestamp guard discards
        // out-of-order drains; Keychain write before in-memory commit.
        if !multiHandled,
           let envelopeDict = payload[Constants.remoteAgentEnvelopeKey] as? [String: Any],
           let envelope = RemoteAgentBroadcastEnvelope.decode(from: envelopeDict) {
            let lastSeen = WatchSettingsReader.shared.lastRemoteAgentEnvelopeTimestamp
            if envelope.timestamp > lastSeen {
                // Same keyless-on-explicit-`.none` rule as the multi path: never
                // clear a `.bearer` ref's token merely because this envelope
                // arrived token-less (transient read failure preservation).
                if envelope.authScheme == .none {
                    await WatchIdentityResolver.shared.clearRemoteAgentToken()
                    await WatchIdentityResolver.shared.clearRemoteAgentToken(for: envelope.backendRef)
                } else if let token = envelope.token, !token.isEmpty {
                    await WatchIdentityResolver.shared.setRemoteAgentToken(token)
                    // Also seed the per-ref slot so multi-aware routing
                    // can resolve this ref even on a single-envelope
                    // (legacy-iPhone) install. Keyed by `backendRef` so a custom
                    // default's token still lands in the right slot.
                    await WatchIdentityResolver.shared.setRemoteAgentToken(token, for: envelope.backendRef)
                }
                // The legacy single-envelope in-memory commit is built-in-only
                // (`updateRemoteAgent(backend:)` is enum-typed). A custom default
                // in the single envelope can't drive the legacy mirror — its
                // token slot is seeded above, but the multi envelope (the only
                // place customs are configured) owns the in-memory routing. So
                // commit the mirror only for a built-in ref.
                if case .builtin(let backend)? = RemoteAgentRef(rawString: envelope.backendRef) {
                    _ = WatchSettingsReader.shared.updateRemoteAgent(
                        backend: backend,
                        url: envelope.url,
                        fingerprint: envelope.certFingerprintHex,
                        authScheme: envelope.authScheme,
                        sessionID: envelope.activeSessionID,
                        timestamp: envelope.timestamp
                    )
                }
            } else {
                #if DEBUG
                print("[Watch] Discarding stale RemoteAgent envelope (ts=\(envelope.timestamp) <= last=\(lastSeen))")
                #endif
            }
        }

        // Identity delivery (fallback channel — may also arrive via applicationContext)
        if let userID = payload[Constants.iCloudKVSUserIDKey] as? String, !userID.isEmpty {
            await WatchIdentityResolver.shared.didReceiveUserID(userID)
        }

        // Preferred-language courier — present only in a settings-PULL reply
        // (the broadcast queue never carries it; it rides applicationContext
        // there, so this read is a harmless no-op on the userInfo path).
        // Non-secret latest-value semantics; absent/empty leaves the cached
        // value untouched.
        if let lang = payload[Constants.sttPreferredLanguageKVSKey] as? String, !lang.isEmpty {
            WatchSettingsReader.shared.preferredLanguage = lang
        }

        // "Enable on Watch" master switch: recompute the reader's cached flag
        // on every settings delivery. The flag itself rides applicationContext
        // + iCloud KVS (never this envelope), but the KVS external-change
        // observer alone is unreliable on watchOS — a fresh-settings moment
        // doubles as the heal that keeps the render-path cache converged.
        WatchSettingsReader.shared.refreshWatchEnabledCache()

        WatchLog.note(.session, "settings.apply", [
            "keys": payload.count,
            "ms": Int(Date().timeIntervalSince(applyStarted) * 1000),
        ])
    }

    // MARK: - Interactive settings pull (Watch → iPhone)

    /// Single in-flight pull task. Concurrent callers coalesce onto it — the
    /// pull is idempotent so one round-trip serves everyone — while each
    /// caller races its OWN deadline against the shared task (see
    /// `pullSettingsFromPhone`). `@MainActor` so check-then-set is race-free.
    @MainActor private var inFlightPull: Task<Bool, Never>?

    /// Interactive settings pull (Watch → iPhone). Closes the lazy
    /// `transferUserInfo` gap: a fresh launch can resolve the active STT
    /// provider in one `sendMessage` round-trip instead of waiting for the
    /// queued envelopes to drain. Idempotent — replies are applied through
    /// the same monotonic-timestamp guards as broadcast envelopes. Single
    /// in-flight task; concurrent callers coalesce onto it, each racing its
    /// OWN `maxWait` so a hot-path caller with a tight budget is never held
    /// by a longer one.
    ///
    /// Returns `true` when a reply arrived AND was fully applied before the
    /// deadline; `false` on not-activated / unreachable / send error /
    /// deadline. Callers proceed with current state on `false` — the pull is
    /// an opportunistic freshness upgrade, never a gate.
    func pullSettingsFromPhone(maxWait: TimeInterval = 5) async -> Bool {
        let pull = await currentOrNewPullTask()
        // Deadline race via `awaitValue` (TaskDeadline.swift) — returns at the
        // deadline TIME, not just with the deadline value (a `withTaskGroup`
        // race would drain the child parked in the pull's continuation and
        // hold the caller until WCSession's own reply timeout). The shared
        // pull keeps running past the deadline; its payload still applies
        // when the reply lands — only this caller stops waiting.
        return await awaitValue(of: pull, deadline: maxWait, onDeadline: false)
    }

    /// Get-or-create the shared pull task. The task clears itself on
    /// completion so the NEXT pull performs a fresh round-trip (settings may
    /// have changed iPhone-side between pulls).
    @MainActor
    private func currentOrNewPullTask() -> Task<Bool, Never> {
        if let existing = inFlightPull { return existing }
        let task = Task { () -> Bool in
            let applied = await self.performSettingsPull()
            await MainActor.run { self.inFlightPull = nil }
            return applied
        }
        inFlightPull = task
        return task
    }

    /// One pull round-trip via the injected transport (which owns the
    /// activation/reachability gate AND the `sendMessage` exchange — see
    /// `SettingsPullTransport`), inline-applying the reply payload (same
    /// shape as the broadcast userInfo; empty dict = nothing configured on
    /// the iPhone yet — valid, applies as a no-op). Resolves `true` only
    /// AFTER the apply commits — the inline-await contract pull callers
    /// rely on.
    private func performSettingsPull() async -> Bool {
        let started = Date()
        guard let payload = await pullTransport.performPull() else {
            WatchLog.note(.session, "settings.pull", [
                "ok": false,
                "ms": Int(Date().timeIntervalSince(started) * 1000),
            ])
            return false
        }
        #if DEBUG
        // Key NAMES only — the payload VALUES carry API keys/tokens.
        print("[Watch] Settings pull reply keys: \(payload.keys.sorted())")
        #endif
        await applyEnvelopePayload(payload)
        WatchLog.note(.session, "settings.pull", [
            "ok": true,
            "keys": payload.count,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
        ])
        return true
    }

    // MARK: - Reverse channel: last successful Watch turn

    /// Report the timestamp of a successful Watch agent turn to iPhone — the
    /// iPhone Diagnostics `sync.watch` row shows it as "Last Watch reply landed
    /// <relative>". Merges into the existing `applicationContext` so we
    /// don't clobber identity/language keys the iPhone reads. `applicationContext`
    /// is the right channel — it's a single latest-value snapshot (not a queue),
    /// exactly the semantics of "last successful turn".
    ///
    /// `Constants.watchLastSuccessfulTurnKey` matches the iOS read site
    /// (`PhoneSessionManager`). Single caller: `WatchAudioUploader`'s converse
    /// completion — the one funnel EVERY Watch turn (voice, typed, Ask, deferred
    /// relay drain) resolves through; a future non-uploader reply path must
    /// call this too or the phone's recency read undercounts.
    func reportSuccessfulTurn() {
        guard WCSession.default.activationState == .activated else { return }
        var context = WCSession.default.applicationContext
        context[Constants.watchLastSuccessfulTurnKey] = Date().timeIntervalSinceReferenceDate
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            #if DEBUG
            print("[Watch] reportSuccessfulTurn updateApplicationContext failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Reachability

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isCompanionReachable = isReachable

            WatchLog.note(.session, "wc.reachability", ["reachable": isReachable])

            // If iPhone just became reachable and we have no identity, try requesting it
            if isReachable {
                Task {
                    let currentID = await WatchIdentityResolver.shared.getUserID()
                    if currentID == nil {
                        _ = await WatchIdentityResolver.shared.requestFromPhone()
                    }
                }

                // Drain any deferred Apple-speech relay entries
                // queued while the iPhone was unreachable. The drain itself
                // guards against re-entry, so a reachability flap doesn't
                // multi-fire it.
                Task { @MainActor in
                    await AppleRelayPendingQueue.shared.drain()
                }

                // Settings pull, trigger (b): reachability gained. Same lazy-queue
                // gap as activation (the queued envelopes may still be sitting
                // undelivered); idempotent through the timestamp guards, and the
                // in-flight coalescing keeps a reachability flap from stacking
                // round-trips.
                Task { _ = await self.pullSettingsFromPhone() }
            }
        }
    }
}
