// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPicker.swift
//
// One gateway chooser for a new chat and a Work conversation. Hosts own the
// selection, roster and presence-probe lifecycle; this view never changes a
// default or probes a gateway merely because a hidden shell remains mounted.
// A sole selected gateway and a reviewed handoff render as identity, without
// a chevron. An unavailable selection still permits choosing a sole survivor.
// macOS keeps its presence mark beside the capsule, while iOS includes it in
// the menu label and speaks its state through the menu's accessibility value.

import SwiftUI

struct GatewayPicker: View {
    struct Option: Identifiable, Equatable, Sendable {
        let ref: RemoteAgentRef
        let name: String
        var id: String { ref.rawString }

        var isHosted: Bool {
            guard case .builtin(let backend) = ref else { return false }
            return RemoteAgentBackendRegistry.lookup(id: backend).category == .hostedModel
        }
    }

    let options: [Option]
    let selectedRef: RemoteAgentRef?
    var selectedName: String? = nil
    var allowsSelection = true
    /// MainWindowView already owns the dot beside its picker/clone/title states.
    var showsPresence = true
    var optionAccessibilityPrefix: String? = nil
    let onPick: (RemoteAgentRef) -> Void

    private var selectedOption: Option? { options.first { $0.ref == selectedRef } }
    private var presenceRef: RemoteAgentRef? { selectedOption?.ref }
    private var canChoose: Bool {
        allowsSelection && !options.isEmpty && (options.count > 1 || selectedOption == nil)
    }

    private var name: String {
        selectedName ?? selectedOption?.name ?? String(localized: LocalizedStringResource(
            "workdesk.conversation.gateway.choose", defaultValue: "Choose a gateway"
        ))
    }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            if showsPresence {
                GatewayPresenceDot(ref: presenceRef, diameter: 6)
            }
            control
        }
        #else
        control
        #endif
    }

    @ViewBuilder
    private var control: some View {
        if canChoose {
            Menu {
                ForEach(options.filter { !$0.isHosted }) { option in
                    optionButton(option)
                }
                if options.contains(where: \.isHosted) {
                    Section(String(localized: LocalizedStringResource(
                        "settings.remoteAgent.hostedModels.header", defaultValue: "Hosted models"
                    ))) {
                        ForEach(options.filter(\.isHosted)) { option in
                            optionButton(option)
                        }
                    }
                }
            } label: {
                identity(interactive: true)
            }
            #if os(macOS)
            // AppKit's default menu style discards custom label chrome. The
            // button style keeps the same capsule and hover as Chat's clone.
            .menuStyle(.button)
            .pointerIconButton(shape: .capsule)
            .help(String(localized: LocalizedStringResource("chat.chooseAI.label", defaultValue: "Choose AI")))
            #endif
            .accessibilityLabel(
                Text(LocalizedStringResource("chat.chooseAI.label", defaultValue: "Choose AI"))
                    + Text(verbatim: ": " + name)
            )
            #if !os(macOS)
            .gatewayPresenceAccessibilityValue(for: showsPresence ? presenceRef : nil)
            #endif
        } else {
            identity(interactive: false)
        }
    }

    private func optionButton(_ option: Option) -> some View {
        Button { onPick(option.ref) } label: {
            if option.ref == selectedRef {
                Label(option.name, systemImage: "checkmark")
            } else {
                Text(verbatim: option.name)
            }
        }
        .accessibilityIdentifier((optionAccessibilityPrefix ?? "gateway-option-") + option.id)
    }

    private func identity(interactive: Bool) -> some View {
        HStack(spacing: 6) {
            #if !os(macOS)
            if showsPresence {
                GatewayPresenceDot(ref: presenceRef, standaloneAccessibility: !interactive)
            }
            #endif
            HStack(spacing: 4) {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    #if os(macOS)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    #else
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    #endif
                if interactive {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        #if os(macOS)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(AppColors.cardBackgroundElevated, in: Capsule())
        .contentShape(Capsule())
        #endif
    }
}
