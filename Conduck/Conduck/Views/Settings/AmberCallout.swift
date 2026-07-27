// SPDX-License-Identifier: Apache-2.0

// Conduck
// AmberCallout.swift
//
// The shared amber-callout treatment (12pt rounded rect, 0.12 fill / 0.25
// border) used across the setup surfaces, so "amber block" means ONE consistent
// thing: something the user must read before acting, not an error and not a tip.
//
// Extracted so the pairing import review card and the gateway editor render the
// identical shape. NOT `.accessibilityElement(children: .combine)`: these sit in
// Form rows next to actionable siblings, and combining would swallow them.

import SwiftUI

struct AmberCallout: View {
    let systemImage: String
    let title: LocalizedStringResource
    /// Named `message` rather than `body` — a stored `body` would collide with
    /// `View.body`. Callers that read better with `body:` keep their own thin
    /// wrapper (see `RemoteAgentConfigBody.amberCallout`).
    let message: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.brandAmber.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.brandAmber.opacity(0.25), lineWidth: 1)
        )
    }
}
