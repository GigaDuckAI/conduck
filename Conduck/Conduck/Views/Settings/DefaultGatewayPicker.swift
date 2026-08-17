// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayPicker.swift
//
// Personal AI's single canonical "which gateway" surface — the analog of the
// Voice screen's STT/TTS selectors. Two pieces, shared iOS + macOS:
//
//   - `DefaultGatewaySelectorRow` — the top row on the Personal AI screen,
//     reading "Default for new chats → <gateway>". Tapping it opens the picker.
//     Mirrors `VoiceDirectionSelectorRow` (amber trailing value + chevron).
//
//   - `DefaultGatewayPicker` — the pushed chooser. Lists every gateway; a
//     CONFIGURED one is tappable (tap → make it the default for NEW conversations
//     → pop); an UNCONFIGURED one deep-links into its config detail ("Set up…").
//     The current default carries the single amber check (the picker idiom).
//
// WHY "Default for new chats", not "Active gateway": routing is PER-CONVERSATION
// (each thread is bound to the gateway it was started on). The default is only
// the pre-pick for NEW conversations — the honest label defuses the false read
// that changing it re-routes an open chat. (Codex + Gemini both flagged this.)
//
// The pre-pick is NOT this value alone: a new chat continues on the gateway the
// last one was started on (`NewChatGatewaySeed`), and falls back here when there
// is no such gateway. Choosing a default clears that memory, so this screen always
// takes effect immediately — including a re-tap of the gateway already checked,
// which is how a user reacts when a setting looks ignored. The footer says so; keep
// it and the copy honest about "until you use a different gateway", because the row
// shows the STORED default and the next chat may legitimately start elsewhere.
//
// The amber check answers "which one is currently CHOSEN", never "which one
// works" — so a row the user CHOSE keeps it even when that gateway is not set up
// here, which is precisely the state a device whose default broke lands in. A
// chooser that showed no selection there would leave the user unable to tell
// which gateway the screen is even about; the row still says "Set up…" and still
// deep-links, so both facts stay legible at once. When NOTHING has been chosen —
// no pointer stored, or one the app parked after a Forget — no row is checked at
// all (`SettingsViewModel.personalAIRows` clears it rather than decorate a
// gateway the user never picked), and the leading callout is what says what the
// screen is about.
//
// A leading callout names the trouble when there is any: the stored default
// cannot send here (`brokenDefaultName`), or nothing has been chosen
// (`needsDefaultChoice`). Both are optional and default to off, so the
// iPhone-hosted Apple Watch chooser and the headless Fix sheet mount this view
// unchanged.
//
// REJECTED, and do not re-propose: auto-pushing this chooser from the chat
// notice. It presumes the user wants to abandon the named gateway, when
// finishing its setup is just as often the right fix. The honest one-tap
// destination is the Personal AI screen, which shows BOTH doors.
//
// Presentation only — the caller owns `setDefaultRemoteAgentRef` + the deep-link.

import SwiftUI

/// The top "Default for new chats" selector row on the Personal AI screen.
/// Stateless; the parent supplies the default gateway's name and owns the tap.
struct DefaultGatewaySelectorRow: View {
    /// The default gateway's display name (e.g. "OpenClaw").
    let defaultName: String

    /// Whether the named gateway cannot currently send. Rendered as a SECOND
    /// line under the name rather than appended to it: the trailing slot on an
    /// iPhone row has roughly 70-100pt once the leading label is laid out, which
    /// the name alone fills. Defaults false so the Watch-override row, which
    /// carries no such state, is unaffected.
    var needsSetup: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(LocalizedStringResource(
                    "settings.personalAI.default.selector.label",
                    defaultValue: "Default for new chats"
                ))
                .foregroundStyle(AppColors.textPrimary)
            } icon: {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(AppColors.brandAmber)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(defaultName)
                    .font(.body)
                    .foregroundStyle(AppColors.brandAmber)
                if needsSetup {
                    // Same key + wording as `SettingsStatusMark`'s incomplete row,
                    // so the selector and the gateway list below it say the same
                    // thing about the same gateway. The glyph sits ON that line
                    // rather than above it: a third line would break the macOS
                    // two-line row allowance in `MacPersonalAICategory`.
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(AppColors.sunsetOrange)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "settings.personalAI.default.selector.broken.a11y",
                                defaultValue: "Needs attention"
                            )))
                        Text(LocalizedStringResource(
                            "settings.status.incomplete",
                            defaultValue: "Needs setup"
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The pushed chooser listing every gateway, to pick the default for new chats.
/// Configured rows activate-default on tap; unconfigured rows deep-link to setup.
struct DefaultGatewayPicker: View {
    let rows: [PersonalAIRow]
    /// Make a configured gateway the default for new chats (then pop).
    let onActivate: (RemoteAgentRef) -> Void
    /// Deep-link into an unconfigured gateway's detail to set it up.
    let onSetUp: (RemoteAgentRef) -> Void

    /// Optional "Follow iPhone" leading option — used ONLY by the iPhone-hosted
    /// Apple Watch default-gateway chooser (`WatchSettingsView`). When supplied,
    /// a top section renders a single "Follow iPhone" row (checked when
    /// `followPhoneSelected`); selecting it calls `onFollowPhone`. `nil` on the
    /// Personal AI screen (no such option there). Presentation only.
    var onFollowPhone: (() -> Void)? = nil
    /// Whether the "Follow iPhone" row carries the amber check (override unset).
    var followPhoneSelected: Bool = false

    /// The stored default's display name when it cannot send here. Renders a
    /// leading callout naming it, so the chooser shows BOTH doors: pick another
    /// gateway, or finish setting this one up. Defaulted so the Watch chooser and
    /// the headless Fix sheet need no change.
    var brokenDefaultName: String? = nil
    /// True when NOTHING has been chosen — either no default is stored at all and
    /// the device may not guess one, or a pointer is stored but the app parked it
    /// on the user's behalf after a Forget. Renders the no-name callout.
    var needsDefaultChoice: Bool = false

    private var navTitle: LocalizedStringResource {
        LocalizedStringResource("settings.personalAI.default.picker.title", defaultValue: "Default for new chats")
    }

    private var footer: LocalizedStringResource {
        LocalizedStringResource(
            "settings.personalAI.default.picker.footer",
            defaultValue: "New chats start here until you use a different gateway, then they follow that one. Existing chats keep the one they started on."
        )
    }

    // Partition rows by category. Custom refs have no descriptor — they always
    // go in the self-hosted bucket (they're the user's own OpenAI-compatible endpoint).
    private var selfHostedRows: [PersonalAIRow] {
        rows.filter {
            guard case .builtin(let b) = $0.ref else { return true }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .selfHostedAgent
        }
    }

    private var hostedModelRows: [PersonalAIRow] {
        rows.filter {
            guard case .builtin(let b) = $0.ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .hostedModel
        }
    }

    var body: some View {
        // One section tree for BOTH platforms — the adaptive container renders it
        // as a grouped `Form` on iOS and as full-bleed `SettingsCard`s on macOS;
        // only the iOS-only nav-bar display mode is gated.
        PlatformSettingsForm {
            // The trouble, named, as the FIRST thing on the screen — above even
            // the Watch's "Follow iPhone" option, because it is the reason the
            // user is here. A named broken gateway wins over "nothing chosen":
            // it is the more specific fact. The two are mutually exclusive because
            // the caller derives the name from the same predicate that "nothing
            // chosen" clears (`defaultSelectorBrokenName` off
            // `defaultSelectorFlagsBroken`), so the `else` is belt-and-braces
            // rather than the thing keeping them apart.
            if let brokenDefaultName {
                Section {
                    AmberCallout(
                        systemImage: "exclamationmark.triangle.fill",
                        title: LocalizedStringResource(
                            "settings.personalAI.default.picker.broken.title",
                            defaultValue: "\(brokenDefaultName) isn't set up here"
                        ),
                        message: LocalizedStringResource(
                            "settings.personalAI.default.picker.broken.body",
                            defaultValue: "Pick a gateway below to use for new chats, or tap \(brokenDefaultName) to finish setting it up."
                        )
                    )
                    .settingsCardPassiveRow()
                }
            } else if needsDefaultChoice {
                Section {
                    AmberCallout(
                        systemImage: "questionmark.circle",
                        title: LocalizedStringResource(
                            "settings.personalAI.default.picker.noChoice.title",
                            defaultValue: "No default yet"
                        ),
                        message: LocalizedStringResource(
                            "settings.personalAI.default.picker.noChoice.body",
                            defaultValue: "Pick a gateway below and new chats will start on it."
                        )
                    )
                    .settingsCardPassiveRow()
                }
            }

            // Optional leading "Follow iPhone" option (Apple Watch chooser only).
            // Sits in its own section above the gateway list so it reads as the
            // "inherit" choice, distinct from picking a specific gateway.
            if let onFollowPhone {
                Section {
                    Button {
                        onFollowPhone()
                    } label: {
                        HStack(spacing: 12) {
                            leadingCheck(followPhoneSelected)
                            Text(LocalizedStringResource(
                                "settings.watch.default.followPhone",
                                defaultValue: "Follow iPhone"
                            ))
                            .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .settingsCardRowButton()
                }
            }

            // Self-hosted gateways (OpenClaw / Hermes / customs). The picker
            // footer lives on THIS section when there are no hosted-model rows,
            // so it always renders at the bottom of the visible list.
            if hostedModelRows.isEmpty {
                Section {
                    ForEach(selfHostedRows) { row in
                        optionRow(row)
                    }
                } footer: {
                    Text(footer)
                }
            } else {
                Section {
                    ForEach(selfHostedRows) { row in
                        optionRow(row)
                    }
                }
                // Hosted-model services (OpenRouter) in a distinct section so the
                // user sees the cloud boundary before selecting.
                Section {
                    ForEach(hostedModelRows) { row in
                        hostedOptionRow(row)
                    }
                } header: {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.hostedModels.header",
                        defaultValue: "Hosted models"
                    ))
                } footer: {
                    Text(footer)
                }
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle(Text(navTitle))
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS: own in-pane header (no native title-bar toolbar) so the Settings
        // sidebar never shifts on push. See `MacSettingsSubScreenChrome`.
        .macSettingsSubScreenChrome(title: String(localized: navTitle))
        #endif
    }

    @ViewBuilder
    private func optionRow(_ row: PersonalAIRow) -> some View {
        if row.configured {
            Button {
                onActivate(row.ref)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(row.isDefault)
                    Text(row.displayName)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            // No padding argument anywhere in this picker: a card row takes its
            // inset from the row style, INSIDE the live frame, so every row here
            // — and in the twin voice chooser (`VoiceActiveProviderPicker`) —
            // lands on the identical inset with the fixed 18pt check slot still
            // doing the name alignment. A padding at the call site would sit
            // outside the live frame and be dead.
            .settingsCardRowButton()
        } else {
            Button {
                onSetUp(row.ref)
            } label: {
                HStack(spacing: 12) {
                    // The check follows the CHOSEN gateway, not the working one —
                    // see the file header. An unconfigured default wears it when
                    // the user chose it; nothing is checked at all when nothing
                    // has been chosen — see `SettingsViewModel.personalAIRows`.
                    leadingCheck(row.isDefault)
                    Text(row.displayName)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text(LocalizedStringResource("settings.voice.chooser.setUp", defaultValue: "Set up…"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .settingsCardRowButton()
        }
    }

    /// Like `optionRow` but adds a secondary "Hosted" caption so the user sees
    /// the cloud-service boundary before selecting (OpenRouter, etc.). Used for
    /// `.hostedModel` backends in the "Hosted models" section.
    @ViewBuilder
    private func hostedOptionRow(_ row: PersonalAIRow) -> some View {
        if row.configured {
            Button {
                onActivate(row.ref)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(row.isDefault)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .foregroundStyle(AppColors.textPrimary)
                        Text(LocalizedStringResource(
                            "settings.personalAI.hostedBadge",
                            defaultValue: "Hosted"
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .settingsCardRowButton()
        } else {
            Button {
                onSetUp(row.ref)
            } label: {
                HStack(spacing: 12) {
                    // The check follows the CHOSEN gateway, not the working one —
                    // see the file header. An unconfigured default wears it when
                    // the user chose it; nothing is checked at all when nothing
                    // has been chosen — see `SettingsViewModel.personalAIRows`.
                    leadingCheck(row.isDefault)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .foregroundStyle(AppColors.textSecondary)
                        Text(LocalizedStringResource(
                            "settings.personalAI.hostedBadge",
                            defaultValue: "Hosted"
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    }
                    Spacer()
                    Text(LocalizedStringResource("settings.voice.chooser.setUp", defaultValue: "Set up…"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .settingsCardRowButton()
        }
    }

    /// Fixed-width leading slot: amber checkmark on the current default, empty
    /// otherwise (keeps names aligned — no radio circles).
    private func leadingCheck(_ selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.brandAmber)
            .opacity(selected ? 1 : 0)
            .frame(width: 18, alignment: .leading)
    }
}
