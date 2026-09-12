// SPDX-License-Identifier: Apache-2.0

// A project is a visible container rather than another material card. Folder
// tabs, a content strip and a title survive at different desk scales; readable
// layouts reuse the same face without imposing a fixed canvas footprint.
// Previews decode only thumbnail bytes already held by the board. They never
// fetch payloads, start playback, or turn a missing file into an openable one.

import SwiftUI

struct WorkDeskProjectFolder: View {
    enum Style { case tile, row }
    let project: WorkDeskCanvasProject
    var style: Style = .tile
    var isTargeted = false

    var body: some View {
        Group {
            switch style {
            case .tile: tile
            case .row: row
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: project.record.title))
        .accessibilityValue(Text(WorkDeskCopy.materialCount(project.materialCount)))
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if project.previewMaterials.isEmpty {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(AppColors.brandAmber)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                } else {
                    ForEach(Array(project.previewMaterials.prefix(3))) { material in
                        WorkDeskProjectMaterialGlimpse(material: material)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .accessibilityHidden(true)
            Text(verbatim: project.record.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(WorkDeskCopy.materialCount(project.materialCount))
            }
            .font(.caption).foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            WorkDeskFolderOutline()
                .fill(AppColors.cardBackgroundElevated)
                .overlay { WorkDeskFolderOutline().fill(AppColors.brandAmber.opacity(isTargeted ? 0.21 : 0.09)) }
        }
        .overlay { WorkDeskFolderOutline().stroke(AppColors.brandAmber.opacity(isTargeted ? 0.95 : 0.50), lineWidth: isTargeted ? 2 : 1) }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(AppColors.brandAmber.opacity(0.7))
                .frame(width: 34, height: 3).padding(.leading, 22).padding(.top, 8)
                .accessibilityHidden(true)
        }
        .contentShape(WorkDeskFolderOutline())
    }

    private var row: some View {
        HStack(spacing: 14) {
            ZStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 43, weight: .regular))
                    .foregroundStyle(AppColors.brandAmber)
                if let first = project.previewMaterials.first {
                    WorkDeskProjectMaterialGlimpse(material: first)
                        .frame(width: 26, height: 23)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(x: 4, y: 6)
                }
            }
            .frame(width: 58, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: project.record.title).font(.headline).lineLimit(2)
                Text(WorkDeskCopy.materialCount(project.materialCount))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(AppColors.brandAmber.opacity(isTargeted ? 0.15 : 0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(AppColors.brandAmber.opacity(isTargeted ? 0.9 : 0.3)) }
    }
}

struct WorkDeskProjectHoverPreview: View {
    let project: WorkDeskCanvasProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(verbatim: project.record.title).lineLimit(2) }
                icon: { Image(systemName: "folder.fill").foregroundStyle(AppColors.brandAmber) }
                .font(.headline)
            if project.previewMaterials.isEmpty {
                Text(LocalizedStringResource("workdesk.project.previewEmpty", defaultValue: "Drop materials into this project"))
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary)
            } else {
                ForEach(Array(project.previewMaterials.prefix(3))) { material in
                    HStack(spacing: 10) {
                        WorkDeskProjectMaterialGlimpse(material: material)
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: material.name).font(.subheadline).lineLimit(2)
                            Text(material.kind.title).font(.caption2).foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                let remainder = max(0, project.materialCount - project.previewMaterials.prefix(3).count)
                if remainder > 0 {
                    Text(LocalizedStringResource("workdesk.project.previewMore", defaultValue: "\(remainder) more materials"))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.brandAmber.opacity(0.45)) }
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkDeskProjectMaterialGlimpse: View {
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
