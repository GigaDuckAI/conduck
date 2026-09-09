// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardComponents.swift
//
// Shared visual language for the desk: material glyphs, the empty-desk
// placeholder, the add-material control and the oversized-import confirm. Shape
// carries meaning before colour does, and custom controls reuse the app's macOS
// pointer targets so the visible card is also the live hit region.
//
// There is no container view here on purpose: the WHOLE Work pane is the drop
// target, and a bordered surface would read as the one place a drop lands.

import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum WorkboardMetrics {
    /// The board's column, OUTER: the cap is applied after the horizontal
    /// padding in `WorkboardDetailView`, so the grid itself gets 1440 of it.
    /// That is six uniform cards per row on a wide display — 12 grid units at
    /// 109 points each — where the older 920 gave four and left most of a Mac
    /// window as margin. Wider buys no seventh column at these unit
    /// thresholds, only bigger tiles.
    static let contentMaxWidth: CGFloat = 1472
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
    ///
    /// A minimum alone is the right shape for a form or a page of text, which
    /// wants to be no smaller than legible and no larger than the window it
    /// sits in. It is the WRONG shape for a picture: a minimum-only sheet opens
    /// at that minimum, so a media surface would launch at its floor and every
    /// image would arrive shrunk. Such a sheet therefore also states the size it
    /// WANTS (`ideal`, what macOS opens it at) and the size it will grow to
    /// (`max`, so a resize is not fought by the content). All three optional
    /// parameters default to nil so the text sheets keep the exact frame they
    /// already had.
    @ViewBuilder
    func workboardDesktopSheetFrame(
        minWidth: CGFloat,
        minHeight: CGFloat,
        idealWidth: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
        frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            idealHeight: idealHeight,
            maxHeight: maxHeight
        )
        #else
        self
        #endif
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
        case .image, .note, .audio:
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

/// The single add-material control for Work. `.menu` mounts Chat's shared
/// `AttachmentMenu` unchanged, so the desk composer keeps the exact paperclip
/// interaction a conversation has. `Presentation` stays an enum with one case so
/// a second mounting can be introduced without re-threading the call site, and a
/// new route belongs in `AttachmentMenu` rather than forked here — one paperclip
/// means one route list. Every handler below is a route that menu actually
/// offers: a closure this control cannot fire is a door that does not exist.
struct WorkboardMaterialActions: View {
    enum Presentation: Equatable {
        case menu
    }

    let presentation: Presentation
    let onPickPhotos: () -> Void
    let onTakePhoto: () -> Void
    let onPickFiles: () -> Void
    let onAddLink: () -> Void
    var iconPointSize: CGFloat = 22
    var iconFrame: CGFloat = WorkboardMetrics.touchTarget

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
        }
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
                    defaultValue: "One large file (%@) stays on this device instead of syncing to your other devices, and may take a moment to copy."
                )),
                formattedSize
            )
        }
        return String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.large.confirm.message",
                defaultValue: "%1$lld large files (%2$@) stay on this device instead of syncing to your other devices, and may take a moment to copy."
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
