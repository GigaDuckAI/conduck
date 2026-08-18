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
//   - `DefaultGatewayPicker` — the pushed chooser. Lists ONLY the gateways that
//     can send here; tapping one makes it the default for NEW conversations and
//     pops. The current default carries the single amber check (the picker idiom).
//
// A gateway you have not connected is NOT offered here, and that is the whole
// rule this screen enforces: the catalog on the Personal AI screen is a menu of
// optional things you MAY connect, while this is the shorter question "which of
// the ones that work should new chats start on". Offering an unconnected gateway
// as a default answers neither — it cannot be the default, and a chooser is the
// wrong place to start a setup flow. The catalog is one back-tap away and shows
// every gateway, connected or not, which is where connecting belongs.
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
// The amber check answers "which one is currently CHOSEN", and since only
// send-able gateways are listed, a chosen gateway that cannot send here has no
// row to wear it. That is not a loss of information: the leading callout names
// it in a full sentence, which says more than a check ever did.
//
// NO row is checked in exactly one state — `defaultSelectorNeedsChoice`, which is
// "nothing chosen ON A DEVICE THAT HAS SOMETHING TO CHOOSE BETWEEN": either the
// resolver asked for a pick (`.selectionRequired`, returned only past its
// zero-configured branch, so working gateways always exist there) or the app
// parked the pointer after a Forget. `SettingsViewModel.personalAIRows` clears
// the check rather than decorate a gateway the user never picked, and the leading
// callout is what says what the screen is about.
//
// A device with NOTHING configured is not that state and must not be read as it.
// `zeroConfiguredVerdict` answers `.nothingConfigured`, `.setupUnfinished` or
// `.readingUnreliable` depending on what residue it finds — but none of the three
// is `.selectionRequired` and none parks the pointer, so `selectorNeedsChoice` is
// false for all of them and no callout renders. There are also no rows: with
// nothing send-able the list is empty and the empty line carries the screen.
// There is nothing to choose between yet, and the screen that owns that moment is
// the Personal AI catalog, not this chooser.
//
// A leading callout carries the sentence the rest of the app is not allowed to
// say: the stored default is not available here (`defaultUnavailableName`), or
// nothing has been chosen (`needsDefaultChoice`). THIS IS THE PLACE, because the
// user opened it — the chat window stays silent about the same fact precisely so
// that it lands once, where it is asked for, instead of every launch.
//
// The unavailable-default copy is deliberately NEUTRAL and deliberately NAMES the
// gateway. Neutral, because "isn't set up" and "needs setup" both assert a chore
// the storage cannot actually evidence — a key still crossing iCloud Keychain
// reads exactly like a setup abandoned months ago. Named, because the alternative
// is a user whose gateway has silently vanished from a list they know they
// configured, and the reasonable conclusion from that is data loss. Naming it
// also turns the next tap into an informed REPLACEMENT rather than the filling of
// an empty slot, which matters: choosing here overwrites the stored pointer, so
// the original will not resume on its own if its key later arrives.
//
// Both are optional, but "optional" does NOT mean "safe to omit". Every mount
// that filters an unavailable choice out of its own list owes the callout, or it
// renders a chooser with nothing checked and nothing said — the iPhone-hosted
// Apple Watch chooser (whose pinned override can stop sending) and the
// Diagnostics Fix sheet (opened from a red row about a named gateway) both pass
// it. Leaving them off is what turns "your gateway is not offered here" into
// "your gateway is gone".
//
// REJECTED, and do not re-propose: auto-pushing this chooser from a chat surface.
// It presumes the user wants to abandon the named gateway, when waiting for its
// key to arrive is just as often the right answer.
//
// Presentation only — the caller owns `setDefaultRemoteAgentRef`.

import SwiftUI

/// The top "Default for new chats" selector row on the Personal AI screen.
/// Stateless; the parent supplies the default gateway's name and owns the tap.
struct DefaultGatewaySelectorRow: View {
    /// The default gateway's display name (e.g. "OpenClaw").
    let defaultName: String

    // NO status line here, and none may be added. This row answers "which
    // gateway do new chats start on", and the answer is the name. Whether that
    // gateway can send from THIS device is a different question, asked and
    // answered one tap in — by the picker's callout — where the user has actually
    // asked it. A ⚠ and the words "Needs setup" used to ride under the name; they
    // turned an optional, unconnected gateway into a chore on a screen the user
    // opened to do something else.

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

/// The pushed chooser listing the gateways that can send here, to pick the
/// default for new chats. Every listed row activates the default on tap.
struct DefaultGatewayPicker: View {
    /// The FULL catalog, as the Personal AI screen builds it. Filtered to the
    /// send-able rows here rather than at each of the four call sites, so no
    /// mount can accidentally offer a gateway this device cannot use.
    let rows: [PersonalAIRow]
    /// Make a configured gateway the default for new chats (then pop).
    let onActivate: (RemoteAgentRef) -> Void

    /// Optional "Follow iPhone" leading option — used ONLY by the iPhone-hosted
    /// Apple Watch default-gateway chooser (`WatchSettingsView`). When supplied,
    /// a top section renders a single "Follow iPhone" row (checked when
    /// `followPhoneSelected`); selecting it calls `onFollowPhone`. `nil` on the
    /// Personal AI screen (no such option there). Presentation only.
    var onFollowPhone: (() -> Void)? = nil
    /// Whether the "Follow iPhone" row carries the amber check (override unset).
    var followPhoneSelected: Bool = false

    /// The stored default's display name when it cannot send here. Renders the
    /// leading callout that names it — the ONE place in the app that says this
    /// out loud, because it is the one place the user asked. Defaulted so the
    /// Watch chooser and the headless Fix sheet need no change.
    var defaultUnavailableName: String? = nil
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

    /// The only rows this screen may offer: gateways that can send from here.
    ///
    /// The filter is the screen's contract, not a tidy-up. A row the user cannot
    /// pick has no business in a picker, and an unconnected gateway shown here
    /// reads as an option that silently fails — the very thing the "Set up…" row
    /// tried to paper over by turning the chooser into a second setup entrance.
    private var offerableRows: [PersonalAIRow] {
        rows.filter(\.configured)
    }

    // Partition rows by category. Custom refs have no descriptor — they always
    // go in the self-hosted bucket (they're the user's own OpenAI-compatible endpoint).
    private var selfHostedRows: [PersonalAIRow] {
        offerableRows.filter {
            guard case .builtin(let b) = $0.ref else { return true }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .selfHostedAgent
        }
    }

    private var hostedModelRows: [PersonalAIRow] {
        offerableRows.filter {
            guard case .builtin(let b) = $0.ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .hostedModel
        }
    }

    var body: some View {
        // One section tree for BOTH platforms — the adaptive container renders it
        // as a grouped `Form` on iOS and as full-bleed `SettingsCard`s on macOS;
        // only the iOS-only nav-bar display mode is gated.
        PlatformSettingsForm {
            // The state of the stored pointer, as the FIRST thing on the screen —
            // above even the Watch's "Follow iPhone" option, because it is the
            // reason the user is here and the reason the gateway they expected is
            // not in the list below. A named unavailable default wins over
            // "nothing chosen": it is the more specific fact. The two are mutually
            // exclusive because the caller derives the name from the same
            // predicate that "nothing chosen" clears
            // (`defaultSelectorUnavailableName` off
            // `defaultSelectorFlagsUnavailable`), so the `else` is belt-and-braces
            // rather than the thing keeping them apart.
            //
            // `questionmark.circle`, never a warning triangle, and the copy says
            // "isn't available" rather than "isn't set up". Both are the same
            // ruling: the storage cannot tell a key still crossing iCloud from a
            // setup abandoned long ago, so the app states the one fact that holds
            // either way and leaves the user to decide whether to wait or replace.
            if let defaultUnavailableName {
                Section {
                    AmberCallout(
                        systemImage: "questionmark.circle",
                        title: LocalizedStringResource(
                            "settings.personalAI.default.picker.unavailable.title",
                            defaultValue: "\(defaultUnavailableName) isn't available here"
                        ),
                        // The Watch chooser pins a gateway for the WRIST, not the
                        // default for new chats here, so it gets the sentence that
                        // is true of it. `onFollowPhone` is that screen's existing
                        // discriminator — it is supplied by nothing else.
                        message: onFollowPhone == nil
                            ? LocalizedStringResource(
                                "settings.personalAI.default.picker.unavailable.body",
                                defaultValue: "It's still your default, and it'll work again on its own if it's just waiting on iCloud. To use a different gateway for new chats on this device, pick one below."
                            )
                            : LocalizedStringResource(
                                "settings.personalAI.default.picker.unavailable.watch.body",
                                defaultValue: "It's still the gateway your Apple Watch is pinned to, and it'll work again on its own if it's just waiting on iCloud. To pin a different one, pick it below."
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

            // Nothing can send from here, so there is nothing to choose between.
            // One passive line rather than an empty box: a chooser that renders
            // as blank chrome reads as a screen that failed to load, and the user
            // has no way to tell that from "you have not connected anything yet".
            // The catalog that fixes it is the screen they came from.
            if offerableRows.isEmpty {
                Section {
                    Text(LocalizedStringResource(
                        "settings.personalAI.default.picker.empty",
                        defaultValue: "No gateways are set up on this device yet. Connect one in Personal AI and it'll appear here."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsCardPassiveRow()
                } footer: {
                    Text(footer)
                }
            } else if hostedModelRows.isEmpty {
                Section {
                    ForEach(selfHostedRows) { row in
                        optionRow(row)
                    }
                } footer: {
                    Text(footer)
                }
            } else if selfHostedRows.isEmpty {
                // Only hosted models can send here — OpenRouter connected, nothing
                // self-hosted. Its own branch because the two-section arm below
                // would emit an EMPTY self-hosted `Section`, which macOS renders as
                // a blank `SettingsCard` floating above the real one. Unreachable
                // before `offerableRows` existed (the unfiltered list always
                // carried the self-hosted built-ins), which is why the arm was
                // missing.
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

    /// One offerable gateway. No unconfigured branch exists: `offerableRows`
    /// has already dropped every row that cannot send, so this is unconditionally
    /// a live choice.
    private func optionRow(_ row: PersonalAIRow) -> some View {
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
    }

    /// Like `optionRow` but adds a secondary "Hosted" caption so the user sees
    /// the cloud-service boundary before selecting (OpenRouter, etc.). Used for
    /// `.hostedModel` backends in the "Hosted models" section.
    private func hostedOptionRow(_ row: PersonalAIRow) -> some View {
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
