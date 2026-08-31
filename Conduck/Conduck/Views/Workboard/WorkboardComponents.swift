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
#if os(iOS)
import UIKit
#endif

enum WorkboardMetrics {
    static let contentMaxWidth: CGFloat = 920
    static let cardCornerRadius: CGFloat = 18
    static let surfaceCornerRadius: CGFloat = 16
    static let standardSpacing: CGFloat = 16
    static let generousSpacing: CGFloat = 24
    static let touchTarget: CGFloat = 44
}

extension UTType {
    /// Build-scoped type identity prevents a Community drag from being mistaken
    /// for an Official-build project while avoiding a hard-coded Apple identity.
    nonisolated static let conduckWorkboardCard = UTType(
        exportedAs: "\(Constants.identityNamespace).workboard-card"
    )

    /// A material card carries its own type so a project drag and a card drag
    /// can never be mistaken for one another, and so the pane-wide capture drop
    /// (file, image, url, text) never claims an in-board rearrangement.
    nonisolated static let conduckWorkboardMaterial = UTType(
        exportedAs: "\(Constants.identityNamespace).workboard-material"
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

/// Identity only, plus the project the card was lifted from: a material may be
/// rearranged only inside its own board, so a receiving board rejects a payload
/// carrying a different `itemID` before it plans anything.
nonisolated struct WorkMaterialDragPayload: Codable, Hashable, Sendable, Transferable {
    let itemID: UUID
    let materialID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .conduckWorkboardMaterial)
    }
}

/// Presentation for the persisted lifecycle lanes. The board has no state enum
/// of its own: these are the only things the UI adds to `WorkItemState`.
extension WorkItemState {
    var title: LocalizedStringResource {
        switch self {
        case .draft:
            return LocalizedStringResource("workboard.state.draft", defaultValue: "Draft")
        case .waiting:
            return LocalizedStringResource("workboard.state.waiting", defaultValue: "Waiting")
        case .review:
            return LocalizedStringResource("workboard.state.review", defaultValue: "Review")
        case .done:
            return LocalizedStringResource("workboard.state.done", defaultValue: "Done")
        }
    }

    var systemImage: String {
        switch self {
        case .draft: return "square.and.pencil"
        case .waiting: return "hourglass"
        case .review: return "sparkle.magnifyingglass"
        case .done: return "checkmark.circle.fill"
        }
    }

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

    /// Human-attention order, independent from persistence ordering.
    nonisolated var attentionRank: Int {
        switch self {
        case .review: return 0
        case .waiting: return 1
        case .draft: return 2
        case .done: return 3
        }
    }

    /// The one lane order. Every list that walks the lanes derives it from
    /// `attentionRank`, so a new lifecycle state cannot be ranked in one place
    /// and forgotten in another.
    nonisolated static var attentionOrder: [WorkItemState] {
        allCases.sorted { $0.attentionRank < $1.attentionRank }
    }
}

struct WorkboardStateBadge: View {
    let state: WorkItemState
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
    let state: WorkItemState
    let count: Int

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
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum WorkboardProjectActionTitle {
    static let rename = LocalizedStringResource("workboard.action.rename", defaultValue: "Rename")
    static let pin = LocalizedStringResource("workboard.pin", defaultValue: "Pin")
    static let unpin = LocalizedStringResource("workboard.unpin", defaultValue: "Unpin")
    static let duplicate = LocalizedStringResource(
        "workboard.action.duplicate",
        defaultValue: "Duplicate Work"
    )
    static let delete = LocalizedStringResource("workboard.action.delete", defaultValue: "Delete Work")

    static func pinToggle(isPinned: Bool) -> LocalizedStringResource {
        isPinned ? unpin : pin
    }
}

/// The one project action list. The sidebar row's context menu, the All Work
/// card's and the Mac main menu all build from it, so a project offers the same
/// four actions wherever the person reaches for it. Nothing is gated on
/// lifecycle state: this is the only route to a project's name and pin, so a
/// finished project must stay renameable.
@ViewBuilder
func workboardProjectActions(
    isPinned: Bool,
    renameShortcut: KeyboardShortcut? = nil,
    onRename: @escaping () -> Void,
    onTogglePin: @escaping () -> Void,
    onDuplicate: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(action: onRename) {
        Label(WorkboardProjectActionTitle.rename, systemImage: "pencil")
    }
    .keyboardShortcut(renameShortcut)
    Button(action: onTogglePin) {
        Label(
            WorkboardProjectActionTitle.pinToggle(isPinned: isPinned),
            systemImage: isPinned ? "pin.slash" : "pin"
        )
    }
    Divider()
    Button(action: onDuplicate) {
        Label(WorkboardProjectActionTitle.duplicate, systemImage: "plus.square.on.square")
    }
    Divider()
    Button(role: .destructive, action: onDelete) {
        Label(WorkboardProjectActionTitle.delete, systemImage: "trash")
    }
}

struct WorkboardCard: View {
    let item: WorkboardItemSnapshot
    let onOpen: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    var onMoveEarlier: (() -> Void)? = nil
    var onMoveLater: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
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
                    .font(.headline)
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if !item.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.objective)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
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
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
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
            workboardProjectActions(
                isPinned: item.isPinned,
                onRename: onRename,
                onTogglePin: onTogglePin,
                onDuplicate: onDuplicate,
                onDelete: onDelete
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.item.open.hint",
            defaultValue: "Opens the brief and its run history."
        )))
        // The card is one custom element, so every context-menu entry needs its
        // own named action or VoiceOver cannot reach it at all.
        .accessibilityAction(named: Text(WorkboardProjectActionTitle.rename)) {
            onRename()
        }
        .accessibilityAction(
            named: Text(WorkboardProjectActionTitle.pinToggle(isPinned: item.isPinned))
        ) {
            onTogglePin()
        }
        .accessibilityAction(named: Text(WorkboardProjectActionTitle.duplicate)) {
            onDuplicate()
        }
        .accessibilityAction(named: Text(WorkboardProjectActionTitle.delete)) {
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
                    Image(systemName: "calendar")
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

/// Glyph and tint for one Work material. Files route through Chat's
/// `AttachmentChipStyle` so a CSV, a JSON payload and a source file are as
/// distinguishable in Work as they are in a conversation, and a new file type
/// is still described in exactly one place. Images, links and notes keep the
/// kind glyph: `AttachmentChipStyle` maps text and code types only, so an image
/// routed through it would come back as a document.
enum WorkboardMaterialIcon {
    static func symbol(for material: WorkboardMaterialSnapshot) -> String {
        guard material.kind == .file else { return material.kind.systemImage }
        if let mimeType = material.mimeType {
            return AttachmentChipStyle.symbol(forMimeType: mimeType, filename: material.name)
        }
        let ext = (material.name as NSString).pathExtension
        return ext.isEmpty
            ? material.kind.systemImage
            : AttachmentChipStyle.symbol(forExtension: ext)
    }

    static func tint(for material: WorkboardMaterialSnapshot) -> Color {
        switch material.kind {
        case .file:
            if let mimeType = material.mimeType {
                return AttachmentChipStyle.tint(forMimeType: mimeType, filename: material.name)
            }
            let ext = (material.name as NSString).pathExtension
            return ext.isEmpty ? AppColors.brandAmber : AttachmentChipStyle.tint(forExtension: ext)
        case .link:
            return AppColors.guidedSetupBlue
        case .image, .note:
            return AppColors.brandAmber
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
        Image(systemName: WorkboardMaterialIcon.symbol(for: material))
            .font(.title2)
            .foregroundStyle(WorkboardMaterialIcon.tint(for: material))
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

// MARK: - Adding material

/// Every way material enters Work, described once for both Work surfaces.
enum WorkboardMaterialRoute: String, CaseIterable, Identifiable {
    case photos
    case camera
    case files
    case link
    case note

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .photos:
            return LocalizedStringResource("workboard.material.addPhotos", defaultValue: "Photos")
        case .camera:
            return LocalizedStringResource("composer.attach.takePhoto", defaultValue: "Take Photo")
        case .files:
            return LocalizedStringResource("workboard.material.addFiles", defaultValue: "Files")
        case .link:
            return LocalizedStringResource("workboard.material.addLink.short", defaultValue: "Link")
        case .note:
            return LocalizedStringResource("workboard.material.addNote.short", defaultValue: "Note")
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "photo.on.rectangle.angled"
        case .camera: return "camera"
        case .files: return "doc.badge.plus"
        case .link: return "link.badge.plus"
        case .note: return "note.text.badge.plus"
        }
    }
}

/// The single add-material control for Work. `.menu` mounts Chat's shared
/// `AttachmentMenu` unchanged, so the pinned composer keeps the exact paperclip
/// interaction a conversation has; `.row` is the editor's always-visible list of
/// the same routes. Both presentations take the same handlers, so a new route is
/// added and wired once. `.note` reaches only the row: it has no place in
/// Chat's menu, and Work must not fork that shared control to add one.
struct WorkboardMaterialActions: View {
    enum Presentation: Equatable {
        case menu
        case row
    }

    let presentation: Presentation
    let onPickPhotos: () -> Void
    let onTakePhoto: () -> Void
    let onPickFiles: () -> Void
    let onAddLink: () -> Void
    let onAddNote: () -> Void
    var iconPointSize: CGFloat = 22
    var iconFrame: CGFloat = WorkboardMetrics.touchTarget

    /// True only on an iOS device with a camera, so the route is removed rather
    /// than shown as a dead pill — matching `AttachmentMenu`'s own rule.
    private var cameraAvailable: Bool {
        #if os(iOS)
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        return false
        #endif
    }

    private var rowRoutes: [WorkboardMaterialRoute] {
        WorkboardMaterialRoute.allCases.filter { $0 != .camera || cameraAvailable }
    }

    var body: some View {
        switch presentation {
        case .menu:
            AttachmentMenu(
                onPickLibrary: onPickPhotos,
                onTakePhoto: onTakePhoto,
                onPickFiles: onPickFiles,
                purpose: .work,
                onAddLink: onAddLink,
                iconPointSize: iconPointSize,
                iconFrame: iconFrame
            )
        case .row:
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(rowRoutes) { route in
                        Button(action: action(for: route)) {
                            label(for: route)
                        }
                        .choiceCardButton(cornerRadius: WorkboardMetrics.touchTarget / 2)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func action(for route: WorkboardMaterialRoute) -> () -> Void {
        switch route {
        case .photos: return onPickPhotos
        case .camera: return onTakePhoto
        case .files: return onPickFiles
        case .link: return onAddLink
        case .note: return onAddNote
        }
    }

    private func label(for route: WorkboardMaterialRoute) -> some View {
        Label(route.title, systemImage: route.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 13)
            .frame(minHeight: WorkboardMetrics.touchTarget)
            .background(AppColors.backgroundSecondary, in: Capsule())
            .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
            .contentShape(Capsule())
    }
}

// MARK: - Oversized material soft-confirm

/// A pending oversized-material confirmation from any Work import route. The
/// copy is derived here so the alert's keys have exactly one default value no
/// matter which route raised it.
protocol WorkboardLargeImportConfirming: Identifiable {
    /// Byte counts of the oversized items only.
    var largeItemByteCounts: [Int64] { get }
}

extension WorkboardLargeImportConfirming {
    var largeImportMessage: String {
        let counts = largeItemByteCounts
        let totalBytes = counts.reduce(Int64(0)) { $0 + max(0, $1) }
        let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if counts.count == 1 {
            return String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.material.large.confirm.message.one",
                    defaultValue: "One large file (%@) is stored only on this device and may take a moment to copy now or send later."
                )),
                formattedSize
            )
        }
        return String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.large.confirm.message",
                defaultValue: "%1$lld large files (%2$@) are stored only on this device and may take a moment to copy now or send later."
            )),
            Int64(counts.count),
            formattedSize
        )
    }
}

extension View {
    /// The one soft-confirm every Work import route shows before copying
    /// oversized material. Each route keeps its own confirm and cancel work —
    /// only the wording and the buttons are shared.
    func workboardLargeImportAlert<Item: WorkboardLargeImportConfirming>(
        item: Binding<Item?>,
        onConfirm: @escaping (Item) -> Void,
        onCancel: @escaping (Item) -> Void
    ) -> some View {
        alert(item: item) { confirmation in
            Alert(
                title: Text(LocalizedStringResource(
                    "workboard.material.large.confirm.title",
                    defaultValue: "Add large files?"
                )),
                message: Text(verbatim: confirmation.largeImportMessage),
                primaryButton: .default(Text(LocalizedStringResource(
                    "workboard.material.large.confirm.add",
                    defaultValue: "Add to Work"
                ))) {
                    onConfirm(confirmation)
                },
                secondaryButton: .cancel {
                    onCancel(confirmation)
                }
            )
        }
    }
}

#if os(macOS)
/// What the main menu acts on: the project whose desk is on screen. The desk
/// carries no project chrome and every row action lives in the Work sidebar,
/// which the window's own toggle can collapse — so without this route a Mac
/// window with a hidden sidebar offers no way at all to rename, pin, duplicate
/// or delete the open project, and no keyboard route to any of them.
struct WorkboardProjectCommandTarget: Equatable {
    let viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot

    static func == (
        lhs: WorkboardProjectCommandTarget,
        rhs: WorkboardProjectCommandTarget
    ) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.item.id == rhs.item.id
            && lhs.item.isPinned == rhs.item.isPinned
    }
}

struct WorkboardProjectCommandTargetKey: FocusedValueKey {
    typealias Value = WorkboardProjectCommandTarget
}

extension FocusedValues {
    var workboardProjectCommandTarget: WorkboardProjectCommandTarget? {
        get { self[WorkboardProjectCommandTargetKey.self] }
        set { self[WorkboardProjectCommandTargetKey.self] = newValue }
    }
}

struct WorkboardProjectCommands: Commands {
    @FocusedValue(\.workboardProjectCommandTarget) private var target

    var body: some Commands {
        CommandMenu(String(localized: LocalizedStringResource(
            "workboard.title",
            defaultValue: "Work"
        ))) {
            workboardProjectActions(
                isPinned: target?.item.isPinned ?? false,
                renameShortcut: KeyboardShortcut("e", modifiers: .command),
                onRename: { perform { $0.requestRename($1) } },
                onTogglePin: {
                    perform { viewModel, item in
                        Task { await viewModel.setPinned(!item.isPinned, for: item.id) }
                    }
                },
                onDuplicate: { perform { $0.requestDuplicate($1) } },
                onDelete: { perform { $0.requestDelete($1) } }
            )
            .disabled(target == nil)
        }
    }

    private func perform(
        _ action: (WorkboardViewModel, WorkboardItemSnapshot) -> Void
    ) {
        guard let target else { return }
        action(target.viewModel, target.item)
    }
}
#endif
