// SPDX-License-Identifier: Apache-2.0

#if DEBUG

import SwiftUI

/// Red strip rendered above all content when QA mode is active. Unmissable in
/// screenshots, so the QA agent can verify the QA build actually activated
/// before driving scenarios; missing banner ⇒ abort. The default backend name
/// is appended so the agent can confirm which gateway a fresh conversation
/// will bind to.
struct QABanner: View {
    init() {}

    var body: some View {
        HStack(spacing: 6) {
            Text("QA MODE")
                .font(.system(size: 11, weight: .semibold))
            Text("·")
                .font(.system(size: 11, weight: .regular))
            // "default:" prefix so the label reads as the default backend a NEW
            // conversation binds to — not the currently-viewed thread's backend
            // (which can differ). Avoids misreading the banner during QA.
            Text("default: \(QAMode.defaultBackend.displayName)")
                .font(.system(size: 11, weight: .regular))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.red)
    }
}

#endif
