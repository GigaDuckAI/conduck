// SPDX-License-Identifier: Apache-2.0

//  Conduck
//  GuidedGatewaySetupView.swift
//
//  Re-runnable "Guided setup" sheet reached from the Personal AI Settings
//  screen. It drives the redesigned LANE-AWARE gateway-setup machine so a
//  returning user can walk the same guided path the first-run flow uses, to add
//  / change a gateway any time — without re-running ALL of onboarding.
//
//  Two self-hosted LANES share one linear sub-flow (`GatewaySetupLane`):
//    .fullAgent — OpenClaw / Hermes (a full personal-AI server).
//    .custom    — any OpenAI-compatible endpoint the user runs.
//  Both lanes walk the SAME steps, differing only in copy and help-page context:
//    fork → readiness → helper → commands → success
//  The hosted-model (OpenRouter) lane is NOT a `GatewaySetupLane`; it has its
//  own dedicated single step (`HostedModelGatewayStepView`).
//
//  Step machine (`Step`):
//    primer             — first-run orientation (step 0): Conduck is the client,
//                         the AI is yours. Shown only for an eligible unconfigured
//                         first-timer (`showPrimer`); "Choose how to connect"
//                         advances to the chooser, "Set up manually" hands off to
//                         the Personal AI list (`onPrimerManual`).
//    chooser            — "where does your AI live?" fork (entry point when the
//                         primer is skipped).
//    fork(lane)         — create-a-code vs. already-have-a-code.
//    readiness(lane)    — pre-flight checklist before running the command. The
//                         custom lane offers a secondary escape into `adapter`.
//    adapter(lane)      — custom-lane escape hatch: keep a self-built AI and have
//                         an AI-coding tool build a small OpenAI-compatible adapter
//                         in front of it (copy-instructions brief). Continues to
//                         `helper`; Back returns to `readiness`.
//    helper(lane)       — install / trust the conduck-connect helper.
//    commands(lane)     — the command to run, then scan / paste the result.
//    success(ref)       — TERMINAL, and shared by EVERY path (self-hosted AND
//                         hosted): a gateway connected during THIS session. Carries
//                         only the ref — `GatewaySetupSuccessView` derives every line
//                         from it and branches on no lane, which is what lets the
//                         hosted lane (not a `GatewaySetupLane`) end on the same
//                         screen instead of vanishing under the user.
//    hostedModel        — OpenRouter API key + model (first-time setup, or the
//                         "you're set up — what to change?" manage card). A
//                         first-time Connect lands on `success`; the manage card's
//                         Done dismisses (nothing was connected THIS session).
//    hostedModelEdit    — the dedicated edit screen pushed from the manage card
//                         (API key + model, generously spaced). NOT an inline
//                         reveal; saving pops back to `hostedModel` (manage).
//
//  Pairing import is a CONTAINER-level sheet (`PairingImportSheet`), not a Step:
//  it is reachable from both the fork ("I already have a code") and the commands
//  step ("scan / paste"). A VERIFIED import sets `connectedRef` (the sheet's
//  eager `onConnected` hook); on sheet dismiss the machine advances to
//  `success(ref)`. A dismiss with no verified connection leaves the user where
//  they were.
//
//  Navigation is a back-stack (`backStack`) rather than a fixed chooser pivot:
//  Back pops the previous step, so deep lanes unwind one screen at a time. Reach
//  `success` and the stack is cleared — its only exits are Done (footer) + Close.
//
//  Modeled on `SetupGuideView`'s chrome (gradient bg, slide transitions, a
//  top-trailing Close / top-leading Back affordance) for visual consistency.
//
//  CRITICAL — live view-model: the step views are handed the CALLER's
//  `SettingsViewModel`, NOT a fresh one. A save here must reflect in the live
//  Settings screen behind the sheet, so the caller passes its own VM through.
//
//  Entry paths (`initialPath`):
//    - nil / .later → start on the PRIMER when eligible (`showPrimer`), else the
//                     CHOOSER (own gateways first, hosted last).
//    - .selfHosted  → jump straight to the full-agent lane fork.
//    - .hostedModel → jump straight to the hosted-model step.
//    - .quickConnect(target) → jump straight to the COMMANDS step in the target's
//                     lane (built-in → full-agent, custom → custom), with the
//                     pairing import LOCKED to that ref — a `.custom` target
//                     imports into the SAME custom gateway (updating it), never a
//                     freshly minted one. OpenRouter never quick-connects (no
//                     pairing lane); it maps defensively to the hosted step.
//
//  No manual-entry escape inside the guided lanes: the fork offers only the two
//  guided branches. Hand-editing a URL/token stays reachable OUTSIDE the guide —
//  the primer's "Set up manually" (`onPrimerManual`) and the Personal AI list's
//  gateway rows / "+ Add custom gateway" — so the guide never competes with itself.
//  The chooser's Custom card is hidden when `customLaneAvailable == false` (the
//  caller is at the custom-gateway cap).
//
//  Presentation is the CALLER's job: `.fullScreenCover` on iOS, a FULL-SCREEN
//  overlay on macOS. This view only builds the content + provides Close/Done
//  affordances that call the passed-in `onDismiss`.

import SwiftUI

/// Re-runnable guided gateway-setup sheet. Wraps the lane-aware setup steps in
/// Settings chrome and routes by `initialPath`. Finishing (a step's `proceed`,
/// or Close) calls `onDismiss`.
struct GuidedGatewaySetupView: View {
    /// The LIVE Settings view-model — passed through to every step view so saves
    /// reflect in the Settings screen behind the sheet (never a fresh VM).
    @Bindable var viewModel: SettingsViewModel

    /// Where to start. `nil`/`.later` opens the primer (when `showPrimer`) or the
    /// chooser; a concrete path jumps straight to that lane's first step (skipping
    /// both the primer and the chooser).
    let initialPath: GatewayPath?

    /// Whether to show the first-run PRIMER (step 0) ahead of the chooser.
    /// CALLER-RESOLVED from authoritative state ("unseen primer flag AND no
    /// configured gateway") — never re-derived from stale VM state in `init`. A
    /// configured user (adding a 2nd gateway) or a lane deep-link passes `false`.
    let showPrimer: Bool

    /// Dismiss the sheet — the caller resets its presentation binding here. Used
    /// by Close and a step's `proceed` (finish).
    let onDismiss: () -> Void

    /// The PRIMER's "Set up manually" hand-off — open the Personal AI list (NO
    /// lane, NO draft mint). The only manual escape in this flow. REQUIRED
    /// (non-optional) so a missing wiring is a compile error, not a silent
    /// "mark seen + stuck on the primer".
    let onPrimerManual: () -> Void

    /// Whether the custom lane is offered on the chooser. `false` when the caller
    /// is at the custom-gateway cap — the chooser then hides the Custom card.
    let customLaneAvailable: Bool

    /// Which screen is showing. The primer (step 0) precedes the chooser for an
    /// eligible unconfigured first-timer; otherwise the chooser is the entry point
    /// when `initialPath` is `nil`/`.later`; picking a card pushes a lane step.
    /// `internal` (not `private`) so the pure `initialStep(...)` decision is
    /// unit-testable via `@testable import`.
    enum Step: Hashable {
        case primer
        case chooser
        case fork(GatewaySetupLane)
        case headsUp(GatewaySetupLane)
        case readiness(GatewaySetupLane)
        case adapter(GatewaySetupLane)
        case helper(GatewaySetupLane)
        case commands(GatewaySetupLane)
        case success(RemoteAgentRef?)
        case hostedModel
        case hostedModelEdit
    }

    /// Top band the step content reserves for the Back / ✕ chrome this view
    /// overlays on top of it, plus a lead-in gap so the mascot never reads as
    /// level with the buttons. Derived from the chrome's own geometry below:
    /// its top padding (8 iOS / 16 macOS) + the 44pt circle + the gap.
    /// Published to the scaffold via `\.onboardingChromeInset`.
    private static var chromeInset: CGFloat {
        #if os(macOS)
        16 + 44 + 24
        #else
        8 + 44 + 20
        #endif
    }

    /// Current step, seeded from `initialPath` on first build.
    @State private var step: Step

    /// Visited steps, oldest → newest. Back pops this; non-empty == Back shows.
    @State private var backStack: [Step] = []

    /// Tracks navigation direction for the slide transition.
    private enum NavigationDirection { case forward, backward }
    @State private var navigationDirection: NavigationDirection = .forward

    /// Container-level pairing-import sheet (reachable from fork + commands).
    @State private var showingPairingImport = false

    /// Set by a VERIFIED-CONNECTED import (`PairingImportSheet.onConnected`, which
    /// fires only when the gateway stage passed — not on a mere save or an
    /// unresolved cert). Consumed on sheet dismiss to advance to `success(ref)`.
    /// `nil` = no connected import (stay put — a failed import shows the sheet's own
    /// recovery, never a false "Connected").
    @State private var connectedRef: RemoteAgentRef?

    init(
        viewModel: SettingsViewModel,
        initialPath: GatewayPath?,
        onDismiss: @escaping () -> Void,
        onPrimerManual: @escaping () -> Void,
        showPrimer: Bool = false,
        customLaneAvailable: Bool = true
    ) {
        self.viewModel = viewModel
        self.initialPath = initialPath
        self.showPrimer = showPrimer
        self.onDismiss = onDismiss
        self.onPrimerManual = onPrimerManual
        self.customLaneAvailable = customLaneAvailable
        _step = State(initialValue: GuidedGatewaySetupView.initialStep(initialPath: initialPath, showPrimer: showPrimer))
    }

    /// Pure entry-step decision — testable without a View (`@testable import`).
    /// The primer precedes the chooser ONLY for an eligible unconfigured first-timer
    /// (`showPrimer`, resolved by the caller); a lane deep-link jumps straight to
    /// that lane and never shows the primer or the chooser.
    static func initialStep(initialPath: GatewayPath?, showPrimer: Bool) -> Step {
        switch initialPath {
        case .selfHosted:   return .fork(.fullAgent)
        case .hostedModel:  return .hostedModel
        case .quickConnect(let target):
            // Straight to the Commands step in the target's lane. OpenRouter has
            // no pairing lane at all — a (never-constructed) hosted target maps
            // defensively to its own step instead of a meaningless command screen.
            switch target {
            case .builtin(.openrouter): return .hostedModel
            case .builtin:              return .commands(.fullAgent)
            case .custom:               return .commands(.custom)
            }
        case .later, .none: return showPrimer ? .primer : .chooser
        }
    }

    /// The ref a `.quickConnect` entry LOCKS the pairing import to — threaded into
    /// `PairingImportSheet.lockedTarget`, whose plan then refuses kind-mismatched
    /// codes and lands a custom code on this SAME custom ref (no fresh mint).
    /// nil for every other entry (free-target import), and for the defensive
    /// OpenRouter mapping (the hosted step never opens the import sheet).
    private var quickConnectTarget: RemoteAgentRef? {
        guard case .quickConnect(let target) = initialPath else { return nil }
        if case .builtin(.openrouter) = target { return nil }
        return target
    }

    var body: some View {
        ZStack {
            SetupAtmosphereBackground()

            stepContent
                // Every guided step is a WIZARD step, not a first-run ceremony
                // beat: pin the content to the top so the mascot + title land at
                // the same y on all ten steps (centering made that y a function
                // of body-text height — the mascot visibly jumped step to step),
                // and reserve the band the Back / ✕ circles below are overlaid
                // into, so tall steps can't render level with them. On the big
                // canvases (macOS / iPad-regular) `.top` also opts the scaffold
                // into its height-capped PANEL: the whole step (content + pinned
                // footer) is bounded and centered below the chrome band, so a
                // tall window never strands the CTA at its bottom edge.
                .environment(\.onboardingStepPlacement, .top)
                .environment(\.onboardingChromeInset, Self.chromeInset)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: navigationDirection == .forward ? .trailing : .leading)
                        .combined(with: .opacity),
                    removal: .move(edge: navigationDirection == .forward ? .leading : .trailing)
                        .combined(with: .opacity)
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Back affordance — shown whenever there's a previous step to unwind
            // to. The back-stack is empty on the entry step and after reaching
            // `success` (which clears it), so Close is then the only exit.
            .overlay(alignment: .topLeading) {
                if !backStack.isEmpty {
                    Button(action: back) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textEmphasis)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(AppColors.backgroundSecondary))
                    }
                    // Circular wash to match the drawn circle: a rounded-square
                    // one would tint only the corner slivers outside it.
                    .pointerIconButton(size: 44, shape: .circle)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "settings.guidedSetup.back",
                        defaultValue: "Go Back"
                    )))
                    #if os(macOS)
                    .padding(.top, 16)
                    .padding(.leading, 24)
                    #else
                    .padding(.top, 8)
                    .padding(.leading, 16)
                    #endif
                }
            }
            // Close affordance — always available to bail out of the guide.
            .overlay(alignment: .topTrailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textEmphasis)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(AppColors.backgroundSecondary))
                }
                // Circular wash — same reason as the Back circle above.
                .pointerIconButton(size: 44, shape: .circle)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "settings.guidedSetup.close",
                    defaultValue: "Close"
                )))
                #if os(macOS)
                .padding(.top, 16)
                .padding(.trailing, 24)
                #else
                .padding(.top, 8)
                .padding(.trailing, 16)
                #endif
            }
        }
        // Pairing import is a CONTAINER-level sheet, not a Step — it is reachable
        // from both the fork ("I already have a code") and the commands step
        // ("scan / paste"). A VERIFIED connection stores the ref via
        // `onConnected`; when the sheet dismisses with a ref set, advance to the
        // shared success step. A dismiss with no verified connection leaves the
        // user where they were.
        //
        // `onImported` is deliberately NOT wired: a bare commit is not enough to
        // show a success screen that claims the gateway works, and the editor
        // behind this cover learns about the commit from
        // `SettingsViewModel.remoteAgentCommitEpoch` (bumped inside
        // `saveRemoteAgent`, so it covers this sheet AND the hosted-model step),
        // not from a callback this view would have to relay.
        .sheet(isPresented: $showingPairingImport, onDismiss: {
            // Advance to success ONLY on a verified connection (`connectedRef`),
            // carrying the ref so the success screen names the gateway + its
            // default/file-sharing state. A failed import leaves `connectedRef`
            // nil → stay put (the sheet showed its own recovery). A certificate
            // refusal is one such failure: it is terminal and ends the import
            // before stage 1, never a pending state this flow waits on.
            if let ref = connectedRef {
                connectedRef = nil
                goToSuccess(ref)
            }
        }) {
            PairingImportSheet(
                viewModel: viewModel,
                lockedTarget: quickConnectTarget,
                onConnected: { connectedRef = $0 },
                // "Open manual settings" after a failed import: close the whole
                // guided flow back to the Personal AI list, where the just-saved
                // (failing) gateway is now a row the user can open + fix. No new
                // draft is minted (that would orphan the saved config).
                onOpenManualSettings: { onDismiss() }
            )
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .primer:
            // Step 0 — the first-run orientation ("you bring the AI"). Marking it
            // seen is SYNCHRONOUS (commits before we navigate/dismiss, so a rapid
            // reopen can't beat an async write and re-show it). Only "Choose how to
            // connect" / "Set up manually" mark it — the ✕ Close (onDismiss) never
            // does, so a Close-without-choosing re-shows it next time.
            GatewayPrimerStepView(
                onChoose: { SettingsManager.markGatewayPrimerSeen(); goTo(.chooser) },
                onManual: { SettingsManager.markGatewayPrimerSeen(); onPrimerManual() }
            )

        case .chooser:
            // The "where does your AI live?" fork. Full-agent / custom push that
            // lane's fork step IN this sheet; hosted pushes the hosted step. The
            // Custom card is hidden when the caller is at the custom-gateway cap
            // (`customLaneAvailable == false`). Bailing out is the sheet's
            // top-trailing Close — the chooser carries no "set up later" link.
            GatewayChooserStepView(
                onFullAgent: { goTo(.fork(.fullAgent)) },
                onCustom: customLaneAvailable ? { goTo(.fork(.custom)) } : nil,
                onHostedModel: { goTo(.hostedModel) }
            )

        case .fork(let lane):
            // Lane fork: create a fresh code (walk heads-up → readiness → helper →
            // commands), or use a code you already have (open the import sheet).
            // The heads-up beat is phone/iPad-only — macOS forks straight to
            // readiness (a Mac user is already at a computer), so the step never
            // enters the macOS back-stack.
            GatewaySetupForkView(
                lane: lane,
                onCreateCode: {
                    #if os(macOS)
                    goTo(.readiness(lane))
                    #else
                    goTo(.headsUp(lane))
                    #endif
                },
                onHaveCode: { connectedRef = nil; showingPairingImport = true }
            )

        case .headsUp(let lane):
            // Early expectation-setter (iOS/iPadOS only): commands are coming and
            // a computer is the comfortable place to run them — the lane-correct
            // site page has everything ready to copy. Replaces the per-step
            // "easier from a computer" cards the adapter and commands steps used
            // to carry.
            GatewayHeadsUpView(lane: lane, proceed: { goTo(.readiness(lane)) })

        case .readiness(let lane):
            // Pre-flight checklist before running the conduck-connect command. The
            // custom lane also offers an escape to the adapter step (for a user
            // whose self-built AI is not an HTTP server yet); the full-agent lane
            // passes nil, so its footer is unchanged.
            GatewayReadinessView(
                lane: lane,
                proceed: { goTo(.helper(lane)) },
                onAdapterEscape: lane == .custom ? { goTo(.adapter(lane)) } : nil
            )

        case .adapter(let lane):
            // Escape hatch (custom lane only): keep your own AI and have your
            // AI-coding tool build a small OpenAI-compatible adapter in front of it.
            // Back returns to readiness; continue advances to the helper step.
            GatewayAdapterBriefView(proceed: { goTo(.helper(lane)) })

        case .helper(let lane):
            // Install / trust the conduck-connect helper.
            GatewayHelperTrustView(lane: lane, proceed: { goTo(.commands(lane)) })

        case .commands:
            // The command to run, then scan / paste the resulting setup code
            // (the container-level import sheet does the actual import).
            GatewayCommandsView(
                onScanOrPaste: { connectedRef = nil; showingPairingImport = true }
            )

        case .success(let ref):
            // A gateway CONNECTED during THIS session — a verified pairing import
            // (self-hosted lanes) or a completed OpenRouter save (hosted). The ref is
            // carried in so the screen names it. Only exits are the footer Done
            // (`proceed`) and the top-trailing Close.
            GatewaySetupSuccessView(
                viewModel: viewModel,
                connectedRef: ref,
                proceed: onDismiss
            )

        case .hostedModel:
            // Hosted-model (OpenRouter) detail. The screen classifies itself after
            // hydration: first-time → editable setup body; already-configured →
            // a "you're set up — what to change?" manage card.
            //   onConnected — FIRST-TIME connect only, and only once `saveRemoteAgent`
            //     COMPLETED (never on a bare probe pass): advance to the shared
            //     success screen, so the hosted lane confirms itself like every other
            //     lane instead of silently dismissing.
            //   proceed (onDismiss) — the manage card's Done: nothing connected this
            //     session, so there is nothing to confirm; close the flow.
            //   onEdit (manage only) — push the dedicated edit step.
            HostedModelGatewayStepView(
                viewModel: viewModel,
                proceed: onDismiss,
                onConnected: { goToSuccess(.builtin(.openrouter)) },
                onEdit: { goTo(.hostedModelEdit) }
            )

        case .hostedModelEdit:
            // The dedicated edit screen pushed from the manage card. On a
            // successful save it pops back to `.hostedModel` (the manage card,
            // which remounts + re-probes). Cancel = the top-leading Back chrome.
            HostedModelEditStepView(
                viewModel: viewModel,
                onSaved: { back() }
            )
        }
    }

    // MARK: - Navigation

    /// Forward navigation: remember the current step, then slide to `next`.
    private func goTo(_ next: Step) {
        backStack.append(step)
        navigationDirection = .forward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = next
        }
    }

    /// Back: pop the most recent step off the stack and slide back to it. No-op
    /// when the stack is empty (the Back chrome is hidden in that case).
    private func back() {
        guard let previous = backStack.popLast() else { return }
        navigationDirection = .backward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = previous
        }
    }

    /// Advance to the shared success step and clear the back-stack — success is a
    /// terminal screen whose only exits are the footer Done and Close. Called from
    /// every path that connects a gateway: the pairing-import sheet (self-hosted
    /// lanes) and the hosted step's completed save.
    private func goToSuccess(_ ref: RemoteAgentRef?) {
        navigationDirection = .forward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = .success(ref)
        }
        backStack.removeAll()
    }
}

#Preview {
    GuidedGatewaySetupView(
        viewModel: SettingsViewModel(),
        initialPath: nil,
        onDismiss: {},
        onPrimerManual: {},
        showPrimer: true
    )
}
