// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleSpeechRelayCoordinator.swift
//
// Apple Native STT as the 6th provider. iOS-side handler for
// the "Option B" Watch relay protocol: Watch records audio locally, ships
// the compressed .m4a to iPhone (queued `WCSession.transferFile`, or — new
// fast path — inline `sendMessage` when reachable), iPhone runs
// `AppleSpeechRunner.transcribe`, reply ships back via interactive
// `sendMessage` when the request stamped the capability (falling back to
// `WCSession.transferUserInfo`), else `transferUserInfo`. Watch correlates
// by `requestID` UUID — a claim token the Watch RETRIES with verbatim, so
// this side dedups by it (in-flight Set + LRU verdict cache).
//
// PLATFORM GATE: same protective pattern as `AppleSpeechRunner.swift` —
// `PBXFileSystemSynchronizedBuildFileExceptionSet` entries are non-
// functional in the Xcode 26 synchronized-groups model that this project
// uses, so the file must NOT compile into the Watch target via the
// `#if !os(watchOS)` body gate. The Watch surface owns its own coordinator
// in `ConduckWatch Watch App/Services/AppleSpeechRelayCoordinator.swift`
// (the sender side); they share NO source.
//
// Wire protocol (matches Watch-side coordinator):
//   - File metadata["kind"] == "apple-speech-relay" identifies a relay
//     request (not some future WCSessionFile use case).
//   - "providerID" stamp routing: absent ⇒ transcribe with
//     the iPhone's CURRENT active provider (the iPhone is the settings
//     authority — see `Wire.providerIDKey`); a custom-endpoint stamp ⇒
//     that EXACT endpoint; an unrecognized non-custom stamp keeps the
//     legacy Apple route (never bill an unknown vendor on a guess).
//   - Inline fast path: the SAME request can
//     arrive via `sendMessage` with the compressed clip under "audio"
//     (Data) when the iPhone is reachable — `PhoneSessionManager` ACKs
//     delivery immediately and routes here. "apple-speech-relay-wake" is
//     a fire-and-forget wake-ping the Watch sends alongside a
//     `transferFile`; its delivery launches/wakes us, nothing more.
//   - Reply dict shape (identical on BOTH reply channels):
//        success: ["requestID": String, "kind": "apple-speech-relay-reply",
//                  "result.text": String]
//        failure: ["requestID": String, "kind": "apple-speech-relay-reply",
//                  "result.errorCode": Int]   // AppError.errorCode
//   - Reply channel: interactive `sendMessage` when the request stamped
//     "replySendMessageOK": true AND the Watch is reachable (errorHandler
//     falls back to `transferUserInfo`); otherwise queued
//     `transferUserInfo` (legacy Watch builds keep working byte-for-byte).
//
// Privacy invariant (spec.md "Privacy & Security"): never log audio bytes,
// transcripts, file paths, request UUIDs, or language hints. DEBUG prints
// are size/state-only.
//
// Audio-cleanup mandate: the received `WCSessionFile.fileURL`
// lives in a temp Inbox owned by WatchConnectivity that auto-purges when
// the delegate callback returns — so `PhoneSessionManager` moves it to an
// owned temp URL SYNCHRONOUSLY on the delegate queue via `RelayInboxMover`
// BEFORE the delegate returns — an async-Task copy would race that
// deletion and lose under load. This coordinator receives the
// already-owned URL and deletes it in a `defer` so a thrown error cannot
// leak the file.
//
// Idempotency: the Watch retries an undelivered
// request with the SAME requestID. `inFlightRequestIDs` drops duplicates
// while a transcription runs; the bounded `RelayReplyCache` re-sends the
// prior verdict after completion — one utterance is never transcribed
// (never agent-hopped, never billed) twice. The cache admits SETTLED
// verdicts ONLY (success, or PERMANENT error): a retryable error such as
// `sttProviderUnreachable` is deliberately NOT cached, because the Watch
// leaves that entry queued and re-fires the same requestID expecting a
// FRESH attempt — see `shouldCacheVerdict(for:)`.

// macOS exclusion: `WatchConnectivity` is iOS-only (and watchOS, but the
// file-level gate already excludes Watch). macOS menu-bar Conduck has
// no companion Watch to receive relays from, so the coordinator simply
// doesn't exist there.
#if os(iOS)

import Foundation
import WatchConnectivity
import UIKit

/// iPhone-side relay handler. Receives relay-request audio from the Watch
/// (queued file or inline message), transcribes it — custom-endpoint stamp ⇒
/// that endpoint; no stamp ⇒ the iPhone's current active provider; other
/// stamps ⇒ legacy Apple on-device — and ships the transcript (or error
/// code) back: interactive `sendMessage` when the request allows it, queued
/// `transferUserInfo` otherwise.
///
/// Singleton wired by `PhoneSessionManager` (which owns the WCSession
/// delegate); the only cross-request state this type holds is the
/// idempotency ledger (in-flight Set + verdict cache), so a missed reply
/// on iPhone restart stays recoverable from the Watch's deferred-relay
/// queue: a re-fire of the SAME requestID against an empty ledger simply
/// transcribes fresh.
@MainActor
final class AppleSpeechRelayCoordinator {
    static let shared = AppleSpeechRelayCoordinator()

    /// Metadata key constants — kept in lockstep with the Watch-side
    /// coordinator. If you change a literal here, change it there too.
    enum Wire {
        static let kindKey = "kind"
        static let kindValue = "apple-speech-relay"
        static let replyKind = "apple-speech-relay-reply"
        static let requestIDKey = "requestID"
        static let languageKey = "language"
        static let resultTextKey = "result.text"
        static let resultErrorCodeKey = "result.errorCode"
        /// Custom-STT V1.x: which STT provider the iPhone should run for the
        /// relayed clip. Absent (legacy Watch builds / the Apple path) ⇒
        /// transcribe with the iPhone's CURRENT active provider (the
        /// iPhone is the settings authority; a stale Watch that
        /// still thinks Apple is active gets the user's real provider, not
        /// a guaranteed-wrong Apple run); `"custom-openai"` /
        /// `"custom-openai_<uuid>"` ⇒ run the BYO custom OpenAI-compatible
        /// endpoint via `STTClient.transcribe` (the iPhone alone holds the
        /// base URL, cert pin, and long timeout — the Watch can't reach a
        /// Tailscale server, so it relays here). Any other (future) stamp
        /// keeps the legacy Apple route — see `processRelayRequest`.
        static let providerIDKey = "providerID"
        /// Inline fast path: when the iPhone is
        /// reachable the Watch sends the whole request via `sendMessage`
        /// with the compressed clip as raw `Data` under this key (request
        /// payload only — never present in `transferFile` metadata).
        static let audioKey = "audio"
        /// Fire-and-forget `sendMessage` kind the
        /// Watch sends alongside a `transferFile` when reachable: message
        /// delivery itself launches/wakes the suspended iPhone app so the
        /// queued file gets serviced promptly. Carries no audio; the reply
        /// (if any handler is attached) is an empty ACK.
        static let wakeKind = "apple-speech-relay-wake"
        /// Capability stamp (Bool), present in the
        /// inline payload AND in `transferFile` metadata. We reply via
        /// interactive `sendMessage` ONLY when this is present and true;
        /// absent ⇒ legacy queued `transferUserInfo` reply (stale-Watch-
        /// build safety: an old build that never filled `didReceiveMessage`
        /// must keep receiving replies on the channel it knows).
        static let supportsMessageReplyKey = "replySendMessageOK"
    }

    /// Routing verdict for a relay request that arrived WITHOUT a providerID
    /// stamp. Semantics: absent providerID means "transcribe with
    /// the iPhone's CURRENT active provider" — the iPhone is the settings
    /// authority; a stale Watch that still thinks Apple is active gets the
    /// user's real provider instead of a guaranteed-wrong Apple run.
    enum NilProviderRoute: Equatable {
        case appleOnDevice
        case customEndpoint(presetID: String)
        case activeCloud
    }

    /// Pure routing decision — extracted so the verdict is unit-testable
    /// without a `SettingsManager` snapshot. Apple wins regardless of the
    /// dynamic-endpoint flag (the Apple registry entry never carries one;
    /// the precedence is pinned in `RelayRoutingDecisionTests`).
    static func resolveNilProviderRoute(activePresetID: String, activeHasDynamicEndpoint: Bool) -> NilProviderRoute {
        if activePresetID == STTProvider.appleOnDevice.id { return .appleOnDevice }
        if activeHasDynamicEndpoint { return .customEndpoint(presetID: activePresetID) }
        return .activeCloud
    }

    private init() {}

    // MARK: - Idempotency ledger

    /// requestIDs with a transcription currently running. A duplicate
    /// arriving while its original is in flight (inline send + file
    /// fallback both landing, or a drain re-fire racing a slow transcribe)
    /// is dropped — the running request will reply for both. Main-actor
    /// confined; checked-then-inserted synchronously (no await between),
    /// so there is no TOCTOU window.
    private var inFlightRequestIDs: Set<String> = []

    /// Completed verdicts, LRU-bounded (capacity 16). A duplicate arriving
    /// AFTER completion re-receives the cached verdict — never triggers a
    /// second transcription. Admission-gated by `shouldCacheVerdict(for:)`:
    /// SETTLED verdicts only.
    private let replyCache = RelayReplyCache()

    /// Verdict-cache admission rule: the reply cache is an idempotency
    /// ledger for SETTLED verdicts — success or PERMANENT error — never a
    /// memo of transient conditions.
    ///
    /// Why this matters: on a retryable error code (e.g.
    /// `sttProviderUnreachable` = 20, a transient BYO-endpoint outage) the
    /// Watch deliberately LEAVES the entry queued and re-fires the SAME
    /// requestID later, expecting a fresh transcription attempt. If that
    /// verdict were cached, every re-fire would hit the cache first and
    /// re-serve the stale outage verdict without ever touching the endpoint
    /// again — one blip would permanently poison the request (until iPhone
    /// process death or the Watch's 24 h age-out) AND block the head of the
    /// Watch's drain queue behind it.
    ///
    /// `AppError.isRetryable` is the canonical transient/permanent
    /// classifier, so the rule cannot drift from the app-wide retry
    /// taxonomy. Skipping the store for retryables costs only a fresh
    /// transcription on retry — exactly the desired behavior — while
    /// `inFlightRequestIDs` still dedups CONCURRENT duplicates of the same
    /// attempt. Permanent errors (`appleSpeechModelNotInstalled`,
    /// `audioInvalid`, `audioTooLarge`, `sttCustomEndpointNotConfigured`,
    /// `audioProcessingFailed`, …) stay cached: retrying them re-yields the
    /// identical verdict, so replaying it is pure savings.
    static func shouldCacheVerdict(for error: AppError) -> Bool {
        !error.isRetryable
    }

    /// Returns `true` if the incoming `WCSessionFile`'s metadata identifies
    /// it as an Apple-speech relay request. `PhoneSessionManager` calls this
    /// to decide whether to route to us or fall through to legacy handling.
    nonisolated func isRelayFile(_ file: WCSessionFile) -> Bool {
        guard let metadata = file.metadata,
              let kind = metadata[Wire.kindKey] as? String else {
            return false
        }
        return kind == Wire.kindValue
    }

    /// Synchronous-ingestion failure escape hatch for `PhoneSessionManager`:
    /// called (on the WCSession delegate queue) when `RelayInboxMover` could
    /// not take ownership of an incoming relay file, or when an inline
    /// request's audio Data could not be written to disk. The audio is
    /// already lost at that point, so the ERROR reply may hop to the main
    /// actor — only the file rescue itself was timing-critical. Replying
    /// (instead of silently dropping) lets the Watch converge on
    /// `audioInvalid` instead of burning its full reply timeout.
    nonisolated static func sendIngestionFailureReply(metadata: [String: Any]) {
        guard let requestID = metadata[Wire.requestIDKey] as? String,
              !requestID.isEmpty else { return }
        let prefersMessage = metadata[Wire.supportsMessageReplyKey] as? Bool ?? false
        Task { @MainActor in
            shared.sendReply(
                requestID: requestID,
                errorCode: AppError.audioInvalid.errorCode,
                preferMessage: prefersMessage
            )
        }
    }

    /// Handle a Watch-originated relay request file whose ownership was
    /// ALREADY transferred to us. The caller (`PhoneSessionManager`) has
    /// confirmed `isRelayFile(_:)`, captured the metadata by value, and
    /// moved the WatchConnectivity Inbox file to `fileURL` synchronously
    /// via `RelayInboxMover` BEFORE the delegate returned (the Inbox
    /// original is deleted by the OS on delegate return).
    /// From here on WE own `fileURL` and must delete it on every exit.
    ///
    /// Thin wrapper: parses the wire metadata and forwards to
    /// `processRelayRequest` — the shared core both ingress channels
    /// (queued file + inline message) funnel through, so dedup/transcribe/
    /// reply behavior cannot diverge between them.
    func handleIncomingRelayFile(at fileURL: URL, metadata: [String: Any]) async {
        guard let requestID = metadata[Wire.requestIDKey] as? String,
              !requestID.isEmpty else {
            // We own the moved file; with no requestID there is nobody to
            // answer — delete and drop.
            try? FileManager.default.removeItem(at: fileURL)
            #if DEBUG
            print("[Phone] Apple relay file missing requestID — dropping")
            #endif
            return
        }
        let language = metadata[Wire.languageKey] as? String
        // Custom-STT V1.x: when the Watch stamped a provider ID, the iPhone runs
        // THAT provider instead of Apple on-device. Absent ⇒ the iPhone's
        // CURRENT active provider (settings authority — see processRelayRequest).
        let relayProviderID = metadata[Wire.providerIDKey] as? String
        // Stale-watch-build safety: interactive replies ONLY when the Watch
        // explicitly stamped the capability (absent ⇒ legacy transferUserInfo).
        let replyPrefersMessage = metadata[Wire.supportsMessageReplyKey] as? Bool ?? false
        await processRelayRequest(
            requestID: requestID,
            audioURL: fileURL,
            language: language,
            providerID: relayProviderID,
            replyPrefersMessage: replyPrefersMessage
        )
    }

    /// Shared relay core — BOTH ingress channels (queued `transferFile` via
    /// `handleIncomingRelayFile(at:metadata:)`, inline `sendMessage` via
    /// `PhoneSessionManager`) land here with an audio temp URL WE own.
    ///
    ///   1. Idempotency ledger FIRST (the Watch retries with the SAME
    ///      requestID): cached verdict → re-ship it, delete the duplicate
    ///      audio, done — never re-transcribe. In-flight → delete the
    ///      duplicate audio and drop — the running request replies for both.
    ///   2. Mark in-flight; delete the temp audio on EVERY exit (`defer`).
    ///   3. Route by `providerID` stamp: a custom-endpoint stamp ⇒ that
    ///      EXACT endpoint; nil ⇒ the iPhone's CURRENT active provider
    ///      (`transcribeWithActiveProvider`); any other
    ///      stamp ⇒ the legacy Apple route (unknown future stamps must
    ///      not be guessed onto a billable provider).
    ///   4. Store the verdict in the reply cache, then ship the reply —
    ///      interactive `sendMessage` when `replyPrefersMessage` and the
    ///      Watch is reachable, queued `transferUserInfo` otherwise.
    ///
    /// All `AppError` failures from the runner map cleanly to their
    /// `errorCode` slot — including `appleSpeechModelNotInstalled` (18),
    /// which the Watch surfaces with the "open Conduck on iPhone to
    /// download the model" recovery phrase. We do NOT auto-download here:
    /// the user is on the Watch, may be away from Wi-Fi, and the model
    /// is multi-hundred MB — silent download would be a privacy + data-
    /// quota regression.
    func processRelayRequest(
        requestID: String,
        audioURL: URL,
        language: String?,
        providerID: String?,
        replyPrefersMessage: Bool
    ) async {
        // ── Idempotency ledger ──────────────────────────
        // Completed before: re-ship the prior verdict. A second transcribe
        // run for the same utterance is the exact double-agent-hop bug the
        // claim-token design exists to prevent. The duplicate audio is
        // redundant — delete it now.
        if let cached = replyCache.cachedReply(forKey: requestID) {
            try? FileManager.default.removeItem(at: audioURL)
            #if DEBUG
            print("[Phone] Relay duplicate after completion — re-sent cached verdict")
            #endif
            ship(payload: cached.payload(requestID: requestID), preferMessage: replyPrefersMessage)
            return
        }
        // Currently running: drop silently. The in-flight original will
        // reply for both deliveries (e.g. inline send AND its file
        // fallback both landed).
        if inFlightRequestIDs.contains(requestID) {
            try? FileManager.default.removeItem(at: audioURL)
            #if DEBUG
            print("[Phone] Relay duplicate while in-flight — dropped")
            #endif
            return
        }
        inFlightRequestIDs.insert(requestID)
        defer { inFlightRequestIDs.remove(requestID) }

        // Own the temp audio to the end of this scope — success OR throw.
        // (On the custom-endpoint branch `STTClient.transcribe` also
        // deletes it via its own `defer`; the double-remove is a harmless
        // `try?` no-op.)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        // Keep the system from suspending us mid-transcribe on iOS.
        let backgroundTask = await beginBackgroundTaskIfPossible()
        defer {
            endBackgroundTaskIfPossible(backgroundTask)
        }

        do {
            let text: String
            // A BYO custom endpoint id is EITHER the legacy bare `custom-openai`
            // OR a per-endpoint `custom-openai_<uuid>` (Phase B). Both dispatch to
            // the custom-endpoint relay; the guard inside checks the iPhone is
            // still on the SAME endpoint (no silent reroute).
            let isCustomRelay = providerID == STTProvider.customOpenAICompat.id
                || (providerID.map { STTProvider.customEndpointUUID(fromPresetID: $0) != nil } ?? false)
            if isCustomRelay, let providerID {
                // BYO custom endpoint. The iPhone holds the base URL, cert pin,
                // effective auth scheme, and long timeout — all resolved in one
                // actor hop via `activeSTTSnapshot()` (atomic url/model/auth/pin).
                // `STTClient.transcribe` owns the temp file's lifecycle via its
                // own `defer`-remove; the coordinator's `defer` above is then a
                // harmless no-op. Privacy: the key never leaves the iPhone — only
                // the transcript text crosses back over the wire.
                text = try await transcribeViaCustomEndpoint(audioFileURL: audioURL, language: language, relayProviderID: providerID)
            } else if providerID == nil {
                // No stamp ⇒ the iPhone's CURRENT active provider. The
                // iPhone is the settings authority — a stale Watch
                // that still believes Apple is active gets the user's real
                // provider instead of a guaranteed-wrong Apple run.
                text = try await transcribeWithActiveProvider(audioFileURL: audioURL, language: language)
            } else {
                // Unknown NON-custom stamp (a future Watch build talking to
                // this iPhone): deliberately keep the legacy Apple route —
                // rerouting an unrecognized stamp to the active provider
                // would silently transcribe (and bill) on a vendor the
                // sender never asked for.
                let response = try await AppleSpeechRunner.transcribe(
                    audioFileURL: audioURL,
                    language: language
                )
                text = response.text
            }
            // Cache BEFORE shipping: a duplicate landing between ship and
            // in-flight removal must already see the verdict.
            replyCache.store(.init(text: text, errorCode: nil), forKey: requestID)
            sendReply(requestID: requestID, text: text, preferMessage: replyPrefersMessage)
            #if DEBUG
            print("[Phone] Relay reply shipped (text length=\(text.count), custom=\(isCustomRelay))")
            #endif
        } catch let appError as AppError {
            // Admission gate: transient failures must NOT be memoized — the
            // Watch leaves the entry queued on a retryable code and re-fires
            // the SAME requestID expecting a fresh attempt, not a replay of
            // the outage. See `shouldCacheVerdict(for:)`.
            if Self.shouldCacheVerdict(for: appError) {
                replyCache.store(.init(text: nil, errorCode: appError.errorCode), forKey: requestID)
            }
            sendReply(requestID: requestID, errorCode: appError.errorCode, preferMessage: replyPrefersMessage)
            #if DEBUG
            print("[Phone] Apple relay failed AppError code=\(appError.errorCode)")
            #endif
        } catch {
            // Unknown error → bubble as audioProcessingFailed; the Watch
            // surfaces the existing "couldn't process" copy. We deliberately
            // do NOT pass the underlying error description across the wire
            // (privacy + brand-surface invariant). Routed through the same
            // admission gate as the typed branch (today
            // `audioProcessingFailed` is permanent ⇒ cached; a future
            // re-classification is respected automatically).
            let fallback = AppError.audioProcessingFailed
            if Self.shouldCacheVerdict(for: fallback) {
                replyCache.store(.init(text: nil, errorCode: fallback.errorCode), forKey: requestID)
            }
            sendReply(requestID: requestID, errorCode: fallback.errorCode, preferMessage: replyPrefersMessage)
            #if DEBUG
            print("[Phone] Apple relay failed (unknown)")
            #endif
        }
    }

    // MARK: - Custom-endpoint relay (Custom-STT V1.x)

    /// Transcribe a Watch-relayed clip through the BYO custom OpenAI-compatible
    /// endpoint, resolving the URL / key / model / auth / cert-pin in one actor
    /// hop via `activeSTTSnapshot()`. The custom config (and thus the base URL +
    /// cert pin + long timeout) lives ONLY on the iPhone — the Watch never holds
    /// it — so this is the sole transcription path for a custom-active Watch
    /// recording.
    ///
    /// Resilience: if the iPhone is no longer on the custom preset (the user
    /// switched providers between the Watch recording and this relay arriving)
    /// the snapshot won't be the custom provider; we throw
    /// `sttCustomEndpointNotConfigured` rather than silently transcribing on a
    /// different provider with a different key — no silent reroute (matches the
    /// gateway "unconfigured bound backend throws" posture). `STTClient.transcribe`
    /// owns the temp-file deletion via its own `defer`.
    ///
    /// Phase B (multiple named endpoints): the snapshot resolves off the ACTIVE
    /// preset, not the relayed uuid — so an additional guard
    /// (`snapshot.presetID == relayProviderID`) ensures the iPhone is still on the
    /// EXACT endpoint the Watch recorded against. If the user switched between two
    /// custom endpoints (different URL + key) we throw rather than transcribe on
    /// the wrong server.
    private func transcribeViaCustomEndpoint(audioFileURL: URL, language: String?, relayProviderID: String) async throws -> String {
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        guard snapshot.provider.dynamicEndpointKey != nil,
              snapshot.presetID == relayProviderID,
              let customConfig = snapshot.customConfig else {
            throw AppError.sttCustomEndpointNotConfigured
        }
        // Effective key, through `STTKeyReadiness` for the reason every other
        // snapshot-driven call site now uses it: `snapshot.apiKey` is a
        // collapsed `String?`, and its nil means EITHER no key or a Keychain
        // that could not answer. The keyless (`.none` auth) local-server case
        // is already inside `requiresKey`, so this is one call, not a special
        // case bolted onto one.
        //
        // Which reading matters MORE here than on any in-app lane: the words
        // arriving on this path were spoken on a WATCH, and the refusal travels
        // back as a bare error code the wrist rebuilds. Code 23 is terminal
        // there, so it deletes the wrist's recording and says the user has no
        // key; code 75 is retryable, so the wrist keeps the capture and the
        // verdict is never cached (`shouldCacheVerdict` admits settled verdicts
        // only), which is what lets a re-fire of the same requestID transcribe
        // for real once the phone is unlocked (I3, I6).
        let apiKey: String
        switch await STTKeyReadiness.resolve(
            presetID: snapshot.presetID,
            snapshotKey: snapshot.apiKey,
            provider: snapshot.provider,
            customConfig: customConfig
        ) {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            throw AppError.sttMissingAPIKey
        case .unreadable:
            throw AppError.sttKeyUnreadable
        }
        let response = try await STTClient.shared.transcribe(
            audioFileURL: audioFileURL,
            apiKey: apiKey,
            language: language,
            provider: snapshot.provider,
            customModel: snapshot.customModel,
            customConfig: customConfig
        )
        return response.text
    }

    // MARK: - Active-provider relay (nil providerID)

    /// Transcribe a Watch-relayed clip with whatever provider the iPhone
    /// currently has active — the route an UNSTAMPED request takes. One
    /// `activeSTTSnapshot()` actor hop resolves preset/key/provider/model/
    /// config atomically (torn-read posture), then
    /// `resolveNilProviderRoute` picks the arm:
    ///   - Apple active ⇒ on-device `SpeechAnalyzer`, byte-identical to the
    ///     legacy path.
    ///   - Custom endpoint active ⇒ `transcribeViaCustomEndpoint` with the
    ///     snapshot's OWN presetID, so its same-endpoint guard passes by
    ///     construction.
    ///   - Cloud provider active ⇒ `STTClient.transcribe` with the snapshot
    ///     key (`customConfig: nil` — frozen cloud providers stay on default
    ///     ATS, never the cert-pin path).
    /// On the STTClient arms the client defer-deletes the audio file; the
    /// caller's own defer-remove is then a harmless `try?` no-op (same as
    /// the custom branch).
    private func transcribeWithActiveProvider(audioFileURL: URL, language: String?) async throws -> String {
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        switch Self.resolveNilProviderRoute(
            activePresetID: snapshot.presetID,
            activeHasDynamicEndpoint: snapshot.provider.dynamicEndpointKey != nil
        ) {
        case .appleOnDevice:
            let response = try await AppleSpeechRunner.transcribe(audioFileURL: audioFileURL, language: language)
            return response.text
        case .customEndpoint(let presetID):
            return try await transcribeViaCustomEndpoint(audioFileURL: audioFileURL, language: language, relayProviderID: presetID)
        case .activeCloud:
            // Same two readings, same asymmetry as the custom-endpoint arm
            // above — a nil key here is either an empty slot (23) or a Keychain
            // that could not answer (75), and only the second one must leave the
            // wrist's recording alive. `customConfig: nil` mirrors what this arm
            // hands `STTClient`: `.activeCloud` is reached only for a FROZEN
            // cloud provider, for which the snapshot resolves no custom config,
            // so a key is unconditionally required.
            let key: String
            switch await STTKeyReadiness.resolve(
                presetID: snapshot.presetID,
                snapshotKey: snapshot.apiKey,
                provider: snapshot.provider,
                customConfig: nil
            ) {
            case .ready(let resolved):
                key = resolved
            case .notConfigured:
                throw AppError.sttMissingAPIKey
            case .unreadable:
                throw AppError.sttKeyUnreadable
            }
            let response = try await STTClient.shared.transcribe(
                audioFileURL: audioFileURL,
                apiKey: key,
                language: language,
                provider: snapshot.provider,
                customModel: snapshot.customModel,
                customConfig: nil
            )
            return response.text
        }
    }

    // MARK: - Reply

    // Both overloads build their payload through
    // `RelayReplyCache.CachedReply.payload(requestID:)` — the SINGLE
    // payload-shape site, shared with the cached-verdict re-send path, so
    // fresh and replayed replies are provably identical — and funnel
    // through `ship(payload:preferMessage:)`, the single channel-choice
    // site.

    private func sendReply(requestID: String, text: String, preferMessage: Bool) {
        ship(
            payload: RelayReplyCache.CachedReply(text: text, errorCode: nil)
                .payload(requestID: requestID),
            preferMessage: preferMessage
        )
    }

    private func sendReply(requestID: String, errorCode: Int, preferMessage: Bool) {
        ship(
            payload: RelayReplyCache.CachedReply(text: nil, errorCode: errorCode)
                .payload(requestID: requestID),
            preferMessage: preferMessage
        )
    }

    /// Channel choice (reply half): the queued
    /// `transferUserInfo` channel is opportunistic background delivery with
    /// no latency guarantee — the reply must ride the interactive
    /// `sendMessage` channel whenever it can. `preferMessage` is true only
    /// when the REQUEST stamped `Wire.supportsMessageReplyKey` (a stale
    /// Watch build keeps its legacy channel); reachability is re-checked at
    /// ship time because it may have flapped during transcription. The
    /// `sendMessage` errorHandler falls back to `transferUserInfo` —
    /// delivery beats latency.
    private func ship(payload: [String: Any], preferMessage: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if preferMessage, session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Interactive send failed (reachability flapped mid-flight,
                // counterpart suspended, …) — fall back to the queued
                // channel; it survives both apps suspending.
                _ = WCSession.default.transferUserInfo(payload)
            }
        } else {
            _ = session.transferUserInfo(payload)
        }
    }

    // MARK: - Background task helpers

    private typealias BackgroundTaskHandle = UIBackgroundTaskIdentifier

    private func beginBackgroundTaskIfPossible() async -> BackgroundTaskHandle {
        await MainActor.run {
            var handle: UIBackgroundTaskIdentifier = .invalid
            handle = UIApplication.shared.beginBackgroundTask(
                withName: "AppleRelayTranscribe"
            ) {
                // Expiration: end the task to satisfy UIKit's contract.
                // The SpeechAnalyzer run continues to completion on its own
                // task; the next launch recovery is the Watch's deferred-relay
                // re-fire.
                UIApplication.shared.endBackgroundTask(handle)
                handle = .invalid
            }
            return handle
        }
    }

    private func endBackgroundTaskIfPossible(_ handle: BackgroundTaskHandle) {
        guard handle != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(handle)
        }
    }
}

#endif // os(iOS)
