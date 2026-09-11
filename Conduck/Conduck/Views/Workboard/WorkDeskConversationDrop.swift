// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskConversationDrop.swift
//
// The project conversation's pane-wide macOS drop bridge. It uses the same
// ordered DropSession and composer staging as the Chat window. Navigation
// cancels provider work and reclaims every unclaimed temporary file; a late
// provider result cannot enter another conversation or leak its staging copy.

#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation

@Observable @MainActor
final class WorkDeskConversationDrop {
    var isTargeted = false
    var pendingBatch: PendingDropBatch?
    var dispatchingIdentity: ComposerMountIdentity?
    private var loading: DropSession<ResolvedDropItem>?
    private var progresses: [Progress] = []
    private var watchdogs: [Task<Void, Never>] = []

    var isResolving: Bool { loading != nil || pendingBatch != nil }
    var resolvingCount: Int { loading?.providerCount ?? pendingBatch?.items.count ?? 0 }
    var canAccept: Bool { !isResolving && dispatchingIdentity == nil }

    func accept(_ providers: [NSItemProvider], conversationID: UUID) -> Bool {
        guard canAccept else { return false }
        let routed = providers.compactMap { provider -> (NSItemProvider, DropProviderRoute)? in
            let route = ComposerDropRouting.route(
                hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                canLoadImage: provider.canLoadObject(ofClass: NSImage.self)
            )
            return route == .unsupported ? nil : (provider, route)
        }
        guard !routed.isEmpty else { return false }
        let session = DropSession<ResolvedDropItem>(destination: .conversation(conversationID), count: routed.count)
        loading = session
        for (index, entry) in routed.enumerated() {
            load(entry.0, route: entry.1, index: index, session: session)
        }
        return true
    }

    func cancel() {
        for progress in progresses { progress.cancel() }
        clearBookkeeping()
        if let loading {
            for source in loading.cancel() { try? FileManager.default.removeItem(at: source.url) }
        }
        loading = nil
        if let pendingBatch {
            for source in pendingBatch.appOwnedSources { try? FileManager.default.removeItem(at: source.url) }
        }
        pendingBatch = nil
        isTargeted = false
    }

    private func load(_ provider: NSItemProvider, route: DropProviderRoute,
                      index: Int, session: DropSession<ResolvedDropItem>) {
        let type = route == .fileURL ? UTType.fileURL.identifier : UTType.image.identifier
        // Begin every provider's load inside the drop callback. The source can
        // withdraw its provider as soon as that callback returns.
        let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
            let item: ResolvedDropItem = {
                guard let data else { return .failed }
                switch route {
                case .imageData:
                    return .image(data)
                case .fileURL:
                    guard let url = URL(dataRepresentation: data, relativeTo: nil),
                          !ComposerDropRouting.isDirectory(url),
                          let stagingURL = AttachmentStagingFile.copyUnderScope(url) else { return .failed }
                    return .file(DroppedFileSource(url: stagingURL, originalName: url.lastPathComponent, isAppOwned: true))
                case .unsupported:
                    return .failed
                }
            }()
            Task { @MainActor in
                guard let self else {
                    if let source = item.reclaimable { try? FileManager.default.removeItem(at: source.url) }
                    return
                }
                self.finish(index, item: item, session: session)
            }
        }
        progresses.append(progress)
        watchdogs.append(Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Constants.dropProviderLoadTimeoutSeconds))
            guard !Task.isCancelled, !session.isFinished else { return }
            progress.cancel()
            self?.finish(index, item: .failed, session: session)
        })
    }

    private func finish(_ index: Int, item: ResolvedDropItem, session: DropSession<ResolvedDropItem>) {
        guard loading === session else {
            if let source = item.reclaimable { try? FileManager.default.removeItem(at: source.url) }
            return
        }
        if case .rejected(let source) = session.resolve(index: index, with: item), let source {
            try? FileManager.default.removeItem(at: source.url)
        }
        guard let batch = session.takeBatch() else { return }
        clearBookkeeping()
        loading = nil
        pendingBatch = batch
    }

    private func clearBookkeeping() {
        for task in watchdogs { task.cancel() }
        watchdogs.removeAll()
        progresses.removeAll()
    }
}
#endif
