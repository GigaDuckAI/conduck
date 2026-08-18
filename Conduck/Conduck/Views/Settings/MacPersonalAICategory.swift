// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacPersonalAICategory.swift
//
// macOS Settings → Personal AI category. Mirrors the iOS
// `PersonalAISettingsView`: a top "Default for new chats" selector (the single
// place to pick which gateway new conversations start on) + a gateway LIST whose
// rows are configure-only (tap → a roomy per-gateway config detail via a
// `NavigationStack` inside the full-window Settings mode swap). Status is
// discrete and BINARY — a quiet green check via `SettingsStatusMark`, or nothing
// at all; no colored pills, no in-row set-default, and no third "unfinished"
// state. The "Default" caption rides either state (so a default that cannot send
// stays identifiable), suppressed only while nothing at all is configured.
//
// Content sits on the shared settings rail (720pt max width, centered, 28pt
// horizontal padding) as a stack of hand-drawn `SettingsCard` sections rather
// than a grouped `Form`: the card applies no padding around its rows, so a
// row's live frame IS the card's full bleed and the hover wash fills the whole
// row (`MacSettingsCard.swift` carries the measurements). Section headers take
// the card's own 13pt semibold secondary treatment — the zone-header prominence
// `RemoteAgentConfigBody` applies — so list and editor read as one surface.
//
// Global pickers (Playback / Session / Attachments) live in `MacGeneralCategory`
// per the plan's clean grouping — NOT here.

import SwiftUI

/// Navigation route for the macOS Personal AI category — the "Default for new
/// chats" chooser or a per-gateway config detail (mirrors the iOS screen).
private enum MacPersonalAIRoute: Hashable {
    case defaultChooser
    case configure(RemoteAgentRef)
}

struct MacPersonalAICategory: View {
    @Bindable var viewModel: SettingsViewModel

    /// Drives all pushes — the default chooser + a gateway config detail.
    @State private var route: MacPersonalAIRoute?

    /// The guided-setup presentation, OWNED by `MainWindowView` and threaded down
    /// through `MacSettingsView`. On macOS the guided flow is a FULL-WINDOW overlay
    /// at the window root (a `.sheet` is always an inset panel and can't go
    /// edge-to-edge), so this category only TRIGGERS it (`isPresented = true`).
    @Binding var guidedHost: GuidedGatewayHostState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LocalizedStringResource("settings.mac.personalAI.title", defaultValue: "Personal AI"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppColors.textEmphasis)
                        .padding(.horizontal, 28)
                        .padding(.top, 28)

                    // The section stack owns the gap BETWEEN cards; each card
                    // owns the gap to its own header and footer. Nothing here
                    // pads a card horizontally — a card's rows are live to its
                    // edges, and padding applied out here would be dead.
                    VStack(alignment: .leading, spacing: SettingsCardMetrics.sectionSpacing) {
                        // Always the populated layout — the "New chats use"
                        // selector, the permanent Connect section, then the
                        // gateway lists (configured rows get a green check;
                        // unconfigured ones render dimmed without one). Gated on
                        // `hasLoadedRemoteAgentState` so nothing flashes before
                        // state loads.
                        if viewModel.hasLoadedRemoteAgentState {
                            defaultSelector
                            connectSection
                            selfHostedGatewaySection
                            hostedModelSection
                            customGatewaySection
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                // The shared settings content rail — the same column width
                // `RemoteAgentConfigBody`'s editor takes, so the list and the
                // pushed editor read as one surface. Applied to the stack INSIDE
                // the ScrollView (never to the ScrollView itself, which would
                // shrink the scroll surface) and after that stack's own padding.
                .macSettingsRail()
            }
            .navigationDestination(item: $route) { route in
                switch route {
                case .defaultChooser:
                    DefaultGatewayPicker(
                        rows: viewModel.personalAIRows,
                        // `viewModel.setDefaultRemoteAgentRef` routes through
                        // `SettingsManager.applyUserChosenDefault` — the canonical
                        // user-choice writer, which also retires the sticky
                        // last-used pointer and acknowledges any pending adoption
                        // notice. Never call `SettingsManager.setDefaultRemoteAgentRef`
                        // from here.
                        onActivate: { ref in
                            Task {
                                await viewModel.setDefaultRemoteAgentRef(ref)
                                self.route = nil
                            }
                        },
                        defaultUnavailableName: viewModel.defaultSelectorUnavailableName,
                        needsDefaultChoice: viewModel.defaultSelectorNeedsChoice
                    )
                case .configure(let ref):
                    // The editor supplies its own `bufferedEditorChrome` macOS
                    // header (toolbar hidden), so no `.navigationTitle` here.
                    RemoteAgentConfigBody(viewModel: viewModel, ref: ref, guidedHost: $guidedHost)
                }
            }
        }
    }

    // MARK: - Connect (permanent setup affordances)

    /// "Connect" — the prominent guided-setup entry (the lane chooser). Scan/paste
    /// is no longer a list-level row: it lives inside each gateway's "Guided setup"
    /// disclosure, and the chooser's guided flow ends in the same step.
    private var connectSection: some View {
        SettingsCard {
            PersonalAIConnectRows(
                emphasized: viewModel.hasLoadedRemoteAgentState
                    && viewModel.configuredRemoteAgentRefSet.isEmpty,
                onGuidedSetup: {
                    guidedHost.present()   // open at the chooser
                }
            )
        } header: {
            Text(GatewayGroupCopy.connectHeader)
        }
    }

    // MARK: - Default selector (the single "which gateway" surface)

    /// The "Default for new chats → <gateway>" selector at the top, the one
    /// canonical place to choose the gateway new conversations start on (mirrors
    /// the Voice STT/TTS selectors). Tapping opens the chooser.
    @ViewBuilder
    private var defaultSelector: some View {
        // Two spellings of ONE card rather than a footer that renders an empty
        // view: `SettingsCard` pads a non-nil footer slot by `footerGap`, so an
        // empty one leaves 6pt of dead air under the card. Everything but the
        // footer is shared.
        if let footer = defaultSelectorFooter {
            SettingsCard {
                defaultSelectorRow
            } header: {
                defaultSelectorHeader
            } footer: {
                Text(footer)
            }
        } else {
            SettingsCard {
                defaultSelectorRow
            } header: {
                defaultSelectorHeader
            }
        }
    }

    private var defaultSelectorRow: some View {
        Button {
            route = .defaultChooser
        } label: {
            DefaultGatewaySelectorRow(
                // "Not chosen yet" rather than a name when no default is stored:
                // the compatibility shim projects to the built-in fallback there,
                // which may itself be configured, so a name would claim a choice
                // the user never made. Expressed through its OWN flag because
                // `defaultSelectorNeedsSetup` must stay byte-identical.
                defaultName: DefaultGatewayNotice.selectorValue(
                    needsChoice: viewModel.defaultSelectorNeedsChoice,
                    displayName: viewModel.defaultSelectorDisplayName
                )
            )
        }
        // The standard row height, unconditionally: this row's value is ALWAYS one
        // line now. It used to grow to 64pt for the ⚠ + "Needs setup" second line
        // an unavailable default drew; that line is gone, so the allowance would
        // only pad an empty row on the one state a user most needs to read.
        .settingsCardRowButton()
    }

    // Header, not row — see the iOS twin in `PersonalAISettingsView`. On
    // macOS the tip also carries `.help(…)`, so hovering surfaces the same
    // text without a click.
    private var defaultSelectorHeader: some View {
        HStack(spacing: 0) {
            Text(LocalizedStringResource(
                "settings.personalAI.newChats.header",
                defaultValue: "New chats use"
            ))
            InfoTipButton(tip: GatewayFieldTips.defaultForNewChats)
        }
    }

    /// The footer under the selector, or nil when the default is unremarkable.
    /// Broken first — a named gateway is the more specific fact — then the
    /// nothing-chosen state. Twin of `PersonalAISettingsView.defaultSelectorFooter`;
    /// the two must stay in lockstep.
    ///
    /// Two sentences only: the chooser one tap away already carries the
    /// per-conversation invariant ("Existing chats keep the one they started on")
    /// in `DefaultGatewayPicker`'s own footer.
    private var defaultSelectorFooter: String? {
        if let name = viewModel.defaultSelectorUnavailableName {
            return String(localized: LocalizedStringResource(
                "settings.personalAI.default.unavailable.footer.mac",
                defaultValue: "\(name) isn't available on this Mac, so anything that starts a chat from outside the app has nowhere to go. It'll work again on its own if it's waiting on iCloud — or pick a gateway that works here."
            ))
        }
        if viewModel.defaultSelectorNeedsChoice {
            return String(localized: LocalizedStringResource(
                "settings.personalAI.default.noChoice.footer.mac",
                defaultValue: "Nothing that starts a chat from outside this Mac knows which gateway to use. Pick one and new chats will start on it."
            ))
        }
        return nil
    }

    // MARK: - Gateway list

    /// "Full agent gateways" — the user's own self-hosted backends (OpenClaw /
    /// Hermes; tools, file attachments). Mirrors
    /// `PersonalAISettingsView.selfHostedGatewaySection`. Omitted whole when the
    /// registry yields none: the card is chrome its header NAMES, so a header
    /// over an empty card reads as a rendering fault rather than as "nothing
    /// here".
    @ViewBuilder
    private var selfHostedGatewaySection: some View {
        let selfHostedRows = viewModel.personalAIRows.filter {
            guard case .builtin(let b) = $0.ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .selfHostedAgent
        }
        if !selfHostedRows.isEmpty {
            SettingsCard {
                ForEach(selfHostedRows) { row in
                    gatewayRow(row)
                }
            } header: {
                Text(GatewayGroupCopy.fullAgentHeader)
            } footer: {
                Text(GatewayGroupCopy.fullAgentFooter)
            }
        }
    }

    /// "Hosted model" — third-party hosted services (OpenRouter). Hidden when none
    /// are registered. Mirrors `PersonalAISettingsView.hostedModelSection`.
    @ViewBuilder
    private var hostedModelSection: some View {
        let hostedRows = viewModel.personalAIRows.filter {
            guard case .builtin(let b) = $0.ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .hostedModel
        }
        if !hostedRows.isEmpty {
            SettingsCard {
                ForEach(hostedRows) { row in
                    gatewayRow(row)
                }
            } header: {
                Text(GatewayGroupCopy.hostedModelHeader)
            } footer: {
                Text(GatewayGroupCopy.hostedModelFooter)
            }
        }
    }

    /// "Custom gateways" group — the user-added gateways + the Add row. Shows
    /// even with zero customs so the Add row always has context — the Add row is
    /// permanent, so this card is never empty and needs no guard.
    private var customGatewaySection: some View {
        SettingsCard {
            ForEach(viewModel.personalAIRows.filter { !$0.ref.isBuiltin }) { row in
                gatewayRow(row)
            }
            addCustomGatewayCard
        } header: {
            Text(GatewayGroupCopy.customHeader)
        } footer: {
            Text(GatewayGroupCopy.customFooter)
        }
    }

    @ViewBuilder
    private func gatewayRow(_ row: PersonalAIRow) -> some View {
        // Single tap → config detail. Discrete, BINARY status: a quiet green check
        // (+ a tertiary "Default" caption on the default) when configured, nothing
        // at all otherwise, with the name dimmed. No third state, and none may be
        // added — see the iOS twin for the argument. The default is chosen in the
        // top selector; file-transfer readiness lives in the detail (Advanced).
        let configured = row.configured
        Button {
            route = .configure(row.ref)
        } label: {
            HStack(spacing: 12) {
                Text(row.displayName)
                    .font(.body)
                    .foregroundStyle(configured ? AppColors.textPrimary : AppColors.textSecondary)
                Spacer()
                SettingsStatusMark(
                    configured: configured,
                    // The "Default" caption renders on unconfigured rows too —
                    // a default that cannot send is exactly the row a user has to
                    // find. Suppressed only when NOTHING is configured: the
                    // pointer is then the never-chosen built-in fallback, and
                    // labelling it would advertise the same phantom default the
                    // selector's empty-set guard exists to kill.
                    caption: row.isDefault && viewModel.hasAnyConfiguredRemoteAgent
                        ? LocalizedStringResource("settings.remoteAgent.list.pill.default", defaultValue: "Default")
                        : nil
                )
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .settingsCardRowButton()
        .accessibilityIdentifier("settings.personalAI.row.\(row.ref.rawString)")
    }

    /// "+ Set up a custom server" row — at the cap it's VISIBLE but disabled, with a
    /// hint to delete/edit one above. Tap → mint a draft → push editor.
    @ViewBuilder
    private var addCustomGatewayCard: some View {
        let canAdd = viewModel.customGatewayCount < Constants.maxCustomGateways
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let id = viewModel.newCustomGatewayDraftID() {
                    route = .configure(.custom(id))
                }
            } label: {
                Label {
                    Text(canAdd
                        ? LocalizedStringResource("settings.remoteAgent.customGateway.add.v2", defaultValue: "Set up a custom server")
                        : LocalizedStringResource("settings.remoteAgent.customGateway.addAtCap.v2", defaultValue: "Set up a custom server (limit reached)"))
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAdd ? AppColors.brandAmber : AppColors.textTertiary)
                }
                .font(.body)
                .foregroundStyle(canAdd ? AppColors.textPrimary : AppColors.textTertiary)
            }
            .settingsCardRowButton()
            .disabled(!canAdd)
            .accessibilityIdentifier("settings.personalAI.addCustomGateway")
            if !canAdd {
                // Passive caption riding along in the Add row's cell, not a row
                // of its own. Its inset is applied to the TEXT — the button's
                // own inset lives inside the button's live frame, and the card
                // supplies none, so without this the hint would sit flush
                // against the card's left edge under an indented label.
                Text(LocalizedStringResource(
                    "settings.remoteAgent.customGateway.capHint.v2",
                    defaultValue: "Delete a custom server above to add another."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.horizontal, SettingsCardMetrics.rowInset)
                    .padding(.bottom, 10)
            }
        }
    }

}
#endif
