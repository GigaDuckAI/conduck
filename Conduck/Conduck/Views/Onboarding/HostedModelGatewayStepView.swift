// SPDX-License-Identifier: Apache-2.0

// Conduck
// HostedModelGatewayStepView.swift
//
// Guided gateway-setup — the HOSTED-MODEL branch (OpenRouter), reached when the
// user picks "Hosted cloud model" on `GatewayChooserStepView`. The no-server
// on-ramp: get an OpenRouter key onto the device + pick a model. ONLY used
// inside the guided-setup flow (`GuidedGatewaySetupView`); onboarding no longer
// mounts it.
//
// TWO WAYS TO SUPPLY THE KEY, ONE CREDENTIAL AT A TIME. "Sign in with
// OpenRouter" opens the system web-auth sheet, and the key OpenRouter mints
// comes back through a private-use callback scheme (the PKCE machinery lives in
// `OpenRouterOAuth`; the staging lives in `SettingsViewModel+OpenRouterOAuth`).
// Pasting a key stays on the same screen as the equal alternative — a user who
// already has a key, or whose sign-in failed, is never stranded. The screen
// enforces a SINGLE credential source: staging a sign-in clears the typed buffer
// and any voice-key reuse; typing, or choosing the voice key, discards the
// staged sign-in atomically. Precedence at Connect reads the same way top to
// bottom: signed-in key → typed key → voice key → stored key.
//
// The signed-in key is never held here. This view holds a HANDLE; the raw key
// stays in the view model and is resolved at Save/Test time, exactly as the
// voice-key reuse is. The handle is discarded on disappear, so backing out of
// setup leaves nothing staged — but it does NOT undo the key at OpenRouter,
// which the exchange created for real. So every discard SNAPSHOTS that key's
// settings URL first and keeps offering it: dropping the handle destroys the
// only copy of the key and with it the ability to compute the digest that
// addresses it, and a user who abandons a sign-in would otherwise never be told
// a live key is now spending their credit. The digest is not a credential, so it
// can outlive the key it points at.
//
// UNSTAGING RETRACTS THE VERDICT. Every credential-source switch on this screen
// clears `remoteAgentValidationStates[ref]`, because a verdict earned by one
// credential describes nothing once another is in play — and the sign-in path
// auto-probes, so a staged sign-in reaches "API key valid." without the user
// pressing anything.
//
// TWO ENTRY MODES, classified ONCE after `refreshRemoteAgentState()` hydrates the
// VM (classifying before hydration would misread a cold `configuredRemoteAgentRefSet`
// and treat a configured user as first-time):
//   • `.setup`  — OpenRouter NOT configured. First-time body: key + model +
//     Validate key + Connect. A successful Connect calls `onConnected` → the flow's
//     SHARED success screen (`GatewaySetupSuccessView`), the same confirmation every
//     self-hosted lane ends on. Partial-sync banner appears only when a synced model
//     is present with no stored key.
//   • `.manage` — OpenRouter already configured (second-time). A confirmation card
//     ("OpenRouter is set up" / "…is connected" once a probe passes) with the
//     current model + masked key, plus a "Change model or API key" button that
//     pushes the dedicated edit step (`HostedModelEditStepView`) — editing is NOT
//     inline here. Nothing connected THIS session, so there is nothing to confirm:
//     Done dismisses (`proceed`) rather than routing to success.
//
// ADVANCE IS KEYED ON THE SAVE, NEVER THE PROBE. `onConnected` fires only when
// `saveRemoteAgent` returned true — a passing `/v1/key` probe whose save then fails
// (e.g. the unsigned-sim Keychain) must never push the user onto a screen that says
// "Connected". The probe proves the KEY; only the save proves the CONFIG.
//
// The full manual gateway editor (`RemoteAgentConfigBody`, reached from the
// Settings list) is a SEPARATE surface — this screen never routes to it.
//
// Privacy: a TYPED key lives only in `pendingKey` + the SecureField; it flows out
// exactly once via `saveRemoteAgent` (→ Keychain), then cleared. A SIGNED-IN key
// never enters this View at all — only its handle and a masked tail. The
// quiet probe validates the STORED key via `retestRemoteAgent` (raw key never
// enters the View). Never logged, printed, or echoed in error messages.

import AuthenticationServices
import SwiftUI

struct HostedModelGatewayStepView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Leave the hosted step with nothing to confirm. In guided setup this is the
    /// container's `onDismiss` — it closes the whole flow. Called ONLY by manage
    /// mode's Done; a first-time connect goes to `onConnected` instead.
    let proceed: () -> Void

    /// Setup mode: the gateway is SAVED and connected — the container advances to
    /// the shared success screen. REQUIRED (non-optional) so a missing wiring is a
    /// compile error, not a silent "saved, but the user is left staring at the form
    /// with no confirmation."
    let onConnected: () -> Void

    /// Manage mode: the user tapped "Change model or API key" — the container
    /// pushes the dedicated `.hostedModelEdit` step. Unused in setup (defaults
    /// to a no-op so any setup-only mount compiles).
    let onEdit: () -> Void

    init(
        viewModel: SettingsViewModel,
        proceed: @escaping () -> Void,
        onConnected: @escaping () -> Void,
        onEdit: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.proceed = proceed
        self.onConnected = onConnected
        self.onEdit = onEdit
    }

    /// The OpenRouter built-in ref — this whole step configures exactly it.
    private let ref = RemoteAgentRef.builtin(.openrouter)

    /// First-time vs. returning. `nil` until `refreshRemoteAgentState()` lands;
    /// the body shows a placeholder until then so a cold VM can't misclassify.
    private enum EntryMode { case setup, manage }
    @State private var entryMode: EntryMode?

    /// Local SecureField buffer for the API key (setup mode). Flows out once via
    /// `saveRemoteAgent`, then cleared.
    @State private var pendingKey: String = ""

    /// Voice-key reuse is STAGED, not persisted: tapping the callout only sets
    /// this flag, and Connect commits key + model together via
    /// `StagedRemoteAgentToken.reuseVoiceKey` (the VM resolves the key from the
    /// Keychain at save/probe time — it never enters this View). Persisting on
    /// tap would store a key for a gateway that still lacks its required model.
    @State private var useVoiceKey = false

    /// The handle of the OpenRouter sign-in whose key is STAGED right now, or
    /// nil when none is. The View never sees the key itself — only this handle,
    /// which it presents to the view model to probe, save, deep-link, discard or
    /// render as a mask.
    @State private var oauthHandle: UUID?

    /// True from the tap that opens the web-auth sheet until the exchange (and
    /// its auto-probe) settles. Disables every other credential control so an
    /// in-flight sign-in cannot be raced by a Validate / Connect / source switch.
    @State private var signingIn = false

    /// The sign-in in flight, bound to THIS step. Cancelled on disappear and
    /// whenever a new sign-in starts, so a completion that lands after the user
    /// moved on is dropped rather than staging a key nobody is looking at.
    @State private var signInTask: Task<Void, Never>?

    /// The saved gateway key's OpenRouter settings page (manage mode). Resolved
    /// asynchronously because it reads the Keychain VM-side; nil hides the row.
    @State private var storedKeySettingsURL: URL?

    /// The OpenRouter page for a signed-in key this step DISCARDED without
    /// saving. Snapshotted at the moment of discard, because the vault entry it
    /// is computed from is gone a line later — and the key it addresses is real
    /// and still spending the user's credit. Nil hides the note.
    @State private var discardedKeyURL: URL?

    /// Presents the OpenRouter authorization page. SwiftUI's own session — no
    /// hand-rolled `ASWebAuthenticationSession` and no presentation anchor to
    /// keep correct across iPhone, iPad and Mac windows.
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    /// Lets `.onSubmit` resign focus — Return is the dismiss/submit affordance.
    @FocusState private var keyFieldFocused: Bool

    /// Local filter for the (large) OpenRouter model catalog — buffer-only.
    @State private var modelFilter: String = ""

    /// True only while the primary save (validate→save) is in flight.
    @State private var connecting = false

    /// True only while a "Validate key" (validate-only) probe is in flight. Set
    /// SYNCHRONOUSLY at tap so a rapid double-tap can't launch two probes.
    @State private var validatingKey = false

    /// Quiet entry-probe (manage mode) outcome. `.ok` upgrades the tick + title to
    /// "connected"; `.failed` shows a non-blocking Retry. Editing/saving cancels
    /// it so a stale stored-key probe can't paint a fresh edit as verified.
    private enum ProbeState: Equatable { case idle, checking, ok, failed }
    @State private var probeState: ProbeState = .idle
    @State private var probeTask: Task<Void, Never>?

    /// The OpenRouter descriptor — supplies all policy (placeholder, required
    /// model, fixed URL). Looked up once.
    private var descriptor: RemoteAgentBackendMetadata {
        RemoteAgentBackendRegistry.lookup(id: .openrouter)
    }

    /// The configured row matching THIS ref, if any — drives the manage card name.
    private var connectedRow: PersonalAIRow? {
        viewModel.personalAIRows.first { $0.ref == ref && $0.configured }
    }

    /// Whether OpenRouter's connection probe PASSED this session (live `/v1/key`).
    private var isVerified: Bool { viewModel.remoteAgentLiveValidated.contains(ref) }

    /// True once a token is stored for this ref (masked tail present). Lets manage
    /// mode save a model-only change and lets setup mode Connect after key reuse.
    private var hasStoredKey: Bool { viewModel.remoteAgentMaskedTails[ref] != nil }

    /// Cross-device PARTIAL sync: the non-secret model arrived (iCloud KVS) but the
    /// secret key has NOT — only meaningful in `.setup` (manage means configured).
    private var isPartiallySynced: Bool {
        entryMode == .setup
            && !hasStoredKey
            && !(viewModel.remoteAgentModelStrings[ref] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Validation state for this ref (read from the dict).
    private var validationState: KeyValidationState {
        viewModel.remoteAgentRowState(for: ref)
    }

    /// Two-way binding to the per-ref model buffer.
    private var modelBinding: Binding<String> {
        Binding<String>(
            get: { viewModel.remoteAgentModelStrings[ref] ?? "" },
            set: { viewModel.remoteAgentModelStrings[ref] = $0 }
        )
    }

    /// Honesty-aware title: "connected" ONLY once a probe passed this session;
    /// otherwise "set up" (a saved config + the `/v1/key` probe prove the KEY, not
    /// model validity or chat completion).
    private var titleText: LocalizedStringKey {
        switch entryMode {
        case .manage:
            return (probeState == .ok || isVerified)
                ? "OpenRouter is connected"   // xcstrings: hosted-model
                : "OpenRouter is set up"      // xcstrings: hosted-model
        default:
            return "Use a hosted model"       // xcstrings: hosted-model
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image("conduck-scientist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            Text(titleText)
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            switch entryMode {
            case .none:
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            case .setup:
                setupBody
            case .manage:
                manageBody
            }
        }
        .onboardingStepLayout {
            footer
        }
        .onChange(of: keyFieldFocused) { _, focused in
            // Freeze the pre-filled buffers once the user starts entering
            // credentials so a late iCloud-KVS reload can't revert them.
            if focused { viewModel.editorHasUnsavedChanges = true }
        }
        .onChange(of: pendingKey) { _, _ in
            // The verdict described the PREVIOUS key. The moment the USER edits, it
            // describes nothing on screen — so retract it rather than leave a red
            // line accusing a key that may now be correct. Mirrors the edit step.
            // `remoteAgentLiveValidated` is deliberately NOT cleared here (the edit
            // step doesn't either — one divergence, not two).
            //
            // `connecting` excludes the one write that is NOT a user edit: a
            // successful `connect()` blanks `pendingKey` after the save, and
            // without this guard that blanking would immediately stomp the `.valid`
            // the save just wrote back to `.unset`.
            guard !connecting else { return }
            viewModel.remoteAgentValidationStates[ref] = .unset
            // A typed character while another credential source is staged
            // switches back to manual — the field is authoritative the moment the
            // user touches it. Both switches are atomic with the keystroke, so
            // there is never an instant where two sources are live.
            if !pendingKey.isEmpty {
                if useVoiceKey { useVoiceKey = false }
                discardStagedSignIn()
            }
        }
        .onChange(of: useVoiceKey) { _, _ in
            // Staging/unstaging swaps WHICH credential is in play: a verdict
            // earned by the other one describes nothing on screen. Mirrors the
            // typed-key retraction above (`connecting` excludes the post-save
            // teardown writes).
            guard !connecting else { return }
            viewModel.remoteAgentValidationStates[ref] = .unset
            viewModel.noteRemoteAgentSecretEdited(for: ref)
        }
        .onDisappear {
            probeTask?.cancel()
            // The sign-in is bound to THIS step: cancel it, and drop the key it
            // staged. Unsaved by definition (a save consumes the handle), so
            // nothing persisted is lost — and the discard is handle-scoped, so a
            // late teardown cannot reach a sign-in some other step started.
            signInTask?.cancel()
            discardStagedSignIn()
            // Only setup raises the dirty fence here (via `keyFieldFocused`).
            // Manage never sets it, so it must NOT clear it on disappear —
            // otherwise the manage→edit push could stomp the edit step's fence.
            if entryMode == .setup { viewModel.editorHasUnsavedChanges = false }
        }
        .task {
            // Hydrate FIRST, then classify — a cold `configuredRemoteAgentRefSet`
            // would otherwise misread a configured user as `.setup`.
            await viewModel.refreshRemoteAgentState()
            let configured = viewModel.isRemoteAgentConfigured(ref)
            entryMode = configured ? .manage : .setup
            if configured {
                runQuietProbe()
                // Manage-card deep link. Reads the Keychain VM-side and returns a
                // URL built from the key's digest — the key itself never crosses.
                storedKeySettingsURL = await viewModel.openRouterStoredKeySettingsURL()
            }
        }
    }

    // MARK: - Setup body (.setup — first-time / partial-sync)

    @ViewBuilder
    private var setupBody: some View {
        // ONE form column. Everything below the title — the partial-sync banner,
        // the intro prose, the sign-in pill, the docs link, the reuse callout, the
        // credential stack and the model picker — shares the footer CTA's width
        // and centre line through `guidedFormRail()`, the rail the edit step is
        // built on. Sizing the pieces separately (`buttonMaxWidth` caps with mixed
        // centre/leading alignment inside a wider 32pt content rail) rendered
        // THREE columns on macOS: the pill and key field centred at 400, the model
        // field pinned leading at 400, the footer buttons at 344.
        VStack(alignment: .leading, spacing: 20) {
            if isPartiallySynced {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(AppColors.textSecondary)
                    // xcstrings: hosted-model
                    Text("Synced from your other device — just add your OpenRouter key to finish.")
                        .onboardingScaledFont(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCardBackground()
            }

            // xcstrings: hosted-model
            Text("Sign in with OpenRouter, or paste an API key — then pick a model. Your messages go straight to OpenRouter, no middleman.")
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The one-click path, above the field it replaces. Hidden entirely when
            // another credential source is already staged (that row supersedes it)
            // or when this build claims no callback scheme — an action that cannot
            // come back is worse than no action.
            if oauthHandle == nil, !useVoiceKey, viewModel.openRouterSignInAvailable {
                signInSection
            }

            // Quiet grey link (the primer's tertiary-docs treatment) — a passive
            // exit to the OpenRouter site, not a competing action: the screen's one
            // blue is the Connect fill in the footer. Placed BELOW the sign-in
            // button because it serves the PASTE path: read first, it sends the user
            // off-app to fetch a key the button two lines down would have made for
            // them, and it contradicts that button's own "nothing to copy".
            Link(destination: descriptor.docsURL) {
                HStack(spacing: 4) {
                    Text("Get an OpenRouter API key") // xcstrings: hosted-model
                    Image(systemName: "arrow.up.right")
                        .onboardingScaledFont(.caption)
                }
                .onboardingScaledFont(.subheadline, weight: .semibold)
                .foregroundStyle(AppColors.textSecondary)
            }
            .tint(AppColors.textSecondary)
            .pointerLink()
            .frame(maxWidth: .infinity, alignment: .leading)

            // Offer to reuse a voice OpenRouter key when one exists and the gateway has
            // NO stored key yet. Tapping STAGES the reuse (flag only — nothing is
            // persisted): the callout hides, the key field flips to a "voice key
            // selected" row, and Connect commits key + model together. Hidden while a
            // sign-in is staged — one credential source on screen at a time.
            if entryMode == .setup,
               viewModel.openRouterVoiceKeyAvailable, !hasStoredKey, !useVoiceKey, oauthHandle == nil {
                OpenRouterKeyReuseCallout(
                    title: LocalizedStringResource(
                        "settings.remoteAgent.openRouter.reuse.title",
                        defaultValue: "You've already set up OpenRouter for voice. Reuse that API key here?"
                    ),
                    buttonTitle: LocalizedStringResource(
                        "settings.remoteAgent.openRouter.reuse.button",
                        defaultValue: "Use my voice key"
                    ),
                    action: {
                        // No staging swap while a probe/save/sign-in is mid-flight
                        // against the current credential intent.
                        guard !connecting, !validatingKey, !signingIn else { return }
                        // Atomically the other way round from the typed-key switch:
                        // choosing the voice key drops any signed-in key first, so
                        // the two can never both be staged.
                        discardStagedSignIn()
                        useVoiceKey = true
                        // Freeze the pre-filled buffers (same fence the key field's
                        // focus raises) so a late iCloud-KVS reload can't revert the
                        // in-progress setup under the user.
                        viewModel.editorHasUnsavedChanges = true
                    }
                )
                // Neutral tint: the callout's bordered button inherits it, so the pill
                // reads as a quiet secondary here instead of a second blue competing
                // with Connect. (Settings callsites keep their own default tint.)
                .tint(AppColors.textPrimary)
                // Every other credential control on this screen carries the same
                // gate. Without it the pill stays live-looking and no-ops on macOS,
                // where the auth window is separate and the app window stays
                // clickable. The in-action guard remains as the backstop.
                .disabled(connecting || validatingKey || signingIn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onboardingCardPadding()
                .glassCardBackground()
            }

            VStack(spacing: 12) {
                // The staged row sits ABOVE the key field; the SecureField itself
                // stays PERMANENTLY mounted with an unchanged modifier chain. On
                // macOS a SecureField is an out-of-process NSSecureTextField, and
                // structurally mounting/unmounting it under a state toggle triggers
                // `_NSDetectedLayoutRecursion` / ViewBridge termination (see
                // SecretEntrySheet's header + the CustomSTTConfigBody history).
                // Typing in the field unstages both (see `.onChange(of:
                // pendingKey)`), so the credential sources can't disagree.
                //
                // The orphan note LEADS the stack: it is not a credential source at
                // all, it is what is left over after one was abandoned, and it has
                // to stay visible while the user works with whichever source
                // replaced it.
                if let discardedKeyURL {
                    discardedKeyNote(url: discardedKeyURL)
                }
                if let oauthHandle {
                    stagedSignInRow(handle: oauthHandle)
                }
                if useVoiceKey {
                    stagedVoiceKeyRow
                }
                keyField(placeholder: descriptor.tokenPlaceholder)
                // The verdict sits with the KEY it describes — above the (tall)
                // model picker, not below it. A sign-in failure is written into this
                // same row, and below the picker it lands off-screen on a phone.
                validationStatusRow
                OpenRouterModelPickerField(
                    selection: modelBinding,
                    filter: $modelFilter,
                    suggestions: viewModel.remoteAgentModelSuggestions[ref] ?? []
                )
            }
        }
        .guidedFormRail()
    }

    // MARK: - Manage body (.manage — second-time, already configured)

    /// Card + a "Change model or API key" button that pushes the dedicated edit
    /// step. Editing is NOT inline — `onEdit()` is the container's `goTo`.
    @ViewBuilder
    private var manageBody: some View {
        // Same rail as the setup body and the edit step this hands off to, so the
        // summary card here and the edit step's card are the one width.
        VStack(alignment: .leading, spacing: 20) {
            manageCard

            Button {
                onEdit()
            } label: {
                // Neutral disclosure row (not blue): the screen's one blue is the
                // filled Done in the footer; the chevron carries the "this navigates".
                HStack {
                    Text("Change model or API key") // xcstrings: hosted-model
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .onboardingScaledFont(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Full-width disclosure row: the whole band is live and washes on hover.
            // The label keeps its own frame/contentShape — off macOS this style IS
            // `.plain`, and this row is a free-standing VStack child, not a `List`
            // row, so nothing else would make the `Spacer()` gap hittable there.
            .settingsRowButton()
            .accessibilityIdentifier("settings.remoteAgent.hosted.change")
        }
        .guidedFormRail()
    }

    /// The connected confirmation: honesty-aware tick, current model + masked key,
    /// and the quiet-probe status line.
    private var manageCard: some View {
        let verified = probeState == .ok || isVerified
        let model = (viewModel.remoteAgentModelStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: verified ? "checkmark.seal.fill" : "checkmark.circle")
                    .foregroundStyle(verified ? AppColors.success : AppColors.textSecondary)
                Text(verbatim: connectedRow?.displayName ?? descriptor.displayName)
                    .onboardingScaledFont(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !model.isEmpty {
                summaryRow(label: "Model", value: model) // xcstrings: hosted-model
            }
            if let tail = viewModel.remoteAgentMaskedTails[ref] {
                summaryRow(label: "Key", value: tail) // xcstrings: hosted-model
            }

            // xcstrings: hosted-model
            Text("Messages go straight to OpenRouter, no middleman.")
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Deep link to THIS key's page at OpenRouter — spend, limits,
            // deletion. Addressed by the key's own digest, computed VM-side, so
            // the link exists only while a key is actually stored (nil hides it).
            if let storedKeySettingsURL {
                Link(destination: storedKeySettingsURL) {
                    HStack(spacing: 4) {
                        Text("Manage this key on OpenRouter") // xcstrings: hosted-model
                        Image(systemName: "arrow.up.right")
                            .onboardingScaledFont(.caption)
                    }
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textSecondary)
                }
                .tint(AppColors.textSecondary)
                .pointerLink()
            }

            probeStatusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
    }

    /// One "Label · value" line in the manage card. `value` is verbatim (a model
    /// ID or an already-masked key tail — never localized).
    private func summaryRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .onboardingScaledFont(.caption, weight: .semibold)
                .foregroundStyle(AppColors.textSecondary)
            Text(verbatim: "·")
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textTertiary)
            Text(verbatim: value)
                .onboardingScaledFont(.caption, design: .monospaced)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// Quiet-probe feedback inside the manage card. Non-blocking: Done stays live.
    @ViewBuilder
    private var probeStatusRow: some View {
        switch probeState {
        case .idle, .ok:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…") // xcstrings: hosted-model
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.textSecondary)
                Text("Couldn't reach OpenRouter just now.") // xcstrings: hosted-model
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Button("Retry") { runQuietProbe() } // xcstrings: hosted-model
                    .onboardingScaledFont(.caption, weight: .semibold)
                    // Tinted inline text inside a status line — a caption glyph
                    // run is far under the pointer floor on its own.
                    .inlineLinkButton()
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Sign in with OpenRouter

    /// The one-click credential path: a stroked secondary pill (the flow's shared
    /// secondary vocabulary, same as "Validate key") plus one line saying what
    /// tapping it actually does to the user's OpenRouter account. Deliberately
    /// NOT a second blue — the screen's one filled control stays Connect, because
    /// signing in is a way to fill the form, not the act of finishing it.
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: startSignIn) {
                HStack(spacing: 8) {
                    if signingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.badge.key")
                    }
                    Text("Sign in with OpenRouter") // xcstrings: hosted-model
                }
                .onboardingScaledFont(.headline)
                .foregroundColor(AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.border, lineWidth: 1)
                )
                .opacity(signInEnabled ? 1 : 0.5)
            }
            // Stroke-only background: without the primitive only the 1pt border
            // and the glyphs hit-test on macOS. 14 matches the stroke's radius.
            .choiceCardButton(cornerRadius: 14)
            .disabled(!signInEnabled)
            .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn")

            // xcstrings: hosted-model
            Text("Creates an API key for Conduck in your OpenRouter account — nothing to copy.")
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Fills the form rail, so the pill and the line explaining it share the
        // one column every other control on this screen sits in (`setupBody`).
        .frame(maxWidth: .infinity)
    }

    /// Sits above the (always-mounted) key field while a signed-in key is
    /// staged. Structurally the twin of `stagedVoiceKeyRow`, with two links the
    /// voice row does not need:
    ///   • "Manage on OpenRouter" — the exchange created a REAL key, so the user
    ///     must be able to reach it even if they never press Connect.
    ///   • "Use a different key" — discards the staged key and returns the screen
    ///     to the sign-in button + paste field.
    /// It also restates what the sign-in caption said, because that caption is
    /// unmounted the instant this row appears — which is the instant the key
    /// actually starts existing, so it is the worst possible moment for the only
    /// sentence naming that fact to disappear.
    /// Locked while a probe or the save is in flight: the captured intent must
    /// not mutate under an operation that is mid-commit against it.
    private func stagedSignInRow(handle: UUID) -> some View {
        let masked = viewModel.openRouterIssuedMaskedKey(handle: handle) ?? ""
        let manageURL = viewModel.openRouterKeySettingsURL(handle: handle)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.openRouter.signIn.staged",
                    defaultValue: "Signed in with OpenRouter"
                ))
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
                // Masked through the app's ONE masking helper, so a staged key
                // and a stored key read as the same kind of credential rather
                // than two different formats a few points apart. Verbatim: it is
                // a key fragment, never localized.
                Text(verbatim: masked)
                    .onboardingScaledFont(.caption, design: .monospaced)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Text(LocalizedStringResource(
                "settings.remoteAgent.openRouter.signIn.stagedDetail",
                defaultValue: "A new API key now sits in your OpenRouter account."
            ))
                .onboardingScaledFont(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let manageURL {
                    Link(destination: manageURL) {
                        HStack(spacing: 4) {
                            Text(LocalizedStringResource(
                                "settings.remoteAgent.openRouter.signIn.manage",
                                defaultValue: "Manage on OpenRouter"
                            ))
                            Image(systemName: "arrow.up.right")
                                .onboardingScaledFont(.caption)
                        }
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                    }
                    .pointerLink()
                    .foregroundStyle(.tint)
                }
                Button {
                    unstageSignInForADifferentKey()
                } label: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.openRouter.signIn.useDifferentKey",
                        defaultValue: "Use a different key"
                    ))
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                // Tinted inline text trailing a row — a row style would stretch
                // it to full width and shove the link beside it aside.
                .inlineLinkButton()
                .foregroundStyle(.tint)
                .disabled(connecting || validatingKey || signingIn)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn.stagedRow")
    }

    /// Shown after a signed-in key is dropped WITHOUT ever being saved — the
    /// user typed instead, chose the voice key, or tapped "Use a different key".
    ///
    /// This is the discard half of the same obligation the staged row carries:
    /// the exchange created that key at OpenRouter for real, so dropping our
    /// copy leaves a live key spending the user's credit with, otherwise,
    /// nothing on screen naming it and no way back to it. `url` is snapshotted
    /// before the discard, since the digest that addresses the key is computed
    /// from the key — which is gone a line later. The digest is not a
    /// credential, so it can safely outlive what it points at.
    private func discardedKeyNote(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppColors.textSecondary)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.openRouter.signIn.discarded",
                    defaultValue: "The key you signed in with still exists in your OpenRouter account."
                ))
                    .onboardingScaledFont(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringResource(
                            "settings.remoteAgent.openRouter.signIn.manage",
                            defaultValue: "Manage on OpenRouter"
                        ))
                        Image(systemName: "arrow.up.right")
                            .onboardingScaledFont(.caption)
                    }
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                .pointerLink()
                .foregroundStyle(.tint)
                Button {
                    discardedKeyURL = nil
                } label: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.openRouter.signIn.discardedDismiss",
                        defaultValue: "Dismiss"
                    ))
                        .onboardingScaledFont(.subheadline, weight: .semibold)
                }
                .inlineLinkButton()
                .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.remoteAgent.openRouter.signIn.discardedRow")
    }

    // MARK: - Shared fields

    /// Sits above the (always-mounted) key field while voice-key reuse is
    /// staged. "Change" backs out to manual entry — the staged flag is the ONLY
    /// thing to undo (nothing was persisted). Locked while a probe or the save
    /// is in flight: the captured intent must not mutate under an operation
    /// that is mid-commit against it.
    private var stagedVoiceKeyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
            Text(LocalizedStringResource(
                "settings.remoteAgent.reuse.selected",
                defaultValue: "OpenRouter voice key selected"
            ))
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 0)
            Button {
                useVoiceKey = false
            } label: {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.reuse.change",
                    defaultValue: "Change"
                ))
                    .onboardingScaledFont(.subheadline, weight: .semibold)
            }
            // Tinted inline text trailing a row — a row style would stretch it
            // to full width and shove the staged-key label aside.
            .inlineLinkButton()
            .foregroundStyle(.tint)
            .disabled(connecting || validatingKey || signingIn)
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.remoteAgent.reuse.selectedRow")
    }

    private func keyField(placeholder: String) -> some View {
        SecureField(placeholder, text: $pendingKey)
            // No `.textContentType(.password)`: an API key is a secret, not a
            // website login — that content type wrongly summons the Passwords
            // autofill bar. `SecureField` masks regardless; paste is unaffected.
            #if os(iOS)
            .autocapitalization(.none)
            #endif
            .autocorrectionDisabled()
            .focused($keyFieldFocused)
            .submitLabel(.next)
            .onSubmit { keyFieldFocused = false }
            // Inert while the web-auth sheet is up — typing would be a credential
            // source switch against an operation already in flight. A MODIFIER,
            // never a structural change: the field stays permanently mounted,
            // because mounting/unmounting an out-of-process `NSSecureTextField`
            // under a state toggle terminates ViewBridge on macOS.
            .disabled(signingIn)
            .padding(14)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var validationStatusRow: some View {
        switch validationState {
        case .unset, .checking:
            EmptyView()
        case .valid:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("API key valid.") // xcstrings: hosted-model
                    .foregroundStyle(AppColors.textSecondary)
                    .onboardingScaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .invalid(let message):
            // `.fixedSize(horizontal:vertical:)` + `Spacer` is load-bearing, not
            // cosmetic: without it the HStack sizes the Text to its IDEAL (single-
            // line) width and the message truncates mid-word — which is exactly how
            // a multi-sentence remedy renders as "…for yo…". Mirrors the
            // partial-sync row above.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .foregroundStyle(AppColors.error)
                    .onboardingScaledFont(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch entryMode {
        case .none:
            EmptyView()
        case .manage:
            Button(action: proceed) {
                Text("Done") // xcstrings: hosted-model
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .primaryCTAButton()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        case .setup:
            // TWO decoupled controls, breaking the old chicken-and-egg (the model
            // catalog only loads after a probe, but the single CTA was gated on a
            // model). "Validate key" needs only the key; "Connect" also needs the
            // model and runs the full validate→save.
            VStack(spacing: 12) {
                validateKeyButton
                primaryButton(
                    title: "Connect", // xcstrings: hosted-model
                    systemImage: "checkmark.shield",
                    enabled: connectButtonEnabled,
                    action: connect
                )
            }
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    /// Secondary, validate-only: loads the model catalog. Validates the typed key,
    /// or (manage, blank field) re-probes the stored key. Bordered-stroke chrome
    /// (the flow's shared secondary vocabulary — primer's "Set up manually") with a
    /// neutral glyph, so the footer's one blue stays the Connect fill below.
    private var validateKeyButton: some View {
        Button(action: validateKey) {
            HStack(spacing: 8) {
                if validationState == .checking && !connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield")
                }
                Text("Validate key") // xcstrings: hosted-model
            }
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textPrimary)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.border, lineWidth: 1)
            )
            .opacity(validateKeyEnabled ? 1 : 0.5)
        }
        // The pill's background is a STROKE with no fill, so without this the
        // interior never hit-tests — only the 1pt border and the glyphs do. 14
        // matches the stroke's own radius so the wash lines up with it.
        .choiceCardButton(cornerRadius: 14)
        .disabled(!validateKeyEnabled)
        .frame(maxWidth: .infinity)
    }

    private func primaryButton(
        title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if connecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.textEmphasis)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textEmphasis)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(enabled ? Color.accentColor : AppColors.disabled)
            .cornerRadius(14)
        }
        .primaryCTAButton()
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived enablement

    /// "Validate key" needs a key to probe — typed, staged (a sign-in or
    /// voice-key reuse), or (manage) the stored one. Not gated on the model (the
    /// catalog only appears after a probe).
    private var validateKeyEnabled: Bool {
        let haveSomethingToProbe =
            !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasStoredKey || useVoiceKey || oauthHandle != nil
        return haveSomethingToProbe
            && validationState != .checking
            && !connecting && !validatingKey && !signingIn
    }

    /// "Connect" requires the model and a key — typed, staged (a sign-in or
    /// voice-key reuse), or already stored.
    private var connectButtonEnabled: Bool {
        let keyOK = !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasStoredKey || useVoiceKey || oauthHandle != nil
        let modelOK = !modelBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return keyOK && modelOK
            && validationState != .checking
            && !connecting && !validatingKey && !signingIn
    }

    /// "Sign in with OpenRouter" is live whenever nothing else is mid-flight
    /// against the current credential. It is NOT gated on the field being empty:
    /// starting a sign-in is itself the act of choosing a different source, and
    /// it clears the field as part of staging.
    private var signInEnabled: Bool {
        validationState != .checking && !connecting && !validatingKey && !signingIn
    }

    // MARK: - Actions

    private var fixedURL: String {
        viewModel.remoteAgentURLStrings[ref] ?? Constants.openRouterBaseURLString
    }

    /// Open the system web-auth sheet and stage whatever comes back.
    ///
    /// Staging is atomic with the tap: any previous sign-in is discarded and the
    /// typed / voice-key sources are cleared BEFORE the sheet opens, so there is
    /// no instant where the screen has two live credentials. The task is bound to
    /// this step — a newer sign-in or leaving the screen cancels it, and a
    /// completion that lands after either is dropped (and its key discarded)
    /// rather than staging something nobody is looking at.
    ///
    /// A user cancel is SILENT: `authenticate` throws `canceledLogin`, and a
    /// person who closed the sheet is not owed an error about it. Everything else
    /// lands on the paste field with a message, which is the whole failure
    /// contract for this feature.
    private func startSignIn() {
        guard signInEnabled else { return }
        guard let start = viewModel.beginOpenRouterSignIn() else {
            // The view model already wrote the "can't start a secure sign-in"
            // message into the ref's validation state; nothing else to do.
            return
        }
        probeTask?.cancel()
        signInTask?.cancel()
        discardStagedSignIn()
        // `discardedKeyURL` is deliberately NOT cleared here: a fresh sign-in
        // mints a second real key, and the note is the only route left to the one
        // just abandoned. It carries its own Dismiss.
        // The verdict on screen was earned by whatever this sign-in replaces.
        viewModel.remoteAgentValidationStates[ref] = .unset
        pendingKey = ""
        useVoiceKey = false
        // Freeze the pre-filled buffers (the same fence the key field's focus
        // raises) so a late iCloud-KVS reload can't revert the setup under a
        // sign-in that is already in flight.
        viewModel.editorHasUnsavedChanges = true
        signingIn = true
        let handle = start.handle
        signInTask = Task { @MainActor in
            defer { signingIn = false }
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: start.authorizationURL,
                    callback: .customScheme(start.callbackScheme),
                    // `.shared`, not `.ephemeral`: reusing the browser session the
                    // user is already signed into IS the one-click property. An
                    // ephemeral session would make them log in to OpenRouter
                    // again, which is the friction this whole path removes.
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
                guard !Task.isCancelled else {
                    viewModel.discardOpenRouterSignIn(handle: handle)
                    return
                }
                let outcome = await viewModel.completeOpenRouterSignIn(
                    handle: handle, callbackURL: callback
                )
                guard !Task.isCancelled else {
                    viewModel.discardOpenRouterSignIn(handle: handle)
                    return
                }
                switch outcome {
                case .staged(let staged, _):
                    oauthHandle = staged
                case .cancelled, .failed:
                    // The view model has already surfaced any message; the handle
                    // holds nothing worth keeping.
                    viewModel.discardOpenRouterSignIn(handle: handle)
                }
            } catch is CancellationError {
                viewModel.discardOpenRouterSignIn(handle: handle)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The user closed the sheet. Silent — but the busy state still
                // resets, via the `defer` above.
                viewModel.discardOpenRouterSignIn(handle: handle)
            } catch {
                // The session itself failed (no presentation context, or the
                // system tore it down). Nothing usable came back, which is the
                // same fact a mismatched callback reports.
                viewModel.failOpenRouterSignIn(handle: handle)
            }
        }
    }

    /// Drop the staged sign-in, if any — the ONE place this View forgets a
    /// handle, so "discarded locally, still real at OpenRouter" has a single
    /// meaning. Handle-scoped by construction: it can only forget the handle it
    /// currently holds.
    ///
    /// The key's settings URL is read BEFORE the discard and kept, because the
    /// discard destroys the only copy of the key and therefore the ability to
    /// compute the digest that addresses it. That link is the whole remedy for a
    /// key the exchange already created, so losing it here would leave the user
    /// with an orphan credential and no route to it.
    private func discardStagedSignIn() {
        guard let handle = oauthHandle else { return }
        discardedKeyURL = viewModel.openRouterKeySettingsURL(handle: handle)
        oauthHandle = nil
        viewModel.discardOpenRouterSignIn(handle: handle)
    }

    /// The USER-initiated unstage ("Use a different key"). Unlike the teardown
    /// and replacement call sites, nothing else here retracts the verdict — and
    /// there always is one, because a successful sign-in auto-probes. Leaving it
    /// would show "API key valid." over a screen with nothing staged.
    /// Mirrors what `.onChange(of: useVoiceKey)` does for the other source.
    private func unstageSignInForADifferentKey() {
        discardStagedSignIn()
        viewModel.remoteAgentValidationStates[ref] = .unset
        viewModel.noteRemoteAgentSecretEdited(for: ref)
    }

    /// VALIDATE-ONLY: probe `/v1/key` (also discovering the model catalog) without
    /// saving. Uses the staged sign-in, the staged voice key, the typed key, or
    /// re-probes the stored key when the field is blank in manage mode.
    private func validateKey() {
        guard !validatingKey && !connecting && !signingIn && validationState != .checking else { return }
        probeTask?.cancel()
        // Snapshot the credential intent at TAP time — the probe must test what
        // the user launched it against, immune to a mid-flight toggle.
        let signedInHandle = oauthHandle
        let reuseVoiceKey = useVoiceKey
        let candidate = pendingKey
        let url = fixedURL
        validatingKey = true
        Task {
            if let signedInHandle {
                // The VM resolves the signed-in key from its vault — never the
                // View — and a probe never consumes it.
                await viewModel.testRemoteAgent(
                    ref: ref, stagedToken: .oauthIssued(signedInHandle), name: nil
                )
            } else if reuseVoiceKey {
                // The VM resolves the voice key from the Keychain — never the View.
                await viewModel.testRemoteAgent(ref: ref, stagedToken: .reuseVoiceKey, name: nil)
            } else if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasStoredKey {
                await viewModel.retestRemoteAgent(ref: ref, url: url)
            } else {
                await viewModel.validateRemoteAgent(
                    ref: ref, url: url, token: candidate, authScheme: .bearer, fingerprint: nil
                )
            }
            validatingKey = false
        }
    }

    /// SETUP-mode primary: validate→save, then hand off to the success screen.
    /// Advancing is gated on the SAVE completing, never on the probe verdict — a
    /// valid key that fails to persist leaves the user unconfigured, and must leave
    /// them on this screen (with the error) rather than on a "Connected" one.
    private func connect() {
        guard !connecting && !validatingKey && !signingIn && validationState != .checking else { return }
        // Snapshot the credential intent at TAP time (see `validateKey`).
        let signedInHandle = oauthHandle
        let reuseVoiceKey = useVoiceKey
        let candidate = pendingKey
        connecting = true
        Task {
            let ok = await performSave(
                replacementKey: candidate,
                reuseVoiceKey: reuseVoiceKey,
                signedInHandle: signedInHandle
            )
            guard ok else {
                connecting = false
                return
            }
            pendingKey = ""
            // The save consumed the vault entry, so the handle now addresses
            // nothing — forget it locally too rather than leaving the staged row
            // pointing at a key that has moved into the Keychain. Straight to
            // `oauthHandle`, NOT through `discardStagedSignIn()`: this key was
            // committed, not abandoned, so it must not raise the orphan note.
            oauthHandle = nil
            discardedKeyURL = nil
            viewModel.editorHasUnsavedChanges = false
            // `connecting` stays true through the outgoing slide: clearing it here
            // would flip the button out of its spinner mid-transition. The view is
            // being torn down, so the flag dies with it.
            onConnected()
        }
    }

    /// Validate (whenever a NEW key is in play — typed, a staged sign-in, or
    /// staged voice-key reuse) then persist. `.stored` keeps the saved key
    /// untouched — the model-only path. Every argument is the caller's TAP-time
    /// snapshot, not live state.
    ///
    /// Precedence, top to bottom, is the same order the screen reads: a signed-in
    /// key wins, then a typed one, then the voice key, then whatever is stored.
    /// The screen already keeps those mutually exclusive — this ordering is the
    /// backstop that decides deterministically if they ever aren't.
    private func performSave(
        replacementKey: String,
        reuseVoiceKey: Bool,
        signedInHandle: UUID?
    ) async -> Bool {
        let staged: StagedRemoteAgentToken
        if let signedInHandle {
            staged = .oauthIssued(signedInHandle)
        } else if !replacementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            staged = .typed(replacementKey)
        } else if reuseVoiceKey {
            staged = .reuseVoiceKey
        } else {
            staged = .stored
        }
        switch staged {
        case .typed(let key):
            await viewModel.validateRemoteAgent(
                ref: ref, url: fixedURL, token: key, authScheme: .bearer, fingerprint: nil
            )
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        case .reuseVoiceKey, .oauthIssued:
            // Same prove-the-key-before-save contract as a typed key; the VM
            // resolves the credential internally and, for a sign-in, does NOT
            // consume it — a failed probe here must leave the key retryable.
            await viewModel.testRemoteAgent(ref: ref, stagedToken: staged, name: nil)
            guard viewModel.remoteAgentRowState(for: ref) == .valid else { return false }
        case .stored:
            break
        }
        return await viewModel.saveRemoteAgent(ref: ref, name: nil, stagedToken: staged)
    }

    /// Quiet manage-mode probe of the STORED key (`retestRemoteAgent` reads it from
    /// Keychain — raw key never enters the View). Non-blocking; editing now lives
    /// in a separate step that remounts this view (cancelling `probeTask` on
    /// disappear), so there's no inline-edit race to guard against here.
    private func runQuietProbe() {
        guard entryMode == .manage, hasStoredKey else { return }
        probeTask?.cancel()
        probeState = .checking
        let url = fixedURL
        probeTask = Task { @MainActor in
            await viewModel.retestRemoteAgent(ref: ref, url: url)
            guard !Task.isCancelled else { return }
            probeState = viewModel.remoteAgentLiveValidated.contains(ref) ? .ok : .failed
        }
    }

}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        HostedModelGatewayStepView(
            viewModel: SettingsViewModel(),
            proceed: {},
            onConnected: {}
        )
    }
}
