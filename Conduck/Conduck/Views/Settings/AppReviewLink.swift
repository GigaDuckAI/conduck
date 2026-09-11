// SPDX-License-Identifier: Apache-2.0

// The About review link shared by iPhone, iPad and Mac. Opens the configured
// App Store review page only when selected. Community builds have no listing.
// Choosing this manual route also retires the optional automatic request.

import SwiftUI

struct AppReviewLink: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = Constants.appStoreReviewURL {
            reviewButton(url: url)
        }
    }

    private func reviewButton(url: URL) -> some View {
        Button {
            AppReviewUsage.shared.suppressRequests()
            openURL(url)
        } label: {
            HStack {
                Label {
                    Text(LocalizedStringResource("settings.about.review.title", defaultValue: "Write a Review"))
                } icon: {
                    Image(systemName: "star")
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        #if os(macOS)
        .settingsCardRowButton()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityHint(Text(LocalizedStringResource(
            "settings.about.review.openHint", defaultValue: "Opens the App Store.")))
    }
}
