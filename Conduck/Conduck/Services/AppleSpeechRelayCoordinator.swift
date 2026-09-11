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
//   - "destination" stamp: absent ⇒ the transcript is a CHAT ask and the
//     wrist hops it to a gateway; "work" ⇒ the clip is PARKED in this
//     phone's device-local retry lane before transcription, its words
//     become a Work desk card when they arrive, and nothing on that
//     branch touches a conversation, a gateway ref or the converse
//     pipeline. Chat is never spelled on the wire, so a legacy wrist
//     build is a chat build by construction.
//   - Reply dict shape (identical on BOTH reply channels):
//        success: ["requestID": String, "kind": "apple-speech-relay-reply",
//                  "result.text": String]
//        success (work): the three keys above PLUS "result.work": true —
//                  this phone holds the capture durably, so the wrist may
//                  release its own copy. A work request answered WITHOUT
//                  that stamp is an older iPhone build: the wrist has the
//                  words and knows nothing was kept here. An EMPTY
//                  "result.text" beside the stamp is the third answer:
//                  the phone holds the recording and no words came with
//                  it, so its own retry card owns the capture from here.
//                  No key is added for it — emptiness is the value.
//        failure: ["requestID": String, "kind": "apple-speech-relay-reply",
//                  "result.errorCode": Int]   // AppError.errorCode
//   - Reply channel: interactive `sendMessage` when the request stamped
//     "replySendMessageOK": true AND the Watch is reachable (errorHandler
//     falls back to `transferUserInfo`); otherwise queued
//     `transferUserInfo` (legacy Watch builds keep working byte-for-byte).
//
// Privacy invariant (docs/ai-context/spec.md): never log audio bytes,
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

import CryptoKit
import Foundation
import OSLog
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
        /// Where the transcribed words are meant to land, present in the
        /// inline payload AND in `transferFile` metadata. ABSENT means chat —
        /// the only shape a legacy wrist build can send — so the chat lane is
        /// never spelled on the wire and an old watch keeps working
        /// byte-for-byte. Only `destinationWork` diverts a request off the
        /// converse pipeline.
        static let destinationKey = "destination"
        /// The one recognised `destinationKey` value: the words belong on the
        /// Work desk, and NOTHING on that branch reaches a gateway or a
        /// conversation.
        static let destinationWork = "work"
        /// Reply stamp (Bool `true`), present ONLY on a work reply: this phone
        /// holds the capture durably — the words on the desk, or the recording
        /// parked in the retry lane its own card offers. Its ABSENCE on a work
        /// request's reply is meaningful to the wrist — an older iPhone build
        /// transcribed the clip without keeping it — so it is never written
        /// on a chat reply, whose three-key shape is frozen.
        static let resultWorkSavedKey = "result.work"
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
        // Where the words are meant to land. Read on BOTH ingress channels for
        // the reason the rest of this method exists: a queued file and an
        // inline message are the SAME request, and a destination visible on
        // only one of them would send the wrist's private note to a gateway
        // whenever the phone happened to be unreachable at record time.
        let destination = metadata[Wire.destinationKey] as? String
        await processRelayRequest(
            requestID: requestID,
            audioURL: fileURL,
            language: language,
            providerID: relayProviderID,
            replyPrefersMessage: replyPrefersMessage,
            destination: destination
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
    ///   2a. WORK destination only: PARK the clip in this phone's device-local
    ///      retry lane BEFORE any transcribe arm runs, and while the bytes
    ///      still exist — the STT arms below defer-delete the temp file out
    ///      from under us. Nothing reaches the desk here: a Work voice note is
    ///      its words, and the recording is kept only until they are written.
    ///      Same ordering claim as every other Work voice lane, one step
    ///      earlier: a transcription that never succeeds costs the words and
    ///      keeps the recording for a retry. A failure HERE replies a RETRYABLE
    ///      code so the wrist keeps its clip and re-fires; it is never cached
    ///      (`shouldCacheVerdict`), so the re-fire parks for real.
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
    ///
    /// `destination` is the raw wire value, not a parsed enum, and it has no
    /// default: both ingress channels must state it, so a future third
    /// channel cannot silently inherit chat for a request the wrist marked
    /// Work.
    func processRelayRequest(
        requestID: String,
        audioURL: URL,
        language: String?,
        providerID: String?,
        replyPrefersMessage: Bool,
        destination: String?
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

        // ── Work phase 1: the clip is parked before the words ───────────
        // NOTHING below this point on the work branch touches a
        // conversation, a `RemoteAgentRef`, `startConverseHop`,
        // `startDeferredConverseHop` or `handleQuickSend`. A private thought
        // spoken into the wrist reaches the desk and stops there; the only
        // wire the reply crosses is back to the watch.
        // `WatchWorkRelayPhoneTests` asserts this structurally by reading
        // this source file, because the failure mode is a silent one line.
        //
        // The reservation this request holds over the parked capture, and the
        // whole of what "the phone has it" means: an entry nobody holds is one
        // another surface may take and finish while this request is still
        // transcribing, so no claim reads as NOTHING IS PARKED.
        var parkedClip: PendingRetryClaim?
        var leaseRenewal: Task<Void, Never>?
        defer { leaseRenewal?.cancel() }
        if Self.isWorkDestination(destination) {
            do {
                // The bytes must be read HERE: the transcribe arms below hand
                // the URL to `STTClient`, which defer-deletes it, and this
                // scope's own defer deletes it on every exit. After those, the
                // recording exists nowhere but on the wrist — which is exactly
                // why it is parked before either of them runs.
                let audio = try Data(contentsOf: audioURL)
                let claim = try await Self.parkRelayedWorkClip(
                    requestID: requestID,
                    audio: audio,
                    language: language
                )
                parkedClip = claim
                // The reservation is granted for `claimLeaseDuration`, and a
                // custom endpoint is allowed 300 s and attempted three times —
                // so the work can outlast the hold that protects it. Renewed
                // while this request runs, cancelled by the `defer` above on
                // every exit, so a request that ends stops extending the hold.
                leaseRenewal = Task { await Self.renewWhileTranscribing(claim) }
            } catch {
                // Retryable BY CONSTRUCTION (see `workPublicationFailure`):
                // the wrist leaves the entry queued, keeps the clip, and
                // re-fires the same requestID. Deliberately NOT cached — the
                // admission gate already refuses retryables, and a memoized
                // storage blip would poison every re-fire.
                let failure = Self.workPublicationFailure
                sendReply(
                    requestID: requestID,
                    errorCode: failure.errorCode,
                    preferMessage: replyPrefersMessage
                )
                #if DEBUG
                print("[Phone] Work relay phase 1 refused — wrist keeps the clip")
                #endif
                return
            }
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
            // ── Work phase 2: the words become the card ─────────────────
            // The words are PARKED on the entry before the desk write and the
            // verdict stamped after it, so every instant between them is one a
            // recovery can name: a crash before the publish costs at most one
            // more STT call, and a crash after it replays onto the same card.
            // The clear is last, and it is what finally deletes the recording —
            // the bytes outlive the words by exactly the span of that write.
            //
            // A refused publish is answered with the ACKNOWLEDGEMENT rather
            // than an error: the capture is parked here, under a claim, so the
            // phone's own retry card owns it and a wrist that keeps re-firing
            // would only buy the same refusal again.
            if let parkedClip {
                _ = await PendingRetryStore.shared.recordPublicationState(
                    parkedClip,
                    transcript: text,
                    // The desk still holds nothing for this capture. The words
                    // are parked as a fact about the ENTRY, and only the write
                    // below earns `.published`.
                    publicationState: .phaseOneFailed
                )
                do {
                    _ = try await WorkVoiceCaptureCoordinator.publishTranscript(
                        text,
                        forCapture: parkedClip.id,
                        createdAt: parkedClip.entry.metadata.createdAt,
                        sourceDevice: Self.relaySourceDevice,
                        // NO PICTURE ON THIS LANE. The wrist relays a clip and
                        // nothing else, so relayed words are never a companion
                        // to anything; stated rather than defaulted so a future
                        // picture arriving here has to be a deliberate edit.
                        attachedTo: nil
                    )
                } catch {
                    Self.log.error("Work relay: the words were not written to the desk")
                    await Self.handBackParkedClip(parkedClip)
                    shipWorkRecordingAcknowledgement(
                        requestID: requestID,
                        preferMessage: replyPrefersMessage
                    )
                    #if DEBUG
                    print("[Phone] Work relay phase 2 refused — the phone's retry card owns it")
                    #endif
                    return
                }
                _ = await PendingRetryStore.shared.recordPublicationState(
                    parkedClip,
                    transcript: text,
                    publicationState: .published
                )
                // The recording's last instant. A clear that fails leaves a
                // `.published` entry the day-long clock retires, and whose own
                // recovery is a no-op publish followed by a clear.
                _ = await PendingRetryStore.shared.clear(parkedClip)
            }
            // Cache BEFORE shipping: a duplicate landing between ship and
            // in-flight removal must already see the verdict — INCLUDING the
            // work stamp, so a replayed work reply is not mistaken for an old
            // iPhone build that kept nothing.
            let workSaved = parkedClip != nil
            replyCache.store(
                .init(text: text, errorCode: nil, workSaved: workSaved ? true : nil),
                forKey: requestID
            )
            sendReply(
                requestID: requestID,
                text: text,
                workSaved: workSaved,
                preferMessage: replyPrefersMessage
            )
            #if DEBUG
            print("[Phone] Relay reply shipped (text length=\(text.count), custom=\(isCustomRelay), work=\(workSaved))")
            #endif
        } catch let appError as AppError {
            // THE CAPTURE IS PARKED HERE, so every speech failure — transient
            // or settled — is an acknowledgement rather than an error. The
            // phone's own retry card holds the recording and offers the Try
            // Again, which is a better answer than a wrist that keeps re-firing
            // one clip into an outage: the words are bought once, on this side,
            // by whoever taps. The clip goes back to the queue unfinished, and
            // the wrist is free to release its copy.
            if let parkedClip {
                await Self.handBackParkedClip(parkedClip)
                shipWorkRecordingAcknowledgement(
                    requestID: requestID,
                    preferMessage: replyPrefersMessage
                )
                #if DEBUG
                print("[Phone] Work relay kept the recording, lost the words — acknowledged")
                #endif
                return
            }
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
            // Same reading as the typed arm above, and deliberately identical
            // in shape: the arm that reads an untyped throw is not a different
            // promise from the arm that reads a typed one, and answering the
            // same parked capture two different ways is how one of them ends up
            // telling a wrist to keep a clip this phone already holds.
            if let parkedClip {
                await Self.handBackParkedClip(parkedClip)
                shipWorkRecordingAcknowledgement(
                    requestID: requestID,
                    preferMessage: replyPrefersMessage
                )
                #if DEBUG
                print("[Phone] Work relay kept the recording, lost the words — acknowledged")
                #endif
                return
            }
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

    // MARK: - Work destination (Watch → Work relay, phone half)

    /// The verdict a refused PARK travels back on — the one failure this lane
    /// still answers as a failure.
    ///
    /// It is a named constant rather than an inline literal because its ONE
    /// required property is invisible at the call site: `workDeskWriteFailed`
    /// is `isRetryable`, which is precisely what makes the wrist LEAVE its
    /// entry queued (`AppleRelayPendingQueue.leavesEntryQueued`) and keep the
    /// only copy of the recording. Substituting a terminal code — an
    /// `audioProcessingFailed` reflex, say — would have the wrist delete the
    /// clip on a storage blip the very next attempt would have survived.
    /// `WatchWorkRelayPhoneTests` pins the retryability, not the spelling.
    static let workPublicationFailure: AppError = .workDeskWriteFailed

    /// The verdict a Work request earns once its clip is parked here and the
    /// words did not arrive.
    ///
    /// SUCCESS-SHAPED, with an EMPTY transcript and the durability stamp — and
    /// it introduces no wire literal: `result.text` and `result.work` are the
    /// two keys a stamped work reply already carries. Empty text is the honest
    /// value: there are no words. The wrist reads the stamp as "the phone holds
    /// this capture" (so it settles its entry and deletes its clip) and the
    /// emptiness as "no words came" (so it says which half is missing).
    ///
    /// What backs the stamp is the PARKED ENTRY, handed back to the queue
    /// unfinished: the phone's own retry card offers it, and the words are
    /// bought once, on this side, by whoever taps. That is why every speech
    /// failure earns this and not an error — a wrist re-firing one clip into an
    /// outage buys nothing the retry card does not already own.
    static func workRecordingAcknowledgement() -> RelayReplyCache.CachedReply {
        RelayReplyCache.CachedReply(text: "", errorCode: nil, workSaved: true)
    }

    /// Whether this request's words belong on the Work desk.
    ///
    /// Exact match, and deliberately not a case-folded or prefix one: the
    /// wire value is written by our own wrist build from a shared literal, so
    /// anything else is drift, and guessing at drift is how an unrecognised
    /// stamp becomes a destination nobody chose. An unknown value reads as
    /// chat for the same reason an absent one does — that is the shape every
    /// shipped watch already sends.
    static func isWorkDestination(_ raw: String?) -> Bool {
        raw == Wire.destinationWork
    }

    /// The capture id a relayed clip is parked and published under.
    ///
    /// The wrist mints its requestID as a UUID, so the common path is an
    /// identity: one utterance keeps ONE capture id across the inline send, the
    /// file fallback and every drain re-fire, which is what makes both the park
    /// and the desk write idempotent for a claim token the watch retries
    /// verbatim. A requestID that is NOT a UUID (a foreign or future sender) is
    /// hashed into one — UUIDv5 in a namespace of this lane's own, the same
    /// shape and the same reason as `WorkMaterialCollisionEscape`: a random id
    /// would turn each retry of one utterance into another entry and another
    /// card.
    static func workCaptureID(forRequestID requestID: String) -> UUID {
        if let direct = UUID(uuidString: requestID) { return direct }
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: relayCaptureNamespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(requestID.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // RFC 4122 §4.3: name-based, SHA-1 (version 5) and the standard variant.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Compile-time namespace for `workCaptureID(forRequestID:)`. A literal,
    /// in the same spirit as the desk's own fixed id: two attempts at one
    /// utterance must derive the same capture or the replay duplicates it.
    /// Changing it re-homes every capture already parked and published this way.
    private static let relayCaptureNamespace =
        UUID(uuidString: "3EA1CA9D-0000-4000-A000-000000000001")!

    /// PHASE 1 for the relay lane: put the wrist's clip in this phone's
    /// device-local, non-syncing retry lane and TAKE THE RESERVATION over it,
    /// before speech is attempted at all. Returns the claim the rest of the
    /// request holds.
    ///
    /// Nothing reaches the desk here. A Work voice note is its words, and the
    /// recording is a second copy kept only until they are written — so the
    /// park is what makes the clip survivable, and the entry is `.phaseOneFailed`
    /// (the ORDINARY state of a fresh Work capture: the desk holds nothing, and
    /// no clock may retire these bytes) rather than a failure report.
    ///
    /// A SAVE THAT LANDED WITHOUT A CLAIM IS NOT A PARK. An entry nobody holds
    /// is one the retry card may take and finish while this request is still
    /// transcribing, and a reply built on the belief that this request owns the
    /// capture would then be a durability claim about somebody else's work. So
    /// a refused reservation throws exactly as a refused write does, and the
    /// wrist keeps its clip and re-fires.
    ///
    /// - Throws: `workPublicationFailure` — RETRYABLE by construction, which is
    ///   what has the wrist leave its entry queued rather than delete the only
    ///   other copy of the recording.
    static func parkRelayedWorkClip(
        requestID: String,
        audio: Data,
        language: String?,
        createdAt: Date = Date(),
        lane: PendingRetryStore = .shared
    ) async throws -> PendingRetryClaim {
        let captureID = workCaptureID(forRequestID: requestID)
        do {
            try await lane.save(
                audioData: audio,
                metadata: PendingRetryMetadata(
                    id: captureID,
                    createdAt: createdAt,
                    // Bookkeeping only — the store writes and owns the App-Group
                    // copy of these bytes under its own name, and every retry
                    // surface re-materialises a temp file from THOSE. The URL
                    // this names is already deleted by the time anything reads
                    // the record.
                    audioFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("relay-work-\(captureID.uuidString).m4a"),
                    preferredLanguage: language,
                    attemptCount: 1,
                    // Nothing has failed. The entry is the ordinary shape of a
                    // Work capture waiting for its words, not a report about an
                    // error, so there is no code to carry.
                    lastErrorCode: nil,
                    destination: .work,
                    publicationState: .phaseOneFailed,
                    // The surface the words were SPOKEN at, carried on the entry
                    // because the phone is the one writing the card and filing
                    // every wrist note under whichever iPhone was nearby is the
                    // exact confusion `sourceDevice` exists to prevent.
                    sourceDevice: relaySourceDevice
                ),
                // The wrist relays a clip and nothing else.
                workImageData: nil
            )
        } catch PendingRetrySaveOutcome.recordingParkedWithoutPicture {
            // Unreachable on this lane — it parks no picture — and answered
            // rather than rethrown because the outcome says THE RECORDING IS
            // PARKED. Reading it as a failure would have the wrist keep a clip
            // this phone already holds under an entry no surface knows it owns.
        } catch {
            // Normalised HERE rather than at the call site so this function's
            // one refusal is the retryable one: an underlying file-system error
            // travelling out would be answered on whatever code the caller
            // reached for, and a terminal one has the wrist delete the clip.
            throw workPublicationFailure
        }
        guard let claim = await lane.claim(
            id: captureID,
            duration: PendingRetryStore.claimLeaseDuration
        ) else {
            throw workPublicationFailure
        }
        return claim
    }

    /// Extend the reservation for as long as this request is transcribing.
    ///
    /// The hold is granted for `PendingRetryStore.claimLeaseDuration`; a BYO
    /// custom endpoint is allowed 300 s per attempt and attempted three times,
    /// so the work can outlast it. A lapsed hold is stealable, and a second
    /// surface finishing this capture mid-transcription is two provider calls
    /// for one utterance and two writers for one card. Cancelled by the
    /// caller's `defer` on every exit, so a finished request stops extending.
    private static func renewWhileTranscribing(_ claim: PendingRetryClaim) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(leaseRenewalInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard await PendingRetryStore.shared.renew(claim) else { return }
        }
    }

    /// How often the reservation is extended while speech runs. Comfortably
    /// inside the horizon it renews, so one missed tick does not lose the hold.
    private static let leaseRenewalInterval: TimeInterval =
        PendingRetryStore.claimLeaseDuration / 3

    /// Give the parked capture back to the queue, unfinished.
    ///
    /// The entry, its recording and whatever words were parked on it stay
    /// exactly as they are; only the reservation goes, so the phone's own retry
    /// card can claim it and buy the words the wrist has stopped waiting for.
    /// It is what every failure exit owes: a capture this request holds and
    /// abandons is invisible to the count until the lease lapses, and a wrist
    /// told the phone has it would be pointed at a card that does not offer it.
    static func handBackParkedClip(
        _ claim: PendingRetryClaim,
        lane: PendingRetryStore = .shared
    ) async {
        await lane.release(claim)
    }

    /// The surface the words were SPOKEN at. The phone writes the card, but
    /// filing every wrist note under the iPhone that happened to be nearby is
    /// the exact confusion `sourceDevice` exists to prevent. Matches
    /// `SourceDevice.current` as evaluated on watchOS.
    private static let relaySourceDevice = "watch"

    private static let log = Logger(
        subsystem: Constants.identityNamespace,
        category: "WatchWorkRelay"
    )

    // MARK: - Reply

    // Both overloads build their payload through
    // `RelayReplyCache.CachedReply.payload(requestID:)` — the SINGLE
    // payload-shape site, shared with the cached-verdict re-send path, so
    // fresh and replayed replies are provably identical — and funnel
    // through `ship(payload:preferMessage:)`, the single channel-choice
    // site.

    /// `workSaved` is written only when this request WAS a work request whose
    /// clip this phone parked, because its absence is what tells a modern wrist
    /// it is talking to an iPhone that kept nothing.
    private func sendReply(requestID: String, text: String, workSaved: Bool = false, preferMessage: Bool) {
        ship(
            payload: RelayReplyCache.CachedReply(
                text: text,
                errorCode: nil,
                workSaved: workSaved ? true : nil
            ).payload(requestID: requestID),
            preferMessage: preferMessage
        )
    }

    /// Ship — and CACHE — the acknowledgement a parked capture earns when its
    /// words never arrived.
    ///
    /// The store is unconditional rather than admission-gated: this verdict is
    /// settled by construction (the clip is durably on this phone, under an
    /// entry its own retry card offers, and that cannot un-happen), and a
    /// replay that dropped it would answer a re-fire with the old error — which
    /// is the exact state that stranded the wrist's entry. A re-fire that hits
    /// the cache costs nothing: the capture is already here.
    private func shipWorkRecordingAcknowledgement(requestID: String, preferMessage: Bool) {
        let acknowledgement = Self.workRecordingAcknowledgement()
        replyCache.store(acknowledgement, forKey: requestID)
        ship(
            payload: acknowledgement.payload(requestID: requestID),
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
