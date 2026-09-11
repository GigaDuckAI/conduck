// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskHandoff.swift
//
// The explicit exit from the private desk. Preparation copies and validates
// material locally; only Send may upload to the selected gateway's file lane
// and submit a normal conversation turn. The reviewed packet owns immutable
// copies, the selected connection, and one attempt. A failure before local
// acceptance leaves the project intact; an accepted turn belongs to Chat's
// existing delivery and retry machinery, never a second Work send.

#if !os(watchOS)
import Foundation
import Observation
import UniformTypeIdentifiers

struct WorkDeskGatewayOption: Identifiable, Equatable, Sendable {
    let ref: RemoteAgentRef
    let name: String
    let hasFileTransfer: Bool
    var id: String { ref.rawString }
    var isHosted: Bool { ref == .builtin(.openrouter) }
}

struct WorkDeskGatewayConnection: Sendable {
    let option: WorkDeskGatewayOption
    let agent: SettingsManager.RemoteAgentSnapshot
    let files: SettingsManager.FileTransferSnapshot?

    /// Secrets participate only in equality, never in a display or persisted
    /// fingerprint. Replacing a configured built-in must not redirect a review.
    func matches(_ other: Self) -> Bool {
        agent.hasSameDispatchDestination(as: other.agent) && files == other.files
    }
}

enum WorkDeskHandoffError: Error, LocalizedError, Equatable {
    case noGateway, emptyBrief, materialChanged, bytesUnavailable, needsFileTransfer, connectionChanged
    case submissionRefused

    var errorDescription: String? {
        switch self {
        case .noGateway:
            return String(localized: "workdesk.handoff.noGateway", defaultValue: "Choose an available AI connection to continue.")
        case .emptyBrief:
            return String(localized: "workdesk.handoff.emptyBrief", defaultValue: "Add an instruction so your AI knows what to do with these materials.")
        case .materialChanged:
            return String(localized: "workdesk.handoff.materialChanged", defaultValue: "A selected material changed. Close this brief and open it again to review the latest version.")
        case .bytesUnavailable:
            return String(localized: "workdesk.handoff.bytesUnavailable", defaultValue: "A selected file is not available on this device. Let it finish syncing, reattach it, or leave it out of this handoff.")
        case .needsFileTransfer:
            return String(localized: "workdesk.handoff.needsFileTransfer", defaultValue: "This file needs a connection with file transfer. Choose another AI, or leave the file out of this handoff.")
        case .connectionChanged:
            return String(localized: "workdesk.handoff.connectionChanged", defaultValue: "The selected connection changed. Review the handoff again before sending.")
        case .submissionRefused:
            return String(localized: "workdesk.handoff.submissionRefused", defaultValue: "The chat could not accept this handoff. Your brief and materials are still in Work.")
        }
    }
}

/// Deterministic policy shared by the material checklist and local preparation.
enum WorkDeskHandoffPolicy {
    static func expanded(_ cards: [WorkboardMaterialSnapshot]) -> [WorkboardMaterialSnapshot] {
        var seen = Set<UUID>()
        return cards.flatMap { [$0] + ($0.companion.map { [$0.material] } ?? []) }
            .filter { seen.insert($0.id).inserted }
    }

    static func hasSameContent(_ lhs: WorkboardMaterialSnapshot, _ rhs: WorkboardMaterialSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.kind == rhs.kind
            && lhs.name == rhs.name && lhs.textContent == rhs.textContent
            && lhs.urlString == rhs.urlString && lhs.mimeType == rhs.mimeType
            && lhs.byteCount == rhs.byteCount
    }

    static func needsBytes(_ material: WorkboardMaterialSnapshot) -> Bool {
        [.image, .file, .audio].contains(material.kind)
    }

    static func likelyNeedsFileTransfer(_ material: WorkboardMaterialSnapshot) -> Bool {
        if material.kind == .audio { return true }
        guard material.kind == .file else { return false }
        if (material.byteCount ?? 0) > Int64(Constants.textProbeMaxBytes) { return true }
        let type = material.mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (material.name as NSString).pathExtension)
        guard let type, !type.isDynamic else { return false }
        return !type.conforms(to: .text) && !type.conforms(to: .sourceCode)
            && type != .json && type != .xml && type != .rtf
    }

    static func blockingReason(_ material: WorkboardMaterialSnapshot, gateway: WorkDeskGatewayOption?) -> String? {
        guard needsBytes(material) else { return nil }
        if !material.availability.isAvailable { return WorkDeskHandoffError.bytesUnavailable.localizedDescription }
        if let gateway, !gateway.hasFileTransfer, likelyNeedsFileTransfer(material) {
            return WorkDeskHandoffError.needsFileTransfer.localizedDescription
        }
        return nil
    }

    static func prompt(title: String, brief: String, materials: [WorkboardMaterialSnapshot]) -> String {
        var sections = [title.trimmingCharacters(in: .whitespacesAndNewlines), brief.trimmingCharacters(in: .whitespacesAndNewlines)]
        for (index, material) in materials.enumerated() {
            var content = "Material \(index + 1): \(material.name)"
            if let text = material.textContent, !text.isEmpty { content += "\n\(text)" }
            if let link = material.urlString, !link.isEmpty { content += "\n\(link)" }
            if needsBytes(material) { content += "\n[Attached material]" }
            sections.append(content)
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct WorkDeskPreparedFile: Sendable {
    enum Content: Sendable {
        case image(jpeg: Data, thumbnail: Data, width: Int, height: Int, byteSize: Int)
        case text(String, mimeType: String)
        case binary(mimeType: String)
    }
    let snapshot: WorkMaterialExportSnapshot
    let content: Content
    let storedKey: String?
}

struct WorkDeskPreparedHandoff: Identifiable, Sendable {
    let id: UUID
    let prompt: String
    let materials: [WorkboardMaterialSnapshot]
    let connection: WorkDeskGatewayConnection
    let files: [WorkDeskPreparedFile]
    var gatewayName: String { connection.option.name }
    var attachmentNames: [String] { files.map { $0.snapshot.filename } }
    var textAttachments: [(name: String, text: String)] {
        files.compactMap {
            if case .text(let text, _) = $0.content { return ($0.snapshot.filename, text) }
            return nil
        }
    }
    func reclaim() { files.forEach { $0.snapshot.reclaim() } }
}

@Observable @MainActor
final class WorkDeskHandoff {
    struct Dependencies {
        var connections: @MainActor () async -> [WorkDeskGatewayConnection]
        var material: @MainActor (UUID) async throws -> WorkboardMaterialSnapshot?
        var export: @MainActor (WorkboardMaterialSnapshot) async throws -> WorkMaterialExportSnapshot
        var upload: @MainActor (URL, String, SettingsManager.FileTransferSnapshot) async throws -> Void
        var removeUpload: @MainActor (String, SettingsManager.FileTransferSnapshot) async -> Void
        var createConversation: @MainActor (UUID, RemoteAgentRef) async throws -> Void
        var removeConversation: @MainActor (UUID) async -> Void
        var submit: @MainActor (UUID, String, [PendingAttachment], RemoteAgentRef, String?, SettingsManager.RemoteAgentSnapshot) async -> Bool

        static func live(conversationResolver: WorkDeskConversationResolver) -> Self {
            Self(
                connections: {
                    let settings = SettingsManager.shared
                    let refs = await settings.configuredRemoteAgentRefs()
                    let roster = await settings.gatewayBadgeRoster()
                    var result: [WorkDeskGatewayConnection] = []
                    for ref in refs {
                        guard let agent = await settings.remoteAgentSnapshot(for: ref) else { continue }
                        // Hosted models never gain a file-server lane from stale settings.
                        let files = ref == .builtin(.openrouter) ? nil : await settings.fileTransferReadySnapshot(for: ref)
                        result.append(WorkDeskGatewayConnection(
                            option: WorkDeskGatewayOption(ref: ref, name: RemoteAgentRefMetadata.displayName(for: ref, customs: roster), hasFileTransfer: files != nil),
                            agent: agent, files: files
                        ))
                    }
                    return result
                },
                material: { try await WorkboardLiveRepository.currentMaterialSnapshot(id: $0) },
                export: { try await WorkMaterialExportSnapshot.make(for: $0, bytes: .live) },
                upload: { url, key, lane in
                    try await ConversationDetailViewModel.uploadServerFile(localURL: url, storedKey: key, snapshot: lane, onProgress: { _ in })
                },
                removeUpload: { key, lane in
                    await ConversationDetailViewModel.deleteOrphanServerFile(storedKey: key, snapshot: lane)
                },
                createConversation: { id, ref in
                    _ = try await ConversationStore.shared.createConversation(id: id, backend: ref.rawString)
                },
                removeConversation: { try? await ConversationStore.shared.deleteConversation(id: $0) },
                submit: { id, prompt, attachments, ref, laneID, agent in
                    #if os(macOS)
                    // The window's Stop control and send lock must address the
                    // SAME live VM that owns this request. A private VM would
                    // dispatch successfully but make the opened chat unable to
                    // cancel it, and allow a concurrent second turn.
                    guard let viewModel = conversationResolver.resolve(id) else {
                        return false
                    }
                    #else
                    let viewModel = ConversationDetailViewModel(conversationID: id)
                    #endif
                    return await viewModel.submitUserTurnAwaitingLocalAcceptance(prompt, attachments: attachments, expectedRef: ref, expectedFileLaneID: laneID, expectedGatewaySnapshot: agent)
                }
            )
        }
    }

    private let dependencies: Dependencies
    private(set) var gateways: [WorkDeskGatewayOption] = []
    private(set) var prepared: WorkDeskPreparedHandoff?
    private(set) var isPreparing = false
    private(set) var isSending = false
    private(set) var acceptedConversationID: UUID?
    var errorMessage: String?
    private var claimedPackets = Set<UUID>()
    private var preparationGeneration = UUID()

    init(dependencies: Dependencies? = nil, conversationResolver: WorkDeskConversationResolver = .init()) {
        self.dependencies = dependencies ?? .live(conversationResolver: conversationResolver)
    }

    func loadGateways() async { gateways = await dependencies.connections().map(\.option) }

    /// A deliberate new handoff from the same project. Previous packet IDs
    /// remain consumed, and this action neither prepares nor sends anything.
    func beginAnotherHandoff() {
        guard !isSending, !isPreparing, acceptedConversationID != nil else { return }
        acceptedConversationID = nil
        errorMessage = nil
    }

    func discardPreparation() {
        guard !isSending else { return }
        preparationGeneration = UUID()
        prepared?.reclaim()
        prepared = nil
        errorMessage = nil
    }

    func prepare(title: String, brief: String, cards: [WorkboardMaterialSnapshot], ref: RemoteAgentRef?) async {
        guard !isPreparing, !isSending, acceptedConversationID == nil else { return }
        discardPreparation()
        let generation = preparationGeneration
        isPreparing = true
        defer { isPreparing = false }
        var exports: [WorkMaterialExportSnapshot] = []
        do {
            guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkDeskHandoffError.emptyBrief }
            guard let ref, let connection = await dependencies.connections().first(where: { $0.option.ref == ref }) else { throw WorkDeskHandoffError.noGateway }
            let materials = WorkDeskHandoffPolicy.expanded(cards)
            let conversationID = UUID()
            var files: [WorkDeskPreparedFile] = []
            for material in materials {
                try Task.checkCancellation()
                try await validate(material)
                guard WorkDeskHandoffPolicy.needsBytes(material) else { continue }
                guard material.availability.isAvailable else { throw WorkDeskHandoffError.bytesUnavailable }
                let exported = try await dependencies.export(material)
                exports.append(exported)
                let content = try await Self.process(exported, kind: material.kind, hasFileTransfer: connection.files != nil, textProbeMaxBytes: Constants.textProbeMaxBytes, textInlineMaxBytes: Constants.textInlineMaxBytes)
                if case .binary = content, connection.files == nil { throw WorkDeskHandoffError.needsFileTransfer }
                let key = connection.files.map {
                    FileServerClient.makeStoredKey(originalName: exported.filename, uuid: UUID(), folder: $0.folderCapable ? conversationID.uuidString : nil)
                }
                files.append(WorkDeskPreparedFile(snapshot: exported, content: content, storedKey: key))
                try await validate(material)
            }
            guard generation == preparationGeneration else { exports.forEach { $0.reclaim() }; return }
            try Task.checkCancellation()
            prepared = WorkDeskPreparedHandoff(id: conversationID, prompt: WorkDeskHandoffPolicy.prompt(title: title, brief: brief, materials: materials), materials: materials, connection: connection, files: files)
        } catch {
            exports.forEach { $0.reclaim() }
            if generation == preparationGeneration, !(error is CancellationError) { errorMessage = Self.message(for: error) }
        }
    }

    /// Claims the reviewed packet synchronously, before any settings/store hop.
    /// Once accepted this controller can only open that same conversation.
    func send() async -> UUID? {
        guard !isSending, let packet = prepared, acceptedConversationID == nil,
              claimedPackets.insert(packet.id).inserted else { return nil }
        isSending = true
        errorMessage = nil
        var uploaded: [String] = []
        var conversationCreated = false
        defer { isSending = false }
        do {
            try await validate(packet)
            var attachments: [PendingAttachment] = []
            for file in packet.files {
                if let key = file.storedKey, let lane = packet.connection.files {
                    // Revalidate before EVERY egress, not just the first file.
                    try await validateConnection(packet.connection)
                    // A transport failure may follow a landed PUT, so include
                    // the attempted key in cleanup before starting its upload.
                    uploaded.append(key)
                    try await dependencies.upload(file.snapshot.url, key, lane)
                }
                switch file.content {
                case .image(let jpeg, let thumbnail, let width, let height, let byteSize):
                    attachments.append(.dualImage(processedJPEG: jpeg, thumbnail: thumbnail, width: width, height: height, byteSize: byteSize, storedKey: file.storedKey, filename: file.snapshot.filename))
                case .text(let text, let mime):
                    attachments.append(.dualText(url: file.snapshot.url, extractedText: text, filename: file.snapshot.filename, mimeType: mime, storedKey: file.storedKey))
                case .binary(let mime):
                    guard let key = file.storedKey else { throw WorkDeskHandoffError.needsFileTransfer }
                    attachments.append(.serverFile(url: file.snapshot.url, originalName: file.snapshot.filename, mimeType: mime, storedKey: key))
                }
            }
            try await validateConnection(packet.connection)
            try await dependencies.createConversation(packet.id, packet.connection.option.ref)
            conversationCreated = true
            let accepted = await dependencies.submit(packet.id, packet.prompt, attachments, packet.connection.option.ref, packet.connection.files?.durableLaneID, packet.connection.agent)
            guard accepted else { throw WorkDeskHandoffError.submissionRefused }
            acceptedConversationID = packet.id
            packet.reclaim()
            prepared = nil
            return packet.id
        } catch {
            if conversationCreated { await dependencies.removeConversation(packet.id) }
            if let lane = packet.connection.files {
                for key in uploaded { await dependencies.removeUpload(key, lane) }
            }
            packet.reclaim()
            prepared = nil
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    private func validate(_ material: WorkboardMaterialSnapshot) async throws {
        guard let current = try await dependencies.material(material.id),
              WorkDeskHandoffPolicy.hasSameContent(material, current) else { throw WorkDeskHandoffError.materialChanged }
        if WorkDeskHandoffPolicy.needsBytes(material), !current.availability.isAvailable { throw WorkDeskHandoffError.bytesUnavailable }
    }

    private func validate(_ packet: WorkDeskPreparedHandoff) async throws {
        try await validateConnection(packet.connection)
        for material in packet.materials { try await validate(material) }
    }

    private func validateConnection(_ expected: WorkDeskGatewayConnection) async throws {
        guard let current = await dependencies.connections().first(where: { $0.option.ref == expected.option.ref }), expected.matches(current) else { throw WorkDeskHandoffError.connectionChanged }
    }

    @concurrent private nonisolated static func process(_ file: WorkMaterialExportSnapshot, kind: WorkboardMaterialKind, hasFileTransfer: Bool, textProbeMaxBytes: Int, textInlineMaxBytes: Int) async throws -> WorkDeskPreparedFile.Content {
        let byteSize = (try file.url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard byteSize > 0 else { throw WorkDeskHandoffError.bytesUnavailable }
        if kind == .image {
            let image = try await ImageProcessor.shared.process(fileAt: file.url)
            return .image(jpeg: image.jpegData, thumbnail: image.thumbnailData, width: image.width, height: image.height, byteSize: image.byteSize)
        }
        if kind != .audio, byteSize <= textProbeMaxBytes,
           let extracted = try? TextFileExtractor.extract(from: file.url) {
            if hasFileTransfer, extracted.text.utf8.count > textInlineMaxBytes {
                return .binary(mimeType: file.contentType.preferredMIMEType ?? "application/octet-stream")
            }
            return .text(extracted.text, mimeType: extracted.mimeType)
        }
        return .binary(mimeType: file.contentType.preferredMIMEType ?? "application/octet-stream")
    }

    private static func message(for error: Error) -> String {
        // Arbitrary provider/file-system diagnostics may contain endpoints.
        // Only controlled domain errors reach this preparation surface.
        if let known = error as? WorkDeskHandoffError { return known.localizedDescription }
        if error is WorkMaterialExportError { return WorkDeskHandoffError.bytesUnavailable.localizedDescription }
        return String(localized: "workdesk.handoff.failed", defaultValue: "The handoff could not finish. Your project is unchanged. Review it again to try once more.")
    }
}
#endif
