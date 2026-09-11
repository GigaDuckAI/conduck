// SPDX-License-Identifier: Apache-2.0
//
// Embeds the system's renderer beside Work notes. URLs are disposable exports
// retained by PersonalWorkbenchRouter.filePreview, never vault paths. Native
// views release their item during dismantling; the existing coordinator owns
// byte reclamation and macOS open-with lifetime policy.

#if !os(watchOS)
import SwiftUI
import QuickLook

/// Existing file-preview reclamation can be requested before SwiftUI finishes
/// dismantling an embedded renderer. Keep its export alive until the renderer
/// has explicitly released the item; the original reclaim closure still owns
/// the only deletion authority.
@MainActor
final class WorkMaterialPreviewLease {
    let url: URL
    private var readers: Set<UUID> = []
    private var reclaimRequested = false
    private var didReclaim = false
    private let reclaim: @MainActor () -> Void

    init(url: URL, reclaim: @escaping @MainActor () -> Void) {
        self.url = url
        self.reclaim = reclaim
    }

    func acquire() -> UUID {
        let id = UUID()
        readers.insert(id)
        return id
    }
    func release(_ readerID: UUID) {
        guard readers.remove(readerID) != nil else { return }
        reclaimIfUnobserved()
    }
    func requestReclaim() {
        reclaimRequested = true
        reclaimIfUnobserved()
    }
    private func reclaimIfUnobserved() {
        guard reclaimRequested, readers.isEmpty, !didReclaim else { return }
        didReclaim = true
        reclaim()
    }
}

struct WorkMaterialNativePreviewKey: Hashable {
    let id: UUID
    let sourceByteIdentity: String?
    let fallbackRevision: Int64?
    let availability: WorkboardMaterialAvailability
    let name: String
    let mimeType: String?
    let kind: WorkboardMaterialKind

    init(material: WorkboardMaterialSnapshot) {
        id = material.id
        sourceByteIdentity = material.sourceByteIdentity
        fallbackRevision = material.sourceByteIdentity == nil ? material.revision : nil
        availability = material.availability
        name = material.name
        mimeType = material.mimeType
        kind = material.kind
    }
}

#if os(macOS)
import QuickLookUI

struct WorkMaterialNativePreview: NSViewRepresentable {
    let lease: WorkMaterialPreviewLease

    final class Coordinator {
        let lease: WorkMaterialPreviewLease
        let readerID: UUID
        init(lease: WorkMaterialPreviewLease) { self.lease = lease; readerID = lease.acquire() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = lease.url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // A URL change gives the wrapper a new SwiftUI identity and therefore
        // a new native renderer, allowing the previous item to close first.
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.lease.release(coordinator.readerID)
    }
}
#elseif os(iOS)
struct WorkMaterialNativePreview: UIViewControllerRepresentable {
    let lease: WorkMaterialPreviewLease

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let lease: WorkMaterialPreviewLease
        let readerID: UUID
        init(lease: WorkMaterialPreviewLease) { self.lease = lease; readerID = lease.acquire() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            lease.url as NSURL
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        // Source changes create a new wrapper identity, preserving ownership
        // of the previous export until that controller is dismantled.
    }

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        controller.dataSource = nil
        controller.reloadData()
        coordinator.lease.release(coordinator.readerID)
    }
}
#endif
#endif
