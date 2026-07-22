// Conduck
// PhoneSessionManager.swift
//
// iPhone-side WCSession broadcaster. Broadcasts the STT active preset ID
// (via `updateApplicationContext`) + the STT API key (via
// `transferUserInfo` because the key is secret-class data and `transferUserInfo`
// is queued + delivered once, whereas `applicationContext` is repeatedly
// re-broadcast on every state change).
//
// Privacy invariant: the API key value is NEVER logged. `transferUserInfo`
// keys appear in DEBUG output, never values.
//
// Identity-request handler uses `Constants.iCloudKVSUserIDKey` for the
// payload key — no hardcoded `"gigaduck_user_id"` literal.

#if os(iOS)
import Combine
import Foundation
import UIKit
import WatchConnectivity

/// iPhone-side WCSession delegate for broadcasting identity, STT preset
/// metadata, and the active STT API key to Apple Watch.
final class PhoneSessionManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = PhoneSessionManager()

    /// Timestamp (referenceDate-based) of the Watch's last successful
    /// agent turn, surfaced in Settings ▸ Diagnostics (the `sync.watch` row's
    /// recency detail + the copy block's `turn=` bucket). Updated when the
    /// Watch posts `Constants.watchLastSuccessfulTurnKey` via `updateApplicationContext`.
    /// Nil = no successful Watch turn observed BY THIS iPHONE yet — in-memory
    /// only, re-seeded on activation from `receivedApplicationContext`, so a
    /// brief nil window exists on cold launch until activation completes.
    @Published private(set) var lastSuccessfulWatchTurn: Date?

    private var didRegisterForegroundObserver = false

    /// Pending coalesced broadcast — cancelled and replaced on rapid
    /// `broadcastToWatchDebounced()` calls so only the last preset switch in a
    /// burst hits the WCSession queue. Per the locked 250 ms debounce.
    private var pendingBroadcast: Task<Void, Never>?

    private override init() {
        super.init()
        // Observe `.settingsDidChangeRemotely` so any
        // change to the active preset, an API-key paste (first-time
        // onboarding), key rotation, or key clear triggers a debounced
        // Watch re-broadcast. Without this, the Watch would keep its
        // stale envelope until the next foreground or explicit setting
        // change. `SettingsManager` posts this notification on:
        //   - `setActivePresetID(_:)` (active-preset switch),
        //   - `setAPIKey(_:forPresetID:)` (paste / rotate / first onboarding),
        //   - `clearAPIKey(forPresetID:)` (key removal),
        //   - iCloud KVS server-change for known keys.
        NotificationCenter.default.addObserver(
            forName: .settingsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.broadcastToWatchDebounced()
        }
    }

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        registerForegroundObserverIfNeeded()
    }

    /// Observe `didBecomeActiveNotification` to re-read pairing state when
    /// the app returns to the foreground — catches cases where the user
    /// paired a Watch or installed Conduck on their Watch while the
    /// iPhone app was suspended.
    private func registerForegroundObserverIfNeeded() {
        guard !didRegisterForegroundObserver else { return }
        didRegisterForegroundObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        // Belt-and-suspenders re-broadcast: if the Watch picked up state
        // changes while iPhone was suspended, this makes sure they see the
        // latest preset/language hint. Debounced so a foreground burst
        // (didBecomeActive + KVS hydrate + observer fan-out) collapses to
        // one broadcast.
        broadcastToWatchDebounced()
    }

    // MARK: - Broadcasting

    /// Send current identity + STT state to Watch.
    ///
    /// **Channel split (envelope-only locked decision):**
    /// - `applicationContext` carries ONLY non-secret, atomicity-independent
    ///   metadata: user ID + preferred language hint. The design
    ///   explicitly drops `sttActivePresetIDKVSKey` from this channel to
    ///   close the torn-read race between the fast applicationContext
    ///   delivery and the queued `transferUserInfo` delivery (Watch would
    ///   otherwise observe new presetID + old key, blow a request).
    /// - `transferUserInfo` carries the full `STTBroadcastEnvelope`
    ///   `{ presetID, apiKey, timestamp }` as the SOLE source of Watch STT
    ///   state. Receiver compares against `lastEnvelopeTimestamp` and
    ///   discards older envelopes — defeats out-of-order queue drains.
    ///
    /// Skips the envelope enqueue when the active preset has no Keychain
    /// entry (pre-onboarding) — `SettingsManager.currentBroadcastEnvelope()`
    /// returns nil in that case.
    ///
    /// Public callers SHOULD use `broadcastToWatchDebounced()` to coalesce
    /// bursts; the bare entry point is preserved for activation handlers
    /// where immediacy matters more than coalescing.
    func broadcastToWatch() {
        Task { await broadcastToWatchAsync() }
    }

    /// Async core — extracted so the debounced path can await without
    /// double-Task wrapping. Skips silently when not activated; the explicit
    /// user-tap path (`resendSettingsToWatch()`) preflights activation itself
    /// and surfaces the block instead.
    private func broadcastToWatchAsync() async {
        guard WCSession.default.activationState == .activated else { return }
        _ = await sendSettingsToWatch()
    }

    /// The SINGLE send core shared by the automatic broadcast and the explicit
    /// re-send. Pushes the non-secret applicationContext metadata, then enqueues
    /// the settings envelope via `transferUserInfo`. **Precondition:**
    /// `WCSession.default.activationState == .activated` — every caller
    /// preflights activation (the broadcast path guards, the resend path runs
    /// `resendPreflight`). Returns the transfer object AFTER `transferUserInfo`
    /// has accepted the payload, so a caller may treat the return as
    /// "handed to the queued background channel". `assembleSettingsPayload()`
    /// always carries the read-aloud bool + courier marker, so the payload is
    /// never empty — there is no "nothing to send" skip.
    @discardableResult
    private func sendSettingsToWatch() async -> WCSessionUserInfoTransfer {
        let userID = await UserIdentityManager.shared.getUserID()
        let preferredLanguage = await SettingsManager.shared.getPreferredLanguage()

        // applicationContext: non-secret metadata, repeatedly re-delivered
        // by the OS. NO `sttActivePresetIDKVSKey` (envelope owns it now).
        var context: [String: Any] = [
            Constants.iCloudKVSUserIDKey: userID
        ]
        if let preferredLanguage = preferredLanguage {
            // Legacy alias kept for older readers; new code reads
            // `sttPreferredLanguageKVSKey`.
            context[Constants.iCloudKVSPreferredLanguageKey] = preferredLanguage
            context[Constants.sttPreferredLanguageKVSKey] = preferredLanguage
        }

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            #if DEBUG
            print("[Phone] updateApplicationContext failed for keys \(context.keys): \(error.localizedDescription)")
            #endif
        }

        // transferUserInfo: atomic envelopes. Composed into a single
        // payload so iOS WCSession queues them as one delivery — Watch
        // sees them together or not at all, no inter-envelope torn read.
        let payload = await assembleSettingsPayload()
        return WCSession.default.transferUserInfo(payload)
    }

    // MARK: - Explicit re-send (Settings ▸ Apple Watch recovery control)

    /// Outcome of an explicit "re-send settings to Watch" request. Any case
    /// other than `queued` is a preflight block — nothing was enqueued. `queued`
    /// means the envelope was handed to the queued `transferUserInfo` channel;
    /// it does NOT mean the Watch received or applied it (the wrist sends no
    /// ack, so no honest copy may ever claim the Watch was updated).
    enum WatchResendOutcome: Equatable {
        case queued
        case activationPending
        case notPaired
        case watchAppNotInstalled
    }

    /// Pure, unit-testable preflight for `resendSettingsToWatch()`. Returns a
    /// blocking outcome, or nil when a send may proceed. Precedence is
    /// activation → pairing → install. Deliberately does NOT consult
    /// `isReachable`: `transferUserInfo` is a queued background channel that
    /// delivers whenever the Watch next becomes available, so reachability is
    /// never a precondition.
    static func resendPreflight(
        activationState: WCSessionActivationState,
        isPaired: Bool,
        isWatchAppInstalled: Bool
    ) -> WatchResendOutcome? {
        guard activationState == .activated else { return .activationPending }
        guard isPaired else { return .notPaired }
        guard isWatchAppInstalled else { return .watchAppNotInstalled }
        return nil
    }

    /// Explicit user-initiated re-send of the current settings envelope to the
    /// Watch. Cancels any pending debounced broadcast first so this tap can't
    /// double-enqueue the same envelope 250ms later, preflights the live
    /// session, and — when clear — reuses the shared `sendSettingsToWatch()`
    /// core. Returns `.queued` only after `transferUserInfo` has accepted the
    /// payload.
    func resendSettingsToWatch() async -> WatchResendOutcome {
        pendingBroadcast?.cancel()
        pendingBroadcast = nil

        let session = WCSession.default
        if let blocker = Self.resendPreflight(
            activationState: session.activationState,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled
        ) {
            return blocker
        }

        _ = await sendSettingsToWatch()
        return .queued
    }

    /// Assemble the envelope payload dict — the SINGLE composition site
    /// shared by the push broadcast (`transferUserInfo` above) and the
    /// Watch-initiated settings pull (`didReceiveMessage` replyHandler), so
    /// the two channels cannot drift in envelope shape. Empty dict when
    /// nothing is configured (pre-onboarding) — callers own the skip/reply
    /// decision.
    private func assembleSettingsPayload() async -> [String: Any] {
        var payload: [String: Any] = [:]

        // STT envelope. Skip when no key exists for the active preset
        // (pre-onboarding / post-clear) — no value in shipping an empty
        // envelope.
        if let sttEnvelope = await SettingsManager.shared.currentBroadcastEnvelope() {
            payload[Constants.sttActivePresetEnvelopeKey] = sttEnvelope.encodedDict()
        }

        // Remote Agent (Personal AI) envelope. Skip when the
        // gateway is not configured (backend OR URL missing); the Watch
        // simply keeps its previous remote-agent state until a new
        // envelope arrives. Token IS included when present — spec
        // §Cross-Device Sync locks "gateway token arrives via
        // `WCSession.transferUserInfo`", same posture as the STT key.
        if let remoteAgentEnvelope = await SettingsManager.shared.currentRemoteAgentEnvelope() {
            payload[Constants.remoteAgentEnvelopeKey] = remoteAgentEnvelope.encodedDict()
        }

        // Full multi-gateway Watch support. Broadcast the
        // MULTI-gateway envelope (ALL configured backends + the default pointer)
        // under `remoteAgentMultiEnvelopeKey` ALONGSIDE the legacy single
        // envelope above. The single envelope is kept ONE release as a compat
        // fallback for an un-upgraded Watch that doesn't read the multi key.
        // An upgraded Watch prefers the multi key and ignores the single one.
        // Skip when no backend is configured (mirrors the single-envelope skip).
        if let multiEnvelope = await SettingsManager.shared.currentRemoteAgentMultiEnvelope() {
            payload[Constants.remoteAgentMultiEnvelopeKey] = multiEnvelope.encodedDict()
            // Record the newest agent-envelope timestamp this phone ever minted
            // for the wrist — the phone-side half of the Diagnostics settings-
            // freshness read (compared to the Watch's persisted high-water
            // returned by the diagnostics pull). This is the single composition
            // site (broadcast AND pull reply), so the stamp holds by construction.
            UserDefaults(suiteName: Constants.appGroupID)?
                .set(multiEnvelope.timestamp, forKey: Constants.watchBroadcastLastAgentEnvelopeTsKey)
        }

        // Watch "Replies on Apple Watch" auto-speak toggle. ALWAYS included (a
        // plain bool, not a skip-when-unconfigured envelope) so BOTH ON and OFF
        // propagate over the RELIABLE WCSession channel. Previously this toggle
        // reached the Watch ONLY via iCloud KVS, which is a cold-launch fallback
        // on watchOS (eventually-consistent + laggy — `ubiquityIdentityToken` is
        // always nil there), so the flag frequently never arrived and arrival
        // auto-speak silently stayed OFF. The Watch persists this to its App-Group
        // mirror and reads it FIRST in `readRepliesAloud()`, KVS as fallback.
        payload[Constants.watchReadRepliesAloudKey] =
            await SettingsManager.shared.getWatchReadRepliesAloud()

        // Settings-courier MARKER — lets `session(_:didFinish:error:)` + the
        // Diagnostics outstanding-transfer count tell settings broadcasts apart
        // from the relay transcript replies that ALSO ride `transferUserInfo`
        // (they'd otherwise count as "settings updates queued"). Additive; the
        // Watch's envelope decoder ignores unknown keys.
        payload[Constants.watchBroadcastKindKey] = Constants.watchBroadcastKindSettings

        return payload
    }

    /// Coalesce rapid broadcast triggers (settings toggles, picker activation
    /// taps, foreground re-broadcast) into a single delivery 250ms after the
    /// last call. Cancel-and-restart pattern: each call cancels any pending
    /// task and replaces it. Per locked decision — prevents WCSession queue
    /// buildup on bursty preset switching.
    func broadcastToWatchDebounced() {
        pendingBroadcast?.cancel()
        pendingBroadcast = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.broadcastToWatchAsync()
        }
    }

    // MARK: - WCSessionDelegate (required on iOS)

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            broadcastToWatch()
            // Seed the last-successful-turn AUTHORITATIVELY from the new
            // session's received context — unconditional (nil when absent), so
            // after a multi-Watch switch the value derives entirely from the
            // CURRENT watch and no separate "clear on deactivate" task can race
            // this re-seed on the main actor.
            seedLastSuccessfulTurn(from: session.receivedApplicationContext)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // Required on iOS for multi-watch switching
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS — reactivate for new Watch pairing. Clear the OLD
        // watch's broadcast delivery stamps first: they belong to the watch
        // that just deactivated, and carrying a failure stamp across a
        // multi-Watch switch would contaminate the new watch's Diagnostics
        // row. `lastSuccessfulWatchTurn` needs no clear here — activation
        // re-seeds it AUTHORITATIVELY from the new session's received context
        // (a deactivate-side clear task would race that re-seed on the main
        // actor and could nil a just-seeded value).
        if let defaults = UserDefaults(suiteName: Constants.appGroupID) {
            defaults.removeObject(forKey: Constants.watchBroadcastLastSuccessAtKey)
            defaults.removeObject(forKey: Constants.watchBroadcastLastFailureAtKey)
        }
        WCSession.default.activate()
    }

    /// Settings-broadcast DELIVERY outcome — the phone's only signal that a
    /// queued `transferUserInfo` courier actually reached the wrist (or didn't).
    /// Filtered on the settings MARKER: relay transcript replies also ride
    /// `transferUserInfo` and must not move these stamps. Stamps a DATE only —
    /// never error content (never-log posture per the spec's Privacy & Security section; a bool "it failed" is the
    /// whole diagnostic). App-Group-persisted: a failing courier is exactly the
    /// fact that must outlive the process — but treated as opportunistic
    /// forensics, not an authoritative ledger (Apple doesn't promise launching
    /// the app just to deliver this callback). Completion order across queued
    /// transfers isn't promised either, so Diagnostics reads these as "a recent
    /// success/failure happened", never as a per-payload ledger. Known bounded
    /// gap: a LATE completion from a previous watch's queue can land after the
    /// switch-clear and re-stamp (WCSession exposes no per-watch transfer
    /// identity) — self-healing, since the next courier outcome to the current
    /// watch overwrites it.
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let isSettingsCourier = (userInfoTransfer.userInfo[Constants.watchBroadcastKindKey] as? String)
            == Constants.watchBroadcastKindSettings
        guard isSettingsCourier, let defaults = UserDefaults(suiteName: Constants.appGroupID) else { return }
        let key = (error == nil)
            ? Constants.watchBroadcastLastSuccessAtKey
            : Constants.watchBroadcastLastFailureAtKey
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: key)
        #if DEBUG
        print("[Phone] Settings broadcast \(error == nil ? "delivered" : "FAILED")")
        #endif
    }

    // MARK: - Message Handling (relay fast path + real-time identity requests)

    /// Wire literals shared with `AppleSpeechRelayCoordinator` — single
    /// source for the relay key strings on this side of the process.
    private typealias RelayWire = AppleSpeechRelayCoordinator.Wire

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        // ── Apple-speech relay, interactive channel (relay rework, Stage B) ──
        // The Watch sends the whole request inline via `sendMessage` when the
        // iPhone is reachable — deterministic 1–2 s round trips for typical
        // short asks instead of the opportunistic transferFile queue.
        if let kind = message[RelayWire.kindKey] as? String {
            if kind == RelayWire.kindValue {
                guard let requestID = message[RelayWire.requestIDKey] as? String,
                      !requestID.isEmpty,
                      let audio = message[RelayWire.audioKey] as? Data,
                      !audio.isEmpty else {
                    // Malformed inline request — ACK so the Watch's
                    // replyHandler doesn't dangle, then drop; the Watch's
                    // queued-file retry path owns recovery.
                    replyHandler([:])
                    return
                }
                // ACK = DELIVERY RECEIPT ONLY — never block it on
                // transcription. The sendMessage replyHandler has an OS
                // timeout measured in seconds; transcription takes tens of
                // seconds. The transcript always rides the async reply
                // channel.
                replyHandler([:])
                // Write the clip to an owned temp URL on this (delegate)
                // queue — it's ≤ ~50 KB by Watch-side policy, cheap — so the
                // coordinator's ingress contract ("an audio temp URL WE own")
                // is identical for both channels.
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("apple-relay-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")
                do {
                    try audio.write(to: tempURL, options: .atomic)
                } catch {
                    #if DEBUG
                    print("[Phone] Relay inline audio write failed (\(audio.count) bytes)")
                    #endif
                    // Same escape hatch as a failed inbox takeover: the
                    // message payload carries the same wire keys as file
                    // metadata, so it doubles as the reply source.
                    AppleSpeechRelayCoordinator.sendIngestionFailureReply(metadata: message)
                    return
                }
                let language = message[RelayWire.languageKey] as? String
                let providerID = message[RelayWire.providerIDKey] as? String
                let replyPrefersMessage = message[RelayWire.supportsMessageReplyKey] as? Bool ?? false
                Task { @MainActor in
                    await AppleSpeechRelayCoordinator.shared.processRelayRequest(
                        requestID: requestID,
                        audioURL: tempURL,
                        language: language,
                        providerID: providerID,
                        replyPrefersMessage: replyPrefersMessage
                    )
                }
                return
            }
            if kind == RelayWire.wakeKind {
                // Wake-ping: message delivery itself already launched/woke
                // this app so the queued transferFile gets serviced. Nothing
                // to do beyond acknowledging receipt.
                replyHandler([:])
                return
            }
        }
        // Settings pull (Watch → iPhone): the payload IS the reply. Assembly is
        // actor-hop fast (Keychain/UserDefaults reads), well inside the OS
        // replyHandler window — never put transcription-class work here.
        if message[RelayWire.kindKey] as? String == Constants.settingsPullMessageKind {
            Task {
                var payload = await assembleSettingsPayload()
                if let lang = await SettingsManager.shared.getPreferredLanguage() {
                    payload[Constants.sttPreferredLanguageKVSKey] = lang
                }
                // Empty payload is a valid reply (pre-onboarding) — the
                // Watch distinguishes "nothing configured" from "no answer".
                replyHandler(payload)
            }
            return
        }
        if message["request"] as? String == "user_id" {
            Task {
                let userID = await UserIdentityManager.shared.getUserID()
                // Reply with the canonical KVS key — Watch resolver uses
                // the same constant on the receiving side. No hardcoded
                // literal.
                replyHandler([Constants.iCloudKVSUserIDKey: userID])
            }
        } else {
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Wake-ping absorption (relay rework, Stage B): a fire-and-forget
        // `sendMessage` lands here when the Watch attached no replyHandler.
        // Delivery itself is the wake — no work to do.
        #if DEBUG
        if message[RelayWire.kindKey] as? String == RelayWire.wakeKind {
            print("[Phone] Relay wake-ping received")
        }
        #endif
    }

    // MARK: - Reverse channel from Watch (last successful turn)

    /// The Watch posts `Constants.watchLastSuccessfulTurnKey` (a referenceDate
    /// `Double`) via `updateApplicationContext` on each converse success. Surface
    /// it for the iOS Settings → Apple Watch sub-section.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        readLastSuccessfulTurn(from: applicationContext)
    }

    private func readLastSuccessfulTurn(from context: [String: Any]) {
        guard let stamp = context[Constants.watchLastSuccessfulTurnKey] as? Double, stamp > 0 else { return }
        let date = Date(timeIntervalSinceReferenceDate: stamp)
        Task { @MainActor in
            self.lastSuccessfulWatchTurn = date
        }
    }

    /// Activation-time AUTHORITATIVE seed: assigns unconditionally (nil when
    /// the new session's context carries no turn stamp), so the value always
    /// derives from the CURRENT watch — the multi-Watch-switch reset falls out
    /// of the re-seed instead of racing a separate clear. Live context updates
    /// keep the guarded `readLastSuccessfulTurn` (a mid-session update without
    /// the key must not nil a known value).
    private func seedLastSuccessfulTurn(from context: [String: Any]) {
        let stamp = context[Constants.watchLastSuccessfulTurnKey] as? Double ?? 0
        let date: Date? = stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
        Task { @MainActor in
            self.lastSuccessfulWatchTurn = date
        }
    }

    // MARK: - "Enable on Watch" master switch

    /// Current "Enable on Watch" flag. Default ON when never written. Reads
    /// iCloud KVS under `Constants.watchEnabledKey` (matches the Watch read site
    /// in `WatchSettingsReader.isWatchEnabled()`).
    var isWatchEnabled: Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        if kvs.object(forKey: Constants.watchEnabledKey) == nil { return true }
        return kvs.bool(forKey: Constants.watchEnabledKey)
    }

    /// Write the "Enable on Watch" flag to iCloud KVS + applicationContext so
    /// the Watch picks it up (KVS for cold-launch durability, applicationContext
    /// for low latency). Suppresses the Watch ControlWidget/record action when
    /// off.
    func setWatchEnabled(_ enabled: Bool) {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(enabled, forKey: Constants.watchEnabledKey)
        kvs.synchronize()

        guard WCSession.default.activationState == .activated else { return }
        var context = WCSession.default.applicationContext
        context[Constants.watchEnabledKey] = enabled
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            #if DEBUG
            print("[Phone] setWatchEnabled updateApplicationContext failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - File Transfer (Watch → iPhone Apple-speech relay)

    /// Receives audio files transferred from the Watch. The Apple-speech
    /// relay path: when `metadata["kind"] ==
    /// "apple-speech-relay"`, route to `AppleSpeechRelayCoordinator`
    /// which runs `AppleSpeechRunner.transcribe` and ships the transcript
    /// back. Files we don't recognize are dropped (no other relay use case
    /// exists at V1).
    ///
    /// Defect-1 fix (relay rework, Stage A): WatchConnectivity DELETES
    /// `file.fileURL` the moment this delegate method returns, so ownership
    /// of the audio must transfer SYNCHRONOUSLY on this (delegate) queue —
    /// the previous async-Task copy raced that deletion and lost under
    /// load. `file.metadata` is captured by value for the same reason:
    /// `WCSessionFile` must not outlive the callback.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if AppleSpeechRelayCoordinator.shared.isRelayFile(file) {
            let metadata = file.metadata ?? [:]
            guard let ownedURL = RelayInboxMover.takeOwnership(of: file.fileURL) else {
                // Both move and copy failed — the audio is gone for good
                // (the Inbox original dies on return). The ERROR reply may
                // be async: there is no file left to race over, and replying
                // lets the Watch converge instead of burning its timeout.
                #if DEBUG
                print("[Phone] Apple relay inbox takeover failed — replying audioInvalid")
                #endif
                AppleSpeechRelayCoordinator.sendIngestionFailureReply(metadata: metadata)
                return
            }
            Task { @MainActor in
                await AppleSpeechRelayCoordinator.shared.handleIncomingRelayFile(
                    at: ownedURL,
                    metadata: metadata
                )
            }
            return
        }
        #if DEBUG
        print("[Phone] Ignoring unrecognized WCSessionFile (metadata keys: \(file.metadata?.keys.map { String($0) } ?? []))")
        #endif
    }
}
#endif
