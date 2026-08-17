// SPDX-License-Identifier: Apache-2.0

// Conduck
// PersonalAISettingsView.swift
//
// iOS Settings — the Personal AI screen (single-activation-surface model):
//
//   Default for new chats — a top selector row → `DefaultGatewayPicker` is the
//              ONE place to pick which gateway new conversations start on
//              (routing is per-conversation; the default is only the pre-pick).
//   Gateways — one DISCRETE row per `personalAIRows` entry (built-ins then
//              customs): name + a green check (`SettingsStatusMark`) when
//              configured, a dimmed name + "Needs setup" or nothing when not.
//              The "Default" caption rides ANY of those states, so a default that
//              cannot send is still identifiable as the default — it is
//              suppressed only while nothing at all is configured, where the
//              pointer is the never-chosen built-in fallback. WHOLE-ROW TAP =
//              configure — NO secret
//              set-default row-body tap, NO trailing "Configure" link, NO colored
//              status pill, NO per-row file-transfer line (all removed).
//
// (The global Startup / Session landing-UX pickers now live on the ROOT
//  Settings page — `SettingsView` — directly below the "AI & Voice" section.)
//
// Per-gateway config (URL / token / cert / Test / Forget) lives in
// `RemoteAgentConfigBody` (PURE CONFIG, no in-detail Set-as-Default), pushed via
// `RemoteAgentDetailView`. macOS is `MacPersonalAICategory` (same model). One
// `navigationDestination` keyed on `PersonalAIRoute` serves both the chooser and
// the config detail.

#if os(iOS)
import SwiftUI

/// A typed navigation route for the Personal AI screen: the "Default for new
/// chats" chooser, or a per-gateway config detail. One `navigationDestination`
/// keyed on this so the selector and the gateway rows share one stack (mirrors
/// the Voice screen's `VoiceRoute`).
private enum PersonalAIRoute: Hashable {
    case defaultChooser
    case configure(RemoteAgentRef)
}

struct PersonalAISettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Drives all pushes (the default chooser + a gateway config detail).
    @State private var route: PersonalAIRoute?

    /// The guided-setup presentation is HOISTED to the settings container
    /// (`SettingsView` on iPhone, `IpadSettingsView` on iPad), which attaches the
    /// `.fullScreenCover` to its NavigationStack ROOT. A cover attached to THIS
    /// view never presents on iOS 26: this view is a pushed `navigationDestination`
    /// inside the Settings sheet, and iOS silently drops a full-screen cover
    /// presented from a pushed destination (the working `showSetupGuide` cover in
    /// `SettingsView` is attached to the stack root — that's the contrast that
    /// proves it). We OWN only the trigger (`isPresented`). This mirrors the macOS
    /// `MacPersonalAICategory` ⇄ `GuidedGatewayHostState` wiring.
    @Binding var guidedHost: GuidedGatewayHostState

    var body: some View {
        Form {
            // Always the populated layout — the "New chats use" selector, the
            // permanent Connect section, then the gateway lists (configured rows
            // get a green check; unconfigured ones render dimmed without one).
            // Gated on `hasLoadedRemoteAgentState` so nothing flashes before
            // state loads.
            if viewModel.hasLoadedRemoteAgentState {
                defaultSelectorSection
                connectSection
                selfHostedGatewaySection
                hostedModelSection
                customGatewaySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(LocalizedStringResource(
            "settings.remoteAgent.section.title",
            defaultValue: "Personal AI"
        )))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { route in
            switch route {
            case .defaultChooser:
                DefaultGatewayPicker(
                    rows: viewModel.personalAIRows,
                    // `viewModel.setDefaultRemoteAgentRef` routes through
                    // `SettingsManager.applyUserChosenDefault` — the canonical
                    // user-choice writer, which also retires the sticky last-used
                    // pointer and acknowledges any pending adoption notice. Never
                    // call `SettingsManager.setDefaultRemoteAgentRef` from here.
                    onActivate: { ref in
                        Task {
                            await viewModel.setDefaultRemoteAgentRef(ref)
                            self.route = nil
                        }
                    },
                    onSetUp: { ref in self.route = .configure(ref) },
                    brokenDefaultName: viewModel.defaultSelectorBrokenName,
                    needsDefaultChoice: viewModel.defaultSelectorNeedsChoice
                )
            case .configure(let ref):
                RemoteAgentDetailView(viewModel: viewModel, ref: ref, guidedHost: $guidedHost)
            }
        }
    }

    // MARK: - Connect (permanent setup affordances)

    /// "Connect" — the prominent guided-setup entry (the lane chooser). Scan/paste
    /// is no longer a list-level row: it lives inside each gateway's "Guided setup"
    /// disclosure, and the chooser's guided flow ends in the same step.
    private var connectSection: some View {
        Section {
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

    /// The top "Default for new chats → <gateway>" selector — the one canonical
    /// place to choose the gateway new conversations start on (mirrors the Voice
    /// STT/TTS selectors). Tapping opens the chooser; the gateway rows below are
    /// configure-only.
    @ViewBuilder
    private var defaultSelectorSection: some View {
        // Two spellings of ONE section rather than a footer that renders an empty
        // view: an empty footer slot still occupies a position and would leave a
        // gap under the card. Everything but the footer is shared.
        if let footer = defaultSelectorFooter {
            Section {
                defaultSelectorRow
            } header: {
                defaultSelectorHeader
            } footer: {
                Text(footer)
            }
        } else {
            Section {
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
                ),
                needsSetup: viewModel.defaultSelectorFlagsBroken
            )
        }
        .buttonStyle(.plain)
    }

    // The tip sits in the HEADER, not the row: the row is a full-width
    // Button whose `contentShape` claims every point in it, and
    // `InfoTipButton`'s placement contract forbids nesting a tip inside a
    // row action (its taps would go to the row). Its trailing slot is
    // taken by the amber value + chevron, so the header is the one spot
    // that keeps the tip a separate, actionable sibling.
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
    /// nothing-chosen state.
    ///
    /// Two sentences only: the chooser one tap away already carries the
    /// per-conversation invariant ("Existing chats keep the one they started on")
    /// in `DefaultGatewayPicker`'s own footer, and repeating it here would make
    /// the screen argue with itself about which sentence matters.
    private var defaultSelectorFooter: String? {
        if let name = viewModel.defaultSelectorBrokenName {
            if DeviceCapabilities.isiPad {
                return String(localized: LocalizedStringResource(
                    "settings.personalAI.default.broken.footer.ipad",
                    defaultValue: "\(name) isn't set up on this iPad, so anything that starts a chat from outside the app has nowhere to go. Pick a gateway that works here, or finish setting up \(name)."
                ))
            }
            return String(localized: LocalizedStringResource(
                "settings.personalAI.default.broken.footer.iphone",
                defaultValue: "\(name) isn't set up on this iPhone, so anything that starts a chat from outside the app has nowhere to go. Pick a gateway that works here, or finish setting up \(name)."
            ))
        }
        if viewModel.defaultSelectorNeedsChoice {
            if DeviceCapabilities.isiPad {
                return String(localized: LocalizedStringResource(
                    "settings.personalAI.default.noChoice.footer.ipad",
                    defaultValue: "Nothing that starts a chat from outside this iPad knows which gateway to use. Pick one and new chats will start on it."
                ))
            }
            return String(localized: LocalizedStringResource(
                "settings.personalAI.default.noChoice.footer.iphone",
                defaultValue: "Nothing that starts a chat from outside this iPhone knows which gateway to use. Pick one and new chats will start on it."
            ))
        }
        return nil
    }

    // MARK: - Gateway List

    /// "Full agent gateways" — the user's own self-hosted OpenClaw / Hermes
    /// backends (tools, file attachments — the recommended path).
    private var selfHostedGatewaySection: some View {
        Section {
            ForEach(viewModel.personalAIRows.filter {
                guard case .builtin(let b) = $0.ref else { return false }
                return RemoteAgentBackendRegistry.lookup(id: b).category == .selfHostedAgent
            }) { row in
                gatewayRow(row)
            }
        } header: {
            Text(GatewayGroupCopy.fullAgentHeader)
        } footer: {
            Text(GatewayGroupCopy.fullAgentFooter)
        }
    }

    /// "Hosted models" — third-party hosted services (OpenRouter). Hidden when
    /// none are registered (e.g. if the feature flag is off).
    @ViewBuilder
    private var hostedModelSection: some View {
        let hostedRows = viewModel.personalAIRows.filter {
            guard case .builtin(let b) = $0.ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: b).category == .hostedModel
        }
        if !hostedRows.isEmpty {
            Section {
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

    /// Custom gateways under their own divider — mirrors the Voice list's
    /// "Custom endpoints" section. The header shows even with zero customs so the
    /// "Set up a custom server" row always has context. (The setup-code row moved to
    /// the permanent "Connect" section.)
    private var customGatewaySection: some View {
        Section {
            ForEach(viewModel.personalAIRows.filter { !$0.ref.isBuiltin }) { row in
                gatewayRow(row)
            }
            addCustomGatewayRow
        } header: {
            Text(GatewayGroupCopy.customHeader)
        } footer: {
            Text(GatewayGroupCopy.customFooter)
        }
    }

    @ViewBuilder
    private func gatewayRow(_ row: PersonalAIRow) -> some View {
        // Single tap → config detail. Status is DISCRETE: a configured gateway
        // gets a quiet green check (+ a tertiary "Default" caption when it's the
        // default pick); a half-configured one gets a quiet "Needs setup"; an
        // un-set gateway gets nothing. Both non-configured states dim the name.
        // The default is CHOSEN in the top selector, not by a secret row-body tap;
        // file-transfer readiness moved into the detail (Advanced).
        let configured = row.configured
        Button {
            route = .configure(row.ref)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body)
                        .foregroundStyle(configured ? AppColors.textPrimary : AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The capability line, so the row states what the lane can
                    // do instead of leaving the section header to imply it.
                    Text(GatewayGroupCopy.capabilitySubtitle(for: row.ref))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                SettingsStatusMark(
                    configured: configured,
                    // A default the selector FLAGS counts as incomplete here even
                    // when it holds no stored evidence of its own — the state a
                    // CLEAN peer Forget leaves behind (it clears the synced URL /
                    // scheme / model slots, so nothing is left to classify the row
                    // as anything but untouched). Without this the selector says
                    // "Needs setup" and the very row it sends the user to says
                    // nothing.
                    //
                    // Read off `defaultSelectorFlagsBroken` rather than spelling
                    // the membership question a second time here. A CONSISTENCY
                    // refactor, not a behaviour fix: the flag is strictly narrower
                    // than the question, and the one state it withholds —
                    // `.readingUnreliable` — is one where the pointer is
                    // unconfigured AND carries stored evidence (the verdict's
                    // hazard arm requires exactly that), so it is already in
                    // `incompleteRemoteAgentRefSet` and `row.incomplete` draws
                    // "Needs setup" on its own. Same mark everywhere; one fewer
                    // place for the two to drift apart.
                    //
                    // That the ROW still speaks while the selector is silent is
                    // the intended split: this mark says "this gateway's setup
                    // cannot be read here", which is true, where suppressing it
                    // would be a false clean bill of health. Argued in
                    // `selectorMaySpeak(for:)`'s doc in `SettingsViewModel.swift`
                    // ("It does NOT gate a gateway's own readiness mark").
                    // (`row.isDefault` is already false whenever the pointer is
                    // one the app parked, so this term speaks only about a gateway
                    // the user actually chose.)
                    incomplete: row.incomplete
                        || (row.isDefault && viewModel.defaultSelectorFlagsBroken),
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityIdentifier("settings.personalAI.row.\(row.ref.rawString)")
    }

    /// "+ Set up a custom server" — at the cap it's VISIBLE but disabled (never
    /// silently vanish, never error-after-filling). Tap → mint a draft → push
    /// the editor bound to `.custom(id)`.
    @ViewBuilder
    private var addCustomGatewayRow: some View {
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
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityIdentifier("settings.personalAI.addCustomGateway")
            if !canAdd {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.customGateway.capHint.v2",
                    defaultValue: "Delete a custom server above to add another."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

}
#endif
