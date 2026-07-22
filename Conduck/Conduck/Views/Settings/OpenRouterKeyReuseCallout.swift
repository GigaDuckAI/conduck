// Conduck
// OpenRouterKeyReuseCallout.swift
//
// Inline callout offering to reuse an existing OpenRouter API key from the
// "other" surface — the hosted-model GATEWAY ⇄ the VOICE provider. OpenRouter is
// the one backend that can be configured on both surfaces; a user who already
// pasted their key on one side can copy it to the other in one tap.
//
// Shown ONLY when the other surface already has a saved key AND this surface
// doesn't yet (a setup accelerant — using two separate keys stays fully
// supported, so this is an offer, never a requirement; it disappears once this
// surface has its own key). The button drives a view-model action that copies +
// validates + persists ENTIRELY in the view-model — the raw key never enters a
// View. COPY semantics: the two slots stay independent afterward.
//
// Cross-platform (iOS + macOS Settings); not a Watch surface.

#if !os(watchOS)
import SwiftUI

struct OpenRouterKeyReuseCallout: View {
    let title: LocalizedStringResource
    let buttonTitle: LocalizedStringResource
    let action: () async -> Void

    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(AppColors.brandAmber)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                working = true
                Task {
                    await action()
                    working = false
                }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text(buttonTitle).font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(working)
            // One fixed caveat for BOTH directions: copy-once + shared credit.
            Text(LocalizedStringResource(
                "settings.openRouter.reuse.caveat",
                defaultValue: "Copies the key once — later changes won't sync, and both use the same OpenRouter credits."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
