// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// DictationService.swift
//
// macOS menu-bar capture pipeline: record → STT (Mistral Voxtral) →
// HAND THE TRANSCRIPT TO THE COORDINATOR.
//
// Terminal step (`docs/ai-context/spec.md`): the STT-success step
// does NOT copy to clipboard, enter `.done`, or auto-dismiss.
// Instead it invokes `onTranscript: (String) -> Void` (set by
// `MenuBarCoordinator`) which forwards the transcript to the active
// `ConversationDetailViewModel.sendUserTurn(_:)` (the agent round-trip). The
// service returns to `.idle` once the transcript is handed off; the
// conversation thread + in-flight UX live on the VM, not here. This service
// owns ONLY the audio→STT hop (plus its `PendingRetryStore` cover).
//
// Pipeline:
//   1. `toggleRecording()` flips state idle → recording (or stops if recording).
//   2. `stopAndProcess()` writes audio to a temp file URL, transitions to .processing.
//   3. `processAudio()` reads API key + preferred language from SettingsManager,
//      calls `STTClient.shared.transcribe(audioFileURL:apiKey:language:)`.
//   4. Success: hand the transcript to `onTranscript`, state → .idle.
//   5. Transient failure (sttServerError/sttProviderUnreachable/persistentNetworkFailure):
//      save audio + metadata to PendingRetryStore, state → .error(isRetryable: true).
//   6. Non-retryable failure (sttAuthFailed/sttQuotaExceeded/audioInvalid/…):
//      state → .error(isRetryable: false).
//
// Pre-recording PendingRetryGuard is intentionally NOT used (per locked
// decision): macOS runs in-process on the main actor; no OS-kill risk between
// startRecording and stopAndProcess. Audio is preserved reactively on STT
// error only.
//
// RETRY IS QUEUE-SHAPED, and that is why `retryLast` does not return to `.idle`
// when it finishes one. `PendingRetryStore` holds every waiting capture, this
// window and the main window's card both reach it, and `.error` is the only
// state this popover draws a Retry control in. So a finish that leaves other
// captures waiting settles into `.error` again, saying how many are left —
// returning to `.idle` there is how the second recording became unreachable
// until the next capture failed. Each attempt RESERVES the capture it takes
// (`claimNext`) and hands the reservation back on every outcome that leaves it
// waiting, so two surfaces cannot transcribe and finish the same recording.
// The reservation is EXTENDED while the provider is working and CHECKED before
// anything irreversible: the transcript reaches `onTranscript`, the deferred
// notice is cancelled and the state settles only after the store confirms this
// window still holds the capture, because a hold that lapsed mid-transcription
// can have been taken over by a surface that already sent the same words.

import AppKit
import AVFoundation
import OSLog
import Speech

/// Recording/transcription states for the menu bar capture flow.
///
/// There is no terminal `.done(text:)` state — STT success does not render a
/// "Copied to clipboard" terminal view. The transcript is handed to
/// `DictationService.onTranscript` and the service returns to `.idle`; the
/// agent reply (and its in-flight UX) lives on `ConversationDetailViewModel`,
/// surfaced by the popover's hosted `ConversationThreadView`. Only the
/// audio→STT lifecycle is modelled here.
enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case error(message: String, isRetryable: Bool)
}

/// Orchestrates the menu-bar dictation pipeline: record → Mistral Voxtral →
/// clipboard. State is observed by `MenuBarController` (icon + popover) and
/// `DictationPopoverView` (compact UI). Single-instance, main-actor isolated.
@Observable
@MainActor
final class DictationService: RecordingExclusivityAuthority {
    /// FACTS ONLY. The one thing this service logs is whether a store write it
    /// deliberately does not fail on succeeded — never a transcript, never an
    /// id, never a file name.
    nonisolated private static let log = Logger(
        subsystem: Constants.identityNamespace, category: "WorkVoiceRetry"
    )

    private(set) var state: DictationState = .idle
    private(set) var recordingTime: TimeInterval = 0

    /// Terminal STT-success hook. Set by `MenuBarCoordinator`; invoked on
    /// the main actor with the decoded transcript the instant transcription
    /// succeeds. The coordinator forwards it to the active
    /// `ConversationDetailViewModel.sendUserTurn(_:)` (the agent round-trip).
    /// Default is a no-op so the service is usable standalone (previews/tests).
    ///
    /// This service is now the menu-bar / ⌘⇧1 quick-capture path ONLY (always
    /// direct-send). The in-window composer has its own host-owned
    /// `InAppAudioRecorder` (review-then-send into the draft), so the old
    /// `.composer` transcript-destination latch is gone.
    var onTranscript: (String) -> Void = { _ in }

    /// Terminal hook for a transcript RECOVERED from the durable queue — the
    /// footer's Retry, never a live capture.
    ///
    /// Separate from `onTranscript` because the two carry different things. A
    /// live capture owns the composition on screen: its ⌘⇧2 screenshot is part
    /// of the same press, and the send consumes it. A Retry replays a recording
    /// captured minutes — or launches — ago, and the picture staged in the
    /// composition now belongs to whatever the person is doing at this moment.
    /// Sending the two together attaches somebody else's screenshot to these
    /// words and clears a slot the person is still composing with.
    ///
    /// Defaults to `onTranscript` so a host that wires only the live hook keeps
    /// working; `MenuBarCoordinator` sets both.
    var onRecoveredTranscript: ((String) -> Void)?

    /// Typed mirror of the last AppError, set when `state` transitions to
    /// `.error`. The popover may branch on this for retryability hints; for
    /// V1 it's primarily an inspection aid (no inline upgrade card).
    private(set) var lastError: AppError?

    /// True between the soft-warning fire (T-60 s) and the hard cap (300 s).
    /// Drives the amber timer in `DictationPopoverView.recordingView`.
    private(set) var nearMaxDuration: Bool = false

    /// How many captures are WAITING FOR A PERSON in `PendingRetryStore`, as of
    /// the last time this service asked. Metadata only — no recording is read —
    /// and refreshed on every finish, so the `.error` state this service settles
    /// into after finishing one can say what is left.
    ///
    /// `waitingCount()` rather than the queue's depth: an ordinary capture holds
    /// its own reservation for the whole of its transcription, so the depth
    /// reading raises a Try Again through every successful recording somebody
    /// makes. A capture comes back into this count the moment its lane dies
    /// without releasing, which is the state the retry affordance exists for.
    ///
    /// It is the DIRECT answer to the question `DictationPopoverView`'s
    /// `hasSavedRetryAudio` asks of the error taxonomy ("are there bytes to
    /// retry?"), which the taxonomy can only answer for the capture that just
    /// failed in this process.
    private(set) var pendingRetryCount: Int = 0

    /// Keeps `pendingRetryCount` honest about captures this service did not
    /// park. Every lane refreshes after its own save, so the count was only
    /// ever stale for one parked somewhere else — and the composer's recorder
    /// parks Work captures whose Try Again this popover is the surface for.
    private var queueObserver: (any NSObjectProtocol)?

    private let recorder = AudioRecorder()
    private var recordingStartTime: Date?
    private var displayTimer: Timer?

    /// Which transcription the person is waiting for. Moved by every cancel that
    /// lands in `.processing`, and carried by the run that was in flight when it
    /// did.
    ///
    /// The provider hop cannot be recalled — it is a foreground `URLSession` this
    /// service does not retain — so what a cancel takes is its RESULT: a run
    /// whose token is stale hands nothing to `onTranscript` (which SENDS), keeps
    /// no recording for a Retry the person did not ask for, and writes no error
    /// over a popover they already dismissed. A generation rather than a flag,
    /// because a cancel followed by a fresh capture must not hand the OLD run's
    /// words to the new one's surface.
    private var transcriptionGeneration = 0

    /// Identifies the START that is currently in flight, so a bail pressed
    /// DURING it is honored once the microphone finally comes up.
    ///
    /// An Ask start suspends twice before there is anything to cancel — the
    /// Speech-Recognition preflight, and `AudioRecorder.startRecording()`'s own
    /// permission hop — and for the first of them this service reads `.idle`,
    /// which is the one state `cancelRecording()` has nothing to act on. So an
    /// Esc pressed there invalidated no startup at all, and the microphone came
    /// up moments later behind a popover that same Esc had just closed, live
    /// until the duration cap with no surface anywhere to stop it.
    ///
    /// Same shape as the Work lane's `workVoiceStartToken`, for the same reason:
    /// a token the start CARRIES is the only thing a press can leave behind
    /// while the lane owns nothing.
    private var recordingStartToken = 0

    init() {
        // Join the exclusivity bus as a mic authority: `claimForAutoSpeak`
        // consults it so the quick-lane arrival speak stays silent while a
        // capture is live. Weakly registered — this (the coordinator's popover
        // service) coexists with the main window's `InAppAudioRecorder` (also a
        // registered authority), and with SwiftUI's throwaway `@State` default
        // re-evaluations; the bus reports any-live-instance-recording.
        SpeechExclusivity.shared.register(recordingAuthority: self)
        // Whatever survived the last launch. `canRecoverPendingQueue` is read
        // while this service is idle, which is exactly the state nothing else
        // refreshes the count from — a capture parked before a relaunch would
        // otherwise be unreachable until an unrelated failure asked.
        Task { await refreshPendingRetryCount() }
        // Somebody else parked a capture. This popover is the surface that
        // offers a Try Again for it, and its count is read once per finish
        // rather than per render — so without this the row says nothing is
        // waiting while a recording is.
        queueObserver = NotificationCenter.default.addObserver(
            forName: PendingRetryStore.queueDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPendingRetryCount() }
        }
        recorder.onRecordingFinished = { [weak self] wasAutoStopped in
            Task { @MainActor in
                guard let self else { return }
                if wasAutoStopped {
                    // Audible cue so the user knows the cap fired (vs. wondering
                    // why recording silently stopped). Independent of any future
                    // user completion-feedback preference.
                    CompletionFeedbackPlayer.play(mode: "sound")
                }
                self.stopAndProcess()
            }
        }
        recorder.onWarningFired = { [weak self] in
            Task { @MainActor in
                self?.nearMaxDuration = true
            }
        }
        // A HAL-aborted capture (delegate `successfully: false`) with no user
        // stop must not strand the popover in `.recording` — that keeps the
        // display timer running AND (now) holds the mic lease against the window
        // composer until the next click. Roll to `.error` so the lease releases.
        recorder.onRecordingFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.stopDisplayTimer()
                self.state = .error(
                    message: String(localized: "Recording stopped unexpectedly. Try again."), // xcstrings: chat-ui-mac-freeze
                    isRetryable: false
                )
            }
        }
    }

    // MARK: - Public Actions

    /// Toggle recording: idle → recording, recording → processing. The
    /// transcript always direct-sends (this is the menu-bar / ⌘⇧1 quick-capture
    /// path); the in-window composer's review-then-send flow lives on its own
    /// `InAppAudioRecorder`, not here.
    func toggleRecording() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            break // Can't toggle during processing
        }
    }

    /// Cancel an in-progress recording without processing, cancel the
    /// transcription that follows a stop, or dismiss an error state.
    func cancelRecording() {
        // FIRST, and unconditionally: a start still suspended in its permission
        // hops owns no state any arm below can reach, and `.idle` is exactly the
        // state it reads while it waits. Without this the microphone that start
        // asked for comes up AFTER the bail, behind a closed popover.
        recordingStartToken &+= 1
        switch state {
        case .recording:
            recorder.cancelRecording()
            stopDisplayTimer()
            state = .idle
            lastError = nil
        case .processing:
            // Esc — and every ✕ that routes through the coordinator's teardown —
            // pressed while the provider is working. The request itself is a
            // foreground `URLSession` nobody holds a handle to, so it is the
            // RESULT that is cancelled: the generation moves, and the run that
            // comes back finds itself stale, sends nothing and surfaces nothing.
            //
            // Without this the words reach a gateway AFTER the cancel — the one
            // thing the capture guide promises cannot happen ("Press Esc to
            // cancel", step 3 under the two Ask shortcuts) — and an unwanted
            // paid turn besides.
            transcriptionGeneration &+= 1
            state = .idle
            lastError = nil
        case .error:
            state = .idle
            lastError = nil
        default:
            break
        }
    }

    /// Whether the run carrying this token is still the one the person is
    /// waiting for. Every write a stale run would make is skipped on the way
    /// out: the transcript hand-off, the preserved retry, the error surface.
    private func stillCurrent(_ token: Int) -> Bool { token == transcriptionGeneration }

    /// Surface a post-STT hand-off failure on the SAME `.error` surface the
    /// popover renders for STT failures. Used by `MenuBarCoordinator` when the
    /// conversation mint fails AFTER a successful transcription — the only
    /// error channel the popover footer reads is this service's state.
    /// `isRetryable: false` because there is no saved audio behind this error
    /// (STT succeeded and cleared the retry store); the coordinator owns the
    /// transcript-level Retry affordance (`retryPendingFailedTurn`). Guarded to
    /// `.idle` so it never clobbers a live capture the user has since started.
    /// Returns whether the error was actually presented — on the `false`
    /// (no-op) branch the caller must NOT keep recovery state behind it, or an
    /// invisible stash would hijack a later, unrelated error's Retry.
    func presentHandoffError(message: String) -> Bool {
        guard state == .idle else { return false }
        lastError = nil
        state = .error(message: message, isRetryable: false)
        return true
    }

    /// True when the durable queue holds a capture and this service is not in
    /// the middle of anything — the state in which `retryLast()` is the ONLY
    /// way back to it.
    ///
    /// A parked capture used to be reachable solely from a standing error,
    /// which is fine while the error that parked it is the one on screen. It
    /// stopped being fine when a Work capture began parking its own debt: the
    /// ✕ that dismisses that error leaves the recorder idle and the capture in
    /// the queue, and this popover is the surface its Try Again lives on. Made
    /// reachable from idle, the recovery is the same one the error path runs.
    var canRecoverPendingQueue: Bool {
        state == .idle && pendingRetryCount > 0
    }

    /// Whether a Retry may run at all. An error is the ordinary way in; a
    /// queue that still holds something is the other, and there is no third.
    private var isRetryPermitted: Bool {
        if case .error = state { return true }
        return canRecoverPendingQueue
    }

    /// Retry the last failed transcription from PendingRetryStore.
    /// Reads the audio file path, language, and terminal destination from the
    /// retry record; resolves the API key fresh at retry time so a rotated key
    /// takes effect.
    ///
    /// The capture it recovers decides where the words land, and that decision
    /// is the record's own: a `.work` entry is finished onto the DESK through
    /// `finishWorkRetry`, a `.chat` entry into a turn, whichever state this
    /// service was in when the tap arrived. Reaching the queue from idle
    /// changes who may ask, never what the answer does.
    func retryLast() {
        Task {
            guard isRetryPermitted else { return }
            lastError = nil
            state = .processing
            // A Retry is a run like any other, and Esc reaches `.processing`
            // whether the words are being bought for the first time or the
            // second. Without this token the promise the capture guide makes
            // ("Press Esc to cancel") is true of a stop and false of a Retry:
            // the cancelled run comes back, retires the entry and hands its
            // words to a gateway.
            let generation = transcriptionGeneration

            // ONE capture per Retry, RESERVED while this window works on it:
            // the queue is offered newest first, and the reservation is what
            // stops the main window's card or a Shortcut host from transcribing
            // and finishing the same recording beside us. What is still queued
            // is offered by the next tap.
            guard let claim = await PendingRetryStore.shared.claimNext() else {
                // Nothing this window may take, which is two different states.
                await refreshPendingRetryCount()
                // THE WHOLE QUEUE, not what is waiting for a person. This is the
                // one question on this surface that is about the recordings
                // rather than about the affordance: `claimNext` skips a capture
                // somebody else is holding, and so does `waitingCount()` by
                // construction, so reading that here would answer "there is
                // nothing to retry" over a recording another surface is finishing
                // — and `isRetryable: false` takes the button away with it. The
                // reservation lapses; the recording does not.
                let waiting = await PendingRetryStore.shared.pendingCount() > 0
                // …and neither sentence is said at all over a cancelled Retry:
                // the reservation hop suspends, and a banner drawn after the Esc
                // lands on whatever the person did next.
                guard stillCurrent(generation) else { return }
                state = .error(
                    message: waiting
                        ? pendingRetryBusyMessage
                        : String(localized: "No saved recording to retry."), // xcstrings
                    // A capture somebody else is holding IS retryable — the
                    // reservation lapses. Only an empty queue retires the
                    // affordance.
                    isRetryable: waiting
                )
                return
            }

            // The reservation goes back on every outcome that leaves the
            // capture waiting, so the next tap can take it immediately instead
            // of waiting out the lease.
            if await attemptRetry(claim, generation: generation) == false {
                await PendingRetryStore.shared.release(claim)
            }
        }
    }

    /// Everything one Retry tap does with the capture it reserved.
    ///
    /// `true` means the capture is FINISHED and its entry retired; `false`
    /// means it is still waiting and the caller hands the reservation back.
    /// Splitting the two keeps "who releases the reservation" one statement in
    /// `retryLast` rather than a duty every early return has to remember.
    ///
    /// `generation` is the run's cancellation identity, and every suspension
    /// below is followed by a check on it. A cancelled Retry answers `false` —
    /// which is exactly the right answer: nothing was finished, so the
    /// reservation goes back and the capture stays queued for the next tap.
    private func attemptRetry(_ claim: PendingRetryClaim, generation: Int) async -> Bool {
        let pending = claim.entry

        // A Work capture whose WORDS are already parked owes the desk a
        // write and nothing else: recognition succeeded and only that write
        // failed. Everything between here and the upload — the key verdict,
        // the staged file, the provider round trip — would be spent buying
        // an answer this record already carries, and a key removed since
        // would refuse a retry that needs none. This one finishes with no
        // network at all.
        //
        // It is also the whole of what a PICTURE-OWING entry needs: words on
        // the desk, recording retired, screenshot still parked. That one is
        // handed over with EMPTY bytes and its words, and this arm publishes
        // the picture, finds the words card already standing, and clears it.
        if pending.metadata.resolvedDestination == .work,
           let parked = pending.metadata.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !parked.isEmpty {
            return await finishWorkRetry(claim, transcript: parked, generation: generation)
        }

        // NO BYTES and no words. The queue hands over an entry with no recording
        // only when it still shelters a picture — the recording was retired the
        // moment the words landed — so the debt is real and the speech hop is
        // not: staging an empty file and asking a provider to read it buys a
        // refusal for money. The desk lane publishes whatever is parked and
        // hands the entry back if that leaves nothing to write.
        if pending.metadata.resolvedDestination == .work, pending.audioData.isEmpty {
            return await finishWorkRetry(claim, transcript: "", generation: generation)
        }

        // ATOMIC snapshot: (presetID, apiKey, provider)
        // resolved in one actor hop so a concurrent preset switch can't
        // produce a key/provider mismatch on retry.
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        // The key question through `STTKeyReadiness` — in-process providers
        // (Apple on-device) and the keyless (`.none` auth) BYO endpoint need
        // no key, and both arms live inside its `requiresKey`.
        //
        // A nil `snapshot.apiKey` is ambiguous, and on THIS path the wrong
        // reading is worse than a wrong sentence: the saved recording is
        // already in `PendingRetryStore`, and telling the user their key is
        // missing with `isRetryable: false` retires the only affordance that
        // reaches those words. `.unreadable` keeps the retry live because an
        // unlock makes the identical bytes succeed (I3, I6). Neither arm
        // clears the store.
        let readiness = await STTKeyReadiness.resolve(
            presetID: snapshot.presetID,
            snapshotKey: snapshot.apiKey,
            provider: snapshot.provider,
            customConfig: snapshot.customConfig
        )
        // The settings and keychain hops above suspend, so the run asks whether
        // it is still the one on screen before it draws anything. `false` is
        // the honest answer for a cancelled Retry: nothing was finished, the
        // caller hands the reservation back, and the capture stays queued.
        guard stillCurrent(generation) else { return false }
        let apiKey: String
        switch readiness {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            state = .error(
                message: AppError.sttMissingAPIKey.localizedDescription,
                isRetryable: false
            )
            return false
        case .unreadable:
            lastError = .sttKeyUnreadable
            // The CAUSE LINE ONLY — see `processAudio`'s twin below for the
            // reasoning; both sites make the same call, because one cause
            // may not read two ways on one surface.
            state = .error(
                message: AppError.sttKeyUnreadable.errorDescription ?? "",
                isRetryable: AppError.sttKeyUnreadable.isRetryable
            )
            return false
        }

        // Re-materialize the saved audio bytes to a fresh temp file URL —
        // PendingRetryStore.load returns Data, and STTClient.transcribe
        // owns the file's lifecycle via defer-remove.
        //
        // The container is read off those bytes rather than assumed: both
        // capture lanes preserve COMPRESSED audio and `AudioCompressor` can
        // return WAV, so a fixed `.m4a` name tells a provider something
        // untrue about its own input and the stricter ones refuse it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck_retry_\(UUID().uuidString)"
                + ".\(PendingRetryAudioFile.extension(for: pending.audioData))"
            )
        do {
            try pending.audioData.write(to: tempURL, options: [.atomic])
        } catch {
            state = .error(
                message: String(localized: "Couldn't stage the retry audio."), // xcstrings
                isRetryable: false
            )
            return false
        }

        do {
            // The reservation is EXTENDED for as long as the provider is
            // working. A custom endpoint is allowed 300 s per request and is
            // attempted three times, so one Retry can outlast the ten minutes
            // the hold was granted for — and the entry's own expiry, which the
            // store waives only while a reservation is live.
            let response = try await PendingRetryLeaseRenewal.whileRenewing(claim) {
                try await STTClient.shared.transcribe(
                    audioFileURL: tempURL,
                    apiKey: apiKey,
                    language: pending.metadata.preferredLanguage,
                    provider: snapshot.provider,
                    customModel: snapshot.customModel,
                    customConfig: snapshot.customConfig
                )
            }
            // THE LINE THE CANCEL IS FOR on this path. Everything below it is
            // terminal — the entry is retired and the words go to a gateway (or
            // onto a card) — so a Retry the person cancelled while the provider
            // was working stops here, with the reservation handed back and the
            // capture still queued for the next tap.
            guard stillCurrent(generation) else { return false }

            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .error(
                    message: String(localized: "Transcription returned empty text. Please try again."), // xcstrings
                    isRetryable: true
                )
                return false
            }

            // Work records take the desk lane and never reach the agent
            // round-trip from this surface, so they leave here rather than
            // falling through to the Chat handoff below. The release of the
            // durable record is theirs to decide, not this method's: it
            // happens only on an outcome that says a card now holds the
            // words.
            if pending.metadata.resolvedDestination == .work {
                return await finishWorkRetry(claim, transcript: trimmed, generation: generation)
            }
            // The finish IS the ownership check, and it has to come FIRST. It
            // retires the entry only while this reservation still holds the
            // capture, so a false answer means another surface overtook a
            // lapsed hold and is sending — or has already sent — these very
            // words. Handing them to the coordinator anyway is a duplicate turn
            // the person never dictated twice.
            guard await settleAfterFinishing(claim, generation: generation) else {
                // Refused, so the capture is still queued — but the sentence
                // about it belongs to this run, and a cancelled run draws no
                // banner over what the person started next.
                guard stillCurrent(generation) else { return false }
                lastError = nil
                state = .error(message: pendingRetryBusyMessage, isRetryable: true)
                return false
            }
            // THE LAST DOOR. The settlement above SUSPENDS — the queue clear and
            // the count refresh are both actor hops — and an Esc that lands
            // inside it leaves this run holding words nobody is waiting for. The
            // hand-off is a gateway turn, which is the one thing "Press Esc to
            // cancel" promises cannot happen after the press.
            //
            // `true` rather than `false`: the entry IS retired, so the capture
            // is not still waiting and the caller must not hand a reservation
            // back for it. What is dropped is the transcript, which is what the
            // cancel was aimed at — the same rule a first-time capture already
            // follows, where a cancelled run keeps nothing.
            guard stillCurrent(generation) else { return true }
            // Legacy and explicit Chat records continue into the agent
            // round-trip.
            (onRecoveredTranscript ?? onTranscript)(trimmed)
            return true
        } catch let error as AppError {
            if error.shouldPreserveForRetry {
                // Count the attempt against the capture this window still
                // HOLDS. A reservation another surface overtook — or a
                // capture the person discarded while STT was suspended —
                // answers false and nothing is written, so a diagnosis can
                // never be painted onto somebody else's recording.
                _ = await PendingRetryStore.shared.updateAttempt(
                    claim,
                    lastErrorCode: error.errorCode
                )
            }
            // The diagnosis is written against the capture either way — it is
            // true of the recording, not of the surface — but the BANNER is
            // not: a cancelled Retry must not draw an error over whatever the
            // person started next.
            guard stillCurrent(generation) else { return false }
            lastError = error
            // Cause AND remedy. `localizedDescription` on a `LocalizedError`
            // is `errorDescription` alone, so the footer showed a certificate
            // refusal's cause with no way out — the server-side routes, the
            // "may be intercepted" warning and the "the certificate is fine"
            // line all live in `recoverySuggestion`, and the popover has no
            // second slot to reach one. `descriptionWithRecovery` drops the
            // generic "Try again." fallback, so an ordinary retryable failure
            // reads exactly as before and the Retry affordance keeps its own
            // gate (`isRetryable`).
            state = .error(
                // STT lane — this service never sends a gateway turn, so
                // there is no ref and the neutral wording is the true one.
                message: error.descriptionWithRecovery(),
                isRetryable: error.isRetryable
            )
        } catch {
            // Same rule as the taxonomy arm above: a cancelled Retry draws
            // nothing.
            guard stillCurrent(generation) else { return false }
            lastError = nil
            if pending.metadata.resolvedDestination == .work {
                state = .error(
                    message: String(
                        localized: "workboard.capture.retry.voice.message",
                        defaultValue: "Couldn't add this recording to Work. Try again."
                    ),
                    isRetryable: true
                )
            } else {
                state = .error(message: error.localizedDescription, isRetryable: false)
            }
        }
        return false
    }

    /// Everything this surface does to the desk with a recovered Work capture,
    /// and the only place it does it — reached both by a retry that had to buy
    /// its words and by one whose words were already parked.
    ///
    /// The desk decision itself is not taken here. `recover` owns it, because
    /// the question — which of a capture's three candidate ids already carries
    /// its words, and whether a card an earlier build published is standing to
    /// take them — is answered from the desk itself, which this surface has no
    /// business reading.
    ///
    /// THE WORDS ARE PARKED FIRST, before either publication. They were bought
    /// from a provider a moment ago and they exist in one place: this call's
    /// argument. A death between here and the desk write would cost them, and
    /// the retry that follows would pay for the same recognition again — so the
    /// entry takes them before anything else is attempted. Non-fatal by design:
    /// the publish proceeds on a refusal, because the words are in hand and the
    /// desk write is what the person is waiting for.
    ///
    /// It TOLERATES AN ENTRY WITH NO RECORDING. A capture whose words already
    /// landed and whose screenshot is still parked is handed over with empty
    /// bytes, and everything below is exactly what it needs: the picture is
    /// published, the recovery finds the words card already standing, and the
    /// entry is cleared. There is no speech hop above it and no file to stage.
    ///
    /// The release of the durable record sits BELOW the recovery and inside the
    /// same `do`, so a store that refused the write skips it and the recording
    /// survives to be recovered again — and a non-terminal outcome keeps it too.
    /// `true` only on the terminal outcome that retired the entry, so the caller
    /// knows whether the reservation still has to go back.
    /// `generation` is the run's cancellation identity, exactly as in
    /// `attemptRetry`. It gates the SURFACE only: the desk writes below stand
    /// whatever happens, because a card half-written is worse than a card the
    /// person stopped waiting for, but the banner and the error state that
    /// describe them must not land on whatever was started after the bail.
    private func finishWorkRetry(
        _ claim: PendingRetryClaim,
        transcript: String,
        generation: Int
    ) async -> Bool {
        let pending = claim.entry
        // Nothing reaches the desk on behalf of a capture this window no longer
        // holds. The words may have been bought minutes ago — a transcription
        // that outlived its horizon and was overtaken — and the surface that
        // took it over is publishing them itself.
        guard await PendingRetryStore.shared.confirmOwnership(claim) else {
            presentRetryOutcome(pendingRetryBusyMessage, generation: generation)
            return false
        }
        // Under the reservation, and RESTATING the verdict rather than deciding
        // it: this line learns nothing about the desk. A fresh capture reads
        // `.phaseOneFailed` and stays it; the picture-owing entry whose words
        // already landed reads `.published` and must not be talked back down to
        // "these bytes are the only copy", which is the reading that exempts an
        // entry from every clock.
        //
        // Skipped when there are no words: an entry offered with no bytes and
        // nothing recognised has none to park, and an empty transcript written
        // over the entry's own would erase words somebody already paid for.
        if !transcript.isEmpty {
            let wordsParked = await PendingRetryStore.shared.recordPublicationState(
                claim,
                transcript: transcript,
                publicationState: pending.metadata.publicationState ?? .phaseOneFailed
            )
            if !wordsParked {
                // FACT only — no transcript, no id. Not a refusal: the words are
                // in memory and the desk write below is what the person is
                // waiting for. What it costs is one more recognition if this
                // process dies in the next few lines.
                Self.log.error("Work retry words not parked")
            }
        }
        do {
            // A GigaAction capture can also carry a screenshot, and the retry
            // record holds the only copy until it lands. Publish it FIRST,
            // under an id derived from the capture's — the capture id itself
            // names the recording, and a screenshot published there is answered
            // by the recording and silently dropped. Both halves are
            // idempotent, so a capture recovered twice still has one picture.
            if let screenshot = pending.workImageData {
                // NOTHING is disposed of on the strength of a call that
                // returned: publication answers nil when the image pipeline
                // could make nothing of these bytes, having enqueued nothing at
                // all. Discarding there deletes the only copy of the picture
                // and hands the person a recovery that quietly dropped it.
                guard try await WorkVoiceScreenshotCoordinator.publish(
                    screenshot,
                    forCapture: pending.metadata.id,
                    createdAt: pending.metadata.createdAt
                ) != nil else {
                    presentRetryOutcome(
                        AppError.workScreenshotWriteFailed.localizedDescription,
                        generation: generation
                    )
                    return false
                }
                // The parked copy goes the moment the queue has TAKEN the
                // picture, under the reservation this surface already holds.
                // Left behind it is the only thing on disk still claiming this
                // entry shelters an irreplaceable image, and the expiry sweep
                // reads exactly that — so a recovery that throws below would
                // leave the capture exempt from the clock for ever.
                await PendingRetryStore.shared.discardWorkImage(claim)
            }
            let outcome = try await WorkVoiceCaptureCoordinator.recover(
                claim,
                transcript: transcript,
                // The picture this recording belongs to, read from the durable
                // record and never reconstructed from the bytes above. Those
                // bytes are gone by this line — the publication took them and
                // the discard retired the parked copy — and an entry armed
                // after the queue already held the picture never carried any.
                attachedTo: pending.metadata.workAttachedToMaterialID
            )
            guard outcome.isTerminal else {
                presentRetryOutcome(Self.workRetryFailureMessage, generation: generation)
                return false
            }
            // The card is on the desk either way, so a clear this reservation
            // can no longer make is not a failure to report — it means the
            // surface that overtook this one will retire the entry itself. The
            // count refresh inside is what the popover needs regardless.
            _ = await settleAfterFinishing(claim, generation: generation)
            return true
        } catch {
            presentRetryOutcome(Self.workRetryFailureMessage, generation: generation)
            return false
        }
    }

    /// The one sentence a Work retry prints when the desk refused it.
    private static var workRetryFailureMessage: String {
        String(
            localized: "workboard.capture.retry.voice.message",
            defaultValue: "Couldn't add this recording to Work. Try again."
        )
    }

    /// Draw a Retry's own outcome — but only while it is still the outcome the
    /// person is waiting for.
    ///
    /// Every write below this line follows an actor hop the person can press Esc
    /// inside (the ownership check, the screenshot publication, the desk
    /// recovery), and a banner drawn from a cancelled run lands on whatever they
    /// started next. `lastError` goes with the sentence: the two are read as one
    /// diagnosis by the popover's Troubleshoot affordance.
    private func presentRetryOutcome(
        _ message: String,
        isRetryable: Bool = true,
        generation: Int
    ) {
        guard stillCurrent(generation) else { return }
        lastError = nil
        state = .error(message: message, isRetryable: isRetryable)
    }

    /// Retire the entry this reservation holds, cancel the "Recording Saved"
    /// notice that would otherwise invite the user back to a retry that no
    /// longer exists, and settle into the state the REST of the queue calls for.
    ///
    /// `.idle` only when nothing is left. `.error` is the one state this
    /// service's popover draws a Retry control in, so returning to `.idle` with
    /// captures still waiting is what made the second recording unreachable
    /// until an unrelated capture failed — it is not an error state so much as
    /// the only state that offers the next tap.
    ///
    /// The sentence is deliberately not an apology: nothing failed here.
    ///
    /// `false` means the clear was REFUSED — this reservation no longer holds
    /// the capture — and it is the ownership proof the caller acts on before it
    /// hands words to the coordinator. The deferred "Recording Saved" notice is
    /// cancelled only on a true clear: it belongs to whichever surface actually
    /// retires the capture.
    ///
    /// `generation` gates the SURFACE half only. The retirement, the deferred
    /// notice and the count are facts about the queue and are settled whatever
    /// the person pressed; the state this method leaves behind is a description
    /// of a run, and both hops above it — the clear and the count refresh — are
    /// suspensions an Esc can land inside. Written unconditionally, that
    /// description reached a capture started after the bail: `.idle` over a live
    /// recording, or a backlog banner over a working view.
    @discardableResult
    private func settleAfterFinishing(
        _ claim: PendingRetryClaim,
        generation: Int
    ) async -> Bool {
        let retired = await PendingRetryStore.shared.clear(claim)
        if retired {
            PendingRetryGuard.cancelDeferredNotification(for: claim.id)
        }
        await refreshPendingRetryCount()
        guard stillCurrent(generation) else { return retired }
        guard pendingRetryCount > 0 else {
            lastError = nil
            state = .idle
            return retired
        }
        // The backlog carries the arming verdict of the capture the next tap
        // would take, so the popover's Troubleshoot affordance points at the
        // right code. It is diagnosis only: `DictationPopoverView` gates the
        // Retry button on `pendingRetryCount`, so a capture that recorded no
        // code — armed by the Shortcuts lane before anything failed — still
        // gets its button.
        let backlogCode = await PendingRetryStore.shared.pendingErrorCode()
        // One more hop, one more check: the read above suspends like the two
        // before it, and this is the last statement that can write a surface.
        guard stillCurrent(generation) else { return retired }
        lastError = backlogCode.map { AppError.from(errorCode: $0, message: nil) }
        state = .error(
            message: String(
                localized: "pendingRetry.card.count",
                defaultValue: "\(pendingRetryCount) recordings waiting"
            ),
            isRetryable: true
        )
        return retired
    }

    /// What is waiting for a person, metadata only — no recording is read. A
    /// capture its own lane is still working on is not waiting for anybody.
    private func refreshPendingRetryCount() async {
        pendingRetryCount = await PendingRetryStore.shared.waitingCount()
    }

    /// The one sentence for "another surface holds this recording". The holder
    /// may be the main window, a Shortcut host, or an attempt this process was
    /// killed in the middle of, so it names nobody.
    private var pendingRetryBusyMessage: String {
        String(
            localized: "pendingRetry.card.busy",
            defaultValue: "This recording is already being finished. Try again in a moment."
        )
    }

    // MARK: - Recording

    private func startRecording() {
        // Speech-Recognition preflight (A fallback) — MUST run BEFORE
        // `beginRecordingSession()` sets `.recording` / starts timers / takes
        // leases. The menu-bar shortcut calls `showPopover()` before toggling,
        // so the popover is visible and a prompt is contextual. If Apple
        // on-device STT is active AND Speech Recognition is `.notDetermined`,
        // prompt now; a determined `.denied`/`.restricted` surfaces the existing
        // `speechPermissionDenied` error and does NOT record. Cloud providers
        // no-op. `.authorized` / just-granted continues into the session.
        recordingStartToken &+= 1
        let startToken = recordingStartToken
        Task {
            let speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
            // The bail lands HERE in the common case: the prompt is a system
            // sheet and this service is `.idle` behind it, so Esc reaches
            // nothing else. A withdrawn press asks for no microphone and draws
            // no banner — the person already knows why nothing is recording.
            guard startToken == recordingStartToken else { return }
            if speechStatus == .denied || speechStatus == .restricted {
                lastError = .speechPermissionDenied
                state = .error(
                    message: AppError.speechPermissionDenied.localizedDescription,
                    isRetryable: false
                )
                return
            }
            beginRecordingSession(startToken: startToken)
        }
    }

    /// The synchronous record-start body: acquire the mic lease, silence
    /// speakers, set `.recording`, start the display timer, then spin up the
    /// underlying `AudioRecorder`. Split out of `startRecording()` so the
    /// Speech-Recognition preflight can run (and bail) BEFORE any of this state
    /// is taken.
    private func beginRecordingSession(startToken: Int) {
        // macOS mic lease: refuse to start if the main-window composer mic (a
        // SEPARATE AVAudioRecorder instance) is already capturing — two concurrent
        // starts on the shared input produce the HAL "there already is a thread" /
        // error-35 thrash. Excluding self so this service never blocks itself; a
        // live capture is sacred, so the SECOND start is refused, never the first.
        guard SpeechExclusivity.shared.acquireMicLease(excluding: self) else {
            state = .error(
                message: String(localized: "Microphone is in use by another recording."), // xcstrings: chat-ui-mac-freeze
                isRetryable: false
            )
            return
        }

        // Mic wins: silence EVERY macOS speaker before the mic comes up — the
        // shared arrival/preview voice AND every view-owned ThreadSpeaker
        // (another window's playing bubble would otherwise bleed straight into
        // this capture; macOS has no audio-session arbitration). The nil claim
        // stops all registered parties, and the mic itself is never registered,
        // so nothing can reciprocally stop a live capture. While `state ==
        // .recording` the bus also refuses auto-speak (`claimForAutoSpeak`),
        // so a reply landing mid-capture stays silent rather than recording
        // itself into the audio.
        SpeechExclusivity.shared.claim(nil)

        // Set state synchronously to prevent race condition on rapid double-clicks.
        lastError = nil
        nearMaxDuration = false
        state = .recording
        recordingStartTime = Date()
        recordingTime = 0
        startDisplayTimer()

        Task {
            do {
                let started = try await recorder.startRecording()
                // Cancelled while the microphone was coming up. The primitive
                // has no handle to cancel — `AudioRecorder.cancelRecording()`
                // returns immediately while `audioRecorder` is still nil — so
                // the teardown has to happen HERE, on the far side of the hop
                // that built it. Only when no live capture owns the recorder:
                // a NEW Ask started after the bail is the rightful owner of the
                // microphone this call brought up, and tearing it down would
                // stop the capture the person is watching.
                guard startToken == recordingStartToken else {
                    if state != .recording { recorder.cancelRecording() }
                    return
                }
                guard started else {
                    stopDisplayTimer()
                    state = .error(
                        message: String(localized: "Failed to start recording."), // xcstrings
                        isRetryable: false
                    )
                    return
                }
            } catch AudioRecorderError.permissionDenied {
                // A withdrawn press draws nothing, on this arm as on the
                // success one: the banner would land on whatever the person
                // started after the bail.
                guard startToken == recordingStartToken else { return }
                stopDisplayTimer()
                state = .error(
                    message: String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to enable."), // xcstrings
                    isRetryable: false
                )
            } catch {
                guard startToken == recordingStartToken else { return }
                stopDisplayTimer()
                state = .error(message: error.localizedDescription, isRetryable: false)
            }
        }
    }

    private func stopAndProcess() {
        guard state == .recording else { return }
        stopDisplayTimer()
        // A stop ENDS the start, whichever way it goes. `.recording` is declared
        // before the primitive's own permission hop completes, so a second press
        // during it lands here while the microphone is still coming up: the
        // recorder holds nothing, `stopRecording()` answers nil, and the error
        // below is written over a startup that then finished and opened the
        // microphone anyway — live behind a surface whose only key clears the
        // banner. Moving the token is what that resumed start reads.
        //
        // A stop that DOES find audio moves it too: by then the start it
        // invalidates has long since finished, so the bump reaches nothing and
        // the rule stays one sentence instead of two.
        recordingStartToken &+= 1

        guard let audioData = recorder.stopRecording() else {
            state = .error(
                message: String(localized: "No audio data recorded."), // xcstrings
                isRetryable: false
            )
            return
        }

        state = .processing
        let startTime = recordingStartTime ?? Date()
        // The run's identity, taken at the stop. A cancel while it is suspended
        // moves the generation, and every terminal step below reads this token
        // before it acts.
        let generation = transcriptionGeneration

        Task {
            await processAudio(audioData: audioData, startTime: startTime, generation: generation)
        }
    }

    // MARK: - Processing Pipeline

    /// Fetch credentials + stage audio to a temp file URL, hand off to STTClient.
    /// Conduck V1 has no audio compression and no per-mode/per-app personalization
    /// layers — the only request inputs are audio bytes, API key, and an optional
    /// language hint.
    private func processAudio(audioData: Data, startTime: Date, generation: Int) async {
        // ATOMIC snapshot: (presetID, apiKey, provider) in
        // one actor hop. Passed through to processTranscription so the
        // provider resolved here is the SAME preset whose key we read.
        let preferredLanguage = await SettingsManager.shared.getPreferredLanguage()
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        // A cancel landed while the settings hops were suspended. Nothing has
        // been spent yet, so the run simply stops here — no error surface over a
        // popover the person already closed, and no upload they cancelled.
        guard stillCurrent(generation) else { return }
        // The key question through `STTKeyReadiness` — in-process providers
        // (Apple on-device) and the keyless (`.none` auth) BYO endpoint need no
        // key, and both arms live inside its `requiresKey`.
        //
        // This refusal lands AFTER the microphone, so the two readings of a nil
        // key differ in what they cost the user. Code 23 is terminal and this
        // path preserves nothing, which is right for an empty slot — the same
        // bytes fail again until a key is entered, and the store's one slot is
        // better spent on a capture that can succeed. A blackout is the opposite
        // case: the bytes are valid, the fix is an unlock, so the capture goes
        // into `PendingRetryStore` through the lane's own reactive save and the
        // popover keeps a live Retry (I3, I6).
        //
        // `preferredLanguage` is resolved above rather than below so the
        // preserved metadata carries the SAME language hint the transcribe call
        // would have used; a retry that silently dropped it could come back in
        // the wrong language.
        let apiKey: String
        switch await STTKeyReadiness.resolve(
            presetID: snapshot.presetID,
            snapshotKey: snapshot.apiKey,
            provider: snapshot.provider,
            customConfig: snapshot.customConfig
        ) {
        case .ready(let key):
            apiKey = key
        case .notConfigured:
            guard stillCurrent(generation) else { return }
            lastError = .sttMissingAPIKey
            state = .error(
                message: AppError.sttMissingAPIKey.localizedDescription,
                isRetryable: false
            )
            return
        case .unreadable:
            // The guard precedes the PRESERVATION as well as the banner: a
            // capture the person cancelled must not come back as a Retry they
            // never parked.
            guard stillCurrent(generation) else { return }
            await preserveForRetry(
                error: .sttKeyUnreadable,
                audioData: audioData,
                preferredLanguage: preferredLanguage,
                generation: generation
            )
            // ASKED AGAIN, because the preservation above suspends. An Esc plus
            // a fresh recording inside that window leaves this run writing
            // `.error` over a LIVE microphone: the HUD disappears behind a
            // banner, the stop that follows has nothing to stop, and the
            // recording the person cancelled is the one Retry offers back.
            guard stillCurrent(generation) else { return }
            lastError = .sttKeyUnreadable
            // The CAUSE LINE ONLY, not `descriptionWithRecovery`. 75's cause
            // line already carries its own remedy ("unlock it and try again") —
            // written that way for the Shortcut lane, which renders
            // `errorDescription` alone and has no second slot; `.sttMissingAPIKey`
            // (23) reads the same way. So appending `recoverySuggestion` would
            // tell this user to unlock twice — and its second half ("open Conduck
            // and retry") is addressed to someone who is NOT in the app, while
            // this banner is the popover they are looking at, with a live Retry
            // on it. The wrist and the iOS retry card make the same call.
            state = .error(
                message: AppError.sttKeyUnreadable.errorDescription ?? "",
                isRetryable: AppError.sttKeyUnreadable.isRetryable
            )
            return
        }

        // A cancel during the key resolve above. Checked HERE rather than only
        // at the hand-off, so a cancelled capture never buys the round trip.
        guard stillCurrent(generation) else { return }

        // Stage to a temp file URL — STTClient.transcribe owns lifecycle via
        // defer-remove, so this method does not need to clean up post-call.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck_capture_\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: tempURL, options: [.atomic])
        } catch {
            state = .error(
                message: String(localized: "Couldn't stage audio for upload."), // xcstrings
                isRetryable: false
            )
            return
        }

        await processTranscription(
            audioData: audioData,
            audioFileURL: tempURL,
            apiKey: apiKey,
            provider: snapshot.provider,
            customModel: snapshot.customModel,
            customConfig: snapshot.customConfig,
            preferredLanguage: preferredLanguage,
            startTime: startTime,
            generation: generation
        )
    }

    /// Foreground STT call + state transitions. On transient failure the
    /// original audio bytes (not the temp URL — STTClient has consumed it)
    /// are saved to `PendingRetryStore` so the user can hit "Retry" later.
    /// `provider` is passed in by the caller from its atomic snapshot — never
    /// re-resolve here (avoids key/provider mismatch).
    private func processTranscription(
        audioData: Data,
        audioFileURL: URL,
        apiKey: String,
        provider: STTProvider,
        customModel: String?,
        customConfig: CustomSTTConfig?,
        preferredLanguage: String?,
        startTime: Date,
        generation: Int
    ) async {
        do {
            let response = try await STTClient.shared.transcribe(
                audioFileURL: audioFileURL,
                apiKey: apiKey,
                language: preferredLanguage,
                provider: provider,
                customModel: customModel,
                customConfig: customConfig
            )

            // THE LINE THE CANCEL IS FOR. `onTranscript` below is a send — the
            // words go to a gateway the moment they are handed over — so a run
            // the person cancelled while the provider was working stops here,
            // with nothing sent and nothing drawn.
            guard stillCurrent(generation) else { return }

            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .error(
                    message: String(localized: "Transcription returned empty text. Please try again."), // xcstrings
                    isRetryable: true
                )
                return
            }

            // Terminal step (`docs/ai-context/spec.md`): hand the
            // transcript to the coordinator (→ agent round-trip) and return to
            // idle. No clipboard, no `.done`, no auto-dismiss.
            state = .idle
            onTranscript(trimmed)

        } catch let error as AppError {
            // Same rule on the failure side, and it covers the PRESERVATION
            // too: a cancelled capture must not reappear as a Retry card for
            // words the person threw away.
            guard stillCurrent(generation) else { return }
            await preserveForRetry(
                error: error,
                audioData: audioData,
                preferredLanguage: preferredLanguage,
                generation: generation
            )
            // ASKED AGAIN — the preservation suspends, and the twin above says
            // why: a stale `.error` written after an Esc hides the microphone
            // the person started next.
            guard stillCurrent(generation) else { return }
            lastError = error
            // Cause AND remedy, for the reason the retry path above states —
            // this is the FIRST-attempt twin of that sink and the two must not
            // render one failure two ways.
            state = .error(
                message: error.descriptionWithRecovery(),
                isRetryable: error.isRetryable
            )
        } catch {
            guard stillCurrent(generation) else { return }
            lastError = nil
            state = .error(message: error.localizedDescription, isRetryable: false)
        }
    }

    // MARK: - Helpers

    /// The ONE place this service hands a capture to the retry lane, so the
    /// pre-flight key refusal and the STT failure below it cannot preserve on
    /// different terms. No-ops unless the taxonomy says these bytes can succeed
    /// on a second attempt (`shouldPreserveForRetry`).
    ///
    /// `PendingRetryStore.save` owns the App-Groups file write; the metadata's
    /// `audioFileURL` is bookkeeping only — the store derives the real path from
    /// the SAME container, so when the container is unavailable the save would
    /// throw regardless of what path travelled in the metadata. Hence the early
    /// return rather than a fallback URL that could never be used.
    ///
    /// The bookkeeping path is built from `PendingRetryFiles` rather than
    /// spelled out, so it names the id-scoped file the store actually writes.
    /// The fixed `pending_retry_audio.m4a` name is the PRE-ID-SCOPED recording
    /// an older release parked, which the store folds in once and then never
    /// reads or deletes — a record pointing there would describe a file that is
    /// not this capture's and that nothing may touch.
    ///
    /// Best-effort by design: a save failure is logged inside the store and the
    /// caller still surfaces the original error, because swapping in a storage
    /// error would tell the user the wrong thing about why their capture stopped.
    private func preserveForRetry(
        error: AppError,
        audioData: Data,
        preferredLanguage: String?,
        generation: Int
    ) async {
        guard error.shouldPreserveForRetry else { return }
        let captureID = UUID()
        guard let pendingURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)?
            .appendingPathComponent(
                PendingRetryFiles.audio(captureID, .chat)
            ) else { return }
        try? await PendingRetryStore.shared.save(
            audioData: audioData,
            metadata: PendingRetryMetadata(
                id: captureID,
                createdAt: Date(),
                audioFileURL: pendingURL,
                preferredLanguage: preferredLanguage,
                attemptCount: 1,
                lastErrorCode: error.errorCode
            )
        )
        // The disk write is a SUSPENSION, so the cancel can land inside it —
        // and the rule the caller's guard states is only kept if it survives
        // that: a capture the person threw away must not come back as a Retry
        // they never parked. The entry is retired by the id this call just
        // wrote and by no other, under the store's own lease, so a capture
        // another surface has since taken over is left alone.
        if !stillCurrent(generation) {
            if let claim = await PendingRetryStore.shared.claim(id: captureID) {
                _ = await PendingRetryStore.shared.clear(claim)
            }
        }
        // The popover's Retry is drawn from `lastError`; the COUNT is what says
        // whether more than this capture is waiting, and it is read once here
        // rather than on every render.
        await refreshPendingRetryCount()
    }

    /// Mic-authority view for the exclusivity bus. Only `.recording` counts —
    /// during `.processing` the mic is already released, so speaking is fine.
    var isActivelyRecording: Bool { state == .recording }

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingTime = self?.recorder.recordingTime ?? 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
}
#endif
