// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
// Conduck
// iOSMessageComposerBar.swift
//
// TEXT chat composer for iOS / iPadOS — the type-or-talk bar that replaces the
// voice-only `micFooter` on iPhone (`ContentView`) and iPad
// (`ConversationLibraryView`). Mirrors the macOS `MessageComposerBar` reference
// design but adapts the layout to `usesRegularLayout` — idiom AND size class,
// the same predicate `ContentView` routes on:
//
//   - compact (every iPhone geometry, iPad Stage-Manager-narrow): [growing
//     TextField][morphing trailing button]. The trailing button is MIC when the
//     draft is empty (idle/recording/processing, behaviour lifted from
//     ContentView's mic logic) and morphs into SEND the moment the draft is
//     non-empty.
//   - regular (iPad full width): [mic icon][TextField][send arrow] — the
//     persistent-controls layout from the macOS composer.
//
// The send/voice plumbing is owned by the host (ContentView / library) so the
// shared in-flight VM, conversation-minting, and pending-retry refresh stay in
// one place. This view is presentation + input only:
//   - onSendText  : a typed turn (trimmed, non-empty)
//   - onVoiceResult: the STT Result from `recorder.stopAndUpload()`
//
// Return-key handling: `.onSubmit` is unreliable with `axis: .vertical` on iOS,
// so soft-keyboard Return inserts a newline (the default) and hardware-keyboard
// Return is intercepted via `.onKeyPress(.return)` — Shift+Return = newline,
// plain/Cmd+Return = send.

import SwiftUI
import UIKit

struct iOSMessageComposerBar: View {
    /// The thread VM the typed/spoken turn lands on. Drives the send-disabled
    /// state (its own claim plus the derived wait indicator) and the Stop morph;
    /// nil before the first conversation is minted.
    let viewModel: ConversationDetailViewModel?
    /// Shared in-app mic recorder (host-owned). The mic button drives it.
    var recorder: InAppAudioRecorder
    /// The draft text — host-owned (`@State` in ContentView / the library) and
    /// passed as a binding so a `⌘Return` keyboard shortcut on the host can read
    /// and send the current draft. The TextField writes through this binding.
    @Binding var draft: String
    /// Staged-but-unsent attachments — host-owned (mirrors `draft`) so the host
    /// owns the `.photosPicker` / `.fileImporter` / camera-cover modifiers and
    /// converts the staged collection into `[PendingAttachment]` at send time.
    @Binding var attachments: [StagedAttachment]
    /// Per-loading-item determinate progress (0…1), host-driven from the
    /// PhotosPicker `loadTransferable` Progress overload. Optional default keeps
    /// the indeterminate spinner for items the host hasn't wired progress to.
    var progressByID: [UUID: Double] = [:]
    /// Forward a typed turn to the converse path (host owns minting + VM). The
    /// host reads the staged `attachments` itself; this fires the text payload.
    let onSendText: (String) async -> Bool
    /// Host-side work can begin before a tile exists (security-scoped copy,
    /// image processing, route resolution). Every button and ⌘Return fails
    /// closed during that interval.
    var attachmentPreparationInProgress: Bool = false
    /// Forward the STT Result from a spoken turn (host routes success/failure +
    /// pending-retry refresh — same contract as ContentView's mic footer).
    let onVoiceResult: (Result<String, AppError>) async -> Void
    /// Attach-menu callbacks (host owns the actual pickers/sheets).
    let onPickLibrary: () -> Void
    let onTakePhoto: () -> Void
    let onPickFiles: () -> Void
    /// Open the file-transfer setup guide (host-owned sheet) scoped to the bound
    /// gateway — fired by the menu's "Set Up File Transfer…" item (shown only when
    /// no server) AND by the strip's per-tile "Set Up" button (via `onSetUp`).
    /// Default no-op so existing call sites still compile.
    var onSetUpFileTransfer: () -> Void = {}
    /// True when the bound gateway has a usable file-server snapshot — when FALSE
    /// the menu surfaces the "Set Up File Transfer…" discovery item. Host resolves
    /// it (vm/settings change) and passes it in. Default false.
    var fileTransferAvailable: Bool = false
    /// Remove a staged attachment by id (the strip's X overlay).
    let onRemoveAttachment: (UUID) -> Void
    /// Re-kick a failed `.serverFile` upload (the strip's Retry affordance).
    /// Default no-op so existing call sites compile.
    var onRetryUpload: (UUID) -> Void = { _ in }
    /// Open the setup guide for a `.needsSetup` tile (the strip's inline "Set Up"
    /// button). Default routes to `onSetUpFileTransfer` semantics; host wires it to
    /// the same setup sheet. Default no-op so existing call sites compile.
    var onSetUpAttachment: (UUID) -> Void = { _ in }
    /// The user has turned toward this composer with something in mind — focus,
    /// or the first thing worth sending. The host re-checks the gateway presence
    /// dot on it, so the toolbar's claim is measured at the moment the user is
    /// actually deciding rather than whenever the screen last appeared.
    ///
    /// Fires the INTENT, never a ref: the three hosts each own the authoritative
    /// `presenceRef` (a deliberately triplicated invariant), and a composer that
    /// resolved one itself would be a fourth copy of it. Default no-op so
    /// existing call sites compile.
    var onComposerEngaged: () -> Void = {}

    @FocusState private var fieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    /// One-shot amber border flash on the composer field when a transcript lands
    /// (Part 2d). Set true on a successful recording→processing→idle landing,
    /// then cleared after ~0.4s. Static (no animation) under Reduce Motion.
    @State private var transcriptFlash = false

    /// True once `.processing` has run past `Constants.transcribeStallHintDelay`
    /// without resolving — surfaces the "Still working…" line + Cancel under
    /// the Transcribing banner so a hung STT round-trip is never a silent,
    /// inescapable spinner. Reset whenever the capture phase changes.
    @State private var showSlowTranscribeHint = false
    @State private var sendSubmissionInProgress = false

    /// The capture slot's one height, scaled with Dynamic Type like the text
    /// it holds (two `.caption`-class lines plus spacing). A fixed point value
    /// would compress or clip the rows at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var captureSlotHeight = Constants.composerCaptureSlotHeight

    /// Which of the two layouts this bar draws — and the ONLY place that decides
    /// it, so the card, its background suppression and the field's own fill can
    /// never disagree about which surface they are on.
    ///
    /// Idiom AND size class, the identical predicate `ContentView` routes the
    /// split view on. A large iPhone (Plus/Max) reports a REGULAR horizontal size
    /// class in landscape while staying on `phoneLayout`, so size class alone
    /// would dock the iPad's two-row card in a 440pt-tall phone canvas: a
    /// full-width field row plus a separate control row, where that canvas has
    /// room for one row and the compact bar carries every control inline. Keeping
    /// the two predicates identical is what makes the composer belong to the
    /// layout that hosts it.
    private var usesRegularLayout: Bool {
        horizontalSizeClass == .regular && DeviceCapabilities.isiPad
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraft: Bool { !trimmedDraft.isEmpty }

    /// True when at least one attachment is staged (resolved OR still loading).
    private var hasAttachments: Bool { !attachments.isEmpty }

    /// True while any staged attachment is still loading — Send is disabled so a
    /// partial payload never ships (key UX decision #6).
    private var hasLoadingAttachment: Bool { attachments.hasLoadingItem }

    /// True while any `.serverFile` tile is still uploading OR has failed its
    /// upload, OR any `.needsSetup` tile is staged — Send is disabled (strict
    /// send-gating: a turn dispatches only once every server-file PUT has landed;
    /// a failed upload must be retried or its tile removed first; a `.needsSetup`
    /// binary has no wire route until file transfer is set up or the tile is
    /// removed). Extends the existing `.loading` gate.
    private var hasBlockingUpload: Bool {
        attachments.hasUploadingItem || attachments.hasFailedUpload || attachments.hasNeedsSetupItem
    }

    /// There's something sendable: a draft OR at least one staged attachment
    /// (image-only, no caption, is a valid turn).
    private var hasSendableContent: Bool { hasDraft || hasAttachments }

    /// Send is blocked while a turn is in flight OR while any attachment is
    /// still loading. A nil VM is a valid first-turn state — the host
    /// (`onSendText` → `sendTurn`) mints a fresh conversation on the first send,
    /// exactly as the voice path does. (Gating on `viewModel == nil` here would
    /// make the FIRST typed turn impossible — the headline regression caught in
    /// review.)
    ///
    /// TWO in-flight terms, not one. `isAwaitingReply` is this VM instance's own
    /// claim — the only thing that covers the pre-dispatch window. The wait
    /// indicator covers turns this instance did not dispatch (a discarded sibling
    /// VM, the background session, the macOS share drainer), which a fresh VM
    /// would otherwise let the user send straight into.
    private var isSendDisabled: Bool {
        viewModel?.isAwaitingReply == true
            || viewModel?.showsGatewayWaitIndicator == true
            || hasLoadingAttachment
            || hasBlockingUpload
            || attachmentPreparationInProgress
            || sendSubmissionInProgress
            || viewModel?.isPreparingLiveTurn == true
            || captureActive
    }

    /// True while the in-app mic is capturing or transcribing (Part 1f). Folded
    /// into `isSendDisabled` so EVERY send path — the morphing trailing send, the
    /// subdued attachment-only send, the regular-layout send, and the
    /// `.onKeyPress` ⌘Return — is blocked mid-recording (voice now POPULATES the
    /// field, so a send during capture would ship a stale/empty draft).
    private var captureActive: Bool {
        switch recorder.state {
        case .recording, .processing, .preparingVoice: return true
        case .idle, .error: return false
        }
    }

    /// True once a turn this device can actually STOP is running — the trailing
    /// control becomes a neutral Stop that cancels it (TOP priority in the state
    /// machine). Same gate as the Mac composer for uniformity.
    ///
    /// Deliberately `canStopLiveTurn`, not the wait indicator: a turn this device
    /// can see but holds no handle to (a macOS share drain, a CarPlay upload)
    /// must show the wait and no Stop, rather than a button that does nothing.
    /// `isSendDisabled` covers those turns instead.
    private var isInFlight: Bool {
        viewModel?.canStopLiveTurn == true
    }

    /// The SUBDUED secondary Send shows only when attachments are staged AND the
    /// draft is empty — so the trailing button STAYS the mic (the user can
    /// voice-caption the photo) while still offering a way to send the
    /// attachment with no caption (key UX decision #1).
    private var showsSubduedSend: Bool { hasAttachments && !hasDraft }

    var body: some View {
        VStack(spacing: 6) {
            // Staged-attachment strip — FIRST child of the VStack, above the
            // field. Zero-height + animated in/out so the thread doesn't hitch.
            AttachmentPreviewStrip(
                attachments: attachments,
                progressByID: progressByID,
                onRemove: onRemoveAttachment,
                onRetryUpload: onRetryUpload,
                onSetUp: onSetUpAttachment
            )
            .allowsHitTesting(!sendSubmissionInProgress)

            // Capture status slot — recording, transcribing, preparing voice,
            // and the capture error, all in ONE phase-keyed group so every edge
            // rides the same transaction. The three active phases share one
            // fixed height (see `captureStatusBanner`).
            captureStatusBanner

            if usesRegularLayout {
                regularLayout
            } else {
                compactLayout
            }
        }
        .padding(.horizontal, 16)
        .appReviewBusy(workbenchDestinationIsActive && (isSendDisabled || hasSendableContent))
        .padding(.vertical, 12)
        // Compact keeps the docked-bar material chrome; regular (iPad) has no
        // full-width material — the composer CARD is the container there. Keyed
        // off the same `usesRegularLayout` as the layout above, so the chrome and
        // the arrangement inside it can never disagree.
        .background(usesRegularLayout ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: attachments)
        // Disable only the capture surface—not the entire mounted Chat tree—so
        // an iPad keyboard cannot keep typing or dispatching into hidden Chats.
        .disabled(!workbenchDestinationIsActive)
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            guard !isActive else { return }
            fieldFocused = false
            // Wide iPad keeps Chat mounted behind Work. End capture work that
            // would otherwise keep the microphone, timer and pulse alive in the
            // invisible tree; the draft and staged attachments remain intact.
            switch recorder.state {
            case .recording:
                recorder.cancelRecording()
            case .processing, .preparingVoice:
                recorder.cancelProcessing()
            case .idle, .error:
                break
            }
            recorder.dismissError()
        }
        // The composer never grabs focus on appear: the keyboard opens only when
        // the user taps the field (`.onTapGesture` below) — no auto-open on launch.
        //
        // Which is exactly why focus is a legitimate engagement signal HERE and
        // not on the Mac, whose composer focuses itself in `.onAppear`. Focus
        // covers the field tap and the card-wide tap assist (which sets this
        // flag) in one place, with no gesture competing for the caret.
        .onChange(of: fieldFocused) { _, focused in
            if focused { onComposerEngaged() }
        }
        // Content arriving without focus is engagement too: a landed transcript
        // populates the draft, and the attach menu stages a file, neither of
        // which touches the keyboard. Only the false→true edge, so every further
        // keystroke is silent — and the monitor's freshness window makes a
        // repeat within 30 s cost nothing anyway.
        .onChange(of: hasSendableContent) { was, now in
            if !was, now { onComposerEngaged() }
        }
    }

    // MARK: - Capture status slot (recording ↔ transcribing crossfade, Part 2b)

    /// The dot+timer recording row crossfading into the spinner+"Transcribing…"
    /// row as capture stops, and into the calm "Setting up voice…" row on a
    /// self-heal. `.transition(.opacity)` + a spring keyed on the state PHASE
    /// gives the crossfade; Reduce Motion swaps instantly (nil animation).
    ///
    /// GEOMETRY INVARIANT: the slot has exactly two heights — nothing when idle,
    /// `Constants.composerCaptureSlotHeight` for every active phase. The bar is
    /// a safe-area inset, so each height change re-insets the thread; one box
    /// for all three phases means the bar moves twice per capture (open, close)
    /// instead of at every edge. Anything that would add a row inside a phase
    /// (the slow-transcribe hint here, "1 min left" in the recording row) is a
    /// reserved zero-opacity line, never a new row. The capture error is the
    /// one occupant outside the fixed height: a terminal refusal has to be
    /// readable, and it lands once.
    @ViewBuilder
    private var captureStatusBanner: some View {
        Group {
            switch recorder.state {
            case .recording(let startedAt):
                LiveRecordingStatusIndicator(startedAt: startedAt)
                    .frame(maxWidth: .infinity, minHeight: captureSlotHeight, maxHeight: captureSlotHeight)
                    .transition(.opacity)
            case .preparingVoice(let progress):
                // Self-heal: the on-device model is downloading before we
                // transcribe the SAME audio. Calm label leads (progress is not
                // the hero), crossfading like the transcribing row.
                PreparingVoiceIndicator(progress: progress)
                    .frame(maxWidth: .infinity, minHeight: captureSlotHeight, maxHeight: captureSlotHeight)
                    .transition(.opacity)
            case .processing:
                VStack(spacing: 4) {
                    TranscribingIndicator()
                    // Always present (reserves its line), visible only once the
                    // stall watchdog fires — the slot never grows mid-phase.
                    HStack(spacing: 8) {
                        Text(String(localized: LocalizedStringResource(
                            "recording.transcribing.slow.v2",
                            defaultValue: "Still working…"
                        )))  // xcstrings: hardening
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)

                        Button {
                            recorder.cancelProcessing()
                        } label: {
                            Text(String(localized: LocalizedStringResource(
                                "recording.transcribing.cancel",
                                defaultValue: "Cancel"
                            )))  // xcstrings: hardening
                            .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.brandAmber)
                    }
                    .opacity(showSlowTranscribeHint ? 1 : 0)
                    .allowsHitTesting(showSlowTranscribeHint)
                    .accessibilityHidden(!showSlowTranscribeHint)
                }
                .frame(maxWidth: .infinity, minHeight: captureSlotHeight, maxHeight: captureSlotHeight)
                .transition(.opacity)
            case .error(let error):
                // Cause AND remedy — the iPhone/iPad twin of the macOS composer's
                // `errorBanner`, and the same reasoning: this is the composer's
                // only slot for a capture failure, `.error` carries the whole
                // `AppError` taxonomy, and the certificate verdicts keep the part
                // the user must act on (the interception warning, the server-side
                // routes, the "your certificate is fine") in the remedy half alone.
                let message = error.descriptionWithRecovery(for: viewModel?.boundRef)
                Text(message.isEmpty ? String(localized: "Something went wrong.") : message)  // xcstrings
                    .font(.caption)
                    .foregroundStyle(AppColors.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            case .idle:
                EmptyView()
            }
        }
        .animation(
            reduceMotion ? nil : ComposerMotion.landingSpring,
            value: captureBannerPhase
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: showSlowTranscribeHint
        )
        // Stall watchdog: arm only while transcribing (phase 2). `.task(id:)`
        // cancels + restarts on every phase flip, so the hint resets on each
        // new capture and never fires outside `.processing`.
        .task(id: captureBannerPhase) {
            showSlowTranscribeHint = false
            guard captureBannerPhase == 2 else { return }
            try? await Task.sleep(for: .seconds(Constants.transcribeStallHintDelay))
            guard !Task.isCancelled, case .processing = recorder.state else { return }
            showSlowTranscribeHint = true
        }
    }

    /// A discrete phase tag for the slot crossfade animation: 0 = nothing,
    /// 1 = recording, 2 = transcribing, 3 = preparing voice, 4 = capture error.
    /// Keying the animation on this discrete phase (rather than the full
    /// `state`) keeps the crossfade firing exactly once per phase change.
    /// (`state` is stable across a capture — the `mm:ss` tick lives inside
    /// `LiveRecordingStatusIndicator`'s TimelineView.) The error is its own
    /// phase so its row rides the same transaction instead of snapping in.
    private var captureBannerPhase: Int {
        switch recorder.state {
        case .recording: return 1
        case .processing: return 2
        case .preparingVoice: return 3
        case .error: return 4
        case .idle: return 0
        }
    }

    /// A phase tag that DISTINGUISHES idle from error (unlike `captureBannerPhase`)
    /// so the Part 2d landing flash fires ONLY on a successful processing→idle
    /// transition, never on processing→error (a failed transcription).
    /// 0 = idle, 1 = recording, 2 = processing, 3 = error, 4 = preparingVoice.
    /// `.preparingVoice` is a distinct value so the landing flash (which fires
    /// only on processing→idle) never mistakes a self-heal transition for a
    /// landed transcript.
    private var recorderStatePhase: Int {
        switch recorder.state {
        case .idle: return 0
        case .recording: return 1
        case .processing: return 2
        case .error: return 3
        case .preparingVoice: return 4
        }
    }

    /// Pulse the field's amber border once (~0.4s). Reduce Motion still shows the
    /// flash but snaps it on/off (no fade) so the cue is preserved without motion.
    private func flashTranscriptBorder() {
        if reduceMotion {
            transcriptFlash = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                transcriptFlash = false
            }
        } else {
            withAnimation(.easeIn(duration: 0.12)) { transcriptFlash = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.easeOut(duration: 0.3)) { transcriptFlash = false }
            }
        }
    }

    // MARK: - Attach menu + subdued send (shared by both layouts)

    private var attachMenu: some View {
        AttachmentMenu(
            onPickLibrary: onPickLibrary,
            onTakePhoto: onTakePhoto,
            onPickFiles: onPickFiles,
            onSetUpFileTransfer: onSetUpFileTransfer,
            fileTransferAvailable: fileTransferAvailable
        )
        .disabled(sendSubmissionInProgress)
    }

    /// The SUBDUED secondary Send — usable only when attachments are staged with
    /// an empty draft (so the trailing mic stays the hero for voice-captioning).
    ///
    /// The SLOT exists whenever attachments are staged; only the button's
    /// visibility follows the draft. The slot therefore arrives and leaves with
    /// the attachment strip, on the bar's `.animation(value: attachments)`
    /// transaction, and the first keystroke merely fades the disc in place —
    /// it never reclaims the width, so the field does not jump while the
    /// trailing disc is morphing mic → send.
    @ViewBuilder
    private var subduedSendButton: some View {
        if hasAttachments {
            // Part 2: a SMALLER filled circle (the mic stays the hero, so this
            // attachment-only send sits subdued at 36pt with a neutral fill) —
            // keeps the iMessage idiom without competing with the mic.
            CaptureCircleButton(
                symbol: "arrow.up",
                fillColor: isSendDisabled ? AppColors.disabled : AppColors.textSecondary,
                diameter: 36,
                glyphSize: 15,
                isDisabled: isSendDisabled || !showsSubduedSend,
                accessibilityLabel: String(localized: LocalizedStringResource("composer.send", defaultValue: "Send")),
                action: sendTapped
            )
            .opacity(showsSubduedSend ? 1 : 0)
            .allowsHitTesting(showsSubduedSend)
            .accessibilityHidden(!showsSubduedSend)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsSubduedSend)
        }
    }

    // MARK: - Compact layout (iPhone / narrow iPad)

    private var compactLayout: some View {
        // [paperclip][field][trailing morph] (+ the conditional subdued send when
        // attachments are staged with an empty draft, so the mic stays the hero).
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu

            composerField

            subduedSendButton

            morphingTrailingButton
        }
    }

    /// Morphs between the mic control (empty draft), the send control (draft
    /// present), the held send (accepted, not yet live) and the in-flight Stop.
    /// MUST be a SINGLE `Button` wrapping a SINGLE `Image(systemName:)`:
    /// `.contentTransition(.symbolEffect(.replace))` only animates a glyph swap
    /// when the view identity is stable. An `if/else` over two distinct `Button`s
    /// (the earlier form) gave each branch its own identity, so SwiftUI replaced
    /// the whole view and the swap SNAPPED. With one Button + a resolved control,
    /// the action/color/disabled/label all switch while the identity holds, so
    /// the morph plays. `.animation(value:)` inside `CaptureCircleButton`
    /// supplies the transaction the content transition rides on (a `draft`
    /// keystroke is not itself an animated change).
    private var morphingTrailingButton: some View {
        trailingButton(compactTrailing)
    }

    /// What the trailing control IS on this body pass — glyph, tint, meaning,
    /// enabled — resolved in ONE place (`ComposerTrailingControlResolver`) so
    /// the four can never disagree and the priority order is unit-tested.
    private var compactTrailing: ComposerTrailingControl {
        trailingControl(for: .compact)
    }

    private var regularTrailing: ComposerTrailingControl {
        trailingControl(for: .regular)
    }

    private func trailingControl(for layout: ComposerTrailingLayout) -> ComposerTrailingControl {
        ComposerTrailingControlResolver.resolve(
            capture: capturePhase,
            hasDraft: hasDraft,
            hasAttachments: hasAttachments,
            isSubmitting: isSubmitting,
            canStop: isInFlight,
            isSendDisabled: isSendDisabled,
            isMicDisabled: isMicDisabled,
            layout: layout
        )
    }

    private var capturePhase: ComposerCapturePhase {
        switch recorder.state {
        case .idle: return .idle
        case .recording: return .recording
        case .processing: return .processing
        case .preparingVoice: return .preparingVoice
        case .error: return .error
        }
    }

    /// The send has been tapped and is not yet visibly live: this bar's own
    /// submission window (tap → local acceptance), then the VM's
    /// accepted-but-not-dispatched window (`isPreparingLiveTurn`). The control
    /// holds the Send look across both, so a send morphs exactly once — into
    /// the Stop — instead of walking through the mic.
    private var isSubmitting: Bool {
        sendSubmissionInProgress || viewModel?.isPreparingLiveTurn == true
    }

    /// Part 2: a FILLED 44pt circle + white glyph. `CaptureCircleButton`
    /// preserves the single-Button + single-Image identity so the morph
    /// (`.contentTransition(.symbolEffect(.replace))`) plays, and folds in the
    /// press-scale + recording halo (both Reduce-Motion aware).
    ///
    /// Deliberately ONE button: the safety comes from capturing `intent` here,
    /// not from splitting the control (which would lose the symbol-replacement
    /// animation).
    private func trailingButton(_ control: ComposerTrailingControl) -> some View {
        let intent = trailingIntent(for: control)
        return CaptureCircleButton(
            symbol: control.glyph.rawValue,
            fillColor: tintColor(control.tint),
            showsPulse: control.pulses,
            diameter: 44,
            glyphSize: 18,
            isDisabled: !control.isEnabled,
            accessibilityLabel: trailingAccessibilityLabel(for: control),
            action: { if let intent { trailingAction(intent) } }
        )
    }

    /// The DISC fill colour per role (the glyph itself is always white). The
    /// in-flight Stop is NEUTRAL (clearly tappable, NOT error-red / amber) to
    /// distinguish it from the recording-stop control.
    private func tintColor(_ tint: ComposerTrailingControl.Tint) -> Color {
        switch tint {
        case .brand: return AppColors.brandAmber
        case .error: return AppColors.error
        case .neutral: return AppColors.textSecondary
        case .inert: return AppColors.disabled
        }
    }

    /// What the trailing control MEANT on the body pass that built it. Captured
    /// rather than re-read inside the action closure, because this control
    /// morphs: a tap the user aimed at one meaning can run after it has become
    /// another, and on the compact bar there are THREE, so a late tap could
    /// cancel the turn it was starting or open the mic instead of sending.
    ///
    /// `.stop` carries the identity of the turn it was rendered for, so a stale
    /// tap cancels THAT turn or nothing — a live `isInFlight` re-check would
    /// still cancel a turn that started in the gap. See
    /// `cancelInFlight(expecting:)`. The held send resolves to NO intent: it
    /// has no token to carry and nothing safe to do.
    private enum TrailingIntent { case stop(token: Date?), send, mic }

    private func trailingIntent(for control: ComposerTrailingControl) -> TrailingIntent? {
        switch control.intent {
        case .stop: return .stop(token: viewModel?.inFlightTurnToken)
        case .send: return .send
        case .mic: return .mic
        case .none: return nil
        }
    }

    /// Acts on the CAPTURED intent. `.send` / `.mic` are safe to arrive late on
    /// their own — `sendTapped()` and `micButtonTapped()` re-check live state —
    /// so only `.stop`, the destructive one, needs the token.
    private func trailingAction(_ intent: TrailingIntent) {
        switch intent {
        case .stop(let token): viewModel?.cancelInFlight(expecting: token)
        case .send: sendTapped()
        case .mic: micButtonTapped()
        }
    }

    private func trailingAccessibilityLabel(for control: ComposerTrailingControl) -> String {
        switch control.glyph {
        case .stop where control.intent == .stop:
            return String(localized: "Stop")  // xcstrings: chat-ui
        case .send:
            return String(localized: LocalizedStringResource("composer.send", defaultValue: "Send"))
        case .stop, .mic, .working:
            return micAccessibilityLabel
        }
    }

    /// Drives the halo on the regular layout's persistent mic — true only
    /// while recording so the disc sits still otherwise.
    private var isRecordingActive: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    // MARK: - Regular layout (full-width iPad — macOS composer mirror)

    private var regularLayout: some View {
        // The macOS two-row card mirror (`MessageComposerBar.composerBox`):
        // a multi-line field on top, a control row below — [📎] —— Spacer ——
        // [🎤][⬆]. The mic moves from the row's far left (its compact position)
        // to next-to-send; paperclip stays far left. Send enables when there is
        // a draft OR a staged attachment (image-only is valid). The card itself
        // is the container, capped + centered on the shared chat axis.
        VStack(alignment: .leading, spacing: 10) {
            composerField

            HStack(spacing: 10) {
                attachMenu

                Spacer(minLength: 8)

                CaptureCircleButton(
                    symbol: regularMicSymbol,
                    fillColor: regularMicColor,
                    showsPulse: isRecordingActive,
                    diameter: 44,
                    glyphSize: 18,
                    isDisabled: isMicDisabled,
                    accessibilityLabel: micAccessibilityLabel,
                    action: micButtonTapped
                )

                regularTrailingButton
            }
        }
        .composerCardChrome()
        // The whole card is a focus target — the editable `TextField` is only as
        // tall as its text (a thin strip at the top), so the card's padding, the
        // gap above the control row, and the side margins were dead zones where a
        // tap didn't place the cursor. `.contentShape` makes that transparent area
        // hittable; the plain `.onTapGesture` is automatically lower-priority than
        // the TextField + the mic/send Buttons, so taps that land ON the text still
        // position the caret and taps on the controls still fire — only a tap that
        // misses every interactive child focuses the field (caret to end).
        // A11y: the focus-assist tap lives in a BEHIND-content `.background` hit
        // layer (never `.overlay`, which would steal taps from the field/buttons),
        // hidden from accessibility — VoiceOver users focus the TextField directly,
        // so the card-wide tap is a redundant sighted-only convenience. Putting it
        // on the card wrapper itself surfaced an unlabeled phantom tappable element
        // in the AX tree; hiding the wrapper would instead hide the field/buttons.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
                .accessibilityHidden(true)
        )
        .composerReadableWidth()
    }

    /// Filled-glyph symbol for the regular-layout persistent mic.
    private var regularMicSymbol: String {
        switch recorder.state {
        case .recording: return "stop.fill"
        case .processing, .preparingVoice: return "ellipsis"
        case .idle, .error: return "mic.fill"
        }
    }

    /// Disc fill for the regular-layout persistent mic.
    private var regularMicColor: Color {
        switch recorder.state {
        case .recording: return AppColors.error
        case .processing, .preparingVoice: return AppColors.disabled
        case .idle, .error: return AppColors.brandAmber
        }
    }

    /// The regular-width bar keeps a persistent mic to this control's left, so
    /// it morphs between send, the held send and the in-flight Stop — never the
    /// mic. Same resolver, same captured-intent safety as the compact bar.
    private var regularTrailingButton: some View {
        trailingButton(regularTrailing)
    }

    // MARK: - Shared text field

    private var composerField: some View {
        TextField(
            String(localized: LocalizedStringResource(
                "composer.placeholder.v2",
                defaultValue: "Message your AI"
            )),
            text: $draft,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($fieldFocused)
        // Explicit VoiceOver label (reuses the placeholder string) so the field
        // is announced even when empty / when the placeholder isn't read.
        .accessibilityLabel(LocalizedStringResource(
            "composer.placeholder.v2",
            defaultValue: "Message your AI"
        ))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Regular (iPad card) mode wraps the field in the elevated card already,
        // so the field's own fill is suppressed to avoid a card-in-card; compact
        // keeps the inner elevated fill verbatim.
        .background(usesRegularLayout ? Color.clear : AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Part 2d: a one-shot amber stroke flashes when a transcript lands.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.brandAmber, lineWidth: 2)
                .opacity(transcriptFlash ? 1 : 0)
                .allowsHitTesting(false)
        )
        // Fire the flash on a SUCCESSFUL capture landing: recorder goes
        // .processing → .idle (a failure goes .processing → .error and is
        // skipped). The brief amber pulse + the mic→send morph together cue
        // "your words are in the field — now tap Send."
        .onChange(of: recorderStatePhase) { old, new in
            // 2 = processing, 0 = idle. Only processing→idle is a landed transcript.
            guard old == 2, new == 0 else { return }
            flashTranscriptBorder()
        }
        // Hardware keyboards only (`.onKeyPress` does NOT fire for the on-screen
        // keyboard — soft Return is delivered via the text-input protocol and
        // inserts a newline at the cursor by default). `.onSubmit` is unreliable
        // with `axis:.vertical`, so we read the `KeyPress` modifiers directly.
        // ⌘Return = send; plain/Shift Return = newline. We insert the newline
        // EXPLICITLY rather than returning `.ignored`: on iOS 26 a hardware
        // Return that falls through is a no-op on a vertical TextField (verified
        // on-sim), so `.ignored` would lose the line break entirely.
        .onKeyPress(keys: [.return]) { keyPress in
            if keyPress.modifiers.contains(.command) {
                sendTapped()
                return .handled
            }
            draft += "\n"
            return .handled
        }
    }

    // MARK: - Send

    private func sendTapped() {
        let text = trimmedDraft
        let submittedDraft = draft
        // An attachment-only turn (empty caption) is valid; only block when
        // there is nothing to send or a turn/load is in flight. The host reads
        // the staged `attachments` binding itself and clears it after send.
        guard workbenchDestinationIsActive,
              hasSendableContent,
              !isSendDisabled else { return }
        sendSubmissionInProgress = true
        Task {
            let accepted = await onSendText(text)
            if accepted, draft == submittedDraft {
                draft = ""
            }
            sendSubmissionInProgress = false
        }
    }

    // MARK: - Mic (behaviour lifted from ContentView.micButtonTapped)

    private var isMicDisabled: Bool {
        switch recorder.state {
        case .processing, .preparingVoice: return true
        default: return false
        }
    }

    private var micAccessibilityLabel: String {
        switch recorder.state {
        case .recording:
            return String(localized: LocalizedStringResource("composer.mic.stop", defaultValue: "Stop recording"))
        default:
            return String(localized: LocalizedStringResource("composer.mic.start", defaultValue: "Start recording"))
        }
    }

    private func micButtonTapped() {
        guard workbenchDestinationIsActive else { return }
        switch recorder.state {
        case .idle, .error:
            // Part 2c: LIGHT impact on START (begin capture).
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            recorder.dismissError()
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.recordingStarted",
                defaultValue: "Recording started"
            ))
            Task {
                // On-device default is keyboard dictation — no model download,
                // no proactive gate. The rare "model not available for this
                // language" case surfaces reactively as the recorder's error
                // banner after capture, pointing to Settings → Voice.
                await recorder.startRecording()
            }
        case .recording:
            // Part 2c: MEDIUM impact on STOP (end capture → transcribe).
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcribing",
                defaultValue: "Transcribing"
            ))
            Task {
                let result = await recorder.stopAndUpload()
                await onVoiceResult(result)
            }
        case .processing, .preparingVoice:
            break
        }
    }
}
#endif
