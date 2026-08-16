// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsView.swift
//
// The local Diagnostics screen — an on-device health checklist that
// consolidates the app's connection / voice / file / sync tests, explains any
// failure in plain English with the fix, and offers a paste-safe "Copy
// Diagnostics" button. FOR THE USER: nothing is auto-sent, no backend, no
// telemetry.
//
// `DiagnosticsContent` owns BOTH the checklist and its container — a
// `PlatformSettingsForm`, which is a grouped `Form` on iOS and a hand-drawn
// `SettingsCard` stack (scroll surface, window gutter and reading rail
// included) on macOS. The container lives INSIDE this view rather than at its
// call sites so the screen's lifecycle modifiers — the auto-read task, the
// scene-phase re-probe, the settings-changed observers — hang off the container
// rather than off the section tree, which on macOS is decomposed section by
// section by `Group(sections:)`.
//
// Two entry shapes wrap it:
//   • `DiagnosticsView` adds the nav chrome — used by the iOS Settings push,
//     the iPad split-view detail, and the conversation banner's Troubleshoot
//     sheet (with a `focusedRef`/`focusedErrorCode`).
//   • `MacDiagnosticsCategory` mounts it bare as a macOS Settings category.
//
// macOS row treatment: almost every row here is a STATUS block — a check glyph
// with its explanation, often with its own inline test button — so it takes
// `.settingsCardPassiveRow()`, which supplies the card's inset and row pitch and
// withholds the hover wash a whole-row action would earn. Only the rows that ARE
// a single action (the two standalone voice tests) take a live full-bleed row
// treatment; the compact `.bordered` pills that sit in a status row's trailing
// slot stay pills, because there the pill — not the row — is what a click hits.
//
// Guardrail surfaced in UI: opening the screen auto-runs only instant local
// reads; the gateway/voice reachability sweep fires only inside the explicit
// "Test everything" tap (which also fans out the paid/mutating tests); the
// per-row test buttons re-run one check each. Voice preview stays its own tap
// (it speaks aloud). Nothing probing or billable ever fires on open.

import SwiftUI
#if canImport(UIKit)
import UIKit   // UIApplication.openSettingsURLString — denied-permission repair
#endif
#if canImport(AppKit)
import AppKit   // NSApplication.didBecomeActiveNotification — macOS foreground refresh
#endif

// MARK: - Full-screen wrapper (iOS / iPad / banner sheet)

struct DiagnosticsView: View {
    private let runner: DiagnosticsRunner?
    private let focusedRef: RemoteAgentRef?
    private let focusedErrorCode: Int?

    /// `runner:` lets a longer-lived host (the iPad `IpadSettingsView`) inject a
    /// PERSISTENT runner so a Settings tab-switch doesn't rebuild it — the reason
    /// the Copy button flickered on return. `focusedRef`/`focusedErrorCode`
    /// seed a fresh self-owned runner for the iOS push + the banner-sheet deep-link.
    init(runner: DiagnosticsRunner? = nil, focusedRef: RemoteAgentRef? = nil, focusedErrorCode: Int? = nil) {
        self.runner = runner
        self.focusedRef = focusedRef
        self.focusedErrorCode = focusedErrorCode
    }

    var body: some View {
        // Nav chrome only — `DiagnosticsContent` brings its own container.
        DiagnosticsContent(runner: runner, focusedRef: focusedRef, focusedErrorCode: focusedErrorCode)
            .navigationTitle(Text(LocalizedStringResource("diagnostics.title", defaultValue: "Diagnostics")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            // On macOS this wrapper is reached only as `TroubleshootButton`'s
            // sheet, which sets no size of its own. The card stack scrolls, and a
            // scroll surface has no intrinsic size for a sheet to adopt, so the
            // size is stated here — the same fixed-frame idiom as the Licenses
            // and menu-bar guide sheets, and wide enough for the checklist's
            // status-plus-button rows not to wrap.
            .frame(width: 680, height: 680)
            #endif
    }
}

// MARK: - Shared sections + runner ownership

struct DiagnosticsContent: View {
    @State private var runner: DiagnosticsRunner
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    /// Drives the per-row action layout: inline-trailing at normal text sizes,
    /// stacked below at accessibility sizes (where a trailing button would crush
    /// the status copy in the narrow slot).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two ownership modes:
    ///   • `runner: nil` (default) — SELF-OWNS a fresh runner seeded from the focus
    ///     params (iOS push + banner sheet).
    ///   • `runner:` injected — ADOPTS a runner owned by a longer-lived host
    ///     (`MacSettingsView` / `IpadSettingsView`) so it survives a Settings
    ///     tab-switch. A remount re-reads the already-seeded instance, so the
    ///     checklist renders fully-formed instead of flashing the empty→populated
    ///     placeholder that made the Copy button jump.
    init(runner: DiagnosticsRunner? = nil, focusedRef: RemoteAgentRef? = nil, focusedErrorCode: Int? = nil) {
        _runner = State(initialValue: runner ?? DiagnosticsRunner(
            focusedRef: focusedRef,
            focusedErrorCode: focusedErrorCode
        ))
    }

    var body: some View {
        // One section tree for both platforms. Every conditional below wraps a
        // WHOLE `Section` (or, for `voiceSections`, a whole pair of them) —
        // `Group(sections:)` counts declarations, so narrowing one of these to
        // wrap content INSIDE a Section instead would silently change how many
        // cards macOS draws, with nothing to catch it at compile time.
        PlatformSettingsForm {
            if let focus = runner.focusedExplanation {
                focusedCard(focus)
            }
            testEverythingSection
            connectionSection
            if runner.showsVoiceSection {
                voiceSections
            }
            if runner.showsCapabilitySection { capabilitySection }
            if runner.showsSyncSection { syncSection }
            copySection
        }
        .scrollContentBackground(.hidden)
        .task { await runner.runAutoReads() }
        // Live re-derive on (re)appear + foreground: re-read the provider config +
        // permissions AND re-probe connectivity so a provider the user just
        // switched — a permission just flipped in system Settings, or a network /
        // iCloud that just recovered — reflects without relaunching. No billing;
        // an unchanged config rebuilds identically. The connectivity re-probe
        // coalesces via the runner's latch (can't race the initial phase-2).
        .task(id: scenePhase) {
            if scenePhase == .active { await runner.refreshConfigAndConnectivity() }
        }
        // In-session settings change (e.g. switching STT provider in the Voice tab) —
        // the app already posts this on every provider change. CONFIG-ONLY (no
        // connectivity re-probe): cheap, and it can fire in bursts.
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task { await runner.refreshConfig() }
        }
        #if os(macOS)
        // Returning from ANOTHER app (System Settings, where a permission is granted)
        // does not reliably re-fire `scenePhase` on macOS — observe the AppKit
        // become-active signal directly (config + connectivity, like foreground).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await runner.refreshConfigAndConnectivity() }
        }
        #endif
    }

    // MARK: Focused error card (banner deep-link)

    private func focusedCard(_ focus: (title: String, cause: String, fix: String)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(focus.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(AppColors.warning)
                }
                Text(focus.cause)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                Text(focus.fix)
                    .font(.callout)
                    .foregroundStyle(AppColors.textPrimary)
                // The action this card existed without. A Troubleshoot-landed user
                // had exactly one route forward — the top "Test everything" button,
                // which writes into every file lane and runs a billable
                // transcription to answer a question about ONE gateway.
                //
                // Offered only for a focused ref that is actually configured: a
                // focus can carry no ref at all, and an unconfigured focused ref is
                // already explained by its own `focused.missing` row, which a
                // re-probe cannot help.
                if let ref = runner.focusedRef,
                   runner.gatewayDisplayOrder.contains(where: { $0.ref == ref }) {
                    recheckButton(for: ref)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
            // A prose block that owns an inner button, not a single row action:
            // the passive treatment gives it the card's inset and pitch and
            // withholds the wash that would promise a whole-row click.
            .settingsCardPassiveRow()
        }
    }

    /// Re-probe ONE gateway. Same house-standard bordered action as the file lane's
    /// staged test directly beneath it, but deliberately a DIFFERENT verb: the
    /// two buttons one row apart test DIFFERENT machines, and the labels now say
    /// which — this one re-probes the gateway, the one beneath it says "Test file
    /// server".
    @ViewBuilder
    private func recheckButton(for ref: RemoteAgentRef) -> some View {
        Button {
            Task { await runner.recheckGateway(for: ref) }
        } label: {
            if runner.gatewayRecheckRunning.contains(ref) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "diagnostics.action.checking", defaultValue: "Checking…")))
            } else {
                Label(
                    LocalizedStringResource("diagnostics.action.recheckGateway", defaultValue: "Check Again"),
                    systemImage: "arrow.clockwise"
                )
                .font(.subheadline.weight(.semibold))
                .labelStyle(AccentGlyphActionLabelStyle())
            }
        }
        .buttonStyle(.bordered)
        .disabled(runner.gatewayRecheckRunning.contains(ref) || runner.isRunningAllTests)
    }

    // MARK: Test everything

    private var testEverythingSection: some View {
        Section {
            summaryRow
            Button {
                Task { await runner.runAllTests() }
            } label: {
                testEverythingLabel
            }
            #if os(macOS)
            // Full-row filled surface so it reads as a real push button rather
            // than the stock `.bordered` control's faint grey label with margins
            // around it. It carries its own live frame, hover wash and vertical
            // inset, so it takes NO card row modifier: inside a `SettingsCard`
            // — which pads nothing — the style's own `maxWidth: .infinity` frame
            // already spans the card edge to edge. Label colors are the style's
            // business only in that it sets none; the shape is all it changes.
            .buttonStyle(MacDiagnosticsActionButtonStyle())
            #else
            .buttonStyle(.bordered)
            #endif
            .disabled(runner.isBusy)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            // "each set-up file server" self-scopes to whatever is configured (zero
            // servers → the clause simply covers nothing), so one footer fits both.
            Text(LocalizedStringResource(
                "diagnostics.footer.testEverything",
                defaultValue: "Runs every check, writes and reads back a small file on each set-up file server, and tests your voice providers."
            ))
        }
    }

    /// The "Test everything" button's label — the accent glyph + light title, on
    /// every platform. macOS only changes the button SHAPE (a full-row filled
    /// surface via `MacDiagnosticsActionButtonStyle`), never these colors.
    @ViewBuilder
    private var testEverythingLabel: some View {
        Group {
            if runner.isRunningAllTests {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentColor)
                    Text(LocalizedStringResource(
                        "diagnostics.action.testingEverything",
                        defaultValue: "Testing…"
                    ))
                    .foregroundStyle(AppColors.textPrimary)
                }
            } else {
                Label(
                    LocalizedStringResource("diagnostics.action.testEverything", defaultValue: "Test everything"),
                    systemImage: "stethoscope"
                )
                .labelStyle(AccentGlyphActionLabelStyle())
            }
        }
        .font(.body.weight(.bold))
        .frame(maxWidth: .infinity)
    }

    /// The one-line verdict above the button — amber with a count whenever
    /// ANYTHING on screen needs attention; green "Checks passed" only once the
    /// real sweep has run clean (config reads alone never mint a green); nothing
    /// while checks are still settling.
    @ViewBuilder
    private var summaryRow: some View {
        if runner.attentionCount > 0 {
            Label {
                // The scoped stamp rides the AMBER branch too — this is the case it
                // exists for. A user re-probing a broken gateway needs to know the
                // red they are looking at is a second ago, not ten minutes ago.
                VStack(alignment: .leading, spacing: 2) {
                    Text(runner.attentionCount == 1
                        ? LocalizedStringResource("diagnostics.summary.attention.one", defaultValue: "1 item needs attention")
                        : LocalizedStringResource("diagnostics.summary.attention.many", defaultValue: "\(runner.attentionCount) items need attention"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    scopedCheckLine
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
            }
            // Applied INSIDE each branch, never to the property as a whole: the
            // third state renders nothing at all, and a modifier wrapped around
            // that would risk giving the card a phantom row with the full row
            // pitch and nothing in it.
            .settingsCardPassiveRow()
        } else if runner.checksSettledGreen {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource("diagnostics.summary.passed", defaultValue: "Checks passed"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    lastCheckedLine
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
            }
            .settingsCardPassiveRow()
        }
    }

    /// When the last sweep finished. A bare green "Checks passed" is a trust trap
    /// — a pass from three days ago reads as current, and nothing on screen said
    /// otherwise even though the runner had already recorded the time.
    ///
    /// Names the WHOLE RUN, not a single check: this stamp covers a full sweep
    /// (gateways, file lanes, speech), so "connected" or "model list passed" would
    /// be wrong. It is deliberately never restamped by a single-gateway re-probe —
    /// that would claim freshness for every row nobody touched — so a scoped
    /// re-probe adds its own line beneath instead.
    @ViewBuilder
    private var lastCheckedLine: some View {
        if let lastChecked = runner.lastChecked {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringResource(
                    "diagnostics.summary.lastChecked",
                    defaultValue: "Full check run \(lastChecked.formatted(.relative(presentation: .named)))"
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                scopedCheckLine
            }
        } else {
            // Nothing has been probed yet this launch, so the green comes from
            // local reads alone. Say so rather than implying a network check ran.
            Text(LocalizedStringResource(
                "diagnostics.summary.notCheckedYet",
                defaultValue: "Setup looks right — tap Test everything to check the connection"
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    /// "A real chat turn completed here" — the claim no check on this screen can
    /// make, stated once per gateway.
    ///
    /// Absence is rendered NEUTRALLY, never as a failure: a gateway paired five
    /// minutes ago has nothing recorded and nothing is wrong with it. The line
    /// exists because the opposite reading is the trap — a green row above it
    /// proves reachability and sign-in, and a user needs to know that is not the
    /// same as a working conversation.
    @ViewBuilder
    private func chatProvenLine(for ref: RemoteAgentRef) -> some View {
        if let at = runner.chatSuccesses[ref] {
            Text(LocalizedStringResource(
                "diagnostics.gateway.chatProven",
                defaultValue: "Last reply received \(at.formatted(.relative(presentation: .named)))"
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        } else {
            Text(LocalizedStringResource(
                "diagnostics.gateway.chatUnproven",
                defaultValue: "No reply received on this device yet"
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    /// A single-gateway re-probe's own stamp, sitting beneath the whole-run one.
    /// Exists because the two claims are genuinely different sizes: the full-run
    /// stamp must not move for one gateway, but a user who just tapped "Check
    /// Again" needs to see that THAT probe ran. Names the gateway (view-only — a
    /// user's gateway name never reaches the copied report).
    @ViewBuilder
    private var scopedCheckLine: some View {
        if let scoped = runner.lastScopedGatewayCheck,
           let entry = runner.gatewayDisplayOrder.first(where: { $0.ref == scoped.ref }) {
            Text(LocalizedStringResource(
                "diagnostics.summary.scopedCheck",
                defaultValue: "\(entry.displayName) checked \(scoped.date.formatted(.relative(presentation: .named)))"
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: Connection

    /// Connection = one row per gateway (titled with its REAL name via
    /// `gatewayDisplayOrder`, status read live from `checks`), each with its
    /// file-server lane nested beneath it, then the non-gateway rows (no-gateway /
    /// focused-missing / Internet).
    private var connectionSection: some View {
        Section {
            ForEach(runner.gatewayDisplayOrder) { entry in
                if let check = runner.checks.first(where: { $0.id == entry.connectionCheckID }) {
                    // Row + its own re-probe, laid out like `fileServerSubRow`:
                    // stacked under the status at accessibility text sizes so
                    // neither the copy nor the button is crushed in the narrow
                    // trailing slot.
                    VStack(alignment: .leading, spacing: 6) {
                        if dynamicTypeSize.isAccessibilitySize {
                            DiagnosticCheckRow(check: check, titleOverride: entry.displayName)
                            recheckButton(for: entry.ref)
                                .padding(.leading, 30)
                                .accessibilityLabel(Text(LocalizedStringResource(
                                    "diagnostics.action.recheckGateway.a11y",
                                    defaultValue: "Check the connection to \(entry.displayName) again")))
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                DiagnosticCheckRow(check: check, titleOverride: entry.displayName)
                                Spacer(minLength: 8)
                                recheckButton(for: entry.ref)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel(Text(LocalizedStringResource(
                                        "diagnostics.action.recheckGateway.a11y",
                                        defaultValue: "Check the connection to \(entry.displayName) again")))
                            }
                        }
                        chatProvenLine(for: entry.ref)
                            .padding(.leading, 30)
                    }
                    .settingsCardPassiveRow()
                }
                if let lane = runner.fileLanes.first(where: { $0.ref == entry.ref }) {
                    fileServerSubRow(lane)
                }
            }
            // Half-configured gateways, one row each, TITLED WITH THE REAL NAME —
            // the whole point of the row. The status (red when nothing else can
            // send, amber when a healthy sibling exists) is read live from
            // `checks`; only the name comes from this UI-only list, so the pasted
            // report still shows the gateway KIND and never a user's own label.
            ForEach(runner.incompleteGatewayDisplay) { entry in
                if let check = runner.checks.first(where: { $0.id == entry.connectionCheckID }) {
                    DiagnosticCheckRow(check: check, titleOverride: entry.displayName)
                        .settingsCardPassiveRow()
                }
            }
            ForEach(runner.checks.filter {
                $0.category == .connection
                    && !$0.id.hasPrefix("gateway.")
                    && !$0.id.hasPrefix("connection.gateway.incomplete.")
                    && ($0.id != "connection.network" || runner.showsNetworkConnectionIssue)
            }) {
                DiagnosticCheckRow(check: $0)
                    .settingsCardPassiveRow()
            }
        } header: {
            Text(LocalizedStringResource("diagnostics.section.connection", defaultValue: "Connection"))
        } footer: {
            // Shown only when every gateway on the device is half-configured, so
            // the named rows above have replaced "No Personal AI configured".
            // A footer, not a row: it states the consequence the rows share,
            // without counting as a finding of its own.
            if runner.showsNoSendableGatewayNotice {
                Text(LocalizedStringResource(
                    "diagnostics.connection.gateway.noneSendable.footer",
                    defaultValue: "No gateway can send on this device until you finish one above, or connect another in Personal AI."
                ))
            }
        }
    }

    // MARK: Voice

    /// Two provider-led blocks: each selected provider is immediately followed by
    /// its requirements, explicit test, and result. Provider glyphs stay neutral
    /// when configured because configuration readiness is not proof that a live
    /// provider call succeeds; only missing configuration earns a warning glyph.
    /// `runner.activeVoiceSetup` lives OUTSIDE `checks` so a user-named custom
    /// endpoint never reaches the copyable report.
    @ViewBuilder
    private var voiceSections: some View {
        Section {
            if let setup = runner.activeVoiceSetup {
                voiceSetupRow(
                    title: LocalizedStringResource("diagnostics.voice.setup.stt", defaultValue: "Speech-to-Text"),
                    providerName: setup.sttName,
                    status: setup.sttStatus,
                    systemImage: "waveform"
                )
            }
            ForEach(voiceCheckRows) { checkRow($0) }
            Button {
                Task { await runner.runTranscriptionTest() }
            } label: {
                Label(
                    LocalizedStringResource("diagnostics.action.testTranscription", defaultValue: "Test transcription"),
                    systemImage: "waveform"
                )
                .labelStyle(AccentGlyphActionLabelStyle())
            }
            #if os(macOS)
            // A row that IS one action, so on macOS it becomes a live full-bleed
            // card row rather than a compact pill floating in a dead row. The
            // pills elsewhere on this screen stay pills for the opposite reason:
            // they sit in a status row's trailing slot, where the pill and not
            // the row is the thing a click is aimed at.
            .settingsCardRowButton()
            #else
            .buttonStyle(.bordered)
            #endif
            .disabled(runner.isTranscribing || runner.isRunningAllTests)
            transcriptionTestResult
        } header: {
            Text(LocalizedStringResource("diagnostics.section.voice", defaultValue: "Voice"))
        }

        Section {
            if let setup = runner.activeVoiceSetup {
                voiceSetupRow(
                    title: LocalizedStringResource("diagnostics.voice.setup.tts", defaultValue: "Text-to-Speech"),
                    providerName: setup.ttsName,
                    status: setup.ttsStatus,
                    keyState: setup.ttsKeyState,
                    systemImage: "speaker.wave.2"
                )
            }
            Button {
                Task { await runner.runVoicePreview() }
            } label: {
                Label(
                    LocalizedStringResource("diagnostics.action.previewVoice", defaultValue: "Preview voice"),
                    systemImage: "speaker.wave.2"
                )
                .labelStyle(AccentGlyphActionLabelStyle())
            }
            #if os(macOS)
            // A whole-row action, like "Test transcription" above it.
            .settingsCardRowButton()
            #else
            .buttonStyle(.bordered)
            #endif
            .disabled(runner.voicePreview == .preparing || runner.voicePreview == .playing || runner.isRunningAllTests)
            voicePreviewStatus
        } footer: {
            Text(LocalizedStringResource(
                "diagnostics.footer.voice",
                defaultValue: "Uses your selected providers. Cloud providers may charge for these tests."
            ))
        }
    }

    private func voiceSetupRow(
        title: LocalizedStringResource,
        providerName: String,
        status: DiagnosticStatus,
        keyState: APIKeyState? = nil,
        systemImage: String
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            voiceSetupGlyph(status, systemImage: systemImage).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                // The amber glyph never stands alone — one short gloss says what
                // it means (and gives VoiceOver the warning the icon can't).
                //
                // An UNREADABLE key is not missing setup — but it is also NOT,
                // in practice, a locked device. Secrets are
                // `kSecAttrAccessibleAfterFirstUnlock` and this screen requires
                // an unlocked device to reach, so the locked-Keychain producer
                // is effectively unreachable here. The producer that DOES fire
                // is a slot that read back empty or undecodable — a key that is
                // stored but unusable. "Unlock and try again" is useless advice
                // for that (the device is already unlocked), and "run the tests
                // again" names the wrong control: the run-all sweep never
                // recomputes this row, only Refresh does. Say what is true and
                // point at the one action that fixes it.
                if status == .warning {
                    Text(keyState == .unreadable
                         ? LocalizedStringResource(
                            "diagnostics.voice.setup.keyUnreadable",
                            defaultValue: "A key is saved for this provider but can't be read back — re-enter it in Voice settings."
                         )
                         : LocalizedStringResource(
                            "diagnostics.voice.setup.needsSetup",
                            defaultValue: "Needs setup — finish this provider in Voice settings."
                         ))
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
                }
            }
            Spacer(minLength: 8)
            Text(providerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        // A read-only label/value pair — inset and pitch, no wash.
        .settingsCardPassiveRow()
    }

    @ViewBuilder
    private func voiceSetupGlyph(_ status: DiagnosticStatus, systemImage: String) -> some View {
        if status == .warning {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.warning)
        } else {
            Image(systemName: systemImage)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    /// Voice checks EXCEPT the two paid tests — those render their result beneath
    /// their own button (`transcriptionTestResult` / `voicePreviewStatus`).
    /// Includes the Microphone + Speech-Recognition permission rows (category
    /// `.voice` — every prerequisite for recording sits beside its test).
    private var voiceCheckRows: [DiagnosticCheck] {
        runner.checks.filter { $0.category == .voice && $0.tier != .explicitPaid }
    }

    /// Shared row dispatcher — routes the actionable permission rows to
    /// `permissionRow` (with their Allow / Open Settings button) wherever they
    /// render; every other check gets the plain row.
    ///
    /// The card row treatment lands HERE rather than at the two `ForEach` call
    /// sites, so every branch of the switch arrives on the same inset and pitch.
    private func checkRow(_ check: DiagnosticCheck) -> some View {
        Group {
            switch check.id {
            case "voice.mic.permission":
                permissionRow(check, permission: .microphone)
            case "voice.speech.permission":
                permissionRow(check, permission: .speechRecognition)
            case "connection.notifications":
                permissionRow(check, permission: .notifications)
            case "capability.screenRecording":
                permissionRow(check, permission: .screenRecording)
            default:
                DiagnosticCheckRow(check: check)
            }
        }
        .settingsCardPassiveRow()
    }

    private func permissionRow(
        _ check: DiagnosticCheck,
        permission: DiagnosticPermission
    ) -> some View {
        let action = runner.permissionAction(for: permission)
        return HStack(alignment: .top, spacing: 10) {
            DiagnosticCheckRow(check: check)
            if let action {
                Button {
                    performPermissionAction(action, for: permission)
                } label: {
                    if runner.permissionRequestInFlight == permission {
                        ProgressView().controlSize(.small)
                    } else {
                        switch action {
                        case .allow:
                            Text(LocalizedStringResource(
                                "diagnostics.permission.allow",
                                defaultValue: "Allow"
                            ))
                        case .openSettings:
                            Text(LocalizedStringResource("Open Settings", defaultValue: "Open Settings"))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(runner.isBusy)
            }
        }
    }

    private func performPermissionAction(
        _ action: DiagnosticPermissionAction,
        for permission: DiagnosticPermission
    ) {
        switch action {
        case .allow:
            Task { await runner.requestPermission(permission) }
        case .openSettings:
            openPermissionSettings(for: permission)
        }
    }

    /// A denied TCC grant cannot be prompted again. iOS/iPadOS exposes the app's
    /// own Settings page; macOS can land directly on the matching Privacy pane.
    private func openPermissionSettings(for permission: DiagnosticPermission) {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        let anchor: String
        switch permission {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .notifications:
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
            NSWorkspace.shared.open(url)
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The transcription-test outcome, shown under the "Test transcription" button
    /// once it has run (Heard: … / the fix). Reuses the row renderer.
    @ViewBuilder
    private var transcriptionTestResult: some View {
        if let test = runner.checks.first(where: { $0.id == "voice.stt.test" }), test.status != .notRun {
            DiagnosticCheckRow(check: test)
                .settingsCardPassiveRow()
        }
    }

    /// The card row treatment sits inside each populated branch, not around the
    /// switch: `.idle` renders nothing, and a wrapper there would risk an empty
    /// row at the card's tail carrying the full row pitch.
    @ViewBuilder
    private var voicePreviewStatus: some View {
        switch runner.voicePreview {
        case .idle:
            EmptyView()
        case .preparing, .playing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("diagnostics.voice.playing", defaultValue: "Playing a sample…"))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            .settingsCardPassiveRow()
        case .done:
            Label {
                Text(LocalizedStringResource("diagnostics.voice.played", defaultValue: "Played a sample"))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.success)
            }
            .settingsCardPassiveRow()
        case .failed(let message):
            Label {
                Text(message).font(.caption).foregroundStyle(AppColors.error)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.error)
            }
            .settingsCardPassiveRow()
        }
    }

    // MARK: File server sub-row (nested under its gateway in Connection)

    /// The per-gateway file-server lane, nested beneath its gateway's connection
    /// row. Leads with a "File server" label (the gateway NAME is on the header
    /// row above) + the derived badge + optional detail + an inline "Test" that
    /// runs THAT gateway's staged write test, with the per-ref
    /// `FileTransferStageChecklist` expanding beneath it after a test. Indented so
    /// it reads as a child of the gateway row.
    @ViewBuilder
    private func fileServerSubRow(_ lane: FileLaneState) -> some View {
        let badge = fileLaneBadge(lane)
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize, lane.configured {
                // Accessibility text: stack the action UNDER the status so neither
                // the copy nor the button is crushed in the narrow trailing slot.
                fileServerStatusRow(lane, badge: badge)
                fileServerTestButton(lane)
                    .padding(.leading, 30)   // align under the title column (20pt glyph + 10pt spacing)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    fileServerStatusRow(lane, badge: badge)
                    Spacer(minLength: 8)
                    // The staged write test is offered only for a configured lane
                    // (nothing to write to otherwise). `.fixedSize` keeps the CTA
                    // on one line so it never wraps in the trailing slot.
                    if lane.configured {
                        fileServerTestButton(lane)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            if let result = runner.fileTransferResults[lane.ref] {
                FileTransferStageChecklist(result: result)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 28)   // nest the file server under its gateway row
        // Outside the nesting indent, so the card's own inset adds to it and the
        // lane still reads as a child of the gateway row above.
        .settingsCardPassiveRow()
    }

    /// The "File server" status column (badge glyph + label + derived badge text +
    /// optional detail). Glyph is accessibility-hidden — the badge text already
    /// speaks the status, so VoiceOver shouldn't also read an SF Symbol name.
    private func fileServerStatusRow(
        _ lane: FileLaneState,
        badge: (glyph: String, tint: Color, text: LocalizedStringResource)
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: badge.glyph)
                .foregroundStyle(badge.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringResource("diagnostics.files.serverLabel", defaultValue: "File server"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                Text(badge.text)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                if let detail = lane.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }

    /// The staged write-test action for one file lane — the house-standard bordered
    /// action (accent glyph + neutral title via `AccentGlyphActionLabelStyle`),
    /// matching "Test everything" / "Copy Diagnostics" and the twin "Test
    /// Connection" in `CustomSTTConfigBody`.
    @ViewBuilder
    private func fileServerTestButton(_ lane: FileLaneState) -> some View {
        Button {
            Task { await runner.runFileTransferTest(for: lane.ref) }
        } label: {
            if runner.fileTransferTestRunning.contains(lane.ref) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "diagnostics.action.testing", defaultValue: "Testing…")))
            } else {
                // Same CTA name + glyph as every other surface's staged
                // file-server test (editor, setup guide).
                Label(
                    LocalizedStringResource("settings.fileTransfer.testConnection.button", defaultValue: "Test file server"),
                    systemImage: "checkmark.shield"
                )
                .font(.subheadline.weight(.semibold))
                .labelStyle(AccentGlyphActionLabelStyle())
            }
        }
        .buttonStyle(.bordered)
        .disabled(runner.fileTransferTestRunning.contains(lane.ref) || runner.isRunningAllTests)
        .accessibilityLabel(Text(LocalizedStringResource(
            "diagnostics.action.testFileServer.a11y",
            defaultValue: "Test file-server connection for \(lane.displayName)")))
    }

    /// Map the model-derived `FileLaneState.Badge` to its glyph, tint, and label.
    /// The failure-before-verified ordering lives in the model.
    private func fileLaneBadge(_ lane: FileLaneState) -> (glyph: String, tint: Color, text: LocalizedStringResource) {
        // ONE OVERRIDE, ahead of the model's badge. A lane that moves bytes but
        // cannot list a folder is a genuine pass in the model's terms — uploads
        // work — and "Verified" is what the model calls that. On a diagnostics
        // screen it over-claims: the user came here to find out why files are
        // not coming back, and a green seal is the worst possible answer to that
        // question. The ranking of the persisted verdict against this session's
        // result lives in the runner (`fileLaneReturnCaveat`), where it is
        // testable and stated once; the checklist below spells out which stage
        // it was.
        switch runner.fileLaneReturnCaveat(for: lane) {
        case .uploadsOnly:
            return ("exclamationmark.triangle.fill", AppColors.warning,
                    LocalizedStringResource(
                        "diagnostics.files.badge.uploadsOnly",
                        defaultValue: "Uploads only — can't list folders"))
        case .returnUnchecked:
            // Same reasoning, one step weaker: the seal has to come off for "we
            // could not check" as much as for "it cannot", because the user is
            // on this screen asking why files are not coming back and a green
            // Verified answers that question wrongly either way.
            return ("exclamationmark.triangle.fill", AppColors.warning,
                    LocalizedStringResource(
                        "diagnostics.files.badge.returnUnchecked",
                        defaultValue: "Uploads verified — couldn't check returns"))
        case nil:
            break
        }
        switch lane.badge {
        case .failed:
            return ("xmark.circle.fill", AppColors.error,
                    LocalizedStringResource("diagnostics.files.badge.failed", defaultValue: "Failed"))
        case .unconfirmed:
            return ("exclamationmark.triangle.fill", AppColors.warning,
                    LocalizedStringResource("diagnostics.files.badge.unconfirmed", defaultValue: "Unconfirmed"))
        case .verified:
            return ("checkmark.seal.fill", AppColors.success,
                    LocalizedStringResource("diagnostics.files.badge.verified", defaultValue: "Verified"))
        case .testing:
            return ("ellipsis.circle", AppColors.textSecondary,
                    LocalizedStringResource("diagnostics.files.badge.testing", defaultValue: "Testing…"))
        case .configuredNotTested:
            return ("circle", AppColors.textSecondary,
                    LocalizedStringResource("diagnostics.files.badge.notTested", defaultValue: "Configured — not tested"))
        case .notSetUp:
            return ("minus.circle", AppColors.textTertiary,
                    LocalizedStringResource("diagnostics.files.badge.notSetUp", defaultValue: "Not set up"))
        }
    }

    // MARK: Capabilities and permissions

    private var capabilitySection: some View {
        Section {
            ForEach(checks(in: .capability)) { checkRow($0) }
        } header: {
            Text(LocalizedStringResource(
                "diagnostics.section.capability",
                defaultValue: "Capabilities and Permissions"
            ))
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            ForEach(checks(in: .sync)) { check in
                if check.id == DiagnosticsRunner.watchCheckID {
                    watchRow(check)
                } else {
                    DiagnosticCheckRow(check: check)
                        .settingsCardPassiveRow()
                }
            }
        } header: {
            Text(LocalizedStringResource("diagnostics.section.sync", defaultValue: "Sync"))
        }
    }

    // MARK: Apple Watch row (live health query — the fileServerSubRow pattern)

    /// The Apple Watch row: the standard check row + a trailing "Check" action
    /// (the live `diagnostics-pull` round trip — free/non-billable, needs the
    /// wrist awake) + a nested sub-detail block once a query has produced
    /// anything. The button shows only on the live row (`.passed` — installed
    /// and enabled; a not-installed warning or a disabled master switch has
    /// nothing to query).
    @ViewBuilder
    private func watchRow(_ check: DiagnosticCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The "Check" action shows only on the LIVE row (`.passed` — installed
            // and enabled; a not-installed warning or a disabled master switch has
            // nothing to query).
            if check.status == .passed {
                if dynamicTypeSize.isAccessibilitySize {
                    DiagnosticCheckRow(check: check)
                    watchCheckButton
                        .padding(.leading, 30)   // align under the title column
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        DiagnosticCheckRow(check: check)   // its trailing Spacer pushes the button right
                        watchCheckButton
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            } else {
                DiagnosticCheckRow(check: check)
            }
            // Health block only under the LIVE row form — a disabled master
            // switch (`.notApplicable`) or a not-installed warning must not keep
            // rendering a stale snapshot it offers no Check button to refresh.
            if check.status == .passed, runner.watchHealthLastOutcome != nil {
                watchHealthBlock
                    .padding(.leading, 28)   // nest under the row, like file lanes
            }
        }
        .padding(.vertical, 2)
        .settingsCardPassiveRow()
    }

    /// The live watch health re-query (`diagnostics-pull` round trip — free /
    /// non-billable, needs the wrist awake). House-standard bordered action
    /// (accent glyph + neutral title); `arrow.clockwise` reads as "re-check"
    /// without implying the watch has already passed.
    @ViewBuilder
    private var watchCheckButton: some View {
        Button {
            Task { await runner.runWatchHealthCheck() }
        } label: {
            if runner.isCheckingWatch {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "diagnostics.action.checkingWatch", defaultValue: "Checking…")))
            } else {
                Label(
                    LocalizedStringResource("diagnostics.action.checkWatch", defaultValue: "Check"),
                    systemImage: "arrow.clockwise"
                )
                .font(.subheadline.weight(.semibold))
                .labelStyle(AccentGlyphActionLabelStyle())
            }
        }
        .buttonStyle(.bordered)
        .disabled(runner.isCheckingWatch || runner.isRunningAllTests)
        .accessibilityLabel(Text(LocalizedStringResource(
            "diagnostics.action.checkWatch.a11y", defaultValue: "Check Apple Watch")))
    }

    /// The nested health readout. A failed/unsupported refresh PRESERVES the
    /// last good snapshot under a "couldn't refresh" line — evidence beats a
    /// blank slate.
    @ViewBuilder
    private var watchHealthBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch runner.watchHealthLastOutcome {
            case .reply(let state):
                watchHealthFacts(state)
            case .unsupported:
                Text(LocalizedStringResource("diagnostics.watch.unsupported", defaultValue: "The watch responded, but its Conduck version doesn't support health checks yet — update the app on the watch."))
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
                if let last = runner.watchHealth { watchHealthFacts(last, stale: true) }
            case .noResponse:
                Text(LocalizedStringResource("diagnostics.watch.noResponse", defaultValue: "Watch didn't respond. Open Conduck on your Watch, then check again."))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                if let last = runner.watchHealth { watchHealthFacts(last, stale: true) }
            case nil:
                EmptyView()
            }
        }
    }

    /// The decoded facts: settings-courier standing, relay queue depth (only
    /// when non-empty), amber lines for wrist-side denied permissions, and a
    /// version footnote. `stale:` prefixes a last-checked line when the facts
    /// come from a PREVIOUS successful query.
    @ViewBuilder
    private func watchHealthFacts(_ state: WatchHealthState, stale: Bool = false) -> some View {
        if stale {
            Text(String(
                format: String(localized: "diagnostics.watch.staleFacts", defaultValue: "Last check from %@:"),
                state.receivedAt.formatted(.relative(presentation: .named))
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
        }
        switch state.settingsFreshness {
        case .current:
            Text(String(
                format: String(localized: "diagnostics.watch.settings.current", defaultValue: "Watch accepted the latest settings %@."),
                Date(timeIntervalSinceReferenceDate: state.agentEnvelopeTs).formatted(.relative(presentation: .named))
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        case .behind:
            Text(LocalizedStringResource("diagnostics.watch.settings.behind", defaultValue: "The watch hasn't received the latest settings yet — updates deliver when it's awake and nearby."))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        case .never:
            Text(LocalizedStringResource("diagnostics.watch.settings.never", defaultValue: "The watch hasn't accepted settings from this iPhone yet."))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        case .unknown:
            EmptyView()
        }
        if let depth = state.relayQueueDepth, depth > 0 {
            Text(String(
                format: String(localized: "diagnostics.watch.relayQueue", defaultValue: "%lld recording(s) waiting on the watch to transcribe — they process when the watch reaches this iPhone."),
                Int64(depth)
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
        if state.micPermission == "denied" {
            Label {
                Text(LocalizedStringResource("diagnostics.watch.micDenied", defaultValue: "Microphone is off on the watch — allow it in the Watch app's settings to record from the wrist."))
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
            }
        }
        if state.notificationPermission == "denied" {
            Label {
                Text(LocalizedStringResource("diagnostics.watch.notifDenied", defaultValue: "Notifications are off on the watch — replies to wrist asks won't alert there."))
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
            }
        }
        if let version = state.appVersion, let build = state.appBuild {
            // Verbatim: version identity, not localizable prose.
            Text(verbatim: "Conduck \(version) (\(build))" + (state.osVersion.map { " · watchOS \($0)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: Copy

    private var copySection: some View {
        Section {
            Button {
                Pasteboard.copy(runner.copyBlock())
                copyResetTask?.cancel()
                withAnimation { copied = true }
                copyResetTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation { copied = false }
                }
            } label: {
                Label(
                    copied
                        ? LocalizedStringResource("diagnostics.action.copied", defaultValue: "Copied")
                        : LocalizedStringResource("diagnostics.action.copy", defaultValue: "Copy Diagnostics"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.body.weight(.bold))
                .labelStyle(AccentGlyphActionLabelStyle())
                .frame(maxWidth: .infinity)
            }
            #if os(macOS)
            // Same full-row filled surface as Test everything, and for the same
            // reason it takes no card row modifier: the style already owns a
            // full-width live frame, its own inset and its own hover wash, so
            // inside a `SettingsCard` it fills the card edge to edge on its own.
            .buttonStyle(MacDiagnosticsActionButtonStyle())
            #else
            .buttonStyle(.bordered)
            #endif
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            #if os(macOS)
            // A clear header spacer, purely to reserve extra room above this
            // trailing action: it renders OUTSIDE the section card, setting Copy
            // apart from the checklist above by more than the uniform gap
            // between cards. (`listSectionSpacing` is unavailable on macOS.)
            Color.clear.frame(height: 10)
            #endif
        } footer: {
            Text(LocalizedStringResource(
                "diagnostics.footer.copy",
                defaultValue: "Copies a safe summary you can paste anywhere. No links, keys, or message content are included."
            ))
        }
    }

    // MARK: Helpers

    private func checks(in category: DiagnosticCategory) -> [DiagnosticCheck] {
        runner.checks.filter { $0.category == category }
    }
}

#if os(macOS)
/// The macOS Diagnostics primary-action buttons (Test everything / Copy
/// Diagnostics). The stock `.bordered` control rendered as a faint grey label
/// with margin around it inside the grouped-section row; this fills the row
/// edge-to-edge with a raised elevated-card surface so it reads as a real push
/// button. It sets NO foreground — the label keeps its own colors (accent glyph
/// + light title) untouched; only the button SHAPE changes.
struct MacDiagnosticsActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    /// A `ButtonStyle` is not a `View`, so `@State` and `@Environment` get no
    /// storage on the style itself (see `MacPointerTargets`) — hover tracking and
    /// the enabled read therefore live in this nested view, which IS one.
    private struct Surface: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            return configuration.label
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    ZStack {
                        shape.fill(AppColors.cardBackgroundElevated
                            .opacity(configuration.isPressed ? 0.7 : 1))
                        // The card fill is opaque, so the pointer wash layers ON
                        // TOP of it (still behind the label) — painted behind the
                        // card it would never be visible.
                        shape.fill(highlightFill)
                    }
                }
                .overlay(shape.stroke(AppColors.border, lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(MacPointer.highlightAnimation, value: hovering)
        }

        /// Nothing while disabled — a highlight on an inert control is a lie
        /// about what a click would do.
        private var highlightFill: Color {
            guard isEnabled, hovering, !configuration.isPressed else { return .clear }
            return AppColors.pointerHoverFill
        }
    }
}
#endif
