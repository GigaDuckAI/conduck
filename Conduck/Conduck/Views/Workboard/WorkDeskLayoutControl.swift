// SPDX-License-Identifier: Apache-2.0

// A visible, named layout control makes the spatial desk discoverable even
// when the person has retained an older Tiles preference. Its label describes
// the layout actually drawn: search, aggregate collections and accessibility
// text can require a readable list without overwriting the saved preference.

import SwiftUI

enum WorkDeskLayoutPresentation {
    static func resolved(
        preference: WorkboardLayoutMode,
        supportsSpatialLayout: Bool,
        requiresAccessibleList: Bool
    ) -> WorkboardLayoutMode {
        if requiresAccessibleList { return .list }
        if preference == .desk && !supportsSpatialLayout { return .list }
        return preference
    }
}

struct WorkDeskLayoutControl: View {
    @Bindable var viewModel: WorkboardViewModel
    let supportsSpatialLayout: Bool
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workbenchDestinationIsActive) private var isActive

    private var renderedMode: WorkboardLayoutMode {
        WorkDeskLayoutPresentation.resolved(
            preference: viewModel.layoutMode,
            supportsSpatialLayout: supportsSpatialLayout,
            requiresAccessibleList: dynamicTypeSize.isAccessibilitySize
        )
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { renderedMode },
                set: { viewModel.layoutMode = $0 }
            )) {
                ForEach(WorkboardLayoutMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                        .disabled(mode != .list && (dynamicTypeSize.isAccessibilitySize
                            || (mode == .desk && !supportsSpatialLayout)))
                }
            } label: {
                Text(LocalizedStringResource("workboard.layout.label", defaultValue: "Board view"))
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: renderedMode.symbol)
                if !compact {
                    Text(renderedMode.title)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .pointerIconButton(size: 44)
        .disabled(!isActive)
        .accessibilityLabel(Text(LocalizedStringResource("workboard.layout.label", defaultValue: "Board view")))
        .accessibilityValue(Text(renderedMode.title))
        .accessibilityIdentifier("workdesk-layout-control")
    }
}
