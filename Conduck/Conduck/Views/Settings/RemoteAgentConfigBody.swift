// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentConfigBody.swift
//
// The per-ref Personal AI configuration surface, the iOS analog of
// `ProviderConfigBody` for STT. Pushed from the gateway LIST
// (`PersonalAISettingsView`) into `RemoteAgentDetailView`, parameterized by a
// single `RemoteAgentRef` — a built-in (OpenClaw / Hermes / OpenRouter) OR a
// user-defined custom gateway. Keys every read/write through the per-ref
// SettingsViewModel dicts.
//
// Layout is ONE flat page — no DisclosureGroups — in fixed zone order. State
// (`isRemoteAgentConfigured`) changes only BEHAVIOR (gating, Forget
// availability, the post-save default prompt), NEVER the zone structure.
// Per-LANE differences are driven by the capability descriptor
// (`RemoteAgentBackendMetadata`), never `if backend == …` checks; a lane
// without a zone's content omits the zone (no empty sections):
//   1. Quick connect — one row into the guided cover, deep-linked to THIS ref
//      (`GatewayPath.quickConnect`). Self-hosted + custom lanes only; dirty-
//      gated (an import writing under unsaved edits would corrupt both).
//   2. Connection — reuse callout (OpenRouter) · name (custom) · URL · auth
//      toggle · token row (`SecretEntrySheet`) · Test Connection + remedy ·
//      Server certificate row.
//   3. Model — its own section (OpenRouter required + discovery; custom
//      optional).
//   4. In chats — File transfer (pushes `GatewayFileTransferPage`; save/dirty-
//      gated) + Image history.
//   5. Devices — "Set up on another device" (pairing-code export) + the badge
//      fields (custom).
//   6. Destructive — Forget / Delete, isolated last, no header.
//
// ONE commit contract, page-wide: EVERY field and picker buffers until Save
// (the single commit point, enabled only when the form is VALID and something
// actually changed); backing out with any unsaved change asks "Discard changes?"
// via `bufferedEditorChrome`. Only ACTIONS run immediately
// (Quick connect, pairing export, Forget — each self-confirming), and the
// File transfer sub-page is its own buffered editor with the same contract.
// No zone narrates its commit timing — one contract needs no captions.
//
// The optional certificate pin is edited in ONE place — `CertificateTrustSheet`,
// opened from the Server certificate row. The row shows only plain-language
// values (Automatic / Pinned on this device); the fingerprint jargon is
// quarantined in the sheet. A certificate this device doesn't trust is a
// TERMINAL Test Connection failure with no affordance attached: pinning can
// only narrow what is accepted, never widen it, so the fix is on the server.
//
// Shared field sub-views (`nameField`/`urlField`/`authToggle`/`secretRow`/
// `modelField`/`imageHistoryPicker`/`badgeFields`) are each independently
// guarded off the descriptor, so the unified template just lists them. The
// bearer-token `secretRow` is an ORDINARY row that opens `SecretEntrySheet`
// (the only `SecureField`); NO `SecureField` is ever inline in this editor
// (out-of-process macOS `NSSecureTextField` layout-recursion).
//
// Privacy invariants (unchanged):
//   - The bearer token never leaves the editor-local `pendingToken` buffer (seeded
//     into / committed from `SecretEntrySheet`'s transient `draft`); cleared after a
//     save attempt. Keychain is the only persistence.
//   - The OpenRouter voice-key reuse is staged as INTENT
//     (`StagedRemoteAgentToken.reuseVoiceKey`) and resolved VM-side at
//     commit/probe time — the raw key never enters this View.
//   - The masked tail is the only token surface in `.valid` state.
//
// Cross-platform (iOS + macOS): the body is shared, and the zone tree is
// written ONCE inside `PlatformSettingsForm` — hand-drawn `SettingsCard`s on
// macOS, the stock grouped `Form` on iOS. On macOS that container also owns the
// page chrome (scroll surface, 28pt window gutter, 720pt settings rail), so the
// editor's column lands on exactly the width of the Personal AI list it is
// pushed from, and each row supplies its own inset and full-bleed live frame
// through the card row primitives in `MacPointerTargets.swift` — every one of
// which is a no-op off macOS. UIKit-only `TextField` modifiers
// (`.textContentType(.URL)`, `.keyboardType`, `.textInputAutocapitalization`)
// stay `#if os(iOS)`-gated.
//
// Type-checker-budget discipline: `nameField` / `modelField` / `colorSwatch`
// / `monogramField` are separate `@ViewBuilder` sub-views guarded by
// `if case .custom = ref`, NOT inlined ternaries, so each mode's section
// stays inside the SwiftUI expression budget.

import SwiftUI

struct RemoteAgentConfigBody: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef

    /// The guided-setup host presentation, owned by the window/stack root and
    /// threaded down by the mounting surface (`PersonalAISettingsView` /
    /// `MacPersonalAICategory`). nil when the surface has no guided host (the
    /// Watch companion settings) — the Quick connect zone hides there rather
    /// than render a dead row.
    var guidedHost: Binding<GuidedGatewayHostState>? = nil

    /// Editor-local token buffer — entered via `SecretEntrySheet`, cleared after a
    /// save attempt. NEVER persisted past the validate-and-save call.
    @State private var pendingToken: String = ""

    /// OpenRouter lane: the voice-key reuse is STAGED, not instant — tapping the
    /// callout only sets this flag; Save and Test resolve it VM-side via
    /// `StagedRemoteAgentToken.reuseVoiceKey`. Participates in `isDirty` and
    /// `canSave` (a staged key satisfies the hosted lane's key requirement).
    /// Typing a token clears it; Save success and rehydrate clear it.
    @State private var stagedVoiceKeyReuse: Bool = false

    /// Drives the tap-in `SecretEntrySheet` for bearer-token entry (the only place
    /// a `SecureField` exists — never inline in this editor).
    @State private var showingSecretSheet: Bool = false

    /// Drives the `CertificateTrustSheet` — opened from the Server certificate row.
    @State private var showingCertSheet: Bool = false

    /// Drives the pairing-EXPORT sheet ("Set up on another device") — re-renders
    /// THIS configured gateway's `conduck-setup` code so a new device can scan it.
    @State private var showingPairingExport: Bool = false

    /// Drives the "Where do I find these?" credential-provenance sheet — offered
    /// only for lanes whose descriptor carries a `credentialSource` (the two
    /// self-hosted built-ins; a hosted lane has no server of yours to look on, and
    /// we can't know a custom's layout).
    @State private var showingCredentialHelp: Bool = false

    /// The custom lane's help sheet ("What do I enter?") — the explanation
    /// counterpart to `showingCredentialHelp`'s provenance sheet.
    @State private var showingCustomHelp: Bool = false

    /// True between launching the guided cover from Quick connect and its
    /// dismissal — the signal to rehydrate from storage on return, so an import
    /// that wrote config while this editor was open doesn't read as dirty edits.
    @State private var awaitingGuidedReturn: Bool = false

    /// This ref's commit count at the moment WE launched the guided cover. On
    /// dismissal a higher count means the cover committed underneath us and the
    /// baselines are stale; an equal one means it didn't, so a cancelled cover
    /// leaves an unsaved draft alone. Snapshotted per launch rather than
    /// observed globally: the epoch is app-wide, and the Watch companion mounts
    /// this editor with no guided host at all, so a phone-side import must never
    /// reach in and reset a wrist editor that never opened a cover.
    @State private var guidedLaunchCommitEpoch: Int = 0

    /// True while the post-Quick-connect rehydrate's async storage reads are in
    /// flight. The form is disabled for the duration — the editor is already
    /// interactive when the cover dismisses, and a fast edit would otherwise be
    /// overwritten by the delayed write-back and then rebaselined as pristine.
    @State private var rehydratingAfterGuidedReturn: Bool = false

    /// True while a Save commit is in flight — feeds `canSave` so the button
    /// greys for the duration of its own multi-await chain. Mirrors
    /// `FileTransferSetupContent`'s gate.
    @State private var saving: Bool = false

    /// The per-ref pairing TRANSPORT hint, loaded once from storage. Feeds
    /// `HostReachabilityClass.classify` so the keyless-on-public warning does NOT
    /// fire for a tailnet MagicDNS name — which is an ordinary-looking hostname and
    /// would otherwise classify as `.publicHost`. nil (a hand-typed gateway that
    /// never paired) simply means we judge on the host string alone.
    @State private var transportHint: String?

    /// Local name buffer (custom only) — seeded from the roster `onAppear`.
    @State private var pendingName: String = ""

    // MARK: Buffered non-connection edits (nil = untouched → mirror storage)
    //
    // The page-wide commit contract: these buffer exactly like the connection
    // fields and commit in `saveTapped` after the connection save succeeds.
    // nil-pending (rather than an appear-time snapshot) so late VM hydration
    // can never make an untouched control read dirty.

    /// Buffered Image history selection. nil = untouched (row mirrors the
    /// persisted policy); set on user selection; committed on Save.
    @State private var pendingImageHistory: ImageHistoryPolicy?
    /// Buffered badge color (custom-only). nil = untouched.
    @State private var pendingBadgeColorID: String?
    /// Buffered badge monogram text (custom-only). nil = untouched; the field
    /// mirrors the stored override (or the derived monogram) until edited.
    @State private var pendingMonogram: String?

    /// Confirmation alert for the destructive per-ref "Forget" action.
    @State private var showingForgetConfirm: Bool = false

    /// Post-save prompt offering to make a newly-configured ADDITIONAL gateway the
    /// default for new chats. Fires only on the unconfigured→configured transition
    /// of a non-default ref (never on the first gateway — that bootstraps silently
    /// in `saveRemoteAgent` — and never on a routine edit). The alert's buttons own
    /// the `dismiss()`; `saveTapped` defers dismissal when it's raised.
    @State private var showingMakeDefaultPrompt: Bool = false

    /// Set true right before a Save/Delete-driven `dismiss()` so the shared
    /// `bufferedEditorChrome` `.onDisappear` safety net doesn't also discard the
    /// just-committed change.
    @State private var suppressCancelOnExit: Bool = false

    /// Seed the dirty-detection snapshots exactly ONCE. `.onAppear` fires again
    /// when returning from a child push (the File transfer page); re-seeding then
    /// would re-baseline `original*` to the EDITED values, making unsaved edits
    /// read as pristine → no discard warning. Guarding on this preserves dirty
    /// state across the round-trip.
    @State private var didInitialize: Bool = false

    /// Appear-time snapshot of the editable buffers, for Cancel's dirty check.
    /// A typed token also marks dirty.
    @State private var originalURL: String = ""
    @State private var originalName: String = ""
    @State private var originalModel: String = ""
    @State private var originalCert: String = ""
    /// Appear-time keyless state, for Cancel's dirty check (mirrors the others).
    @State private var originalAuthKeyless: Bool = false

    @Environment(\.dismiss) private var dismiss

    /// The zone tree in the adaptive settings container: a stack of hand-drawn
    /// `SettingsCard`s on macOS, the stock grouped `Form` on iOS.
    ///
    /// The container carries the macOS page chrome itself — scroll surface, the
    /// 28pt window gutter and the 720pt `MacSettingsRail` — so this editor adds
    /// no rail of its own and its column is exactly as wide as the Personal AI
    /// list it is pushed from. A `.frame(maxWidth:)` rail here would be the
    /// wrong lever anyway: on the scrolling view itself it shrinks the scroll
    /// surface and leaves a wide window's margins as dead, unscrollable glass,
    /// which is why `.macSettingsRail()` caps the card STACK inside the
    /// `ScrollView` rather than the `ScrollView`.
    ///
    /// The two scroll modifiers ride the container rather than a `Form` nested
    /// inside it: both apply to the scrollable view anywhere in the subtree, so
    /// the iOS grouped `Form` still drops its opaque backing (the app gradient
    /// reads through) and still dismisses the keyboard on drag.
    private var formCore: some View {
        PlatformSettingsForm {
            editorSections
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var isCustom: Bool { ref.isBuiltin == false }

    /// The capability descriptor for a built-in ref (nil for customs). Drives the
    /// per-backend form stripping for hosted-model built-ins (OpenRouter) while
    /// leaving self-hosted built-ins (OpenClaw/Hermes) — whose flags equal current
    /// behavior — AND customs (nil here) rendering EXACTLY as before.
    private var builtinDescriptor: RemoteAgentBackendMetadata? {
        if case .builtin(let backend) = ref {
            return RemoteAgentBackendRegistry.lookup(id: backend)
        }
        return nil
    }

    /// Local filter text for the model suggestion strip — shown only when the
    /// suggestion list is large (hosted catalogs like OpenRouter return 300+).
    /// Buffer-only; never persisted, never narrows free-text model entry.
    @State private var modelFilter: String = ""

    /// Whether THIS ref's buffered auth scheme is keyless (`.none`). Drives the
    /// authentication toggle, the keyless-aware Save/Test gating, and `secretRow`'s
    /// presence (the bearer-token summary row disappears when keyless). No
    /// `SecureField` reads this — the secret is entered in `SecretEntrySheet`.
    private var isKeyless: Bool {
        (viewModel.remoteAgentAuthSchemes[ref] ?? .bearer) == .none
    }

    /// The roster record for a custom ref (nil for built-ins / a missing draft).
    private var customGateway: CustomGateway? {
        guard case .custom(let id) = ref else { return nil }
        return viewModel.customGateways.first(where: { $0.id == id })
    }

    /// Display-only metadata — built-ins use the registry; customs synthesize a
    /// generic placeholder shape (only `urlPlaceholder` / `tokenPlaceholder`
    /// are read here).
    private var urlPlaceholder: String {
        if case .builtin(let backend) = ref {
            return RemoteAgentBackendRegistry.lookup(id: backend).urlPlaceholder
        }
        return String(localized: "remoteAgent.custom.url.placeholder",
                      defaultValue: "https://your-gateway.example:port")
    }

    private var tokenPlaceholder: String {
        if case .builtin(let backend) = ref {
            return RemoteAgentBackendRegistry.lookup(id: backend).tokenPlaceholder
        }
        return String(localized: "Bearer token")
    }

    private var rowState: KeyValidationState {
        viewModel.remoteAgentRowState(for: ref)
    }

    /// Title of the secret-entry sheet, tracking the row LABEL the descriptor
    /// chose ("API key" for a hosted lane, "Bearer token" elsewhere) — a sheet that
    /// says "Enter bearer token" above an OpenRouter API-key field reads as the
    /// wrong screen. Two distinct KEYS rather than one interpolated title: the
    /// pre-existing `…token.sheet.title` key is frozen in the catalog at "Enter
    /// bearer token" (a catalog value wins over `defaultValue:`), so the hosted
    /// wording has to arrive on a key the catalog has never seen.
    private var secretSheetTitle: LocalizedStringResource {
        builtinDescriptor?.category == .hostedModel
            ? LocalizedStringResource("settings.remoteAgent.apiKey.sheet.title", defaultValue: "Enter API key")
            : LocalizedStringResource("settings.remoteAgent.bearerToken.sheet.title", defaultValue: "Enter bearer token")
    }

    /// The secret row's tip — a vendor-issued, billed API key and a password you
    /// invent on your own server are different objects; the definition must match.
    private var secretTip: GatewayFieldTip {
        builtinDescriptor?.category == .hostedModel ? GatewayFieldTips.apiKey : GatewayFieldTips.bearerToken
    }

    /// The token INTENT for every VM call (Save / Test) — the one resolution
    /// site, so the two paths can't disagree. A staged voice-key reuse wins; a
    /// typed buffer next; otherwise the ref's saved Keychain token (`.stored` —
    /// which a keyless lane resolves to "none").
    private var stagedToken: StagedRemoteAgentToken {
        if stagedVoiceKeyReuse { return .reuseVoiceKey }
        return pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .stored
            : .typed(pendingToken)
    }

    var body: some View {
        formCore
        .sheet(isPresented: $showingSecretSheet) {
            SecretEntrySheet(
                title: secretSheetTitle,
                prompt: tokenPlaceholder,
                initialValue: pendingToken,
                onCommit: { newToken in
                    // The draft lives in the sheet's private state, so the VM can't
                    // see the edit — tell it on COMMIT, so a green earned by the
                    // PREVIOUS token doesn't survive a new one. But ONLY when the
                    // value actually changed: opening the sheet and tapping Done
                    // without editing must not retract a live "Connected" earned by
                    // the token already in the buffer. Compare before reassigning.
                    let tokenChanged = newToken != pendingToken
                    pendingToken = newToken
                    // A typed token supersedes a staged voice-key reuse — the two
                    // are competing answers to "which credential"; last intent wins.
                    if !newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stagedVoiceKeyReuse = false
                    }
                    if tokenChanged {
                        viewModel.noteRemoteAgentSecretEdited(for: ref)
                    }
                }
            )
        }
        .sheet(isPresented: $showingCertSheet) {
            CertificateTrustSheet(fingerprint: certFingerprintBinding)
        }
        .sheet(isPresented: $showingCredentialHelp) {
            if let source = builtinDescriptor?.credentialSource {
                GatewayCredentialHelpSheet(source: source)
            }
        }
        .sheet(isPresented: $showingCustomHelp) {
            CustomGatewayHelpSheet()
        }
        .task {
            // One-shot read of the pairing transport (App-Group stored) — the
            // secondary signal that keeps a tailnet host from reading as public.
            transportHint = await SettingsManager.shared.getRemoteAgentTransportHint(for: ref)
        }
        .sheet(isPresented: $showingPairingExport) {
            PairingExportSheet(viewModel: viewModel, ref: ref)
        }
        .onAppear {
            // Seed once — see `didInitialize`. Re-seeding would corrupt dirty
            // detection (the File transfer page is a child PUSH, so `.onAppear`
            // re-fires on the way back).
            if !didInitialize {
                didInitialize = true
                if let gateway = customGateway { pendingName = gateway.name }
                // Snapshot the editable buffers for Cancel's dirty detection.
                rebaselineOriginals()
            }
        }
        .onChange(of: guidedHost?.wrappedValue.isPresented ?? false) { _, presented in
            // Quick connect returned: the guided cover may have imported a setup
            // code that PERSISTED config while this editor was open. Rehydrate
            // from storage + re-baseline so the imported values don't read as
            // unsaved edits. Only after a launch WE initiated — the host state is
            // shared, and someone else's cover must not wipe this editor.
            if !presented, awaitingGuidedReturn {
                awaitingGuidedReturn = false
                // Rehydrate ONLY when the cover actually COMMITTED — a cancelled
                // cover (nothing imported) on a never-saved custom draft would
                // otherwise drop the draft's in-memory roster row (badge taps
                // no-op, the row vanishes) and reset typed buffers.
                //
                // Gate on the commit receipt, NOT on `isRemoteAgentConfigured`.
                // That predicate reads a cache which an interleaved reload can
                // leave stale, so it answered `false` for a gateway the import
                // had just committed and probed — skipping this rehydrate and
                // stranding the editor with an empty Name, stale baselines, a
                // phantom "unsaved changes" prompt, and a Save button that could
                // not clear it. The epoch only ever increases, so it has no
                // stale value to misread.
                if (viewModel.remoteAgentCommitEpoch[ref] ?? 0) > guidedLaunchCommitEpoch {
                    rehydrateFromStorage()
                }
            }
        }
        // Freeze input while the guided-return rehydrate's storage reads land —
        // see `rehydratingAfterGuidedReturn`.
        .disabled(rehydratingAfterGuidedReturn)
        .alert(
            LocalizedStringResource("settings.remoteAgent.forgetAlert.title", defaultValue: "Forget gateway?"),
            isPresented: $showingForgetConfirm
        ) {
            Button(
                LocalizedStringResource("settings.remoteAgent.forgetAlert.confirm", defaultValue: "Forget"),
                role: .destructive
            ) {
                Task {
                    await viewModel.clearRemoteAgent(for: ref)
                    pendingToken = ""
                    stagedVoiceKeyReuse = false
                    pendingImageHistory = nil
                    pendingBadgeColorID = nil
                    pendingMonogram = nil
                    if isCustom {
                        // A custom is GONE after forget — skip the cancel
                        // safety-net and pop back to the list.
                        suppressCancelOnExit = true
                        dismiss()
                    } else {
                        // A built-in stays open (re-enter to reconfigure). The
                        // clear already persisted, so re-baseline the snapshot to
                        // the now-empty config — avoids a spurious "Discard
                        // changes?" prompt on the way out. (Centralized helper also
                        // re-baselines the keyless flag, which the old inline block
                        // missed — a cleared keyless built-in read dirty.)
                        rebaselineOriginals()
                    }
                }
            }
            Button(
                LocalizedStringResource("settings.remoteAgent.forgetAlert.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) { }
        } message: {
            forgetAlertMessage
        }
        .alert(
            LocalizedStringResource(
                "settings.remoteAgent.makeDefault.title",
                defaultValue: "Make \(viewModel.displayName(for: ref)) your default gateway?"
            ),
            isPresented: $showingMakeDefaultPrompt
        ) {
            Button(
                LocalizedStringResource("settings.remoteAgent.makeDefault.confirm", defaultValue: "Make Default")
            ) {
                Task {
                    await viewModel.setDefaultRemoteAgentRef(ref)
                    dismiss()
                }
            }
            Button(
                LocalizedStringResource("settings.remoteAgent.makeDefault.notNow", defaultValue: "Not Now"),
                role: .cancel
            ) {
                dismiss()
            }
        } message: {
            Text(LocalizedStringResource(
                "settings.remoteAgent.makeDefault.message",
                defaultValue: "New chats start here. Existing chats keep their gateway."
            ))
        }
        .bufferedEditorChrome(
            isDirty: isDirty,
            viewModel: viewModel,
            onDiscard: {
                // A verdict earned by a credential that dies with this discard
                // (typed token / staged voice-key reuse) must not survive to
                // describe the stored config it never actually tested.
                if !pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || stagedVoiceKeyReuse {
                    viewModel.noteRemoteAgentSecretEdited(for: ref)
                }
                await viewModel.cancelRemoteAgentEdit(ref: ref)
            },
            suppressCancelOnExit: $suppressCancelOnExit,
            title: viewModel.displayName(for: ref),
            saveTitle: LocalizedStringResource("settings.editor.save", defaultValue: "Save"),
            // Always a PUSH — from the Personal AI list, the Watch companion
            // settings, or the iPad detail pane. Never its own modal root.
            exit: .back,
            canSave: { canSave },
            onSave: { saveTapped() }
        )
    }

    /// Forget copy must enumerate EVERY slot the action wipes — and say WHERE.
    /// `clearRemoteAgent` is the terminal per-ref wipe and takes the file-transfer
    /// lane with it (server address + generated password + pin), so the alert
    /// names it; an alert that lists only URL/token/pin would understate a
    /// destructive action that also drops the user's file-server password.
    ///
    /// The scope sentence is not decoration. The token is a SYNCHRONIZABLE
    /// Keychain item and the URL is dual-written to iCloud KVS, so deleting either
    /// removes it from every device signed into the same Apple Account — not just
    /// this one. Only the certificate pin is per-device. A user reaching this
    /// alert from a Diagnostics row that says "on this device" would otherwise
    /// reasonably read the wipe as local.
    ///
    /// The custom variant also names what SURVIVES. A forgotten custom keeps its
    /// badge — two characters and a palette colour — so the conversations it
    /// created stay tellable apart; an alert that lists only destruction would
    /// misdescribe that, in the one direction a user cannot check afterwards.
    private var forgetAlertMessage: Text {
        if isCustom {
            // A NEW key, not an edit of an existing one. Rewording an existing
            // `defaultValue:` is inert — the string catalog's stored value wins
            // and extraction never overwrites it.
            return Text(LocalizedStringResource(
                "settings.remoteAgent.forgetAlert.message.custom.retained",
                defaultValue: "Conduck will delete this gateway and its saved URL, token, and pin, plus any file-transfer setup for it (server address and generated password). The URL and token are removed from all your devices signed in to iCloud; the pin is only on this one. Conversations bound to it stay readable but can't send new turns. They keep this gateway's colour tag so you can still tell them apart; its name is not kept."
            ))
        }
        return Text(LocalizedStringResource(
            "settings.remoteAgent.forgetAlert.message",
            defaultValue: "Conduck will erase the saved URL, token, and pin, plus any file-transfer setup for this gateway (server address and generated password). The URL and token are removed from all your devices signed in to iCloud; the pin is only on this one. You'll re-enter them next time."
        ))
    }

    // MARK: - Editor sections (fixed zone order; descriptor-driven omission)

    /// The zone template, identical whether the gateway is empty or filled.
    /// Per-lane visibility is driven by the descriptor inside each zone (a custom
    /// ref has a nil descriptor → the editable defaults); a lane's missing zones
    /// simply omit — no empty sections. Persisted state changes only BEHAVIOR
    /// (gating, Forget availability, post-save default prompt), never this
    /// structure.
    @ViewBuilder
    private var editorSections: some View {
        quickConnectSection
        connectionSection
        modelSection
        inChatsSection
        devicesSection
        destructiveSection
    }

    // A zone header is plain `Text`, styled by the container: on macOS
    // `SettingsCard` gives every header the same 13pt semibold secondary
    // treatment and the same gap down to its card, so this editor's zones and
    // the Personal AI list's sections read as one surface; on iOS the grouped
    // `Form` supplies the stock inset-grouped header. Styling a header here
    // would land closer to the leaf, win over the card's default, and split the
    // rhythm across two files.

    // MARK: - Zone 1: Quick connect (guided cover deep-link; never OpenRouter)

    /// One row into the guided cover, deep-linked to THIS ref
    /// (`GatewayPath.quickConnect(target:needsSetup:)` — the host owns
    /// presentation). A ref that is not configured yet opens the lane at its
    /// readiness step rather than on the bare command; a configured one still goes
    /// straight to the command, so a re-pair stays one screen. Hosted
    /// -model built-ins (OpenRouter) have NO guided server setup — no server to
    /// run, no pairing — so the zone is omitted for that lane, and it hides when
    /// the mounting surface carries no guided host (Watch companion settings).
    /// Dirty-gated: a setup-code import PERSISTS config, and doing that under
    /// unsaved edits would silently interleave two sources of truth.
    @ViewBuilder
    private var quickConnectSection: some View {
        if builtinDescriptor?.category != .hostedModel, let host = guidedHost {
            // ONE read of the configured snapshot per body pass, shared by the
            // label, its amber tint AND the destination the tap commits. Reading it
            // separately inside the action closure would resolve it LATER than the
            // label did, so an iCloud-KVS `refreshRemoteAgentReadinessSnapshots()`
            // landing between render and tap (a second device finishing this same
            // pairing) could open the Commands step from a row still reading amber
            // "Set up". Captured here, the label the user pressed and the screen
            // they get are the same fact.
            let isConfigured = viewModel.isRemoteAgentConfigured(ref)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        awaitingGuidedReturn = true
                        guidedLaunchCommitEpoch = viewModel.remoteAgentCommitEpoch[ref] ?? 0
                        // Destination + presence commit as ONE value (the host's
                        // `.fullScreenCover(item:)`) — writing them as separate
                        // fields raced the cover's first build on iOS 26 and
                        // opened the CHOOSER instead of this ref's Commands step.
                        // `needsSetup` rides inside that same value, so the entry
                        // step is fixed by the state the row was RENDERED from.
                        host.wrappedValue.present(initialPath: .quickConnect(
                            target: ref,
                            needsSetup: !isConfigured
                        ))
                    } label: {
                        HStack(spacing: 8) {
                            Label(
                                LocalizedStringResource("settings.remoteAgent.quickConnect.label", defaultValue: "Quick connect"),
                                systemImage: "bolt"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            Spacer(minLength: 8)
                            Text(isConfigured
                                ? LocalizedStringResource("settings.remoteAgent.quickConnect.setUpAgain", defaultValue: "Set up again")
                                : LocalizedStringResource("settings.remoteAgent.quickConnect.setUp", defaultValue: "Set up"))
                                .font(.subheadline)
                                // Amber only where the user owes an action: an
                                // UNCONFIGURED gateway. A configured one owes
                                // nothing — "Set up again" stays quiet (amber
                                // there read as a warning about a working
                                // gateway). Dirty dims with the disabled row.
                                .foregroundStyle(
                                    isDirty
                                        ? AppColors.textTertiary
                                        : (isConfigured
                                            ? AppColors.textSecondary
                                            : AppColors.brandAmber)
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    // The action is the row; the gate caption below it is not.
                    // So the BUTTON carries the card row treatment (its own
                    // frame is the card's full bleed, wash included) and the
                    // caption takes the passive inset — never the enclosing
                    // `VStack`, which would put the wash around both.
                    .settingsCardRowButton()
                    .disabled(isDirty)
                    .accessibilityIdentifier("settings.remoteAgent.editor.quickConnect")
                    // A disabled row must say why — the gate subtitle doubles as
                    // the spoken value; enabled reads the plain Set-up state.
                    .accessibilityValue(isDirty ? Text(quickConnectDirtyGate) : Text(verbatim: ""))
                    if isDirty {
                        Text(quickConnectDirtyGate)
                            .font(.caption2)
                            .foregroundStyle(AppColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            // No height floor: the caption trails a row that
                            // already sets the pitch, so it owes only its inset.
                            .settingsCardPassiveRow(minHeight: 0)
                    }
                }
            }
        }
    }

    private var quickConnectDirtyGate: LocalizedStringResource {
        LocalizedStringResource(
            "settings.remoteAgent.quickConnect.dirtyGate",
            defaultValue: "Save or discard your changes before reconnecting."
        )
    }

    // MARK: - Zone 2: Connection (fields guarded off the descriptor)

    /// The Save-scoped credentials zone, ending in Test Connection and the
    /// Server certificate row. Each sub-view guards itself off the descriptor:
    /// `urlField`/`authToggle` hide for OpenRouter (fixed
    /// endpoint, locked auth); `nameField` is custom-only; the certificate row
    /// hides for `.systemTrustOnly`. The Model field lives in its own Save-scoped
    /// section directly below — for hosted/custom lanes whose model suggestions
    /// are loaded BY Test Connection, the catalog-backed picker appears BELOW the
    /// button that populates it.
    private var connectionSection: some View {
        Section {
            openRouterReuseRow
            nameField
            urlField
            authToggle
            keylessPublicWarning
            secretRow
            actionRow
            endpointRemedyCallout
            serverCertificateRow
        } header: {
            Text(LocalizedStringResource("settings.remoteAgent.connection.header", defaultValue: "Connection"))
        } footer: {
            connectionFooterView
        }
    }

    /// Whether the lane surfaces a Model section — hosted-model built-ins
    /// (OpenRouter, required) and customs (optional).
    private var hasModelSection: Bool {
        isCustom || (builtinDescriptor?.showsModelField == true)
    }

    // MARK: - Zone 3: Model (own section; only when the model field applies)

    /// The Model field in its OWN section — shown only for lanes that surface a
    /// model (see `hasModelSection`). Self-hosted built-ins (OpenClaw/Hermes,
    /// `model .unsupported`) have no model field, so this section is omitted and
    /// they keep a single Connection section. Capability-driven (matches
    /// `modelField`'s own guard), so it never reintroduces a per-lane structural
    /// split — empty and filled gateways render identically.
    @ViewBuilder
    private var modelSection: some View {
        if hasModelSection {
            Section {
                modelField
                saveBlockerHint
            } header: {
                // The tip rides the section HEADER because the field itself is
                // deliberately label-less (the header already names it) — there is
                // no in-row label to sit beside.
                HStack(spacing: 0) {
                    Text(LocalizedStringResource("settings.remoteAgent.model.header", defaultValue: "Model"))
                    InfoTipButton(tip: GatewayFieldTips.model)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The Connection-section footer. Hosted-model built-ins (OpenRouter) carry
    /// the third-party-service framing PLUS an INLINE "Get an API key ↗" link right
    /// after it (there is no server to run, so a single link suffices); self-hosted
    /// built-ins carry the credential-provenance affordance; customs carry the
    /// EXPLANATION affordance ("What do I enter…", `CustomGatewayHelpSheet`) —
    /// same chrome, deliberately different promise. The custom lane's inline
    /// instruction (the base-address contract) stays under the URL field it
    /// concerns, not here at the section's far end.
    @ViewBuilder
    private var connectionFooterView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if builtinDescriptor?.category == .hostedModel {
                // One flowing footer: gray descriptive text, then the tinted, tappable
                // link inline immediately after it (an `AttributedString` `.link` run,
                // NOT a stacked `Link` below). Points at the OpenRouter home page, not
                // the descriptor's `docsURL` (the deep quickstart) — the founder wants
                // the plain landing page here.
                Text(hostedFooterText)
            } else if builtinDescriptor?.credentialSource != nil {
                selfHostedFooterView
            } else if isCustom {
                customHelpFooterView
            }
        }
    }

    /// Footer for the lanes that require RUNNING A SERVER (the descriptor carries a
    /// `credentialSource`). The value here isn't prose — a manual user is almost never
    /// stuck on what a token IS, they're stuck on where THEIRS lives — so the footer is
    /// the PROVENANCE affordance alone. What each field means is the ⓘ tips' job
    /// (`GatewayFieldTips.url` / `.bearerToken`), and a descriptive sentence here would
    /// only say it a second time, one row below.
    private var selfHostedFooterView: some View {
        Button {
            showingCredentialHelp = true
        } label: {
            Label(
                LocalizedStringResource(
                    "settings.remoteAgent.credentialHelp.button",
                    defaultValue: "Where do I find Gateway URL and Bearer token?"
                ),
                systemImage: "questionmark.circle"
            )
            .font(.footnote.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        // Explicit style, never automatic — an automatic style on a button hosted
        // inside a section footer picks up the row-wide activation treatment.
        .inlineLinkButton()
    }

    /// The custom lane's counterpart — same chrome as `selfHostedFooterView`,
    /// different PROMISE: "What do I enter" (explanation), never "Where do I
    /// find" (provenance) — Conduck cannot know where an arbitrary server keeps
    /// its token, and a discovery promise it can't keep would tax the two
    /// sheets that do deliver. The sheet's full rationale lives in
    /// `CustomGatewayHelpSheet`'s header.
    private var customHelpFooterView: some View {
        Button {
            showingCustomHelp = true
        } label: {
            Label(
                LocalizedStringResource(
                    "settings.remoteAgent.customHelp.button",
                    defaultValue: "What do I enter for Gateway URL and Bearer token?"
                ),
                systemImage: "questionmark.circle"
            )
            .font(.footnote.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .inlineLinkButton()
    }

    /// The endpoint-off remedy: fires on `.remoteAgentEndpointUnexpectedResponse`
    /// (2xx but not JSON — an HTML page) or `.remoteAgentEndpointWrongEnvelope`
    /// (2xx, JSON, wrong shape — a disabled endpoint answering `{}` is the same
    /// trap wearing JSON). Both flagship self-hosted gateways ship their OpenAI
    /// endpoint DISABLED, which is far and away the commonest reason a
    /// hand-configured gateway fails — their descriptors name that likely cause.
    ///
    /// Amber, and worded as a LIKELIHOOD — the identical symptom is produced by a
    /// reverse-proxy login page or a Cloudflare Access interstitial. The red error
    /// above states the SYMPTOM; this only offers the probable CAUSE, so an assertive
    /// "your endpoint is off" would send the wrong user down the wrong path.
    ///
    /// CUSTOM lanes (`builtinDescriptor == nil`) have no saved provenance: the
    /// endpoint may be existing OpenAI-compatible software OR an adapter built for
    /// Conduck. The remedy therefore presents both server-side checks instead of
    /// guessing: `--check-server` for existing software; `--check-adapter` for a
    /// Conduck adapter. An interactive PASS can continue directly into setup.
    /// The download step (`Constants.conduckConnectDownloadCommand`) leads both:
    /// this user hand-configured their gateway and has typically never run
    /// `conduck-connect`, so naming an action alone would print a command they
    /// cannot execute.
    /// A built-in whose descriptor carries NO remedy (hosted OpenRouter) stays
    /// silent: its user can't run anything on the server side.
    @ViewBuilder
    private var endpointRemedyCallout: some View {
        if let code = viewModel.remoteAgentLastErrorCodes[ref],
           code == AppError.remoteAgentEndpointUnexpectedResponse.errorCode
            || code == AppError.remoteAgentEndpointWrongEnvelope.errorCode {
            if let remedy = builtinDescriptor?.endpointDisabledRemedy {
                amberCallout(
                    systemImage: "wrench.and.screwdriver",
                    title: LocalizedStringResource(
                        "settings.remoteAgent.endpointDisabled.title",
                        defaultValue: "Most likely: the AI endpoint is switched off"
                    ),
                    body: remedy
                )
            } else if isCustom {
                amberCallout(
                    systemImage: "stethoscope",
                    title: LocalizedStringResource(
                        "settings.remoteAgent.customCheck.title",
                        defaultValue: "Choose the matching server check"
                    ),
                    body: LocalizedStringResource(
                        "settings.remoteAgent.customCheck.body",
                        defaultValue: "On that machine, download the script with \(Constants.conduckConnectDownloadCommand), then run the matching check. Already running OpenAI-compatible software? Run bash conduck-connect.sh --check-server. If this is an adapter built for Conduck, run bash conduck-connect.sh --check-adapter instead. Both send live test requests without changing server configuration. After a PASS, the interactive script can continue into setup."
                    )
                )
            }
        }
    }

    /// Keyless auth on an address that looks reachable from the open internet.
    /// `conduck-connect` HARD-REFUSES this combination ("that would put an
    /// unauthenticated, tool-capable agent on the open internet") — the manual
    /// editor can't refuse (a split-DNS internal hostname is indistinguishable from
    /// a public one), so it warns.
    ///
    /// Worded as *appears* public, never as fact: `HostReachabilityClass` reads an
    /// ordinary hostname as `.publicHost`, so a MagicDNS or split-DNS name would be
    /// falsely accused. The stored transport hint is what rescues a paired tailnet
    /// host. (Tailscale FUNNEL still classifies public — correctly: Funnel IS public
    /// egress, and keyless behind it is exactly the dangerous case.)
    @ViewBuilder
    private var keylessPublicWarning: some View {
        if isKeyless, urlLooksPublic {
            amberCallout(
                systemImage: "exclamationmark.shield",
                title: LocalizedStringResource(
                    "settings.remoteAgent.keylessPublic.title",
                    defaultValue: "This address appears public"
                ),
                body: LocalizedStringResource(
                    "settings.remoteAgent.keylessPublic.body",
                    defaultValue: "Without a token, anyone who can reach this address can use your AI and its tools. Turn the token back on, or move the gateway onto a private network like Tailscale. If this address is already private (a Tailscale or internal name), you can ignore this."
                )
            )
        }
    }

    /// Whether the typed URL's host classifies as reachable from the open internet,
    /// judged WITH the stored pairing transport so a tailnet host isn't accused.
    private var urlLooksPublic: Bool {
        let trimmed = (viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let host = URLComponents(string: trimmed)?.host else { return false }
        return HostReachabilityClass.classify(host, transportHint: transportHint) == .publicHost
    }

    /// Local spelling of the shared `AmberCallout` — the same shape the guided
    /// Commands step's handoff callout and the pairing review card use, so "amber
    /// block" means one consistent thing across the setup surfaces. Kept as a
    /// wrapper so this file's call sites keep reading `body:`, and so the card
    /// row inset is declared ONCE for both callouts: a callout is something to
    /// read, not a row action, so it takes the passive treatment and gets no
    /// hover wash.
    private func amberCallout(
        systemImage: String,
        title: LocalizedStringResource,
        body: LocalizedStringResource
    ) -> some View {
        AmberCallout(systemImage: systemImage, title: title, message: body)
            .settingsCardPassiveRow()
    }

    /// Builds the hosted (OpenRouter) footer as a single `AttributedString` so the
    /// "Get an API key ↗" link flows inline right after the descriptive sentence.
    /// Reuses the two existing localized strings (no URL baked into a translatable
    /// string); the link target is the OpenRouter landing page.
    private var hostedFooterText: AttributedString {
        var text = AttributedString(String(localized: LocalizedStringResource(
            "settings.remoteAgent.section.footer.hosted",
            defaultValue: "Hosted by OpenRouter, not your own server."
        )))
        text += AttributedString(" ")
        var link = AttributedString(String(localized: LocalizedStringResource(
            "settings.remoteAgent.guided.hosted.link",
            defaultValue: "Get an API key"
        )) + " ↗")
        link.link = URL(string: "https://openrouter.ai")
        text += link
        return text
    }

    /// A visible reason the top-trailing Save is disabled when the MODEL — this
    /// section's own required field — is empty, so a hosted lane that requires
    /// one (OpenRouter) never reads as a dead, unexplained button.
    ///
    /// Scoped to this section deliberately. It renders inside `modelSection`, so
    /// it can only ever explain a blocker belonging to the Model field; a hint
    /// about the Name field would print two zones below the field it names, and
    /// for a lane with no model section at all it would never render. Each
    /// required field carries its own message instead — see `nameField`.
    ///
    /// INVALID only, never merely pristine. A gateway with nothing to save is
    /// the ordinary state of opening a working one to look at it; a caption
    /// there would render on the most common screen in the flow and read as a
    /// warning about something that is fine. That case is announced to
    /// VoiceOver on the Save button itself instead. Same argument the
    /// Quick connect row makes for its quiet "Set up again" treatment.
    @ViewBuilder
    private var saveBlockerHint: some View {
        if builtinDescriptor?.requiresModel == true,
           (viewModel.remoteAgentModelStrings[ref] ?? "")
               .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(
                LocalizedStringResource("settings.remoteAgent.save.needsModel", defaultValue: "Pick a model to save."),
                systemImage: "info.circle"
            )
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .settingsCardPassiveRow()
        }
    }

    // MARK: - Name field (custom-only)

    @ViewBuilder
    private var nameField: some View {
        if case .custom(let id) = ref {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource("settings.remoteAgent.custom.name.label", defaultValue: "Name"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                TextField(
                    "",
                    text: $pendingName,
                    prompt: Text(LocalizedStringResource(
                        "settings.remoteAgent.custom.name.placeholder",
                        defaultValue: "My gateway"
                    ))
                )
                    .labelsHidden()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                if viewModel.remoteAgentNameClashes(pendingName, excludingID: id) {
                    Label(
                        LocalizedStringResource(
                            "settings.remoteAgent.custom.name.duplicate",
                            defaultValue: "Another gateway already uses this name."
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(AppColors.warning)
                } else if isDirty, pendingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // A name is REQUIRED to save a custom, so an empty one greys
                    // Save out — say why, beside the field that owns the problem
                    // rather than in the save-blocker slot, which lives in the
                    // Model section two zones down.
                    //
                    // Dirty-gated so it reads as an unmet requirement, not a
                    // scolding: a pristine draft opens with this field legitimately
                    // empty and its placeholder already showing, and a hint there
                    // would name only one of the two empty required fields. Once
                    // the user has actually started, it is the live answer to "why
                    // can't I save?". Same copy as the VM's own save guard, so the
                    // pre-emptive hint and the post-failure message cannot diverge.
                    Label(
                        LocalizedStringResource(
                            "remoteAgent.custom.name.required",
                            defaultValue: "Give this gateway a name."
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                }
            }
            // A label + field + hints block is a place to TYPE, not one row
            // action: it takes the card row's inset and height floor and no
            // wash. The stacked label is also why nothing here depends on a
            // `Form` laying a label column out — the block reads the same in a
            // hand-drawn card as it does in the iOS grouped Form.
            .settingsCardPassiveRow()
        }
    }

    // MARK: - URL field

    @ViewBuilder
    private var urlField: some View {
        // Hidden for hosted-model built-ins (OpenRouter): the endpoint is fixed,
        // not user-supplied. Self-hosted built-ins + customs keep the field.
        if builtinDescriptor?.hidesURLField != true {
            // Writes THROUGH the VM (not the raw dict) so a keystroke retracts a
            // green earned by a DIFFERENT URL — a stale "Connected" beside an edited
            // address is the editor's most convincing lie.
            let urlBinding = Binding<String>(
                get: { viewModel.remoteAgentURLStrings[ref] ?? "" },
                set: { viewModel.setRemoteAgentURLBuffer($0, for: ref) }
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text(LocalizedStringResource("settings.remoteAgent.url.label", defaultValue: "Gateway URL"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                    InfoTipButton(tip: GatewayFieldTips.url)
                    Spacer(minLength: 0)
                }
                TextField("", text: urlBinding, prompt: Text(urlPlaceholder))
                    .labelsHidden()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                if let portHint = nonStandardPortHint {
                    Text(portHint)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                if let endpointSuffixHint {
                    Text(endpointSuffixHint)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                if let temporaryTunnelHint {
                    // Warning-tinted rather than tertiary: the other two hints
                    // CONFIRM what the user typed, while this one predicts a
                    // failure they will otherwise meet as "gateway unreachable".
                    Text(temporaryTunnelHint)
                        .font(.caption2)
                        .foregroundStyle(AppColors.warning)
                }
                // The footer says what to DO (mirrors the file-server URL field);
                // reachability nuance (Tailscale vs home network) lives in the ⓘ tip.
                // The custom lane's variant adds the base-address contract — pasting
                // the full endpoint out of a vendor's docs is that lane's natural
                // mistake, and `endpointSuffixHint` only catches it AFTER the paste.
                Text(isCustom
                    ? LocalizedStringResource(
                        "settings.remoteAgent.url.footer.custom",
                        defaultValue: "Paste the https:// address your server is reachable at — just the base address, Conduck adds /v1/… itself."
                    )
                    : LocalizedStringResource(
                        "settings.remoteAgent.url.footer",
                        defaultValue: "Paste the https:// address your gateway is reachable at."
                    ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCardPassiveRow()
        }
    }

    /// Announce — BEFORE Save/Test silently rewrites it — that the typed URL
    /// carries an API path Conduck appends itself. Pasting the full endpoint out
    /// of a gateway's docs is the natural mistake (and, uncorrected, would make
    /// the client request `…/v1/chat/completions/v1/chat/completions`).
    /// `SettingsViewModel.normalizedGatewayBaseURL` trims it either way; saying so
    /// beats trimming invisibly, which reads as the field eating what was typed.
    private var endpointSuffixHint: String? {
        let trimmed = (viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https"
        else { return nil }
        let normalized = SettingsViewModel.normalizedGatewayBaseURL(url)
        guard normalized.absoluteString != url.absoluteString else { return nil }
        return String(
            localized: "settings.remoteAgent.url.baseHint",
            defaultValue: "Conduck adds /v1/… itself — it will use \(normalized.absoluteString)"
        )
    }

    // MARK: - Model field

    @ViewBuilder
    private var modelField: some View {
        // Shown for customs (optional model override) AND for hosted-model
        // built-ins (OpenRouter) where picking the model IS the config. Self-hosted
        // built-ins (OpenClaw/Hermes) keep it hidden — the model lives server-side.
        if hasModelSection {
            let modelBinding = Binding<String>(
                get: { viewModel.remoteAgentModelStrings[ref] ?? "" },
                set: { viewModel.remoteAgentModelStrings[ref] = $0 }
            )
            VStack(alignment: .leading, spacing: 4) {
                // No inline "Model" label — the enclosing `modelSection` header
                // already names the field. The requirement is conveyed by the
                // helper below (custom: "leave blank…") and, for a required hosted
                // model that's still empty, the `saveBlockerHint` ("Pick a model to
                // save.") — so a standalone "(required)/(optional)" tag here would
                // just be noise next to the section header.
                TextField(
                    "",
                    text: modelBinding,
                    prompt: Text(builtinDescriptor?.category == .hostedModel
                        ? LocalizedStringResource(
                            "settings.remoteAgent.model.placeholder.hosted",
                            defaultValue: "e.g. anthropic/claude-opus-4"
                        )
                        : LocalizedStringResource(
                            "settings.remoteAgent.model.placeholder",
                            defaultValue: "e.g. llama3"
                        ))
                )
                    .labelsHidden()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                // Hosted-model built-ins (OpenRouter) get only the routing-suffix
                // syntax (the discovery mechanics — "run Test Connection / type an
                // ID" — are the ⓘ tip's and the empty-state hint's job, so saying
                // them here again was pure repetition); customs keep the
                // self-hosted (Ollama/vLLM) framing, whose "leave blank" optional
                // semantics live nowhere else.
                Text(builtinDescriptor?.category == .hostedModel
                    ? LocalizedStringResource(
                        "settings.remoteAgent.model.helper.hosted.v2",
                        defaultValue: "Add :floor to a model ID for the cheapest provider, or :nitro for the fastest."
                    )
                    : LocalizedStringResource(
                        "settings.remoteAgent.model.helper",
                        defaultValue: "Leave blank to let your gateway choose. Ollama and vLLM usually need a model ID running on your server, e.g. 'llama3'."
                    ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)

                modelSuggestionList(binding: modelBinding)
            }
            .settingsCardPassiveRow()
        }
    }

    /// Suggestion chips populated from Test Connection's `/v1/models` list. The
    /// two non-populated states are explicit — a spinner row while a probe (which
    /// is what loads the catalog) is in flight, and a "run Test Connection" hint
    /// when nothing has been fetched — so an empty strip never reads as broken.
    /// Free-text is always allowed.
    ///
    /// For large catalogs (hosted gateways like OpenRouter return 300+ models) the
    /// unbounded chip strip becomes a wall, so a lightweight filter `TextField`
    /// appears above the chips once the list crosses `Constants`-free threshold of
    /// 12; it narrows the chips case-insensitively by the typed substring WITHOUT
    /// touching the model `binding` (free-text entry is unaffected). Short lists
    /// (self-hosted) keep the bare strip — no filter shown.
    @ViewBuilder
    private func modelSuggestionList(binding: Binding<String>) -> some View {
        let suggestions = viewModel.remoteAgentModelSuggestions[ref] ?? []
        if suggestions.isEmpty {
            if case .checking = rowState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.model.suggestions.loading",
                        defaultValue: "Loading models…"
                    ))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(.top, 2)
            } else {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.model.suggestions.empty",
                    defaultValue: "No models yet — run Test Connection to load them."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.top, 2)
            }
        } else {
            let showFilter = suggestions.count > 12
            let query = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = (showFilter && !query.isEmpty)
                ? suggestions.filter { $0.localizedCaseInsensitiveContains(query) }
                : suggestions
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.model.suggestions.header",
                    defaultValue: "Available models"
                ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                if showFilter {
                    TextField(
                        "",
                        text: $modelFilter,
                        prompt: Text(LocalizedStringResource(
                            "settings.remoteAgent.model.suggestions.filter.placeholder",
                            defaultValue: "Filter models"
                        ))
                    )
                        .labelsHidden()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                }
                if visible.isEmpty {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.model.suggestions.noMatch",
                        defaultValue: "No models match your filter."
                    ))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visible, id: \.self) { model in
                                Button {
                                    binding.wrappedValue = model
                                } label: {
                                    Text(model)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(AppColors.backgroundSecondary))
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                // A caption2 chip with 4pt of vertical padding is
                                // a ~21pt target — under the pointer floor. The
                                // chip IS a capsule, so the wash takes that
                                // outline; no `horizontalPadding`, since the 8pt
                                // side inset already lives INSIDE the drawn pill
                                // and more would widen the wash past its edge.
                                .pointerIconButton(shape: .capsule)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Authentication toggle (Bearer token vs keyless)

    /// Inline Toggle for the gateway's two auth schemes (`.bearer` when ON,
    /// `.none` when OFF). BUFFER-ONLY — Save is the single commit point.
    ///
    /// This row carries the keyless affordance: its helper `Text` swaps its STRING
    /// on the toggle, and the flip drives `secretRow`'s presence (the bearer-token
    /// summary row shows ONLY under `.bearer`, disappears when keyless). The secret
    /// itself is entered in `SecretEntrySheet` — there is NO `SecureField` anywhere
    /// in this editor, so showing/hiding `secretRow` on `isKeyless` can't trip the
    /// out-of-process macOS `NSSecureTextField` layout recursion that the old
    /// inline `tokenField` had to avoid (see `SecretEntrySheet.swift`).
    @ViewBuilder
    private var authToggle: some View {
        // Hidden for built-ins with a LOCKED auth scheme (hosted-model OpenRouter,
        // locked .bearer): the toggle would be inert. The locked scheme is already
        // seeded into the auth-scheme buffer by the load path, so `secretRow` below
        // still renders (bearer requires a token). Self-hosted built-ins + customs
        // (showsAuthToggle == true / nil) keep the toggle.
        if builtinDescriptor?.showsAuthToggle != false {
            authToggleBody
        }
    }

    @ViewBuilder
    private var authToggleBody: some View {
        // Title + caption + tip form the leading block; the switch is `labelsHidden`
        // and trails it. The caption stays glued to the title (the native iOS
        // Settings idiom — the switch centers against the whole block), but the ⓘ
        // must NOT live inside the Toggle's label: a label is part of the toggle's
        // hit area, so a tap meant for the tip would flip the auth scheme.
        //
        // The tip rides the TITLE line, not the gap before the switch: the caption
        // wraps to two lines and ate the row's width, which squeezed the ⓘ up
        // against the switch and left it looking like a stray dot mid-row.
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.auth.requiresToken.label",
                        defaultValue: "Requires a bearer token"
                    ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                    InfoTipButton(tip: GatewayFieldTips.requiresToken)
                    Spacer(minLength: 0)
                }
                // String-swap (NOT an if/else producing two Texts) so view identity
                // is stable — only the localized content differs.
                Text(isKeyless
                    ? LocalizedStringResource(
                        "settings.remoteAgent.auth.keyless.helper",
                        defaultValue: "Keyless — no token sent. Use only on a private network (Tailscale/LAN); HTTPS encrypts traffic but doesn't limit who can reach your gateway."
                    )
                    : LocalizedStringResource(
                        "settings.remoteAgent.auth.requiresToken.helper",
                        defaultValue: "Turn off only for a keyless gateway on a private network (Tailscale/LAN)."
                    ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding<Bool>(
                get: { !isKeyless },
                set: { requiresToken in
                    viewModel.setRemoteAgentAuthSchemeBuffer(requiresToken ? .bearer : .none, for: ref)
                    if !requiresToken { pendingToken = "" }   // drop a typed-but-unsaved token when going keyless
                }
            )) {
                EmptyView()
            }
            .labelsHidden()
            #if os(macOS)
            // A `Form` is what resolves `.automatic` to a switch on macOS;
            // outside one it resolves to a CHECKBOX, and `.tint` alone does not
            // reshape the control. iOS already renders a switch by default, so
            // the request is macOS-only rather than unconditional.
            .toggleStyle(.switch)
            #endif
            // The visual title lives outside the Toggle, so the control needs
            // its own VoiceOver name — an unlabeled switch reads as just "off".
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.remoteAgent.auth.requiresToken.label",
                defaultValue: "Requires a bearer token"
            )))
            .tint(AppColors.brandAmber)
        }
        // Passive: the ⓘ and the switch are two INDEPENDENT actions sharing one
        // row, so there is no single row-level action for a wash to stand for —
        // it would light the helper sentence and the gap before the switch as
        // though either were clickable. Inset and height floor only. (The
        // `CustomSTTConfigBody` auth row takes the whole-row `Button` instead,
        // which it can precisely because it carries no tip.)
        .settingsCardPassiveRow()
    }

    // MARK: - OpenRouter key reuse (voice → gateway; STAGED intent)

    /// Offer to reuse the OpenRouter VOICE key for this hosted gateway — shown
    /// only on the OpenRouter built-in, only when voice has a saved key, the
    /// gateway has no saved token, and the reuse isn't already staged. Tapping
    /// STAGES the intent (`stagedVoiceKeyReuse`) — nothing persists until Save
    /// resolves it VM-side; the raw key never enters this View.
    @ViewBuilder
    private var openRouterReuseRow: some View {
        if case .builtin(.openrouter) = ref,
           viewModel.openRouterVoiceKeyAvailable,
           viewModel.remoteAgentMaskedTails[ref] == nil,
           !stagedVoiceKeyReuse {
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
                    stagedVoiceKeyReuse = true
                    // A different credential is now in play — retract any live
                    // verdict the previous one earned (same contract as a
                    // token commit through the entry sheet).
                    viewModel.noteRemoteAgentSecretEdited(for: ref)
                }
            )
            // A callout that owns its own inner button, not a single row
            // action: passive treatment, so no wash promises a row-wide tap.
            .settingsCardPassiveRow()
        }
    }

    // MARK: - Secret row (tap-in entry; the SecureField lives in SecretEntrySheet,
    // never inline in this editor — see SecretEntrySheet.swift for why).

    /// A non-secure summary row that opens the secret-entry sheet. Shown ONLY when
    /// auth is `.bearer`; when keyless it's absent. Because it is an ORDINARY row
    /// (no `SecureField`), toggling its presence on `isKeyless` is recursion-free —
    /// the exact thing the old inline `tokenField` could not do on macOS.
    @ViewBuilder
    private var secretRow: some View {
        if !isKeyless {
            // The ⓘ is a SIBLING of the row's action, never inside it: a Button's
            // `.contentShape(Rectangle())` claims its whole frame, so a nested tip
            // would hand every tap to the secret sheet. To put the tip NEXT TO ITS
            // LABEL (not stranded at the far edge) the row's action is split in two:
            // a label Button that hugs its text, and a trailing Button covering the
            // status + chevron — same action, so the row still feels whole, and the
            // ⓘ sits in between with its own disjoint hit area.
            //
            // VoiceOver sees the row action (label + status as its VALUE), the tip,
            // and — when a voice-key reuse is staged — the "Change" undo. The
            // trailing status Button is `.accessibilityHidden` — it is a redundant
            // hit area, not a second thing to announce — and the row deliberately
            // carries NO `.accessibilityElement(children: .combine)`.
            HStack(spacing: 0) {
                Button {
                    showingSecretSheet = true
                } label: {
                    // Row label from the descriptor for built-ins ("API key" for
                    // OpenRouter, "Bearer token" for OpenClaw/Hermes); customs fall
                    // back to "Bearer token".
                    Text(secretRowLabel)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        #if os(macOS)
                        // Both halves claim the card row's FULL height as their
                        // own live band, so the pointer activates the row from
                        // its top edge to its bottom rather than only over the
                        // glyphs. Height alone: the label's leading inset is the
                        // row's, applied once by `.settingsCardRowControl()`
                        // below, and any extra here would indent this row past
                        // every other row in the card.
                        .frame(minHeight: SettingsCardMetrics.rowMinHeight)
                        #endif
                        .contentShape(Rectangle())
                }
                // `.plain`, and deliberately no per-half style: the two halves
                // are ONE action split only so the tip can sit between them, so
                // the wash belongs to the whole row and arrives once, from
                // `.settingsCardRowControl()`. A style on a half would stack a
                // second tint over its share of the row and draw a seam down
                // the middle on hover.
                .buttonStyle(.plain)
                .accessibilityValue(secretStatusAccessibilityValue)

                InfoTipButton(tip: secretTip)

                Button {
                    showingSecretSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Spacer(minLength: 8)
                        secretStatusLabel
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    #if os(macOS)
                    .frame(maxWidth: .infinity, minHeight: SettingsCardMetrics.rowMinHeight)
                    #endif
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                if stagedVoiceKeyReuse {
                    // The undo back to manual entry — clears the staged intent
                    // without touching the (empty) typed buffer. A verdict
                    // earned by the staged key dies with it.
                    Button {
                        stagedVoiceKeyReuse = false
                        viewModel.noteRemoteAgentSecretEdited(for: ref)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    // Keeps its own icon wash — unlike the two halves above,
                    // this is a DIFFERENT action from the row's, so its own
                    // hover affordance is the honest one.
                    .pointerIconButton()
                    .padding(.leading, 8)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "settings.remoteAgent.token.stagedVoiceKey.change",
                        defaultValue: "Change"
                    )))
                }
            }
            // The row's own action, so the inset band the sub-`Button`s can't
            // reach opens the sheet too instead of washing and doing nothing.
            .settingsCardRowControl { showingSecretSheet = true }
        }
    }

    private var secretRowLabel: String {
        builtinDescriptor?.tokenLabel
            ?? String(localized: LocalizedStringResource("settings.remoteAgent.token.label", defaultValue: "Bearer token"))
    }

    /// The secret's state, shared by the visible trailing label and the row's
    /// VoiceOver value so the two can't drift.
    private enum SecretRowStatus {
        case stagedVoiceKey     // OpenRouter voice-key reuse staged (not yet saved)
        case entered            // typed but not yet saved
        case stored(String)     // saved + valid → masked tail
        case notSet
    }

    private var secretRowStatus: SecretRowStatus {
        if stagedVoiceKeyReuse {
            return .stagedVoiceKey
        }
        if !pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .entered
        }
        if let masked = viewModel.remoteAgentMaskedTails[ref], case .valid = rowState {
            return .stored(masked)
        }
        return .notSet
    }

    /// Trailing status on `secretRow`: a staged voice-key reuse names itself; a
    /// typed-but-unsaved token shows "Entered" (never the value); a stored+valid
    /// token shows its masked tail; otherwise a "Set" prompt.
    @ViewBuilder
    private var secretStatusLabel: some View {
        switch secretRowStatus {
        case .stagedVoiceKey:
            Text(LocalizedStringResource("settings.remoteAgent.token.stagedVoiceKey", defaultValue: "OpenRouter voice key selected"))
                .font(.caption)
                .foregroundStyle(AppColors.success)
        case .entered:
            Text(LocalizedStringResource("settings.secret.entered", defaultValue: "Entered"))
                .font(.caption)
                .foregroundStyle(AppColors.success)
        case .stored(let masked):
            Text(masked)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppColors.textTertiary)
        case .notSet:
            Text(LocalizedStringResource("settings.secret.notSet", defaultValue: "Set"))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    /// Same status, spoken — the trailing Button that draws it is a11y-hidden, so
    /// VoiceOver gets it here as the row action's value ("Bearer token, Entered").
    private var secretStatusAccessibilityValue: Text {
        switch secretRowStatus {
        case .stagedVoiceKey:
            return Text(LocalizedStringResource("settings.remoteAgent.token.stagedVoiceKey", defaultValue: "OpenRouter voice key selected"))
        case .entered:
            return Text(LocalizedStringResource("settings.secret.entered", defaultValue: "Entered"))
        case .stored(let masked):
            return Text(masked)
        case .notSet:
            return Text(LocalizedStringResource("settings.secret.notSet", defaultValue: "Set"))
        }
    }

    /// "Test Connection" — a quiet secondary action (neutral `.bordered`, not the
    /// amber primary). Validate-only; Save (top-trailing) is the commit. The
    /// destructive Forget/Delete lives in its own bottom section (`destructiveSection`).
    @ViewBuilder
    private var actionRow: some View {
        // The Test Connection result is folded into this row (no standalone
        // resting status row). `ViewThatFits` keeps the feedback inline-trailing
        // while it fits at its IDEAL width (iPad/Mac, short statuses), then falls
        // back to a stacked row-below when it can't — a narrow iPhone OR a long
        // multi-line error. `.lineLimit(1)` + `.fixedSize` on the inline variant
        // stops a truncating row from masquerading as a fit (same guard as
        // `SettingsView.summaryRow`). When `statusFeedback` is empty (at rest)
        // the inline variant trivially fits → the row is just the button.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                testButton
                Spacer(minLength: 12)
                statusFeedback
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    testButton
                    Spacer()
                }
                statusFeedback
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A bordered button beside its own result, not a row-wide action: the
        // card row's inset and height floor, no wash.
        .settingsCardPassiveRow()
    }

    private var testButton: some View {
        Button {
            runTestConnection()
        } label: {
            Label(
                LocalizedStringResource("settings.remoteAgent.testConnection.button", defaultValue: "Test Connection"),
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .disabled(testButtonDisabled)
    }

    /// Drop every editor-local buffer and re-hydrate from storage, then
    /// re-baseline the appear-time snapshot — for flows that PERSISTED config
    /// outside this editor while it was open (a setup-code import inside the
    /// Quick connect guided cover), so the buffered chrome's dirty check doesn't
    /// fight the just-written config on the way out.
    private func rehydrateFromStorage() {
        rehydratingAfterGuidedReturn = true
        Task {
            await viewModel.cancelRemoteAgentEdit(ref: ref)   // re-hydrates from storage, never writes
            pendingToken = ""
            stagedVoiceKeyReuse = false
            pendingImageHistory = nil
            pendingBadgeColorID = nil
            pendingMonogram = nil
            if let gateway = customGateway { pendingName = gateway.name }
            rebaselineOriginals()
            rehydratingAfterGuidedReturn = false
        }
    }

    /// Re-snapshot ALL dirty-detection originals from the current buffers — the
    /// single source for every "the form is now pristine" re-baseline (appear,
    /// save, guided-cover return, forget). Centralizing this fixes a class of bug
    /// where an inline block forgot a field (the built-in Forget path omitted
    /// `originalAuthKeyless`, so a cleared keyless built-in still read dirty).
    private func rebaselineOriginals() {
        originalName = pendingName
        originalURL = viewModel.remoteAgentURLStrings[ref] ?? ""
        originalModel = viewModel.remoteAgentModelStrings[ref] ?? ""
        originalCert = viewModel.remoteAgentCertFingerprints[ref] ?? ""
        originalAuthKeyless = isKeyless
    }

    private var forgetButtonTitle: LocalizedStringResource {
        // Catalog values: custom = "Delete", built-in = "Forget". Defaults match
        // the catalog so code + runtime agree (a reworded default would be ignored
        // for an existing key). The confirmation dialog explains the distinction.
        isCustom
            ? LocalizedStringResource("settings.remoteAgent.delete.button", defaultValue: "Delete")
            : LocalizedStringResource("settings.remoteAgent.clear.button", defaultValue: "Forget")
    }

    // MARK: - Zone 6: Destructive (Forget / Delete — plain red, isolated last)

    /// The Forget (built-in) / Delete (custom) destructive action, in its OWN
    /// Section at the bottom of the form, isolated from the config fields (iOS
    /// HIG) — deliberately header-less. Mirrors the sibling custom-STT editor's
    /// delete row (`CustomSTTConfigBody.destructiveSection`): the whole `Label`
    /// is colored via `.foregroundStyle(AppColors.error)` so BOTH the trash icon
    /// and the title go red — a `.bordered` button + `.tint` left the SF Symbol
    /// icon stuck on the system accent (blue), reading as half-rendered. iOS: a
    /// full-width CENTERED red row (whole grouped-list cell is the tap target —
    /// large/accessible). macOS: a quiet LEFT-aligned `.plain` red text button
    /// (a centered+`Spacer` row renders as a heavy filled red slab in a macOS
    /// grouped Form), plus a clear-header spacer that pushes the extra
    /// destructive-isolation gap. Shown for a custom always; for a built-in
    /// whenever this device holds ANY stored state for it — keyed on stored
    /// state, not on a stored token tail (a keyless `.none` OpenClaw/Hermes has
    /// no token by definition and still needs its Forget), and deliberately
    /// wider than CONFIGURED: a half-configured built-in (a URL that synced in
    /// without its token, or a leftover slot) is precisely what Diagnostics
    /// tells the user to come here and remove.
    @ViewBuilder
    private var destructiveSection: some View {
        if viewModel.hasStoredRemoteAgentState(ref) || isCustom {
            Section {
                Button(role: .destructive) {
                    showingForgetConfirm = true
                } label: {
                    #if os(macOS)
                    Label(forgetButtonTitle, systemImage: "trash")
                        .font(.subheadline)
                    #else
                    HStack {
                        Spacer()
                        Label(forgetButtonTitle, systemImage: "trash")
                            .font(.subheadline)
                        Spacer()
                    }
                    #endif
                }
                #if os(macOS)
                .settingsCardRowButton()
                #endif
                .foregroundStyle(AppColors.error)
            } header: {
                #if os(macOS)
                // Not a header — an invisible spacer that adds the extra
                // destructive-isolation separation above this section.
                Color.clear.frame(height: 8)
                #endif
            }
        }
    }

    /// Run the Test Connection probe — VALIDATE-ONLY (Save is the single commit
    /// point; Test never persists). The VM reads url/fingerprint/auth-scheme/model
    /// from its own buffers and resolves the staged token intent internally
    /// (keyless, stored-retest, typed, voice-key reuse). NOTE: the token buffer is
    /// NOT cleared here — Save still needs the typed token to persist it.
    private func runTestConnection() {
        let staged = stagedToken
        let name = isCustom ? pendingName : nil
        Task {
            await viewModel.testRemoteAgent(ref: ref, stagedToken: staged, name: name)
        }
    }

    private var testButtonDisabled: Bool {
        let urlEmpty = (viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if urlEmpty { return true }
        // Custom: a name is required before the gateway can be saved.
        if isCustom, pendingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Keyless: URL (+ custom name) is enough — no token needed to test.
        if isKeyless { return false }
        // A staged voice-key reuse is a live credential intent → testable.
        if stagedVoiceKeyReuse { return false }
        // A freshly-typed token → testable. No typed token → still testable
        // IFF a token is already stored (re-test the saved config).
        if !pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return viewModel.remoteAgentMaskedTails[ref] == nil
    }

    // MARK: - Save gateway (the single commit point — surfaced in the chrome)

    /// Whether Save may fire: the form must be VALID *and* something must have
    /// changed, and a commit must not already be in flight.
    ///
    /// Validity alone is not enough. `saveRemoteAgent` is not idempotent — it
    /// clears the active session pointer and drops `remoteAgentLiveValidated`,
    /// so re-committing an untouched gateway silently demotes a green
    /// "Connected" to a bare "Saved". An enabled Save on a form with nothing to
    /// save is also the wrong claim to make: a pairing import already committed,
    /// so the truthful state on return is an inert Save, not an armed one. The
    /// sibling file-transfer editor has always gated this way.
    private var canSave: Bool { isValidForSave && isDirty && !saving }

    /// URL non-empty, plus a name for a custom — the minimum to persist.
    /// Validity ONLY; `canSave` adds the dirty + in-flight gates.
    private var isValidForSave: Bool {
        let urlOK = !(viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let nameOK = !isCustom || !pendingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A hosted backend whose `model` is `.required` (OpenRouter) can't be
        // saved until a model is picked or typed — makes the `.required` policy
        // live and prevents a silent fall-back to the provider's account-default
        // model. No-op for OpenClaw/Hermes (`.unsupported`) + customs (`.optional`).
        let modelOK = builtinDescriptor?.requiresModel != true
            || !(viewModel.remoteAgentModelStrings[ref] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Hosted lane (locked `.bearer`): SOME key intent must exist — a staged
        // voice-key reuse counts, a typed token counts, a stored token counts.
        // Self-hosted/custom lanes keep their laxer gate (the VM's save guard is
        // the backstop) — a keyless lane trivially passes.
        let tokenOK = builtinDescriptor?.category != .hostedModel
            || stagedVoiceKeyReuse
            || !pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.remoteAgentMaskedTails[ref] != nil
        return urlOK && nameOK && modelOK && tokenOK
    }

    /// Persist all buffers; on success either prompt to set this as the default
    /// gateway (a new, non-default additional gateway) or dismiss immediately.
    private func saveTapped() {
        // Re-entrancy gate: the commit below spans many awaits with the button
        // still on screen, so a double-tap would run two commit chains over the
        // same buffers. `canSave` reads this too, so the button greys for the
        // duration rather than merely ignoring the second tap.
        guard !saving else { return }
        saving = true
        let staged = stagedToken
        let name = isCustom ? pendingName : nil
        // Snapshot the pre-save state the make-default decision keys off, BEFORE
        // the save mutates the configured set / default pointer.
        let hadAnyConfiguredBefore = viewModel.hasAnyConfiguredRemoteAgent
        let wasConfiguredBefore = viewModel.isRemoteAgentConfigured(ref)
        // Buffered non-connection edits — resolve the commit intents NOW: the
        // save may rename the gateway, which shifts the derived-monogram
        // baseline the override-vs-clear decision compares against.
        let imageHistoryToCommit: ImageHistoryPolicy? = {
            guard let pendingImageHistory,
                  pendingImageHistory != viewModel.imageHistoryPolicy(ref) else { return nil }
            return pendingImageHistory
        }()
        let badgeToCommit: (colorID: String?, monogram: String?)? = {
            guard badgeIsDirty else { return nil }
            let monogram: String?
            if let pendingMonogram, pendingMonogram != effectiveStoredMonogram {
                let trimmed = pendingMonogram.trimmingCharacters(in: .whitespacesAndNewlines)
                monogram = trimmed.isEmpty ? nil : trimmed
            } else {
                monogram = customGateway?.monogram
            }
            return (pendingBadgeColorID ?? customGateway?.colorID, monogram)
        }()
        Task {
            defer { saving = false }
            let ok = await viewModel.saveRemoteAgent(ref: ref, name: name, stagedToken: staged)
            guard ok else { return }
            // Connection committed — commit the buffered page edits with it
            // (one Save, everything lands; a failed save keeps them staged).
            if let imageHistoryToCommit {
                viewModel.setImageHistoryPolicy(imageHistoryToCommit, for: ref)
            }
            if let badgeToCommit, case .custom(let id) = ref {
                await updateBadge(id: id, colorID: badgeToCommit.colorID, monogram: badgeToCommit.monogram)
            }
            // Neutralize the onDisappear cancel safety-net, clear the typed
            // token / staged reuse intent / pending page edits, then re-baseline
            // the dirty snapshot so the chrome doesn't treat the just-saved form
            // as dirty while an alert is up.
            suppressCancelOnExit = true
            pendingToken = ""
            stagedVoiceKeyReuse = false
            pendingImageHistory = nil
            pendingBadgeColorID = nil
            pendingMonogram = nil
            rebaselineOriginals()
            if SettingsViewModel.shouldPromptToSetDefault(
                savedRef: ref,
                defaultRef: viewModel.defaultRemoteAgentRef,
                wasConfiguredBefore: wasConfiguredBefore,
                hadAnyConfiguredBefore: hadAnyConfiguredBefore
            ) {
                // The alert's buttons dismiss — keep the editor up to host it.
                showingMakeDefaultPrompt = true
            } else {
                dismiss()
            }
        }
    }

    /// Whether ANY buffer on the page diverged from storage (a typed token, a
    /// staged voice-key reuse, an edited connection field, a staged Image
    /// history pick, a staged badge edit). Drives the discard confirm via
    /// `bufferedEditorChrome` and the Quick connect / File transfer gates — the
    /// page-wide one-commit contract means every control participates. A fresh
    /// draft with NOTHING typed is pristine → Back leaves silently.
    ///
    /// Pristine until seeded, ALWAYS. SwiftUI evaluates `body` — and everything
    /// it reads — before `.onAppear` runs, so on the first frame of an existing
    /// gateway the `original*` baselines are still `""` while the buffers
    /// already hold storage's values: every comparison below reports a
    /// divergence the user did not make. There cannot be an edit before the
    /// editor is seeded, so the guard is safe by construction, and without it
    /// `canSave` flashes enabled on every pristine open.
    private var isDirty: Bool {
        guard didInitialize else { return false }
        if stagedVoiceKeyReuse { return true }
        if !pendingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if isCustom, pendingName != originalName { return true }
        if (viewModel.remoteAgentURLStrings[ref] ?? "") != originalURL { return true }
        if (isCustom || builtinDescriptor?.showsModelField == true),
           (viewModel.remoteAgentModelStrings[ref] ?? "") != originalModel { return true }
        if (viewModel.remoteAgentCertFingerprints[ref] ?? "") != originalCert { return true }
        if isKeyless != originalAuthKeyless { return true }
        if let pendingImageHistory, pendingImageHistory != viewModel.imageHistoryPolicy(ref) { return true }
        if badgeIsDirty { return true }
        return false
    }

    /// Whether a badge buffer diverged from storage (custom-only; nil-pending =
    /// untouched, and a pick/retype that lands back on the stored value is
    /// pristine again).
    private var badgeIsDirty: Bool {
        guard case .custom = ref else { return false }
        if let pendingBadgeColorID, pendingBadgeColorID != customGateway?.colorID { return true }
        if let pendingMonogram, pendingMonogram != effectiveStoredMonogram { return true }
        return false
    }

    /// Transient feedback for the Test Connection action — folded INTO `actionRow`
    /// (no standalone resting row). A configured gateway hydrates to `.valid` at
    /// rest, so a bare `.valid` (saved, never probed this session) shows NOTHING;
    /// we surface a result only while/after a live Test Connection: spinner, green
    /// "Connected"/"API key valid", or a red error.
    @ViewBuilder
    private var statusFeedback: some View {
        switch rowState {
        case .unset:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("settings.remoteAgent.testConnection.checking", defaultValue: "Checking…"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .valid:
            // Green "Connected"/"API key valid" ONLY when a LIVE probe actually
            // succeeded this session (`remoteAgentLiveValidated`, reset on
            // save/relaunch). A bare `.valid` (just saved) renders nothing — no
            // resting badge.
            if viewModel.remoteAgentLiveValidated.contains(ref) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text(successLabel)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
            } else {
                EmptyView()
            }
        case .invalid(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
                troubleshootAffordance
            }
        }
    }

    /// What a PASSING probe actually proved — three different claims, so three
    /// different words. A single "Connected" would overclaim in two of them.
    ///
    /// An auth-validated probe (OpenRouter → `/v1/key`) proves the KEY, not funding
    /// or model usability. A model-list probe that came back with an EMPTY list
    /// (`remoteAgentProbeReportedNoModels` — a fresh Ollama with nothing pulled is
    /// the common case) proves the route exists but the gateway can't answer a
    /// single prompt yet, so a bare green "Connected" would send the user off to
    /// debug a send that was never going to work. Otherwise: genuinely connected.
    ///
    /// A computed `LocalizedStringResource` rather than a nested ternary in the
    /// row — this file's SwiftUI expressions are already near the type-check budget.
    private var successLabel: LocalizedStringResource {
        if builtinDescriptor?.probesAuthDirectly == true {
            return LocalizedStringResource("settings.remoteAgent.testConnection.keyValid", defaultValue: "API key valid")
        }
        if viewModel.remoteAgentProbeReportedNoModels.contains(ref) {
            return LocalizedStringResource(
                "settings.remoteAgent.testConnection.successNoModels",
                defaultValue: "Connected — no models yet"
            )
        }
        return LocalizedStringResource("settings.remoteAgent.testConnection.success", defaultValue: "Connected")
    }

    /// Deep-link into Diagnostics, focused on the code the last probe failed with.
    ///
    /// Gated on a PRISTINE, SAVED editor: Diagnostics reads PERSISTED settings while
    /// this form holds unsaved buffers, so from a dirty editor it would test the OLD
    /// URL/token and contradict the very error the user is reading. `DiagnosticsFocus`'s
    /// failable init is the second filter — a non-troubleshootable code renders nothing.
    @ViewBuilder
    private var troubleshootAffordance: some View {
        if !isDirty,
           viewModel.isRemoteAgentConfigured(ref),
           let focus = DiagnosticsFocus(errorCode: viewModel.remoteAgentLastErrorCodes[ref], ref: ref) {
            TroubleshootButton(focus: focus)
        }
    }

    // MARK: - Server certificate row (the pin surface; plain-language values)

    /// Write-through to the staged fingerprint buffer — the same contract as the
    /// URL field: a re-pinned (or un-pinned) cert is a different trust decision,
    /// so it retracts a live verdict and marks the form dirty. The VM normalizes
    /// an empty pin to "no pin" at probe/save time.
    private var certFingerprintBinding: Binding<String> {
        Binding<String>(
            get: { viewModel.remoteAgentCertFingerprints[ref] ?? "" },
            set: { viewModel.setRemoteAgentCertFingerprintBuffer($0, for: ref) }
        )
    }

    /// "Server certificate" — the one row on the page that names the optional
    /// pin, showing a plain-language value; everything jargon-bearing (the
    /// fingerprint, SPKI) is quarantined in `CertificateTrustSheet`. Hidden for
    /// hosted-model built-ins on a public CA (OpenRouter, `.systemTrustOnly`):
    /// their leaf certs rotate, and letting a user pin one would arm a future
    /// `remoteAgentCertMismatch` break.
    @ViewBuilder
    private var serverCertificateRow: some View {
        if builtinDescriptor?.trust != .systemTrustOnly {
            // Split-action row (the `secretRow` pattern): the ⓘ is a SIBLING of
            // the row's action, never inside it — a label Button that hugs its
            // text, the tip, then a trailing Button covering the value + chevron
            // (same action, `.accessibilityHidden` — a redundant hit area, not a
            // second thing to announce).
            HStack(spacing: 0) {
                Button {
                    showingCertSheet = true
                } label: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.certRow.label",
                        defaultValue: "Server certificate"
                    ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        #if os(macOS)
                        .frame(minHeight: SettingsCardMetrics.rowMinHeight)
                        #endif
                        .contentShape(Rectangle())
                }
                // Wash-free halves + one row-wide wash — see `secretRow` for
                // why a per-half style would seam this row on hover.
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.remoteAgent.editor.serverCertificate")
                .accessibilityValue(Text(certRowValue))

                InfoTipButton(tip: GatewayFieldTips.serverCertificate)

                Button {
                    showingCertSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Spacer(minLength: 8)
                        Text(certRowValue)
                            .font(.caption)
                            .foregroundStyle(certRowValueIsActionable ? AppColors.brandAmber : AppColors.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    #if os(macOS)
                    .frame(maxWidth: .infinity, minHeight: SettingsCardMetrics.rowMinHeight)
                    #endif
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            // Row action for the uncovered inset band — see `secretRow`.
            .settingsCardRowControl { showingCertSheet = true }
        }
    }

    /// The row's plain-language value. ANY buffer that diverged from its
    /// appear-time snapshot owes a Save — including a CLEARED pin, where the
    /// persisted fingerprint still governs connections until Save commits the
    /// removal; then the two resting values.
    private var certRowValue: LocalizedStringResource {
        let buffer = viewModel.remoteAgentCertFingerprints[ref] ?? ""
        let bufferEmpty = buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if buffer != originalCert {
            return bufferEmpty
                ? LocalizedStringResource(
                    "settings.remoteAgent.certRow.value.automaticSaveRequired",
                    defaultValue: "Automatic · Save required"
                )
                : LocalizedStringResource(
                    "settings.remoteAgent.certRow.value.pinnedSaveRequired",
                    defaultValue: "Pinned · Save required"
                )
        }
        if bufferEmpty {
            return LocalizedStringResource(
                "settings.remoteAgent.certRow.value.automatic",
                defaultValue: "Automatic"
            )
        }
        return LocalizedStringResource(
            "settings.remoteAgent.certRow.value.pinned",
            defaultValue: "Pinned on this device"
        )
    }

    /// Amber only where the user owes an action (an unsaved pin change, in
    /// EITHER direction) — the resting values stay quiet.
    private var certRowValueIsActionable: Bool {
        (viewModel.remoteAgentCertFingerprints[ref] ?? "") != originalCert
    }

    // MARK: - Zone 4: In chats

    /// The File transfer destination + the per-gateway image-history policy.
    /// The policy buffers like every other field (committed on Save); the File
    /// transfer row is a push whose page is its own buffered editor.
    @ViewBuilder
    private var inChatsSection: some View {
        Section {
            fileTransferRow
            imageHistoryPicker
        } header: {
            Text(LocalizedStringResource("settings.remoteAgent.inChats.header", defaultValue: "In chats"))
        }
    }

    /// "File transfer" — pushes the full setup page for every file-capable lane
    /// (hidden for `.unsupported` — OpenRouter). The trailing badge is the lane
    /// status in its own tint. Tap-gated twice: a never-saved gateway has nothing
    /// for the file lane to attach to, and a dirty editor holds unsaved connection
    /// buffers the page (which reads persisted settings) would contradict.
    @ViewBuilder
    private var fileTransferRow: some View {
        let status = viewModel.fileLaneStatus(for: ref)
        if status != .unsupported {
            let gateReason = fileTransferGateReason
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink {
                    GatewayFileTransferPage(viewModel: viewModel, ref: ref)
                } label: {
                    HStack(spacing: 8) {
                        Text(LocalizedStringResource(
                            "settings.remoteAgent.fileTransfer.row.label",
                            defaultValue: "File transfer"
                        ))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer(minLength: 8)
                        if let label = status.shortLabel {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(status.tint)
                        }
                        #if os(macOS)
                        // A `NavigationLink` draws its disclosure only inside a
                        // `List`, and a card row is not one — so the row draws
                        // it, with the glyph the sibling secret and certificate
                        // rows already use, or this push would be the only row
                        // in the editor with no forward affordance.
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                        #endif
                    }
                    // Claims the `Spacer()` gap between label and badge, the same
                    // way every other full-width row in this file does.
                    .contentShape(Rectangle())
                }
                // macOS-only: a `NavigationLink` IS a `Button`, so the card row
                // style reaches it and brings the full-bleed live frame, the row
                // inset and the squared wash in one modifier. Unconditional it
                // would also strip the iOS row of the grouped list's own
                // highlight and system chevron.
                #if os(macOS)
                .settingsCardRowButton()
                #endif
                .disabled(gateReason != nil)
                .accessibilityIdentifier("settings.remoteAgent.editor.fileTransfer")
                .accessibilityValue(fileTransferAccessibilityValue(status: status, gateReason: gateReason))
                if let gateReason {
                    Text(gateReason)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsCardPassiveRow(minHeight: 0)
                }
            }
        }
    }

    /// Why the File transfer row is disabled, when it is. Never-saved outranks
    /// dirty: a fresh draft is always dirty too, and "save this gateway first"
    /// is the actionable half of that state.
    private var fileTransferGateReason: LocalizedStringResource? {
        if !viewModel.isRemoteAgentConfigured(ref) {
            return LocalizedStringResource(
                "settings.remoteAgent.fileTransfer.gate.unsaved",
                defaultValue: "Save this gateway before setting up file transfer."
            )
        }
        if isDirty {
            return LocalizedStringResource(
                "settings.remoteAgent.fileTransfer.gate.dirty",
                defaultValue: "Save or discard your changes first."
            )
        }
        return nil
    }

    /// The row's spoken value — the status badge, and the disabled reason when
    /// gated (a disabled row must say why).
    private func fileTransferAccessibilityValue(
        status: GatewayFileLaneStatus,
        gateReason: LocalizedStringResource?
    ) -> Text {
        if let gateReason { return Text(gateReason) }
        if let label = status.shortLabel { return Text(label) }
        return Text(verbatim: "")
    }

    // MARK: - Image history (per-gateway ImageHistoryPolicy)

    /// Menu picker for the gateway's image-history policy (Recent / Extended /
    /// All) + a caption that STRING-SWAPS on the selection (the `authToggle`
    /// idiom — one `Text` whose localized content differs, NEVER an if/else
    /// producing different view structures, so view identity stays stable on
    /// macOS). BUFFERED like every field on this page: a selection lands in
    /// `pendingImageHistory` and `saveTapped` commits it via
    /// `setImageHistoryPolicy` — the page-wide one-commit contract. The policy
    /// is gateway-scoped: a server-less custom endpoint pays the inline-image
    /// cost too and has no file-transfer setup to host a control.
    ///
    /// iOS renders a `Menu` whose label is the WHOLE row line (title + value +
    /// chevrons): a bare `Picker(.menu)` in this hand-rolled VStack row only
    /// responds on its trailing value pill (~40 pt — QA-measured, 2026-06-11),
    /// far too small a touch target for the row's primary affordance. The
    /// caption stays OUTSIDE the trigger (inert, like a Form footer). macOS
    /// keeps the native `Picker(.menu)` popup control — pointer clicks don't
    /// have the target problem and the popup matches the platform's settings
    /// idiom.
    @ViewBuilder
    private var imageHistoryPicker: some View {
        let binding = Binding<ImageHistoryPolicy>(
            get: { pendingImageHistory ?? viewModel.imageHistoryPolicy(ref) },
            set: { pendingImageHistory = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            // The tip is a SIBLING of the Menu/Picker, not inside its label — the
            // iOS Menu label IS the trigger (whole-row `contentShape`), so a nested
            // ⓘ would open the policy menu instead of the tip.
            HStack(spacing: 0) {
            #if os(iOS)
            Menu {
                Picker(selection: binding) {
                    ForEach(ImageHistoryPolicy.allCases, id: \.self) { policy in
                        Text(optionLabel(for: policy)).tag(policy)
                    }
                } label: { EmptyView() }
            } label: {
                HStack(spacing: 8) {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.imageHistory.label",
                        defaultValue: "Image history"
                    ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    // Mirrors the system menu-picker value affordance
                    // (value + up/down chevrons) so the row reads identically
                    // to the bare `Picker(.menu)` it replaces.
                    Text(optionLabel(for: binding.wrappedValue))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.brandAmber)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Trailing accessory: the Menu label claims the whole row, so the tip
            // can only sit outside it.
            InfoTipButton(tip: GatewayFieldTips.imageHistory, glyphAlignment: .trailing)
            #else
            // macOS: the native popup sizes to its content, so a tip appended after
            // it would float mid-row, unattached to anything. Hand-roll the label
            // instead — title + tip lead, the labels-hidden popup trails — which is
            // also the one arrangement where the ⓘ hugs the words it explains.
            Text(LocalizedStringResource(
                "settings.remoteAgent.imageHistory.label",
                defaultValue: "Image history"
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
            InfoTipButton(tip: GatewayFieldTips.imageHistory)
            Spacer(minLength: 8)
            Picker(selection: binding) {
                ForEach(ImageHistoryPolicy.allCases, id: \.self) { policy in
                    Text(optionLabel(for: policy)).tag(policy)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            // The visual title lives outside the Picker, so the control needs its
            // own VoiceOver name — an unlabeled popup reads as just its value.
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.remoteAgent.imageHistory.label",
                defaultValue: "Image history"
            )))
            .tint(AppColors.brandAmber)
            #endif
            }
            // The card row treatment goes on the trigger LINE, not on the
            // enclosing stack, so the caption below keeps its own tighter
            // spacing. Passive: the ⓘ and the popup are two INDEPENDENT actions
            // sharing one row, and no row-level action can raise a popup's menu
            // anyway, so a wash would stand for nothing the row can do.
            .settingsCardPassiveRow()
            // String-swap (NOT an if/else producing distinct Texts) — stable
            // view identity, only the localized content differs.
            Text(captionResource(for: binding.wrappedValue))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsCardPassiveRow(minHeight: 0)
        }
    }

    /// Option label per policy level. UI strings stay in the view layer (the
    /// cross-target enum carries no display copy — same split as the other
    /// pickers).
    private func optionLabel(for policy: ImageHistoryPolicy) -> LocalizedStringResource {
        switch policy {
        case .recent:
            return LocalizedStringResource("settings.remoteAgent.imageHistory.option.recent", defaultValue: "Recent")
        case .extended:
            return LocalizedStringResource("settings.remoteAgent.imageHistory.option.extended", defaultValue: "Extended")
        case .all:
            return LocalizedStringResource("settings.remoteAgent.imageHistory.option.all", defaultValue: "All")
        }
    }

    /// Selection-swapped caption: what the chosen level means in cost +
    /// behavior terms (wire-true to the `priorTurns` windows).
    private func captionResource(for policy: ImageHistoryPolicy) -> LocalizedStringResource {
        switch policy {
        case .recent:
            return LocalizedStringResource(
                "settings.remoteAgent.imageHistory.caption.recent",
                defaultValue: "Fastest and cheapest. The agent sees your last 3 image messages in full; older uploaded images become file references."
            )
        case .extended:
            return LocalizedStringResource(
                "settings.remoteAgent.imageHistory.caption.extended",
                defaultValue: "Sees your last 10 image messages in full. Slower and pricier on image-heavy chats."
            )
        case .all:
            return LocalizedStringResource(
                "settings.remoteAgent.imageHistory.caption.all",
                defaultValue: "Re-sends every recent image message in full each turn. Most expensive; long image chats may hit size limits."
            )
        }
    }

    // MARK: - Zone 5: Devices (pairing export + badge)

    /// Whether the "Set up on another device" entry point applies: a CONFIGURED,
    /// pairing-supported gateway (self-hosted built-in OR custom). Never for the
    /// hosted-model lane (OpenRouter, `pairingSupported == false`) — its lane is
    /// set up via its own key flow, not a `conduck-setup` code, and the exporter
    /// refuses it at the API level too.
    private var showsExportCode: Bool {
        guard viewModel.isRemoteAgentConfigured(ref) else { return false }
        if case .builtin(let backend) = ref {
            return RemoteAgentBackendRegistry.lookup(id: backend).pairingSupported
        }
        return true
    }

    /// Everything about OTHER surfaces showing this gateway: the pairing-code
    /// export (configured, pairing-supported lanes) and the custom badge (how the
    /// Watch/CarPlay pickers tell gateways apart). Omitted entirely when neither
    /// applies (an unconfigured built-in) — no empty sections.
    @ViewBuilder
    private var devicesSection: some View {
        if showsExportCode || isCustom {
            Section {
                if showsExportCode {
                    exportCodeRow
                }
                badgeFields
            } header: {
                Text(LocalizedStringResource("settings.remoteAgent.devices.header", defaultValue: "Devices"))
            } footer: {
                if showsExportCode {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.showSetupCode.footer",
                        defaultValue: "Set up another device by scanning or pasting a code. The code holds this gateway's sensitive information, so treat it like a password."
                    ))
                }
            }
        }
    }

    /// "Set up on another device" — re-renders THIS configured gateway's
    /// `conduck-setup` code so a new device can scan it (the export sheet flow).
    private var exportCodeRow: some View {
        Button {
            showingPairingExport = true
        } label: {
            Label(
                LocalizedStringResource(
                    "settings.remoteAgent.setupOtherDevice.button",
                    defaultValue: "Set up on another device"
                ),
                systemImage: "qrcode"
            )
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .settingsCardRowButton()
        .accessibilityIdentifier("settings.remoteAgent.editor.setupOtherDevice")
    }

    // MARK: - Badge (custom-only): color swatch + monogram

    @ViewBuilder
    private var badgeFields: some View {
        if case .custom(let id) = ref {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.badge.header",
                    defaultValue: "Badge"
                ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.badge.helper",
                    defaultValue: "Shown on Apple Watch and CarPlay so you can tell gateways apart."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                colorSwatchRow(id: id)
                monogramField(id: id)
            }
            // A titled block of several independent controls (swatches + a text
            // field), not one row action — passive inset, no wash. Each swatch
            // keeps its own circular hover wash: those ARE separate actions.
            .settingsCardPassiveRow()
        }
    }

    private func colorSwatchRow(id: UUID) -> some View {
        // Buffered: a tap stages the pick; `saveTapped` commits (page contract).
        let selected = pendingBadgeColorID ?? customGateway?.colorID
        return HStack(spacing: 10) {
            ForEach(RemoteAgentBadgePalette.customPalette, id: \.id) { entry in
                Button {
                    pendingBadgeColorID = entry.id
                } label: {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(AppColors.textPrimary, lineWidth: selected == entry.id ? 2 : 0)
                        )
                }
                // The swatch IS a circle — a rounded-square wash would tint only
                // the corners of the 28pt pointer square around it.
                .pointerIconButton(shape: .circle)
                .accessibilityLabel(Text(entry.id))
            }
        }
    }

    /// The monogram the field mirrors while untouched: the stored override, else
    /// the derived monogram. Also the dirty/commit baseline — an untouched (or
    /// retyped-identical) buffer must never WRITE the derived value as an
    /// override, or a later rename would stop updating the badge.
    private var effectiveStoredMonogram: String {
        customGateway?.monogram ?? RemoteAgentRefMetadata.monogram(for: ref, customs: viewModel.customGateways)
    }

    private func monogramField(id: UUID) -> some View {
        let monogramBinding = Binding<String>(
            get: { pendingMonogram ?? effectiveStoredMonogram },
            set: { newValue in
                // Cap at 2 chars, uppercase, live in the field. Buffered —
                // `saveTapped` decides override-vs-clear at commit.
                pendingMonogram = String(newValue.prefix(2)).uppercased()
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource(
                "settings.remoteAgent.badge.monogram.label",
                defaultValue: "Monogram"
            ))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
            TextField(
                "",
                text: monogramBinding,
                prompt: Text(LocalizedStringResource(
                    "settings.remoteAgent.badge.monogram.placeholder",
                    defaultValue: "1–2 letters"
                ))
            )
                .labelsHidden()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
        }
    }

    /// Persist the badge fields on the roster record VERBATIM — callers pass the
    /// full intended state (the untouched field's CURRENT value alongside the
    /// edited one). No `?? existing` merge: nil must be expressible as "clear
    /// the monogram override", not collapse into "keep".
    private func updateBadge(id: UUID, colorID: String?, monogram: String?) async {
        guard let existing = viewModel.customGateways.first(where: { $0.id == id }) else { return }
        let updated = CustomGateway(
            id: id,
            name: existing.name,
            model: existing.model,
            colorID: colorID,
            monogram: monogram
        )
        await viewModel.updateCustomGatewayBadge(updated)
    }

    // MARK: - Temporary-tunnel hint

    /// Warns that a Cloudflare Quick Tunnel hostname is disposable: the address
    /// is randomly generated per `cloudflared` run, so it changes every time the
    /// tunnel restarts and the saved gateway silently stops resolving.
    ///
    /// This is PREVENTION, deliberately chosen over trying to INFER a rotated
    /// address at failure time. Inference is unreliable — a DNS failure looks
    /// identical whether the hostname died, a VPN dropped, or a resolver
    /// hiccuped — whereas the hostname suffix is a fact available before anything
    /// breaks. Advisory only: it never gates saving, matching the established
    /// pattern for the port and endpoint-suffix hints.
    private var temporaryTunnelHint: String? {
        let trimmed = (viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard EndpointURLPolicy.isCloudflareQuickTunnelURLString(trimmed) else {
            return nil
        }
        return String(localized: LocalizedStringResource(
            "settings.remoteAgent.url.temporaryTunnelHint",
            defaultValue: "This is a temporary tunnel address. It normally changes when the tunnel restarts, and this gateway then stops working until you set it up again."
        ))
    }

    // MARK: - Port-hint logic

    /// A confirming "port N" hint, surfaced ONLY when the user typed a
    /// non-standard explicit port. Returns nil for 443 / no explicit port /
    /// an unparseable URL.
    private var nonStandardPortHint: String? {
        let trimmed = (viewModel.remoteAgentURLStrings[ref] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let port = components.port,
              port != 443
        else {
            return nil
        }
        return String(
            format: String(localized: LocalizedStringResource(
                "settings.remoteAgent.url.portHint",
                defaultValue: "Using port %lld"
            )),
            port
        )
    }
}
