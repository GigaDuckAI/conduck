// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardComponents.swift
//
// Shared visual language for the desk: the surface container, material glyphs,
// the empty-desk placeholder, the add-material control and the oversized-import
// confirm. Shape carries meaning before colour does, and custom controls reuse
// the app's macOS pointer targets so the visible card is also the live hit
// region.

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
    /// A material card carries its own type, build-scoped so a Community drag
    /// can never be mistaken for an Official-build one, and so the pane-wide
    /// capture drop (file, image, url, text) never claims an in-desk
    /// rearrangement.
    nonisolated static let conduckWorkboardMaterial = UTType(
        exportedAs: "\(Constants.identityNamespace).workboard-material"
    )
}

/// Identity only, plus the desk the card was lifted from: a material may be
/// rearranged only inside the desk that holds it, so a receiving desk rejects a
/// payload carrying a different `itemID` before it plans anything.
nonisolated struct WorkMaterialDragPayload: Codable, Hashable, Sendable, Transferable {
    let itemID: UUID
    let materialID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .conduckWorkboardMaterial)
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
