// SPDX-License-Identifier: Apache-2.0

// A quiet, shared marker for user-authored notes on a material. It reads only
// metadata, so unavailable files can still show that there are notes to open.

import SwiftUI

struct WorkboardMaterialNotesIndicator: View {
    let material: WorkboardMaterialSnapshot

    static var title: LocalizedStringResource {
        LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes")
    }

    static func isVisible(for material: WorkboardMaterialSnapshot) -> Bool {
        !(material.annotation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if Self.isVisible(for: material) {
            Label(Self.title, systemImage: "text.bubble")
                .font(.caption2)
                .lineLimit(1)
        }
    }
}
