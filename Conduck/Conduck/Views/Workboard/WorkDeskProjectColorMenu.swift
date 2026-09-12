// SPDX-License-Identifier: Apache-2.0

// One optional, named palette across folder, sidebar and project-title menus.
// The view saves only color against the presented project's revision, through
// the normal organization queue and error surface. It never rewrites a title,
// brief or layout from a stale menu snapshot. Persistent identifiers remain in
// the Foundation-only model; SwiftUI owns their visual presentation here.

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorkDeskProjectColorMenu: View {
    let project: WorkDeskProjectRecord
    let organization: WorkDeskOrganization

    var body: some View {
        Menu {
            Picker(selection: selection) {
                ForEach(WorkDeskProjectColor.allCases, id: \.self) { color in
                    Label {
                        Text(color.title)
                    } icon: {
                        #if os(macOS)
                        Image(nsImage: color.menuSwatch).renderingMode(.original)
                        #else
                        Image(systemName: "circle.fill")
                            .foregroundStyle(color.tint)
                        #endif
                    }
                    .tag(color)
                }
            } label: {
                Text(LocalizedStringResource("workdesk.project.color", defaultValue: "Project color"))
            }
            .pickerStyle(.inline)
        } label: {
            Label(LocalizedStringResource("workdesk.project.color", defaultValue: "Project color"),
                  systemImage: "paintpalette")
        }
        .accessibilityIdentifier("workdesk-project-color-\(project.id.uuidString)")
        .disabled(organization.isSaving)
    }

    private var selection: Binding<WorkDeskProjectColor> {
        Binding(
            get: { project.color },
            set: { color in
                guard color != project.color else { return }
                let expectedUpdatedAt = project.updatedAt
                Task {
                    await organization.setProjectColor(id: project.id, color: color,
                                                       expectedUpdatedAt: expectedUpdatedAt)
                }
            }
        )
    }
}

extension WorkDeskProjectColor {
    #if os(macOS)
    /// Native menus template SF Symbols, discarding their SwiftUI foreground
    /// style. An original image keeps the swatch colored even when highlighted.
    @MainActor var menuSwatch: NSImage {
        let swatchColor = NSColor(tint)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            swatchColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
    #endif

    @MainActor var tint: Color {
        switch self {
        case .amber: AppColors.brandAmber
        case .sage: Color(red: 0.49, green: 0.64, blue: 0.54)
        case .blue: Color(red: 0.45, green: 0.62, blue: 0.80)
        case .lavender: Color(red: 0.64, green: 0.55, blue: 0.78)
        case .coral: Color(red: 0.80, green: 0.54, blue: 0.47)
        case .slate: Color(red: 0.57, green: 0.62, blue: 0.66)
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .amber: LocalizedStringResource("workdesk.project.color.amber", defaultValue: "Amber")
        case .sage: LocalizedStringResource("workdesk.project.color.sage", defaultValue: "Sage")
        case .blue: LocalizedStringResource("workdesk.project.color.blue", defaultValue: "Blue")
        case .lavender: LocalizedStringResource("workdesk.project.color.lavender", defaultValue: "Lavender")
        case .coral: LocalizedStringResource("workdesk.project.color.coral", defaultValue: "Coral")
        case .slate: LocalizedStringResource("workdesk.project.color.slate", defaultValue: "Slate")
        }
    }
}
