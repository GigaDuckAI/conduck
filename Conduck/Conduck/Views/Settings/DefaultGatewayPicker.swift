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
// Presentation only — the caller owns `setDefaultRemoteAgentRef` + the deep-link.

import SwiftUI

/// The top "Default for new chats" selector row on the Personal AI screen.
/// Stateless; the parent supplies the default gateway's name and owns the tap.
struct DefaultGatewaySelectorRow: View {
    /// The default gateway's display name (e.g. "OpenClaw").
    let defaultName: String

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
            Text(defaultName)
                .font(.body)
                .foregroundStyle(AppColors.brandAmber)
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

    private var navTitle: LocalizedStringResource {
        LocalizedStringResource("settings.personalAI.default.picker.title", defaultValue: "Default for new chats")
    }

    private var footer: LocalizedStringResource {
        LocalizedStringResource(
            "settings.personalAI.default.picker.footer",
            defaultValue: "New chats start on this gateway. Existing chats keep the one they started on."
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
        // Single grouped-Form branch on BOTH platforms (macOS adopts the iOS
        // idiom for consistency); only the iOS-only nav-bar display mode is gated.
        Form {
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
                    .buttonStyle(.plain)
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
        .formStyle(.grouped)
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
            .buttonStyle(.plain)
        } else {
            Button {
                onSetUp(row.ref)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(false)
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
        } else {
            Button {
                onSetUp(row.ref)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(false)
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
            .buttonStyle(.plain)
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
