// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDispatchSheet.swift
//
// The deliberate dispatch boundary. It shows the canonical prompt, requires an
// explicit gateway choice, makes every included/omitted material visible, and
// names the destination in the irreversible action. Nothing in this view can
// silently fall back to a different gateway or mutate the frozen sent version.

import SwiftUI

struct WorkboardDispatchSheet: View {
    @Bindable var viewModel: WorkboardViewModel
    let itemID: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let item = viewModel.item(withID: itemID) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                            hero(item)
                            gatewaySection
                            if !item.materials.isEmpty {
                                materialsSection(item)
                            }
                            compatibilitySection(item)
                            promptSection
                            dispatchPromise(item)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 22)
                        .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom) { sendBar(item) }
                } else {
                    WorkboardEmptyState(
                        title: LocalizedStringResource(
                            "workboard.preflight.missing.title",
                            defaultValue: "This brief changed elsewhere"
                        ),
                        message: LocalizedStringResource(
                            "workboard.preflight.missing.message",
                            defaultValue: "Close this preview and open the latest version from the board."
                        )
                    )
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(LocalizedStringResource(
                "workboard.preflight.title",
                defaultValue: "Review & Send"
            ))
            .workboardInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel"), action: cancel)
                        .disabled(viewModel.isDispatching)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isDispatching)
        .onChange(of: viewModel.isDispatching) { _, isDispatching in
            if isDispatching { AccessibilityAnnouncer.announce(sendTitle) }
        }
    }

    private func hero(_ item: WorkboardItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.brandAmber)
                Text(LocalizedStringResource(
                    "workboard.preflight.eyebrow",
                    defaultValue: "Final check"
                ))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(AppColors.brandAmber)
            }
            Text(item.displayTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(AppColors.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(LocalizedStringResource(
                "workboard.preflight.intro",
                defaultValue: "Choose the destination, confirm its materials, then approve the exact brief below."
            ))
            .font(.body)
            .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var gatewaySection: some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    LocalizedStringResource(
                        "workboard.preflight.gateway.title",
                        defaultValue: "1. Choose a gateway"
                    ),
                    caption: LocalizedStringResource(
                        "workboard.preflight.gateway.caption",
                        defaultValue: "No destination is preselected. This run stays bound to the gateway you approve."
                    )
                )

                if viewModel.gateways.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text(LocalizedStringResource(
                                "workboard.preflight.gateway.empty",
                                defaultValue: "Configure a Personal AI gateway before sending. Your draft is already saved."
                            ))
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundStyle(AppColors.warning)
                        }
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)

                        Button {
                            openGatewaySettings()
                        } label: {
                            Label(
                                LocalizedStringResource(
                                    "workboard.preflight.gateway.configure",
                                    defaultValue: "Open Gateway Settings"
                                ),
                                systemImage: "gearshape"
                            )
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .frame(minHeight: WorkboardMetrics.touchTarget)
                            .background(AppColors.backgroundSecondary, in: Capsule())
                        }
                        .settingsRowButton()
                    }
                } else {
                    VStack(spacing: 9) {
                        ForEach(viewModel.gateways) { gateway in
                            gatewayRow(gateway)
                        }
                    }
                }
            }
        }
    }

    private func gatewayRow(_ gateway: WorkboardGatewayChoice) -> some View {
        let isSelected = viewModel.selectedGatewayID == gateway.id
        return Button {
            viewModel.selectGateway(gateway)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                GatewayBadge(ref: gateway.ref, customs: viewModel.customGateways, diameter: 34)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(verbatim: gateway.name)
                            .font(.headline)
                            .foregroundStyle(AppColors.textPrimary)
                        if gateway.isRecommended {
                            Text(LocalizedStringResource(
                                "workboard.preflight.gateway.recommended",
                                defaultValue: "Recommended"
                            ))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppColors.brandAmber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppColors.brandAmber.opacity(0.11), in: Capsule())
                        }
                    }
                    Text(verbatim: gateway.detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.leading)
                    gatewayAvailability(gateway.availability)
                }

                Spacer(minLength: 10)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppColors.brandAmber : AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(
                isSelected ? AppColors.brandAmber.opacity(0.08) : AppColors.backgroundSecondary,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? AppColors.brandAmber.opacity(0.7) : AppColors.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .choiceCardButton(cornerRadius: 13)
        .disabled(!gateway.availability.isUsable || viewModel.isDispatching)
        .accessibilityLabel(gatewayAccessibilityLabel(gateway, selected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func gatewayAvailability(_ availability: WorkboardGatewayAvailability) -> some View {
        switch availability {
        case .ready:
            Label(
                LocalizedStringResource("workboard.preflight.gateway.ready", defaultValue: "Ready"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(AppColors.success)
        case .configured(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(AppColors.brandTeal)
        case .limited(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(AppColors.warning)
        case .unavailable(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(AppColors.error)
        }
    }

    private func materialsSection(_ item: WorkboardItemSnapshot) -> some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    LocalizedStringResource(
                        "workboard.preflight.materials.title",
                        defaultValue: "2. Confirm materials"
                    ),
                    caption: LocalizedStringResource(
                        "workboard.preflight.materials.caption",
                        defaultValue: "Only checked, compatible materials are copied into this run."
                    )
                )

                VStack(spacing: 9) {
                    ForEach(item.materials) { material in
                        materialRow(material)
                    }
                }
            }
        }
    }

    private func materialRow(_ material: WorkboardMaterialSnapshot) -> some View {
        let supported = viewModel.isMaterialSupported(material)
        let included = viewModel.isMaterialIncluded(material)
        return Button {
            viewModel.setMaterial(material, included: !included)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppColors.cardBackgroundElevated)
                    Image(systemName: material.kind.systemImage)
                        .foregroundStyle(supported ? AppColors.brandAmber : AppColors.textTertiary)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: material.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(material.kind.title)
                        if let byteCount = material.byteCount {
                            Text(verbatim: "·")
                            Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    if material.availability == .unavailableOnThisDevice {
                        Text(LocalizedStringResource(
                            "workboard.material.unavailableHere",
                            defaultValue: "Reattach on this device before sending"
                        ))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppColors.warning)
                    } else if !supported {
                        Text(LocalizedStringResource(
                            "workboard.material.unsupported.fileTransfer",
                            defaultValue: "Needs this gateway’s file transfer connection"
                        ))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppColors.warning)
                    }
                }

                Spacer(minLength: 10)

                Image(systemName: included ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(included ? AppColors.brandTeal : AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(included ? AppColors.brandTeal.opacity(0.46) : AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .choiceCardButton(cornerRadius: 12)
        .disabled(!supported || viewModel.selectedGateway == nil || viewModel.isDispatching)
        .accessibilityLabel(materialAccessibilityLabel(material, included: included, supported: supported))
    }

    @ViewBuilder
    private func compatibilitySection(_ item: WorkboardItemSnapshot) -> some View {
        if let gateway = viewModel.selectedGateway {
            let unavailable = item.materials.filter { !$0.availability.isAvailable }
            let unsupported = item.materials.filter {
                $0.availability.isAvailable && !gateway.supports($0)
            }
            let includedImages = item.materials.filter {
                $0.kind == .image && viewModel.isMaterialIncluded($0)
            }
            if !unsupported.isEmpty || !unavailable.isEmpty || !includedImages.isEmpty || gatewayIsLimited(gateway) {
                WorkboardSurface {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(LocalizedStringResource(
                                "workboard.preflight.compatibility.title",
                                defaultValue: "Route check"
                            ))
                            .font(.headline)
                            .foregroundStyle(AppColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            if !unsupported.isEmpty {
                                Text(unsupported.count == 1
                                    ? String(localized: LocalizedStringResource(
                                        "workboard.preflight.compatibility.unsupported.one",
                                        defaultValue: "One incompatible material will stay in Work and will not be sent."
                                    ))
                                    : String.localizedStringWithFormat(
                                        String(localized: LocalizedStringResource(
                                            "workboard.preflight.compatibility.unsupported",
                                            defaultValue: "%lld incompatible materials will stay in Work and will not be sent."
                                        )),
                                        Int64(unsupported.count)
                                    ))
                                .font(.subheadline)
                                .foregroundStyle(AppColors.textSecondary)
                            }
                            if !unavailable.isEmpty {
                                Text(unavailable.count == 1
                                    ? String(localized: LocalizedStringResource(
                                        "workboard.preflight.compatibility.unavailable.one",
                                        defaultValue: "One material is not on this device and will stay in Work."
                                    ))
                                    : String.localizedStringWithFormat(
                                        String(localized: LocalizedStringResource(
                                            "workboard.preflight.compatibility.unavailable",
                                            defaultValue: "%lld materials are not on this device and will stay in Work."
                                        )),
                                        Int64(unavailable.count)
                                    ))
                                .font(.subheadline)
                                .foregroundStyle(AppColors.textSecondary)
                            }
                            if !includedImages.isEmpty {
                                Text(LocalizedStringResource(
                                    "workboard.preflight.compatibility.images",
                                    defaultValue: "Images are sent inline. Whether the AI can understand them depends on the model behind this gateway."
                                ))
                                .font(.subheadline)
                                .foregroundStyle(AppColors.textSecondary)
                            }
                            if case .limited(let message) = gateway.availability {
                                Text(verbatim: message)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var promptSection: some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(
                    LocalizedStringResource(
                        "workboard.preflight.prompt.title",
                        defaultValue: "3. Approve the exact prompt"
                    ),
                    caption: LocalizedStringResource(
                        "workboard.preflight.prompt.caption",
                        defaultValue: "This canonical text is frozen into the run and sent with the checked materials."
                    )
                )

                Text(verbatim: viewModel.preflightPrompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppColors.borderSubtle, lineWidth: 1)
                    }
            }
        }
    }

    private func dispatchPromise(_ item: WorkboardItemSnapshot) -> some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 10) {
                promiseRow(
                    LocalizedStringResource(
                        "workboard.preflight.promise.snapshot",
                        defaultValue: "The sent version stays immutable"
                    ),
                    systemImage: "doc.badge.lock"
                )
                promiseRow(
                    LocalizedStringResource(
                        "workboard.preflight.promise.binding",
                        defaultValue: "The new conversation stays bound to this gateway"
                    ),
                    systemImage: "link"
                )
                promiseRow(
                    LocalizedStringResource(
                        "workboard.preflight.promise.done",
                        defaultValue: "A reply asks for your review; it never marks the objective done"
                    ),
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                if let reviewBy = item.reviewBy {
                    Label {
                        Text(LocalizedStringResource(
                            "workboard.preflight.promise.reviewBy",
                            defaultValue: "Review reminder"
                        ))
                        Text(verbatim: ": ")
                        Text(reviewBy, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                    } icon: {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(AppColors.brandAmber)
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }

    private func promiseRow(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .symbolRenderingMode(.hierarchical)
    }

    private func sendBar(_ item: WorkboardItemSnapshot) -> some View {
        VStack(spacing: 8) {
            if viewModel.selectedGateway == nil {
                Text(LocalizedStringResource(
                    "workboard.preflight.send.chooseFirst",
                    defaultValue: "Choose a gateway to unlock Send"
                ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            }

            Button {
                Task { await viewModel.dispatchPreflight() }
            } label: {
                HStack(spacing: 10) {
                    if viewModel.isDispatching {
                        ProgressView()
                            .tint(AppColors.background)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(verbatim: sendTitle)
                    Spacer()
                    if !viewModel.isDispatching {
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                }
                .font(.headline)
                .foregroundStyle(AppColors.background)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppColors.brandAmber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .primaryCTAButton()
            .disabled(viewModel.selectedGateway == nil || viewModel.isDispatching || !item.isReadyToSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityLabel(Text(verbatim: sendTitle))
            .accessibilityHint(Text(LocalizedStringResource(
                "workboard.preflight.send.hint",
                defaultValue: "Creates a new bound conversation and sends the approved snapshot once."
            )))
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(AppColors.borderSubtle) }
    }

    private var sendTitle: String {
        if viewModel.isDispatching {
            guard let gateway = viewModel.selectedGateway else {
                return String(localized: LocalizedStringResource(
                    "workboard.preflight.sending",
                    defaultValue: "Sending…"
                ))
            }
            return String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.preflight.sendingTo",
                    defaultValue: "Sending to %@…"
                )),
                gateway.name
            )
        }
        guard let gateway = viewModel.selectedGateway else {
            return String(localized: LocalizedStringResource(
                "workboard.preflight.send",
                defaultValue: "Send"
            ))
        }
        return String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.preflight.sendTo",
                defaultValue: "Send to %@"
            )),
            gateway.name
        )
    }

    private func sectionTitle(
        _ title: LocalizedStringResource,
        caption: LocalizedStringResource
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    private func gatewayIsLimited(_ gateway: WorkboardGatewayChoice) -> Bool {
        if case .limited = gateway.availability { return true }
        return false
    }

    private func gatewayAccessibilityLabel(_ gateway: WorkboardGatewayChoice, selected: Bool) -> Text {
        let selection = selected
            ? String(localized: LocalizedStringResource("workboard.preflight.gateway.selected", defaultValue: "Selected"))
            : String(localized: LocalizedStringResource("workboard.preflight.gateway.notSelected", defaultValue: "Not selected"))
        let availability: String
        switch gateway.availability {
        case .ready:
            availability = String(localized: LocalizedStringResource(
                "workboard.preflight.gateway.ready",
                defaultValue: "Ready"
            ))
        case .configured(let message), .limited(let message), .unavailable(let message):
            availability = message
        }
        let format = String(localized: LocalizedStringResource(
            "workboard.preflight.gateway.accessibility",
            defaultValue: "%1$@. %2$@. %3$@. %4$@"
        ))
        return Text(String.localizedStringWithFormat(
            format,
            gateway.name,
            gateway.detail,
            availability,
            selection
        ))
    }

    private func materialAccessibilityLabel(
        _ material: WorkboardMaterialSnapshot,
        included: Bool,
        supported: Bool
    ) -> Text {
        let status: String
        if !supported {
            status = material.availability == .unavailableOnThisDevice
                ? String(localized: LocalizedStringResource(
                    "workboard.material.unavailableHere",
                    defaultValue: "Reattach on this device before sending"
                ))
                : String(localized: LocalizedStringResource(
                    "workboard.material.unsupported.fileTransfer",
                    defaultValue: "Needs this gateway’s file transfer connection"
                ))
        } else {
            status = included
                ? String(localized: LocalizedStringResource("workboard.material.included", defaultValue: "Included"))
                : String(localized: LocalizedStringResource("workboard.material.omitted", defaultValue: "Not included"))
        }
        return Text(String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.preflight.material.accessibility",
                defaultValue: "%1$@, %2$@. %3$@"
            )),
            String(localized: material.kind.title),
            material.name,
            status
        ))
    }

    private func cancel() {
        viewModel.preflightItemID = nil
        viewModel.selectedGatewayID = nil
        viewModel.excludedMaterialIDs = []
        dismiss()
    }

    private func openGatewaySettings() {
        // Remove the deliberate-send boundary before routing to Chats. This
        // avoids presenting settings behind an orphaned preflight sheet.
        cancel()
        Task { @MainActor in
            await Task.yield()
            viewModel.openGatewaySettings()
        }
    }
}
