// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConverseIntent.swift
//
// Capture-and-converse intent: transcribe recorded audio via `STTClient`, then
// hand the transcript to the agent converse hop as the terminal step.
//
// Two-hop terminal contract:
//   1. STT hop (foreground STTClient) — Shortcuts gives ~30 s before
//      suspension; a typical clip + Mistral round-trip fits within.
//      `PendingRetryGuard` covers this hop AND the destination resolve that
//      follows it, disarming at exactly one place: the moment the user turn
//      lands in `ConversationStore`. See the RETRY-GUARD SPAN note below.
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
// PRE-FLIGHT, and its honest limit. This intent receives
// `audioFile: IntentFile` — the recording has ALREADY happened, inside the
// system Record Audio action — so a check here can only fail FASTER, never
// before the microphone. It exists for users who hand-built their own shortcut
// and never included `CheckNetworkIntent`. The lanes where the check genuinely
// lands before the mic are `CheckNetworkIntent` (first action of the bundled
// shortcut), CarPlay, the menu bar and the Watch.
//
// Two things are checked, both of them AFTER `PendingRetryGuard.arm` and
// OUTSIDE the `do`, so each verdict is reached with the recording ALREADY
// preserved and decides its fate itself, rather than inheriting the catch
// chain's one answer for everything pre-transcript (I6):
//
//   THE SPEECH-TO-TEXT KEY, through `STTKeyReadiness`, which keeps the two
//   readings of a nil key apart. `.notConfigured` is provable absence and
//   raises code 23; `.unreadable` is a Keychain that could not answer — the
//   before-first-unlock case this whole lane runs in — and raises code 75,
//   whose copy says the key could not be READ rather than claiming there
//   isn't one (I3). Neither reading spends an STT call. They part company on
//   the recording, each matching its own `shouldPreserveForRetry`: 75 leaves
//   the guard armed, because an unlock makes those exact bytes succeed; 23
//   disarms, because they cannot succeed until a key is entered and
//   `PendingRetryStore`'s single slot would otherwise be held against a
//   capture that can.
//
//   THE DESTINATION, asked in the SAME ORDER `SharedInboxRouting.resolveOrMint`
//   asks it — live quick-capture pointer first, this device's "Default for new
//   chats" only when there is no live pointer — through the same helper
//   `CheckNetworkIntent` uses. That order is load-bearing here rather than
//   merely tidy: this check runs AFTER the microphone, so a refusal it invents
//   that the pre-flight already waved through costs the user words they have
//   spoken.
//
// RETRY-GUARD SPAN, and why it is not the STT hop. Ordering the two checks
// identically closes a RULE gap; it cannot close a TIME gap. A quick-capture
// pointer that is TTL-fresh at the pre-flight can cross its
// `SessionContinuationPolicy` window while the user is still speaking, so the
// post-mic resolve reaches the default's verdict after the pre-flight waved the
// capture through — and refuses. I6 says a refusal that arrives after the user
// has spoken must leave the audio in the retry lane, so the guard is armed
// before the FIRST thing that can refuse — the key check — and stays armed
// across the destination resolve and the STT hop, disarming at the one point
// the spoken words stop depending on it: `runConverseHop`'s `appendMessage`,
// where the transcript becomes a durable row. Everything that can fail after
// that append (assembly, dispatch) is wrapped by the hop's own catch, which
// marks the turn failed and posts the failure notification — so the thread
// carries a Retry chip and keeping the recording too would only duplicate it.
//
// Title / description / parameter labels carry `// xcstrings` markers.

import Foundation
import AppIntents
import UniformTypeIdentifiers
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Main capture-and-converse intent — fires from the bundled Shortcut
/// (Action Button, Lock Screen, Control Center widget). Foreground STTClient
/// call for the STT hop; `PendingRetryGuard` arms preempt-save so an OS-kill —
/// or a destination that goes away mid-recording — still leaves the recording
/// recoverable. The agent converse hop runs on the background URLSession.
struct ConverseIntent: AppIntent {
    static var title: LocalizedStringResource = "GigaAction"   // xcstrings

    static var description: IntentDescription = IntentDescription(
        LocalizedStringResource(
            "intent.converse.description",
            defaultValue: "Transcribe recorded audio and send it to your configured AI, returning the reply."
        )
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

        // Extract audio data from the Shortcut-provided IntentFile.
        let originalAudioData = audioFile.data

        guard !originalAudioData.isEmpty else {
            throw AppError.audioMissingData
        }

        guard originalAudioData.count <= Constants.maxAudioSize else {
            throw AppError.audioTooLarge
        }

        // Byte count + language only — deliberately no clip DURATION. Measuring
        // it needs an `AVURLAsset`, which needs a file URL, which means writing a
        // second plaintext copy of the user's recording into `temporaryDirectory`
        // in Release builds to feed a DEBUG-only log line. Conduck never persists
        // audio where it controls the storage (`spec.md` Architectural
        // Invariants), so the ONE audio write this intent makes is the
        // `STTClient` handoff below, which that client `defer`-deletes. It also
        // keeps an unbounded `await asset.load(.duration)` off user-wirable
        // Shortcut input.
        #if DEBUG
        print("[Conduck] ConverseIntent")
        print("[Conduck] Audio: \(originalAudioData.count) bytes, Language: \(preferredLanguage ?? "auto")")
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

        // Pre-flight the KEY, on the same terms and for the same reason as the
        // destination below: AFTER `arm` and OUTSIDE the `do`, so each verdict is
        // reached with the recording already preserved and neither is swept along
        // by the catch chain's blanket pre-transcript disarm (I6). What each arm
        // then does with the preserved bytes is its own decision, taken here. It
        // sits above the destination check only because it is the cheaper
        // question.
        //
        // The two verdicts are NOT the same fact, and separating them is the
        // whole point of doing this through `STTKeyReadiness` rather than
        // `snapshot.apiKey == nil`. Keys are stored
        // `kSecAttrAccessibleAfterFirstUnlock`: on a rebooted, not-yet-unlocked
        // iPhone — precisely the Action-Button-from-the-lock-screen case — a key
        // that is present and correct reads back as nothing. Code 23 asserts the
        // slot is empty and sends the user to a settings screen where they will
        // find their key already sitting there; code 75 says only what is true,
        // that the key could not be read, and names the unlock that fixes it.
        // `.notConfigured` is the only reading that PROVES absence, so it is the
        // only one that earns 23 — and it is also the reading `CheckNetworkIntent`
        // refuses before the microphone, which is why a capture that gets this far
        // with no key at all is one the user built their own shortcut for.
        let keyReadiness = await STTKeyReadiness.resolve(
            presetID: snapshot.presetID,
            snapshotKey: snapshot.apiKey,
            provider: snapshot.provider,
            customConfig: snapshot.customConfig
        )
        let apiKey: String
        switch keyReadiness {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            // PROVABLE absence — the one verdict on this lane that spends the
            // guard rather than leaving it armed, matching
            // `sttMissingAPIKey.shouldPreserveForRetry == false`. The same bytes
            // fail identically until a key is entered, and `PendingRetryStore`
            // is a SINGLE overwriting slot: holding it with a capture that
            // cannot succeed evicts one that can. The concrete loss — a capture
            // that failed on preset A with a network error is preserved, the
            // user switches to keyless preset B and presses the Action Button,
            // and A's recoverable words are overwritten by these. Disarming also
            // withdraws the +90 s "Recording Saved" notification, which would
            // otherwise invite a retry into an empty lane.
            //
            // So the temp file goes too: after the disarm nothing holds a copy,
            // and that is the intended outcome for this reading — not an
            // oversight. The blackout arm below is the opposite case and stays
            // armed.
            await PendingRetryGuard.disarm(guardToken)
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttMissingAPIKey
        case .unreadable:
            // The guard stays ARMED, so this throw leaves the words in the retry
            // lane and an unlock reaches them. Dropping the temp file is safe on
            // that footing: `PendingRetryGuard.arm` has already written the App
            // Group copy the in-app retry re-materialises from — and where that
            // write failed, keeping a temp file nothing knows about would not
            // help either.
            if !guardToken.audioPreserved {
                // The one place the promise and the reality can part: a refusal
                // the user can act on, with nothing left to come back to. The
                // line carries the FACT only — no key, no transcript (I5) — and
                // ships in Release, because a save that fails before first
                // unlock is precisely what a DEBUG-only print never shows.
                RemoteAgentDiagnostics.log.error("ConverseIntent: STT key blackout refused with no preserved capture")
            }
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttKeyUnreadable
        }

        // Pre-flight the DESTINATION before spending an STT call. Placed AFTER
        // `arm` and OUTSIDE the `do` on purpose: Shortcuts already recorded the
        // audio, so the only thing left to save is the recording, and throwing
        // from here reaches no disarm at all — the user gets the in-app Retry
        // card plus the deferred "Recording Saved" notification, and the STT
        // provider is never charged for a turn that had nowhere to land. (The
        // mid-flight twin — a pointer that ages out of its continuation window,
        // or a peer forgetting the default, DURING the recording — throws 74 out
        // of `runConverseHop` instead. The guard is still armed there, because
        // it disarms only inside `runConverseHop` once the user turn is stored,
        // so that refusal reaches the same outcome.)
        let preflight = await SettingsManager.shared.newChatPickerSnapshot()
        // The pointer arm, asked FIRST and through the router's own helper — the
        // same question `CheckNetworkIntent` asks before the microphone, so a
        // capture that lane waves through can never be refused by this one after
        // the words are already spoken. `resolveOrMint` reaches the default only
        // when no live pointer answers, so a capture that continues a
        // conversation on a gateway set up here is not minting anything and no
        // verdict about the default may refuse it. A conversation bound to a
        // gateway that is NOT set up here answers false and earns the refusal
        // below, unchanged (I1).
        let continuesLiveConversation = await SharedInboxRouting.liveQuickCaptureCanContinue(
            defaultRef: preflight.defaultRef
        )
        if !continuesLiveConversation {
            switch preflight.resolution {
            case .brokenDefault(let broken, _, let pointerIsParked):
                // Dropping the temp file is safe: `PendingRetryStore.save(audioData:
                // metadata:)` already wrote its own App Group copy, and the in-app
                // retry path re-writes a fresh temp file from those bytes.
                try? FileManager.default.removeItem(at: audioFileURL)
                // A pointer the APP parked after a Forget is not "your default
                // AI": the user never chose it, and may never have set it up, so
                // it takes the unnamed sentence rather than being blamed by name.
                let error: AppError
                if pointerIsParked {
                    error = .remoteAgentDefaultNeedsSetup(gatewayName: nil)
                } else {
                    error = .remoteAgentDefaultNeedsSetup(
                        gatewayName: RemoteAgentRefMetadata.displayName(for: broken, customs: preflight.badgeRoster))
                }
                // The Shortcut may have no visible UI (Action Button), so the push
                // is the user's only tappable route to the fix. Its identifier is
                // fixed, so repeated captures replace rather than stack.
                await BackgroundRemoteAgent.postDefaultNeedsSetupNotification(error: error)
                throw error
            case .selectionRequired:
                try? FileManager.default.removeItem(at: audioFileURL)
                let error = AppError.remoteAgentDefaultNeedsSetup(gatewayName: nil)
                await BackgroundRemoteAgent.postDefaultNeedsSetupNotification(error: error)
                throw error
            case .usable, .adopted, .bootstrapped, .nothingConfigured, .setupUnfinished, .readingUnreliable:
                // The three not-configured verdicts deliberately fall through to the
                // send path, which throws code 12 with its existing, accurate copy.
                // Refusing `.readingUnreliable` here would accuse a default that may
                // be perfectly healthy behind a locked Keychain.
                break
            }
        }

        // True from the moment the spoken words exist as text. Until the user
        // turn is stored, the preserved recording is the ONLY copy of what the
        // user said, so the catch chain below may not clear the retry lane on
        // any failure past this point (I6). Before it, a verdict about the BYTES
        // — silence, audio the provider can't process, a key the provider
        // REJECTS — still disarms, because the same bytes cannot succeed on a
        // second attempt. The two verdicts about the key SLOT never reach this
        // chain: both are refused above, outside the `do`, because they
        // DISAGREE about the recording and this chain has only one answer for
        // anything pre-transcript. Each takes its own above instead — 23
        // disarms there, 75 stays armed.
        var transcriptCaptured = false

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
                // `shouldPreserveForRetry == false` AND both land while
                // `transcriptCaptured` is still false, so the catch chain below
                // disarms on either; only the surfaced string changes.
                throw AppError.noSpeechDetected
            }

            // The words now exist as text, and nothing from here on may throw
            // them away. The guard stays armed until `runConverseHop` stores the
            // user turn.
            transcriptCaptured = true

            // Completion chime / haptic for the STT hop landing.
            CompletionFeedbackPlayer.play(mode: "sound")

            // --- Optional screenshot ---
            // Kept entirely outside the audio retry machinery. Best-effort,
            // mirroring the composer's
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
                screenshotDraft: screenshotDraft,
                retryGuardToken: guardToken
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
            // sttAuthFailed, sttQuotaExceeded, etc.) — same audio won't recover
            // by retrying, so disarm.
            //
            // `transcriptCaptured` is what keeps that rule from reaching past
            // the microphone. Every code that lands here once the words ARE
            // transcribed is a destination verdict, not a verdict about the
            // bytes — `.remoteAgentNotConfigured` when nothing is set up here,
            // a store failure before the append — and the same recording DOES
            // succeed once the user has fixed what the verdict names. Disarming
            // there would delete the only copy of what they said (I6).
            if !transcriptCaptured {
                await PendingRetryGuard.disarm(guardToken)
            }
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
    /// THROWING CONTRACT for the destination. `SharedInboxRouting.resolveOrMint()`
    /// raises `.remoteAgentDefaultNeedsSetup` on the MINT path when this device's
    /// default cannot take a new chat and the roster offers alternatives, or when
    /// no default has been chosen at all; it raises `.remoteAgentNotConfigured`
    /// when nothing is set up, when the reading cannot be trusted, and whenever a
    /// conversation is BOUND to a gateway that is not set up here. Either way the
    /// error surfaces as a friendly Shortcuts error; no crash.
    ///
    /// The mid-flight answer, explicitly: if the quick-capture pointer ages out
    /// of its continuation window — or a peer forgets the default — DURING the
    /// recording, `perform()`'s pre-flight has already passed and this resolve
    /// throws instead. No conversation is minted, no user turn is appended,
    /// nothing is rebound, and no fallback gateway is chosen. The audio survives
    /// because `retryGuardToken` is still armed at that point: the disarm sits
    /// below the append, not above this resolve (I6).
    ///
    /// `retryGuardToken` is the OWNER of that decision, which is why it is
    /// required rather than optional. It disarms in exactly one place — once
    /// `appendMessage` has stored the user turn — because that is the moment the
    /// transcript stops depending on the recording. A failure after it leaves a
    /// turn in the thread carrying its own Retry chip, so a preserved recording
    /// on top would duplicate the ask on the next tap.
    ///
    /// `imageDataURIs` (default `[]`) rides the EXISTING inline-vision path into
    /// `BackgroundRemoteAgent.send(newUserImageDataURIs:)`. `screenshotDraft`
    /// (default `nil`) is persisted on the appended user turn so the screenshot
    /// renders as a thumbnail bubble in history. BOTH defaulted → the Voice-Only
    /// path stays BYTE-IDENTICAL to today (empty array, no attachment).
    private static func runConverseHop(
        userText: String,
        imageDataURIs: [String] = [],
        screenshotDraft: AttachmentDraft? = nil,
        retryGuardToken: PendingRetryGuard.Token
    ) async throws {
        // REORDER (per-conversation routing): resolve-or-mint the conversation
        // FIRST, then route by ITS bound backend (not the global default). An
        // existing thread keeps talking to the gateway it was created with; a
        // fresh thread is minted on the default backend. The exact resolve-or-mint
        // branch (pointer → existing-row-route, else validate-default-then-mint)
        // is the SHARED helper both this intent and the Share-Extension drainer
        // call, so the routing rule can never drift between them.
        let routed: SharedInboxRouting.Resolved
        do {
            routed = try await SharedInboxRouting.resolveOrMint()
        } catch let error as AppError {
            // A default that broke between the pre-flight and here. There is no
            // conversation to notify against, so the fix-route push carries it —
            // same fixed identifier as the pre-flight's, so the two can never
            // stack. Every other error rethrows untouched.
            if case .remoteAgentDefaultNeedsSetup = error {
                await BackgroundRemoteAgent.postDefaultNeedsSetupNotification(error: error)
            }
            throw error
        }
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

        // THE DISARM. The spoken words are now a durable row, so the preserved
        // recording has nothing left to protect: cancel the deferred "Recording
        // Saved" notification and clear the store. Everything above this line —
        // the destination resolve and its refusals included — leaves the guard
        // armed, which is what makes I6 true for a capture refused after the
        // user has already spoken.
        //
        // What makes the trade below sound is not the append alone but the
        // `do`/`catch` further down: EVERY remaining step that can throw is
        // inside it, and its catch flips the turn to `failed` (Retry chip) and
        // posts the failure notification. Nothing between here and there
        // throws. Move a throwing statement out of that `do` and this disarm
        // becomes a silent 30-minute `sending` spinner — the recording deleted,
        // no chip, no notification, and nothing but the launch-time
        // `sweepStaleSendingUserTurns` to end it.
        await PendingRetryGuard.disarm(retryGuardToken)

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

        // Assemble the history, then converse over the background session.
        // FIRE-AND-FORGET: dispatch over the background session and return. The
        // delegate records the reply + fires the completion/failure notification
        // independently of this process, so the Shortcut need not wait — and the
        // delegate is also the authoritative status flipper for the `sending`
        // turn appended above.
        //
        // BOTH steps sit inside this `do` because the delegate that resolves a
        // `sending` turn only exists once a background task does. Everything
        // before that dispatch — the assembler's Core Data reads, the body /
        // metadata encode, the file write — throws with no task in flight and no
        // delegate that will ever come back to the turn, so the catch below is
        // the ONLY thing that can fail it. Assembly is a real instance of that,
        // not a theoretical one: `ConversationHistoryAssembler.assemble` fetches
        // the thread's prior turns, and a fault it cannot resolve (an unmigrated
        // relationship, a protected-data read on a locked device) leaves the user
        // turn spinning `sending` on every device until the launch-time
        // `sweepStaleSendingUserTurns` notices it — up to
        // `ConversationActivityResolver.staleSendingGrace` later, with no Retry
        // chip and no notification in between.
        //
        // The assembler also resolves prior-turn image bytes + the bound ref's
        // image-history policy; `RemoteAgentClient.assembleMessages` then appends
        // the new user turn and applies the trim policy.
        do {
            let priorTurns = try await ConversationHistoryAssembler.assemble(
                conversationID: conversationID,
                excludingUserMessageID: userTurn.id,
                excludingNewUserText: userText,
                boundRef: routed.ref,
                dispatchFileLaneID: dispatchFileLane?.durableLaneID
            )
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
            // Pre-dispatch throw (assembly, or the fire-and-forget enqueue) → no
            // gateway verdict: persist the taxonomy code so the inline row
            // explains the failure, wire code / history fact structurally
            // absent. An untyped throw — which a Core Data fault out of the
            // assembler is — has no taxonomy code of its own and takes
            // `.remoteAgentUnreachable`'s, so the row reads as a delivery
            // failure rather than a store one. That is imprecise and it is the
            // right trade: the code chosen has to be one whose `isRetryable`
            // draws the Retry chip, because the recording is already gone and
            // the chip is the user's only way back to the words they typed or
            // spoke.
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
