// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPlanControls.swift
//
// Contextual Pro presentation and the explicit free-gateway choice after expiry.
// Present above the current gateway owner so its drafts and credentials remain
// in that owner's memory. Purchase can reopen an empty editor, never save a
// configuration, run a connection probe, or dispatch a conversation.

import SwiftUI

@MainActor @Observable
final class GatewayPlanFlow {
    var showingUpgrade = false
    var showingSelection = false
    var manageAfterUpgrade = false
    var resumeAdd = false
}

struct GatewayPlanControls: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var flow: GatewayPlanFlow
    var onlyWhenSelectionRequired = true

    var body: some View {
        // Only unresolved selection needs a top-level reminder. An inactive
        // gateway's editor also offers this link to revise a completed choice.
        if viewModel.showsGatewaySelection
            && (!onlyWhenSelectionRequired || viewModel.gatewayActivation.requiresSelection) {
            Button(LocalizedStringResource("gateway.plan.choose.action", defaultValue: "Choose active gateways")) {
                flow.showingSelection = true
            }
            .font(.callout)
            .foregroundStyle(AppColors.textSecondary)
            .inlineLinkButton()
            .settingsCardPassiveRow()
        }
    }
}

private struct GatewayPlanSheets: ViewModifier {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var flow: GatewayPlanFlow
    let onReadyToAdd: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showingUpgrade, onDismiss: upgradeDismissed) {
                ProPaywallView(context: .gatewayLimit, onManage: viewModel.showsGatewaySelection || onReadyToAdd != nil ? {
                    flow.manageAfterUpgrade = viewModel.showsGatewaySelection
                    flow.resumeAdd = false
                    flow.showingUpgrade = false
                } : nil)
            }
            .sheet(isPresented: $flow.showingSelection, onDismiss: finishPendingAdd) {
                GatewayActivationPicker(viewModel: viewModel)
            }
    }

    private func upgradeDismissed() {
        Task {
            await viewModel.refreshGatewayPlan()
            if flow.manageAfterUpgrade {
                flow.manageAfterUpgrade = false
                flow.showingSelection = true
            } else { finishPendingAdd() }
        }
    }

    private func finishPendingAdd() {
        guard flow.resumeAdd else { return }
        flow.resumeAdd = false
        if viewModel.canAddConfiguredGateway { onReadyToAdd?() }
    }
}

extension View {
    func gatewayPlanSheets(viewModel: SettingsViewModel, flow: GatewayPlanFlow,
                           onReadyToAdd: (() -> Void)? = nil) -> some View {
        modifier(GatewayPlanSheets(viewModel: viewModel, flow: flow, onReadyToAdd: onReadyToAdd))
    }
}

struct GatewayActivationPicker: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selected: Set<RemoteAgentRef> = []
    @State private var saving = false
    @State private var loaded = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(LocalizedStringResource("gateway.plan.choose.message", defaultValue: "Choose up to three active gateways for your free plan. Your other configurations and conversations stay saved."))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(LocalizedStringResource("gateway.plan.choose.openrouter", defaultValue: "OpenRouter is always available and does not count toward this selection."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                Section {
                    ForEach(viewModel.personalAIRows.filter { viewModel.gatewayAllowanceRefs.contains($0.ref) }) { row in
                        Toggle(isOn: Binding(
                            get: { selected.contains(row.ref) },
                            set: { enabled in
                                if enabled { selected.insert(row.ref) }
                                else { selected.remove(row.ref) }
                            }
                        )) { Text(verbatim: row.displayName) }
                        .disabled(!selected.contains(row.ref) && selected.count >= Constants.maxConfiguredGateways)
                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(LocalizedStringResource("gateway.plan.choose.action", defaultValue: "Choose active gateways")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.save", defaultValue: "Save")) {
                        saving = true
                        Task {
                            let saved = await viewModel.chooseActiveGateways(selected)
                            saving = false
                            if saved { dismiss() }
                            else {
                                error = String(localized: "gateway.plan.choose.changed", defaultValue: "Your gateways changed. Choose up to three saved gateways and try again.")
                                selected.formIntersection(viewModel.gatewayAllowanceRefs)
                            }
                        }
                    }.disabled(saving || !loaded)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 440, minHeight: 360)
        .task {
            await viewModel.refreshGatewayPlan()
            selected = viewModel.gatewayActivation.activeRefs
            loaded = true
        }
    }
}
