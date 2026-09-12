// SPDX-License-Identifier: Apache-2.0

// Conduck
// SidebarSettingsFooter.swift
//
// The bottom-pinned Settings row shared by Chats and Work. The host owns
// presentation and any keyboard shortcut, so retained destinations cannot
// register competing Settings commands. Mac keeps its edge-to-edge pointer
// target; touch platforms retain the conversation sidebar's existing inset.

import SwiftUI

struct SidebarSettingsFooter: View {
    let onOpenSettings: () -> Void

    #if os(macOS)
    @State private var appIcon = highResAppIcon(size: 32)
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppColors.border)
            Button(action: onOpenSettings) {
                HStack(spacing: 10) {
                    icon
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Text(LocalizedStringResource("menu.settings.short", defaultValue: "Settings"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
                #if !os(macOS)
                .contentShape(Rectangle())
                #endif
            }
            #if os(macOS)
            // The inset is inside the live frame so the footer remains
            // clickable and highlights all the way to its edges.
            .settingsRowButton(minHeight: 56, horizontalPadding: 12, washCornerRadius: 0)
            #else
            .buttonStyle(.plain)
            .padding(12)
            #endif
            .accessibilityIdentifier("toolbar.settings")
        }
        .background(AppColors.cardBackground)
    }

    private var icon: Image {
        #if os(macOS)
        Image(nsImage: appIcon)
        #else
        Image("conduck-app-mark")
        #endif
    }
}
