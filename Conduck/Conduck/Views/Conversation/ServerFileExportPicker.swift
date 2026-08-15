// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
// Conduck
// ServerFileExportPicker.swift
//
// The iOS/iPadOS durable-save route, and the twin of the macOS `NSSavePanel`
// path in `ConversationThreadView`: a system browser that copies ONE local file
// to a destination the user picks, run once, after the bytes are already on the
// device.
//
// WHY IT EXISTS AT ALL. iOS has no other save affordance in this app — the only
// way a file leaves Conduck today is the share button INSIDE the Quick Look
// preview, and the escape hatch this picker serves is defined by not previewing.
// Handing a type Conduck deliberately declined to open to Quick Look in the last
// three lines of the flow would undo the whole feature silently.
//
// WHY A REPRESENTABLE AND NOT `.fileExporter`. The SwiftUI modifier exports a
// `Transferable`, and `URL`'s own conformance is a `DataRepresentation` — so
// `.fileExporter(item: someFileURL)` compiles, reports success, and writes the
// forty-byte URL STRING into the destination instead of the file's bytes
// (measured: `URL(fileURLWithPath: "/etc/hosts").exported(as: .fileURL)` is 17
// bytes of `file:///etc/hosts`). For a feature whose entire purpose is "we did
// not open this, but you may still keep it", destroying the artifact is the
// worst reachable outcome. Wrapping the file in a `FileRepresentation` would fix
// the bytes and still lose the NAME: `transferRepresentation` is a STATIC
// property, so its exported content type cannot vary per file, and everything
// reaching this picker is by definition a type the allowlist does not carry —
// exactly where a fixed `.data` type lets the exporter negotiate
// `profile.mobileconfig` down to `profile.dat`. The picker negotiates nothing:
// it exports the file at the URL it is handed, leaf name and all.
//
// WHY NOT `ShareLink`: it is a Button with no `isPresented` binding, so it
// cannot be fired after an async download — the flow here is tap, download,
// present, and a `ShareLink` would force a second tap on a control that appears
// only once the bytes land. WHY NOT `UIActivityViewController`: it demands a
// popover anchor on iPad and traps without one, and its destinations are share
// targets rather than a place on disk. The verb here is SAVE.
//
// `asCopy: true` IS LOAD-BEARING, not defensive. `init(forExporting:)` and
// `asCopy: false` both MOVE the file out of the app container, which would
// delete the scratch bytes out from under the caller's own reclaim and under the
// age sweep that backs it up.
//
// PRIVACY: the file URL is handed straight to UIKit and the destination URLs the
// delegate returns are never read, stored or logged — the picker renders the
// name itself, so nothing about this file reaches os_log.

import SwiftUI
import UIKit

struct ServerFileExportPicker: UIViewControllerRepresentable {
    /// The local file to export. Its LAST PATH COMPONENT is the name the user
    /// sees and keeps, which is why callers hand over an `AgentDownloadScratch`
    /// item rather than the raw download temp (a bare UUID with no extension).
    let url: URL
    /// Called AT MOST once, and only when the user reaches one of the two
    /// UIKit delegate arms. A cancel is NOT a failure — the caller settles the
    /// same way in both cases, and only the visible state differs.
    ///
    /// AT MOST, NEVER EXACTLY, and the caller has to be built for the zero
    /// case. A swipe-down (or a tap outside on iPad) dismisses a `.sheet(item:)`
    /// by nilling the binding, which tears this representable down without ever
    /// entering `UIDocumentPickerDelegate` — so neither arm below fires. What
    /// this closure reports is therefore the OUTCOME (saved or cancelled); it
    /// is not a lifecycle signal, and a caller that hangs its scratch reclaim
    /// or its row state on it alone strands both. The presentation binding
    /// going non-nil → nil is the only signal every exit shares, and that is
    /// what the caller settles on.
    let onFinish: (_ saved: Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        // The unusual extension is the whole reason the user is here, so let
        // them see it in the destination browser rather than a bare stem.
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: (_ saved: Bool) -> Void

        init(onFinish: @escaping (_ saved: Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            // The system already performed the copy. These URLs are the
            // DESTINATIONS, and nothing here reads them — so no security-scoped
            // access is started and nothing about where the user put their file
            // is kept. Apple's own rule for this API is "don't save the URLs the
            // open and move operations provide"; not touching them satisfies it
            // by construction.
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
#endif
