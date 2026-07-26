// Conduck
// ConverseIntent.swift
//
// Capture-and-converse intent: transcribe recorded audio via `STTClient`, then
// hand the transcript to the agent converse hop as the terminal step.
//
// Two-hop terminal contract:
//   1. STT hop (foreground STTClient) — Shortcuts gives ~30 s before
//      suspension; a typical clip + Mistral round-trip fits within. The
//      `PendingRetryGuard` arm/disarm discipline covers THIS hop only.
//   2. Converse hop (background URLSession via `BackgroundRemoteAgent`) —
//      FIRE-AND-FORGET: perform() dispatches the converse and returns
//      immediately, so the Shortcut ends without waiting for the reply (which
//      can take 30 s – several minutes). The background session's relaunch
//      semantics (not the retry guard) carry the request; its delegate appends
//      the agent reply + fires the reply notification on success, or a failure
//      notification on error — all independently of this perform() process.
//
// Active conversation: resolve via the TTL-aware headless pointer
// (`SettingsManager.resolveActiveConversationID`); if stale/absent — OR the
// pointed-at `Conversation` row hasn't imported via CloudKit yet (the pointer
// syncs via KVS faster than the row) — mint a fresh `Conversation` bound to the
// configured backend. The user turn is appended BEFORE the converse hop so the
// store is the source of truth even if the reply never lands.
//
// Title / description / parameter labels carry `// xcstrings` markers.

import Foundation
import AppIntents
import AVFoundation
import UniformTypeIdentifiers
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Main capture-and-converse intent — fires from the bundled Shortcut
/// (Action Button, Lock Screen, Control Center widget). Foreground STTClient
/// call for the STT hop; `PendingRetryGuard` arms preempt-save so an OS-kill
/// mid-STT still leaves the recording recoverable. The agent converse hop
/// runs on the background URLSession.
struct ConverseIntent: AppIntent {
    static var title: LocalizedStringResource = "GigaAction"   // xcstrings

    static var description: IntentDescription = IntentDescription(
        LocalizedStringResource("Transcribe recorded audio and send it to your configured personal AI, returning the reply.")  // xcstrings
    )

    // MARK: - Parameters

    @Parameter(
        title: "Audio File",                                          // xcstrings
        supportedContentTypes: [.audio],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var audioFile: IntentFile

    /// OPTIONAL screenshot captured by the Shortcut's "Take Screenshot" action
    /// and wired into this slot. When present it rides the EXISTING inline-vision
    /// path alongside the voice transcript (same data-URI shape the composer
    /// uses). `.never` is deliberate — unlike `audioFile` (which auto-grabs the
    /// previous intent's result), the screenshot must NOT try to connect to the
    /// previous result; it is supplied explicitly by the shortcut graph. Optional
    /// `IntentFile?` is migration-safe (additive — existing voice-only shortcuts
    /// keep working, the field simply stays empty). We NEVER call `requestValue`,
    /// so an absent screenshot never foregrounds the app (headless path intact).
    @Parameter(
        title: "Screenshot",                                          // xcstrings
        supportedContentTypes: [.image],
        inputConnectionBehavior: .never
    )
    var screenshotFile: IntentFile?

    // MARK: - Parameter Summary

    /// REQUIRED so the screenshot field appears as a wireable slot in the
    /// Shortcuts editor (the intent had no summary before; without one the
    /// optional parameter is not surfaced for wiring).
    static var parameterSummary: some ParameterSummary {
        Summary("Converse using \(\.$audioFile) and \(\.$screenshotFile)")    // xcstrings
    }

    // MARK: - Perform

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Notification auth (plan D4 — headless converse dispatch). This is THE
        // path notifications exist for: a fire-and-forget Action-Button/Shortcut
        // ask whose reply/failure has no other feedback channel. The in-app +
        // setup-guide + share triggers don't cover a user whose FIRST action is
        // a headless capture (e.g. a shortcut synced from another device, or the
        // Action Button bound without finishing the in-app Setup Guide), so
        // request here too. Idempotent + non-blocking (no-op once determined).
        await NotificationPermissions.ensureRequested()

        // ATOMIC snapshot: (presetID, apiKey, provider) in
        // one actor hop so a concurrent preset switch can't produce a
        // key/provider mismatch. Reused for the entire perform() lifetime.
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        let preferredLanguage = await SettingsManager.shared.getPreferredLanguage()

        // Fail fast if the user hasn't pasted a key yet. Surfacing the
        // typed error in Shortcuts is more useful than a 401 from the
        // upstream provider. In-process providers (Apple on-device)
        // need no key — the runner's TCC check substitutes. The BYO
        // custom endpoint with `.none` auth (keyless local server) also needs
        // no key.
        let apiKey: String
        if snapshot.provider.transport == .inProcess || snapshot.customConfig?.auth == STTAuthScheme.none {
            apiKey = ""
        } else if let key = snapshot.apiKey, !key.isEmpty {
            apiKey = key
        } else {
            throw AppError.sttMissingAPIKey
        }

        // Extract audio data from the Shortcut-provided IntentFile.
        let originalAudioData = audioFile.data

        guard !originalAudioData.isEmpty else {
            throw AppError.audioMissingData
        }

        guard originalAudioData.count <= Constants.maxAudioSize else {
            throw AppError.audioTooLarge
        }

        // Measure audio duration for diagnostic logging only — not load-bearing.
        var audioDurationSeconds: Int? = nil
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".m4a")
            try originalAudioData.write(to: tempURL)
            // Audio cleanup on EVERY exit from this block — `load(.duration)`
            // can throw, and a post-call removeItem would skip on that path,
            // stranding a full copy of the recording in tmp.
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let asset = AVURLAsset(url: tempURL)
            let duration = try await asset.load(.duration)
            // `CMTimeGetSeconds` returns NaN/±inf for an invalid or indefinite
            // duration, and `Int(NaN)` is an uncatchable runtime trap — the
            // Shortcut's audio parameter is user-wirable, so guard like
            // `STTClient` does (value is diagnostic-only; nil is fine).
            let seconds = CMTimeGetSeconds(duration)
            audioDurationSeconds = seconds.isFinite ? Int(seconds) : nil
        } catch {
            // Non-critical — duration is diagnostic-only.
        }

        #if DEBUG
        print("[Conduck] ConverseIntent")
        print("[Conduck] Audio: \(originalAudioData.count) bytes, Duration: \(audioDurationSeconds ?? -1)s, Language: \(preferredLanguage ?? "auto")")
        #endif

        // Write audio to disk for STTClient (which takes a file URL +
        // `defer`-deletes on exit per the audio-cleanup mandate).
        let audioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-stt-\(UUID().uuidString).m4a")
        do {
            try originalAudioData.write(to: audioFileURL)
        } catch {
            throw AppError.audioMissingData
        }

        // Preempt-save audio + schedule a deferred "Recording saved"
        // notification BEFORE the network call. If perform() throws a typed
        // error we disarm (or leave armed) per the catch chain below; if the
        // OS kills the intent process mid-flight, both the saved audio and
        // the queued notification persist via App Groups +
        // UNUserNotificationCenter so the user gets a path back into the
        // app to retry.
        let pendingMetadata = PendingRetryMetadata(
            id: UUID(),
            createdAt: Date(),
            audioFileURL: audioFileURL,
            preferredLanguage: preferredLanguage,
            attemptCount: 1,
            lastErrorCode: nil
        )
        let guardToken = await PendingRetryGuard.arm(
            audio: originalAudioData,
            metadata: pendingMetadata
        )

        do {
            // Foreground multipart upload. STTClient owns the retry loop
            // (per-error budget) + audio-file `defer` cleanup. We hand it
            // the URL; on success or non-retryable throw, the file is gone.
            // Provider taken from the snapshot resolved at perform() entry —
            // keeps (key, provider) atomic.
            let response = try await STTClient.shared.transcribe(
                audioFileURL: audioFileURL,
                apiKey: apiKey,
                language: preferredLanguage,
                provider: snapshot.provider,
                customModel: snapshot.customModel,
                customConfig: snapshot.customConfig
            )

            #if DEBUG
            // Count-only — never log the transcript text itself.
            RemoteAgentDiagnostics.log.debug("ConverseIntent transcribe ok chars=\(response.text.count, privacy: .public)")
            #endif

            // Guard against empty text from upstream (defense-in-depth).
            let transcript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                // Empty/whitespace-only text = the recording held no transcribable
                // speech (user didn't speak / silence). Surface the accurate
                // "no speech" message, NOT the catch-all `.apiFailure` (which
                // renders the misleading "Something glitched on our end" banner —
                // implies a server fault for what is just silence). Both are
                // `shouldPreserveForRetry == false`, so the catch chain below still
                // disarms the guard identically; only the surfaced string changes.
                throw AppError.noSpeechDetected
            }

            // STT hop succeeded — disarm the retry guard (cancels notification
            // + clears store). The converse hop below relies on the background
            // URLSession's relaunch semantics, NOT the retry guard.
            await PendingRetryGuard.disarm(guardToken)

            // Completion chime / haptic for the STT hop landing.
            CompletionFeedbackPlayer.play(mode: "sound")

            // --- Optional screenshot: process AFTER the retry guard is disarmed ---
            // Kept entirely outside the audio retry machinery (the guard above
            // covers the STT hop only). Best-effort, mirroring the composer's
            // `try?` semantics: an image-processing failure NEVER fails the whole
            // ask — it degrades to text-only. `screenshotDataURIs` rides the
            // EXISTING inline-vision wire path; `screenshotDraft` persists the
            // screenshot in history so it renders as a thumbnail bubble and
            // survives. Voice-only captures (no screenshot wired) leave both at
            // their empty defaults → the converse hop is byte-identical to today.
            var screenshotDataURIs: [String] = []
            var screenshotDraft: AttachmentDraft? = nil
            if let bytes = screenshotFile?.data, !bytes.isEmpty,
               let processed = try? await ImageProcessor.shared.process(bytes) {
                screenshotDataURIs = [DataURIBuilder.jpegDataURI(from: processed.jpegData)]
                screenshotDraft = AttachmentDraft(
                    mimeType: "image/jpeg",
                    data: processed.jpegData,
                    thumbnailData: processed.thumbnailData,
                    width: processed.width,
                    height: processed.height,
                    byteSize: processed.byteSize,
                    sequence: 0
                )
            }

            // --- Terminal step: agent converse hop ---
            // FIRE-AND-FORGET: dispatch the converse over the background session
            // and return immediately, so the Shortcut ends right after the send
            // instead of spinning until the (possibly minutes-long) reply. The
            // background delegate appends the reply + fires the completion
            // notification on success, or a failure notification on error — so
            // delivery is unaffected; only the wait is removed.
            try await Self.runConverseHop(
                userText: transcript,
                imageDataURIs: screenshotDataURIs,
                screenshotDraft: screenshotDraft
            )
            // Return the transcript (what was captured) as the intent result —
            // unused by the bundled Shortcut today, but meaningful if a
            // "Show Result" tail is ever added; the agent reply itself arrives as
            // a notification, not here.
            return .result(value: transcript)

        } catch let error as AppError where error.shouldPreserveForRetry {
            // Transient transport / upstream outages where the same audio is
            // likely to succeed on retry. Audio + notification are already
            // armed — leave them in place so the user sees the in-app retry
            // card AND receives a notification at the deferred deadline.
            throw error

        } catch let error as AppError {
            // Known-bad-input errors (audio_too_large, audioInvalid,
            // sttAuthFailed, sttMissingAPIKey, sttQuotaExceeded, etc.) —
            // same audio won't recover by retrying, so disarm.
            await PendingRetryGuard.disarm(guardToken)
            throw error

        } catch {
            // Unknown thrown type. Wrap as AppError.unknown but leave the
            // guard armed (defensive — we don't know if a retry would help,
            // so let the user decide via the in-app retry card).
            throw AppError.unknown(error)
        }
    }

    // MARK: - Terminal step — agent converse hop

    /// Resolve (or mint) the active conversation, append the user turn, load the
    /// conversation's prior turns, and FIRE-AND-FORGET the converse hop over the
    /// background session — returning as soon as the request is dispatched (the
    /// Shortcut ends without waiting for the reply). The background delegate
    /// appends the agent reply + bumps the active-conversation pointer + posts
    /// the reply notification on success, or a failure notification on error,
    /// AFTER this returns.
    ///
    /// `RemoteAgent` not configured → throws `.remoteAgentNotConfigured`
    /// (surfaced as the friendly error in Shortcuts; no crash). Such pre-dispatch
    /// errors still surface in the Shortcut; only the reply WAIT is removed.
    ///
    /// `imageDataURIs` (default `[]`) rides the EXISTING inline-vision path into
    /// `BackgroundRemoteAgent.send(newUserImageDataURIs:)`. `screenshotDraft`
    /// (default `nil`) is persisted on the appended user turn so the screenshot
    /// renders as a thumbnail bubble in history. BOTH defaulted → the Voice-Only
    /// path stays BYTE-IDENTICAL to today (empty array, no attachment).
    private static func runConverseHop(
        userText: String,
        imageDataURIs: [String] = [],
        screenshotDraft: AttachmentDraft? = nil
    ) async throws {
        // REORDER (per-conversation routing): resolve-or-mint the conversation
        // FIRST, then route by ITS bound backend (not the global default). An
        // existing thread keeps talking to the gateway it was created with; a
        // fresh thread is minted on the default backend. The exact resolve-or-mint
        // branch (pointer → existing-row-route, else validate-default-then-mint)
        // is the SHARED helper both this intent and the Share-Extension drainer
        // call, so the routing rule can never drift between them.
        let routed = try await SharedInboxRouting.resolveOrMint()
        let conversationID = routed.conversationID
        let snapshot = routed.snapshot
        let token = routed.token
        // Capture the READY file lane once for this entire turn. History
        // references, the per-turn file instruction, and reply output scanning
        // must all describe the same physical lane; the background sender
        // revalidates this immutable snapshot immediately before enqueue.
        let dispatchFileLane = await SettingsManager.shared
            .fileTransferReadySnapshot(for: routed.ref)

        // Append the user turn FIRST so the store is authoritative even if the
        // reply never lands. `sourceDevice` is the local device. When a
        // screenshot was wired + processed, persist it as an attachment on this
        // turn so it renders as a thumbnail bubble and survives in history; an
        // empty array (Voice-Only) keeps the store append on its existing
        // text-only fast path (byte-identical to today).
        //
        // `status: "sending"` (was nil): the background delegate is the
        // authoritative flipper (`recordReply` → `sent`, `postTurnFailed` →
        // `failed` via the exact-message pending-turn flip, which only
        // matches `sending` — the id is threaded through `send` below).
        // A nil-status headless turn could therefore NEVER be marked failed —
        // a converse failure left no Retry chip and (when the user was viewing
        // the thread, where the banner is suppressed) no signal at all.
        // Render-compatible: `sending` shows the small spinner until the
        // delegate resolves it; nil renders as sent.
        let attachments = screenshotDraft.map { [$0] } ?? []
        let userTurn = try await ConversationStore.shared.appendMessage(
            role: "user",
            text: userText,
            conversationID: conversationID,
            sourceDevice: SourceDevice.current,
            status: "sending",
            attachments: attachments
        )

        // Stamp the active-conversation pointer NOW — before the (possibly
        // minutes-long) converse hop — so a process kill mid-converse still
        // leaves this freshly-minted conversation recorded as active. Without
        // this, a kill before `recordReply` runs would orphan the conversation
        // and the next headless capture would mint yet another one instead of
        // continuing. `recordReply` re-stamps on success — idempotent.
        // This pre-dispatch stamp is ALLOWED under the implicit-only pointer
        // rule: the intent IS the headless quick-capture lane the per-device
        // pointer exists for (explicit surfaces never stamp).
        await SettingsManager.shared.recordActiveConversation(conversationID)

        // Assemble the conversation's prior turns (EXCLUDING the just-appended
        // user turn) for the request context via the shared assembler — which
        // also resolves prior-turn image bytes (this headless surface was
        // image-blind before) + the bound ref's image-history policy.
        // `RemoteAgentClient.assembleMessages` appends the new user turn +
        // applies the trim policy. Throwing posture unchanged (a store failure
        // here propagates exactly like the previous `fetchMessages` throw).
        let priorTurns = try await ConversationHistoryAssembler.assemble(
            conversationID: conversationID,
            excludingUserMessageID: userTurn.id,
            excludingNewUserText: userText,
            boundRef: routed.ref,
            dispatchFileLaneID: dispatchFileLane?.durableLaneID
        )

        // Converse over the background session. FIRE-AND-FORGET: dispatch over
        // the background session and return. The delegate records the reply +
        // fires the completion/failure notification independently of this
        // process, so the Shortcut need not wait — and the delegate is also the
        // authoritative status flipper for the `sending` turn appended above.
        //
        // PRE-DISPATCH failures (body/metadata encode, file write) throw BEFORE
        // any background task exists — no delegate will ever resolve the turn,
        // so flip it to `failed` here (Retry chip) before rethrowing to
        // Shortcuts.
        do {
            try await BackgroundRemoteAgent.shared.send(
                backend: snapshot.backend,
                ref: snapshot.ref,
                url: snapshot.url,
                token: token,
                authScheme: snapshot.authScheme,
                model: snapshot.model,
                priorTurns: priorTurns,
                newUserText: userText,
                newUserImageDataURIs: imageDataURIs,
                inputFileTransferSnapshot: dispatchFileLane,
                fileTransferSnapshot: dispatchFileLane,
                conversationID: conversationID,
                // EXACT per-message status flips in the delegate (a
                // conversation-wide flip would alias a concurrent in-app
                // sibling turn's status).
                userMessageID: userTurn.id,
                // Headless implicit lane: the delegate's success path stamps
                // the per-device quick-capture pointer for this turn.
                stampsActiveConversation: true,
                awaitReply: false
            )
        } catch {
            // Exact flip — only THIS turn failed to dispatch; a concurrent
            // sibling in the same conversation must keep its own lifecycle.
            // Pre-dispatch throw (fire-and-forget enqueue) → no gateway verdict:
            // persist the taxonomy code so the inline row explains the failure,
            // wire code / history fact structurally absent.
            await ConversationStore.shared.failTurn(
                messageID: userTurn.id,
                classification: .init(
                    failureCode: (error.unwrappedAppError ?? .remoteAgentUnreachable).errorCode,
                    wireCode: nil,
                    hadHistoryImages: nil
                )
            )
            // This is a fire-and-forget headless turn — the Shortcut has ended,
            // so the throw below alone wouldn't reach the user. Raise the
            // macOS menu-bar red dot (`.remoteAgentTurnDidFail`) AND post the
            // failure notification (iOS surfacing + deep-link to the thread to
            // retry), mirroring the background delegate's post-dispatch failure
            // path (`BackgroundRemoteAgent.postTurnFailed`). Still rethrow so
            // Shortcuts records the error too.
            await BackgroundRemoteAgent.postTurnFailed(conversationID: conversationID)
            await BackgroundRemoteAgent.postFailureNotification(conversationID: conversationID, error: error.unwrappedAppError)
            throw error
        }
    }
}
