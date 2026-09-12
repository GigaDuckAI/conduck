// SPDX-License-Identifier: Apache-2.0

// A project is a visible container rather than another material card. Folder
// tabs, a content strip and a title survive at different desk scales; readable
// layouts reuse the same face without imposing a fixed canvas footprint.
// Open and Preview are sibling controls: the folder face opens the full project,
// while its material count opens the interactive contents without navigating.
// Previews decode only thumbnail bytes already held by the board. They never
// fetch payloads, start playback, or turn a missing file into an openable one.

import SwiftUI

struct WorkDeskProjectFolder: View {
    enum Style { case tile, row }
    let project: WorkDeskCanvasProject
    var style: Style = .tile
    var isTargeted = false
    var isPreviewing = false
    let onOpen: () -> Void
    let onPreview: () -> Void

    private var tint: Color { project.record.color.tint }
    private var borderColor: Color { isTargeted ? AppColors.brandAmber : tint }

    var body: some View {
        Group {
            switch style {
            case .tile: tile
            case .row: row
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        // Each action remains a separately discoverable control. Combining or
        // ignoring children would hide Preview contents behind Open project.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: project.record.title))
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: project.record.title)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    thumbnailStrip
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                #if os(iOS)
                .contentShape(Rectangle())
                #endif
            }
            .choiceCardButton(cornerRadius: 12)
            .accessibilityLabel(Text(verbatim: project.record.title))
            .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.openProject", defaultValue: "Open project")))
            .accessibilityIdentifier("workdesk-project-open-\(project.id.uuidString)")
            previewButton
        }
        .background {
            WorkDeskFolderOutline()
                .fill(AppColors.cardBackgroundElevated)
                .overlay { WorkDeskFolderOutline().fill(tint.opacity(isTargeted ? 0.34 : 0.23)) }
        }
        .overlay {
            WorkDeskFolderOutline()
                .stroke(borderColor.opacity(isTargeted ? 0.95 : 0.75), lineWidth: isTargeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.8))
                .frame(width: 34, height: 3).padding(.leading, 22).padding(.top, 8)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(WorkDeskFolderOutline())
    }

    private var thumbnailStrip: some View {
        HStack(spacing: 8) {
            if project.previewMaterials.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(project.previewMaterials.prefix(3))) { material in
                    WorkDeskProjectMaterialGlimpse(material: material)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(height: 52)
        .accessibilityHidden(true)
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    ZStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 43, weight: .regular))
                            .foregroundStyle(tint)
                        if let first = project.previewMaterials.first {
                            WorkDeskProjectMaterialGlimpse(material: first)
                                .frame(width: 26, height: 23)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .offset(x: 4, y: 6)
                        }
                    }
                    .frame(width: 58, height: 52).accessibilityHidden(true)
                    Text(verbatim: project.record.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                .contentShape(Rectangle())
                #endif
            }
            .choiceCardButton(cornerRadius: 14)
            .accessibilityLabel(Text(verbatim: project.record.title))
            .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.openProject", defaultValue: "Open project")))
            .accessibilityIdentifier("workdesk-project-open-\(project.id.uuidString)")
            previewButton
        }
        .background(tint.opacity(isTargeted ? 0.24 : 0.13), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(borderColor.opacity(isTargeted ? 0.9 : 0.3), lineWidth: isTargeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var previewButton: some View {
        Button(action: onPreview) {
            HStack(spacing: 7) {
                Text(WorkDeskCopy.materialCount(project.materialCount))
                Image(systemName: isPreviewing ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppColors.textSecondary)
            .padding(.leading, style == .row ? 86 : 18).padding(.trailing, 18)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.bottom, 6)
            .background(isPreviewing ? tint.opacity(0.10) : .clear)
            #if os(iOS)
            .contentShape(Rectangle())
            #endif
        }
        .pointerIconButton(size: 44)
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.preview.action", defaultValue: "Preview contents"))
            + Text(verbatim: ": " + project.record.title))
        .accessibilityValue(Text(WorkDeskCopy.materialCount(project.materialCount)) + Text(verbatim: ", ")
            + Text(isPreviewing ? LocalizedStringResource("workdesk.expanded", defaultValue: "Expanded")
                : LocalizedStringResource("workdesk.collapsed", defaultValue: "Collapsed")))
        .accessibilityIdentifier("workdesk-project-preview-\(project.id.uuidString)")
    }
}

struct WorkDeskProjectMaterialGlimpse: View {
    let material: WorkboardMaterialSnapshot

    var body: some View {
        Group {
            if let data = material.thumbnailData {
                StagedImageTile(id: material.id, data: data, maxPixel: ImageProcessor.thumbnailMaxPixel,
                                cacheVersion: material.revision) { placeholder }
            } else { placeholder }
        }
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        ZStack {
            AppColors.backgroundSecondary
            Image(systemName: material.kind.systemImage)
                .font(.title3).foregroundStyle(AppColors.brandAmber.opacity(0.8))
        }
    }
}

private struct WorkDeskFolderOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = min(14, rect.height / 8)
        let tabHeight: CGFloat = min(18, rect.height / 10)
        let tabEnd = rect.minX + rect.width * 0.43
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: tabEnd - 10, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: tabEnd + 8, y: rect.minY + tabHeight),
                          control: CGPoint(x: tabEnd, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
