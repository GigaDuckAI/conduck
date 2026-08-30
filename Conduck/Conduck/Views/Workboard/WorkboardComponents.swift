// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardComponents.swift
//
// Shared visual language for the Agent Workboard: state-first cards, material
// tiles, document surfaces and accessible status chrome. Shape carries every
// state before colour does, and custom controls reuse the app's macOS pointer
// targets so the visible card is also the live hit region.

import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum WorkboardMetrics {
    static let contentMaxWidth: CGFloat = 920
    static let cardCornerRadius: CGFloat = 18
    static let surfaceCornerRadius: CGFloat = 16
    static let compactSpacing: CGFloat = 10
    static let standardSpacing: CGFloat = 16
    static let generousSpacing: CGFloat = 24
    static let touchTarget: CGFloat = 44
    static let boardColumnWidth: CGFloat = 292
}

extension UTType {
    /// Build-scoped type identity prevents a Community drag from being mistaken
    /// for an Official-build project while avoiding a hard-coded Apple identity.
    nonisolated static let conduckWorkboardCard = UTType(
        exportedAs: "\(Constants.identityNamespace).workboard-card"
    )
}

/// The drag carries identity only. The receiving board resolves current state,
/// pin cohort and revision from its own snapshots before planning a reorder.
nonisolated struct WorkboardCardDragPayload: Codable, Hashable, Sendable, Transferable {
    let itemID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .conduckWorkboardCard)
    }
}

extension WorkboardItemState {
    var tint: Color {
        switch self {
        case .draft: return AppColors.textTertiary
        case .waiting: return AppColors.brandTeal
        case .review: return AppColors.brandAmber
        case .done: return AppColors.success
        }
    }

    var attentionTitle: LocalizedStringResource {
        switch self {
        case .draft:
            return LocalizedStringResource("workboard.group.drafts", defaultValue: "Drafts")
        case .waiting:
            return LocalizedStringResource("workboard.group.waiting", defaultValue: "Waiting on AI")
        case .review:
            return LocalizedStringResource("workboard.group.needsYou", defaultValue: "Needs You")
        case .done:
            return LocalizedStringResource("workboard.group.done", defaultValue: "Done")
        }
    }
}

struct WorkboardStateBadge: View {
    let state: WorkboardItemState
    var compact = false

    var body: some View {
        Label {
            Text(state.title)
                .lineLimit(1)
        } icon: {
            Image(systemName: state.systemImage)
        }
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(state.tint)
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 4 : 5)
        .background(state.tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(state.tint.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkboardSectionHeader: View {
    let state: WorkboardItemState
    let count: Int
    var subtitle: LocalizedStringResource?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.systemImage)
                .foregroundStyle(state.tint)
                .accessibilityHidden(true)
            Text(state.attentionTitle)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text(count, format: .number)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(AppColors.backgroundSecondary, in: Capsule())
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct WorkboardCard: View {
    let item: WorkboardItemSnapshot
    let compact: Bool
    let onOpen: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    var onMoveEarlier: (() -> Void)? = nil
    var onMoveLater: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: compact ? 9 : 12) {
                HStack(alignment: .top, spacing: 10) {
                    WorkboardStateBadge(state: item.state, compact: true)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.brandAmber)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "workboard.item.pinned",
                                defaultValue: "Pinned"
                            )))
                    }
                    Spacer(minLength: 8)
                    Text(item.modifiedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }

                Text(item.displayTitle)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.leading)
                    .lineLimit(compact ? 2 : 3)

                if !item.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.objective)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(compact ? 2 : 3)
                }

                if item.hasChangesSinceLastSend {
                    Label(
                        LocalizedStringResource(
                            "workboard.item.changedAfterSend",
                            defaultValue: "Changed after this was sent"
                        ),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.warning)
                }

                footer
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 112 : 148, alignment: .topLeading)
            .padding(compact ? 14 : 16)
            .background {
                RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous)
                    .fill(AppColors.cardBackgroundElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous)
                    .stroke(item.state.tint.opacity(item.state == .review ? 0.52 : 0.22), lineWidth: 1)
            }
            .shadow(color: AppColors.shadow.opacity(item.state == .review ? 0.36 : 0.18), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: WorkboardMetrics.cardCornerRadius, style: .continuous))
        }
        .choiceCardButton(cornerRadius: WorkboardMetrics.cardCornerRadius)
        .draggable(WorkboardCardDragPayload(itemID: item.id))
        .contextMenu {
            Button(action: onDuplicate) {
                Label(
                    LocalizedStringResource("workboard.action.duplicate", defaultValue: "Duplicate Work"),
                    systemImage: "plus.square.on.square"
                )
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(
                    LocalizedStringResource("workboard.action.delete", defaultValue: "Delete Work"),
                    systemImage: "trash"
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.item.open.hint",
            defaultValue: "Opens the brief and its run history."
        )))
        .accessibilityAction(named: Text(LocalizedStringResource(
            "workboard.action.duplicate",
            defaultValue: "Duplicate Work"
        ))) {
            onDuplicate()
        }
        .accessibilityAction(named: Text(LocalizedStringResource(
            "workboard.action.delete",
            defaultValue: "Delete Work"
        ))) {
            onDelete()
        }
        .accessibilityActions {
            if let onMoveEarlier {
                Button(
                    LocalizedStringResource(
                        "workboard.action.moveEarlier",
                        defaultValue: "Move Earlier"
                    ),
                    action: onMoveEarlier
                )
            }
            if let onMoveLater {
                Button(
                    LocalizedStringResource(
                        "workboard.action.moveLater",
                        defaultValue: "Move Later"
                    ),
                    action: onMoveLater
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: item.state)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if !item.materials.isEmpty {
                Label {
                    Text(item.materials.count, format: .number)
                } icon: {
                    Image(systemName: "paperclip")
                }
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            }

            if let latestRun = item.latestRun {
                Label {
                    Text(latestRun.state.title)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: latestRun.state.systemImage)
                }
                .font(.caption)
                .foregroundStyle(runTint(latestRun.state))
            }

            Spacer(minLength: 4)

            if let reviewBy = item.reviewBy, item.state != .done {
                Label {
                    Text(reviewBy, format: .dateTime.month(.abbreviated).day())
                } icon: {
                    Image(systemName: "bell")
                }
                .font(.caption)
                .foregroundStyle(reviewBy < Date() ? AppColors.error : AppColors.textTertiary)
            }
        }
    }

    private var accessibilitySummary: Text {
        var parts = [String(localized: item.state.title), item.displayTitle]
        if item.isPinned {
            parts.append(String(localized: LocalizedStringResource(
                "workboard.item.pinned",
                defaultValue: "Pinned"
            )))
        }
        let objective = item.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !objective.isEmpty {
            parts.append(objective)
        }
        if !item.materials.isEmpty {
            parts.append(item.materials.count == 1
                ? String(localized: LocalizedStringResource(
                    "workboard.item.accessibility.materials.one",
                    defaultValue: "One material"
                ))
                : String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workboard.item.accessibility.materials",
                        defaultValue: "%lld materials"
                    )),
                    Int64(item.materials.count)
                ))
        }
        if let latestRun = item.latestRun {
            parts.append(String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.item.accessibility.latestRun",
                    defaultValue: "Latest run: %@"
                )),
                String(localized: latestRun.state.title)
            ))
        }
        if item.hasChangesSinceLastSend {
            parts.append(String(localized: LocalizedStringResource(
                "workboard.item.changedAfterSend",
                defaultValue: "Changed after this was sent"
            )))
        }
        if let reviewBy = item.reviewBy, item.state != .done {
            parts.append(String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.item.accessibility.reviewBy",
                    defaultValue: "Review by %@"
                )),
                reviewBy.formatted(date: .abbreviated, time: .shortened)
            ))
        }
        return Text(parts.joined(separator: ". "))
    }

    private func runTint(_ state: WorkboardRunState) -> Color {
        switch state {
        case .sending, .waiting: return AppColors.brandTeal
        case .replied: return AppColors.success
        case .failed: return AppColors.error
        case .cancelled: return AppColors.textTertiary
        }
    }
}

extension View {
    /// SwiftUI exposes the inline navigation-bar style only on iOS. Keeping
    /// the platform check here lets shared Workboard views compile natively on
    /// macOS without changing their navigation hierarchy.
    @ViewBuilder
    func workboardInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Fixed modal dimensions improve desktop composition, but minimum widths
    /// can overflow compact iPhones and narrow multitasking windows. Let iOS
    /// own the sheet size and apply the composed minimum only on macOS.
    @ViewBuilder
    func workboardDesktopSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

struct WorkboardSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(WorkboardMetrics.standardSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground, in: RoundedRectangle(
                cornerRadius: WorkboardMetrics.surfaceCornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(cornerRadius: WorkboardMetrics.surfaceCornerRadius, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
    }
}

struct WorkboardMaterialTile: View {
    let material: WorkboardMaterialSnapshot
    var isIncluded: Bool? = nil
    var isSupported = true
    var onOpen: (() -> Void)?

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { tile }
                    .choiceCardButton(cornerRadius: 13)
            } else {
                tile
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
                .frame(height: 76)
                .frame(maxWidth: .infinity)
                .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(material.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 5) {
                Text(material.kind.title)
                if let byteCount = material.byteCount {
                    Text(verbatim: "·")
                    Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                }
            }
            .font(.caption2)
            .foregroundStyle(AppColors.textTertiary)

            if !isSupported {
                Label(
                    LocalizedStringResource("workboard.material.unsupported.generic", defaultValue: "Not available for this gateway"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppColors.warning)
                .lineLimit(2)
            } else if let isIncluded {
                Label(
                    isIncluded
                        ? LocalizedStringResource("workboard.material.included", defaultValue: "Included")
                        : LocalizedStringResource("workboard.material.omitted", defaultValue: "Not included"),
                    systemImage: isIncluded ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(isIncluded ? AppColors.brandTeal : AppColors.textTertiary)
            }
        }
        .padding(10)
        .frame(width: 166, alignment: .topLeading)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isIncluded == true ? AppColors.brandTeal.opacity(0.6) : AppColors.borderSubtle, lineWidth: 1)
        }
        .opacity(isSupported ? 1 : 0.72)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if material.kind == .image, let data = material.thumbnailData {
            StagedImageTile(
                id: material.id,
                data: data,
                maxPixel: ImageProcessor.thumbnailMaxPixel,
                cacheVersion: material.revision
            ) {
                thumbnailPlaceholder
            }
            .accessibilityHidden(true)
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        Image(systemName: material.kind.systemImage)
            .font(.title2)
            .foregroundStyle(material.kind == .link ? AppColors.guidedSetupBlue : AppColors.brandAmber)
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: Text {
        let status: String
        if !isSupported {
            status = String(localized: LocalizedStringResource(
                "workboard.material.unsupported.generic",
                defaultValue: "Not available for this gateway"
            ))
        } else if isIncluded == true {
            status = String(localized: LocalizedStringResource(
                "workboard.material.included",
                defaultValue: "Included"
            ))
        } else if isIncluded == false {
            status = String(localized: LocalizedStringResource(
                "workboard.material.omitted",
                defaultValue: "Not included"
            ))
        } else {
            status = ""
        }
        let format = String(localized: LocalizedStringResource(
            "workboard.material.accessibility.summary",
            defaultValue: "%1$@, %2$@. %3$@"
        ))
        return Text(String.localizedStringWithFormat(
            format,
            String(localized: material.kind.title),
            material.name,
            status
        ))
    }
}

struct WorkboardEmptyState: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    var actionTitle: LocalizedStringResource?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppColors.brandAmber.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(AppColors.brandAmber)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.textEmphasis)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.headline)
                    .foregroundStyle(AppColors.background)
                    .padding(.horizontal, 18)
                    .frame(minHeight: WorkboardMetrics.touchTarget)
                    .background(AppColors.brandAmber, in: Capsule())
                    .primaryCTAButton()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

struct WorkboardAutosaveStatus: View {
    let isSaving: Bool
    let hasUnsavedChanges: Bool
    let savedAt: Date?

    var body: some View {
        Group {
            if isSaving {
                Label {
                    Text(LocalizedStringResource("workboard.save.saving", defaultValue: "Saving…"))
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if hasUnsavedChanges {
                Label(
                    LocalizedStringResource("workboard.save.pending", defaultValue: "Changes waiting to save"),
                    systemImage: "ellipsis.circle"
                )
            } else if let savedAt {
                Label {
                    Text(
                        LocalizedStringResource("workboard.save.saved", defaultValue: "Saved")
                    )
                    Text(verbatim: " · ")
                    Text(savedAt, format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                }
            } else {
                Label(
                    LocalizedStringResource("workboard.save.privateDraft", defaultValue: "Private draft"),
                    systemImage: "lock.fill"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(AppColors.textTertiary)
        .accessibilityElement(children: .combine)
    }
}
