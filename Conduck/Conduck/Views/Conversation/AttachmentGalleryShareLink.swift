// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentGalleryShareLink.swift
//
// Chat's half of the gallery header's Share control.
//
// WHY A `ShareLink` HERE AND A COORDINATOR IN WORK. What a Work card can share
// is not known when the control is drawn — a vault original has to be copied
// out first — so Work prepares on the tap and presents itself
// (`WorkMaterialShareCoordinator`). A chat image is simpler: its bytes are one
// store read behind an id the page already carries, so the system's own control
// is enough, and reaching for Work's coordinator would drag the Work material
// model into the conversation surface for no gain.
//
// NOTHING IS READ UNTIL THE PERSON SHARES. The transferable holds the SAME
// loader closure the gallery page uses; `DataRepresentation`'s exporter is
// async, so opening a gallery of twenty pictures prepares nothing at all, and
// the header's control costs one closure per page.
//
// THE TYPE IS CONCRETE, AND THAT IS NOT A DETAIL. `public.image` is an abstract
// type nothing declares itself readable AS: an item registered under it fails
// `canLoadObject(NSImage.self)`, refuses a destination that asks for a real
// encoding, and lands in Files as an extensionless UUID. Chat's stored image
// bytes are always JPEG — every persisted image goes through
// `ImageProcessor.encodeJPEG`, on every route that writes an attachment row —
// so `.jpeg` is both concrete AND true, and the abstract claim bought nothing.
//
// AND THE COPY CARRIES A NAME. `SharePreview` titles the row in the picker; it
// does not name the file the destination writes. The per-item
// `suggestedFileName` does, which is why the item carries a filename beside its
// title rather than deriving one at the picker.
//
// THE PAGE IS CAPTURED, NEVER RE-READ. The item is built from the id the header
// was handed for the page ON SCREEN, so a share the person starts and a swipe
// that lands while the picker is opening cannot end up describing different
// pictures.

#if !os(watchOS)

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// One gallery page as something the system can hand to another app.
struct AttachmentGalleryShareItem: Transferable, Sendable {
    /// What the share sheet calls this picture. Never empty — the caller
    /// substitutes a generic name for a picture that has none, because a share
    /// preview with a blank title reads as a broken row.
    let name: String
    /// What the RECEIVING app writes the copy as. Always carries a `.jpg`
    /// extension, because that is what the bytes are.
    let filename: String
    /// The page's ORIGINAL bytes, resolved when the person actually shares.
    let load: @Sendable () async throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            try await item.load()
        }
        .suggestedFileName { $0.filename }
    }

    /// The name a shared page's copy lands under.
    ///
    /// The share TITLE is the starting point, so the file and the picker row
    /// agree, but a title is not a filename and two things have to be corrected:
    ///
    ///   1. path separators, which a title may legitimately contain and a
    ///      filename may not. They become dashes rather than being dropped, so
    ///      two pages whose titles differ only there still differ here.
    ///   2. the extension. A dual-route image keeps the name its SOURCE carried
    ///      ("photo.heic") while the bytes persisted here are the normalised
    ///      JPEG, so an extension that names a type is replaced rather than
    ///      trusted. A trailing fragment that names no type at all — "Meeting
    ///      v1.2" — is part of the name and is kept.
    nonisolated static func suggestedFilename(
        for pageID: UUID,
        in pages: [AttachmentGalleryPage]
    ) -> String {
        let title = AttachmentGalleryHeader.shareName(for: pageID, in: pages)
        return suggestedFilename(fromTitle: title)
    }

    /// The naming rule alone, so it is provable without building pages.
    nonisolated static func suggestedFilename(fromTitle title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned == "." || cleaned == ".." ? "" : cleaned
        // The generic stand-in, for a page the caller could not name at all.
        // A share whose file is called "" is not a share.
        let base = safe.isEmpty
            ? String(localized: LocalizedStringResource(
                "attachment.gallery.share.filename",
                defaultValue: "Image"
            ))
            : String(safe.prefix(120))

        let currentExtension = (base as NSString).pathExtension
        guard namesAType(currentExtension) else { return "\(base).jpg" }
        guard UTType(filenameExtension: currentExtension)?.conforms(to: .jpeg) != true else {
            return base
        }
        return "\((base as NSString).deletingPathExtension).jpg"
    }

    /// Whether a trailing fragment is an extension the system can name a type
    /// for, rather than a number that happens to follow a dot.
    private nonisolated static func namesAType(_ fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty else { return false }
        return UTType(filenameExtension: fileExtension).map { !$0.isDynamic } == true
    }
}

/// The Share control Chat puts in the gallery header.
struct AttachmentGalleryShareLink: View {
    let item: AttachmentGalleryShareItem

    var body: some View {
        ShareLink(item: item, preview: SharePreview(item.name)) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .pointerIconButton(size: 40, shape: .circle)
        .accessibilityLabel(Text(LocalizedStringResource(
            "attachment.gallery.share",
            defaultValue: "Share"
        )))
    }
}

#endif
