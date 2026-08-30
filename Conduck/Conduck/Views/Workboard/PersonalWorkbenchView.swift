// SPDX-License-Identifier: Apache-2.0

// Conduck
// PersonalWorkbenchView.swift
//
// The top-level Work / Chats shell. Workboard is a first-class personal surface,
// while every dispatched brief still opens in Conduck's normal conversation UI.
// This host owns only presentation routing and local preview/speech conveniences;
// capture persistence and dispatch authority remain in their dedicated seams.
// Wide layouts keep both destinations mounted and animate ONLY their root
// opacity. That makes a section switch a cheap composited dissolve while title,
// toolbar, lifecycle and accessibility state change immediately outside the
// animation transaction. Native NavigationSplitView motion remains untouched.

#if !os(watchOS)

import SwiftUI

/// Both wide workspaces stay mounted so an unsent Chat draft and an unfinished
/// Work thought survive the section switch. Toolbar/title preferences are a
/// separate channel from pixels, though: opacity does not silence them. Every
/// mounted destination reads this value before contributing navigation chrome.
private struct WorkbenchDestinationIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var workbenchDestinationIsActive: Bool {
        get { self[WorkbenchDestinationIsActiveKey.self] }
        set { self[WorkbenchDestinationIsActiveKey.self] = newValue }
    }
}

#if os(macOS)
/// Gives the native macOS conversation shell access to the Work destination so
/// both modes can inhabit one persistent NavigationSplitView. The optional
/// default keeps MainWindowView usable in isolated previews and tests.
private struct PersonalWorkbenchModelKey: EnvironmentKey {
    static let defaultValue: PersonalWorkbenchModel? = nil
}

extension EnvironmentValues {
    var personalWorkbenchModel: PersonalWorkbenchModel? {
        get { self[PersonalWorkbenchModelKey.self] }
        set { self[PersonalWorkbenchModelKey.self] = newValue }
    }
}
#endif

private struct WorkbenchNavigationTitleModifier: ViewModifier {
    let title: Text
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background(alignment: .topLeading) {
            // Keep the substantial destination OUTSIDE the active/inactive
            // branch. Branching between `content.navigationTitle` and `content`
            // changes structural identity and can remount an entire conversation
            // list (including its reload task) during a simple mode switch.
            if isActive {
                Color.clear
                    .frame(width: 0, height: 0)
                    .navigationTitle(title)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func workbenchNavigationTitle(_ title: Text, isActive: Bool) -> some View {
        modifier(WorkbenchNavigationTitleModifier(title: title, isActive: isActive))
    }
}

/// The one motion contract for mounted Work / Chats layers on Mac and iPad.
/// Scoped `animation(_:body:)` is load-bearing: a broad implicit transaction
/// would also animate navigation-title and toolbar preference changes, which
/// can move the otherwise persistent window chrome. Opacity is intentionally
/// the only animated property — no layout pass, blur texture, scale raster or
/// hand-driven split width is added to either substantial workspace tree.
struct WorkbenchDestinationLayerModifier: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool

    private var animation: Animation {
        if reduceMotion { return .linear(duration: 0.06) }
        // A short asymmetric dissolve keeps the handoff legible without making
        // two full workspace surfaces blend for longer than necessary.
        return isActive
            ? .smooth(duration: 0.14, extraBounce: 0)
            : .linear(duration: 0.10)
    }

    func body(content: Content) -> some View {
        content
            .animation(animation) { animatedContent in
                animatedContent.opacity(isActive ? 1 : 0)
            }
            // These semantics switch immediately. Only pixels dissolve.
            .zIndex(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

extension View {
    func workbenchDestinationLayer(
        isActive: Bool,
        reduceMotion: Bool
    ) -> some View {
        modifier(WorkbenchDestinationLayerModifier(
            isActive: isActive,
            reduceMotion: reduceMotion
        ))
    }
}

/// One stable, continuous Work / Chats control shared by Mac and wide iPad.
/// Its outer geometry and centre rule never animate, so the toolbar cannot
/// remeasure or wobble while only the two inexpensive fill colours change.
struct WorkbenchSectionControl: View {
    @Binding var selection: PersonalWorkbenchRouter.Destination
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            segment(
                .work,
                title: LocalizedStringResource("workbench.work", defaultValue: "Work")
            )
            segment(
                .chats,
                title: LocalizedStringResource("workbench.chats", defaultValue: "Chats")
            )
        }
        .frame(width: 160, height: controlHeight)
        .background(AppColors.cardBackgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppColors.border, lineWidth: 1)
                // Overlay the touching button halves so the hard rule never
                // becomes a dead click strip between them.
                Rectangle()
                    .fill(AppColors.border)
                    .frame(width: 1, height: dividerHeight)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(LocalizedStringResource(
            "workbench.section",
            defaultValue: "Section"
        )))
        .accessibilityIdentifier("workbench.section")
    }

    private var controlHeight: CGFloat {
        #if os(macOS)
        30
        #else
        WorkboardMetrics.touchTarget
        #endif
    }

    private var dividerHeight: CGFloat {
        #if os(macOS)
        18
        #else
        26
        #endif
    }

    private func segment(
        _ destination: PersonalWorkbenchRouter.Destination,
        title: LocalizedStringResource
    ) -> some View {
        WorkbenchSectionSegment(
            title: title,
            isSelected: selection == destination,
            reduceMotion: reduceMotion
        ) {
            guard selection != destination else { return }
            selection = destination
        }
        .accessibilityIdentifier(
            destination == .work ? "workbench.section.work" : "workbench.section.chats"
        )
    }
}

private struct WorkbenchSectionSegment: View {
    let title: LocalizedStringResource
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppColors.background : AppColors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkbenchSectionSegmentButtonStyle(
            isSelected: isSelected,
            reduceMotion: reduceMotion
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Full-frame hit, hover and pressed feedback for the custom section control.
/// This mirrors the app-wide MacPointerTargets contract while keeping the two
/// segment fills square so the shared outer clip owns every visible corner.
private struct WorkbenchSectionSegmentButtonStyle: ButtonStyle {
    let isSelected: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(
            configuration: configuration,
            isSelected: isSelected,
            reduceMotion: reduceMotion
        )
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let reduceMotion: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isSelected ? AppColors.brandAmber : .clear)
                .overlay {
                    Rectangle()
                        .fill(washFill)
                        .allowsHitTesting(false)
                }
                .brightness(brightness)
                .contentShape(Rectangle())
                #if os(macOS)
                .onHover { isHovering = $0 }
                #endif
                .opacity(isEnabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isHovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: configuration.isPressed)
        }

        private var washFill: Color {
            guard isEnabled, !isSelected else { return .clear }
            if configuration.isPressed { return AppColors.pointerPressedFill }
            return isHovering ? AppColors.pointerHoverFill : .clear
        }

        private var brightness: Double {
            guard isEnabled, isSelected else { return 0 }
            if configuration.isPressed { return -0.07 }
            return isHovering ? 0.10 : 0
        }
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Notification.Name {
    static let showWorkboard = Notification.Name("showWorkboard")
    static let showChats = Notification.Name("showChats")
    static let openPersonalAISettings = Notification.Name("openPersonalAISettings")
    static let openWorkboardDeepLink = Notification.Name("openWorkboardDeepLink")
}

@MainActor
@Observable
final class PersonalWorkbenchRouter {
    enum Destination: String, Hashable {
        case work
        case chats
    }

    struct MaterialPresentation: Identifiable {
        enum Content {
            case note(String)
            case link(URL)
            case image(Data)
            case file(URL, extractedText: String?)
        }

        let id = UUID()
        let title: String
        let content: Content
    }

    struct PreviewNotice: Identifiable {
        let id = UUID()
        let message: String
    }

    // Preserve Conduck's existing launch behavior. Chat owns OnLaunchMode and
    // must be mounted first so voice/text launch choices remain immediately
    // visible; Workboard is still one top-level tap away.
    var destination: Destination = .chats {
        didSet {
            guard destination != oldValue, destination != .work else { return }
            // A Work preview is transient presentation, not workspace state.
            // Switching to Chats cancels an in-flight load and removes any
            // disposable preview copy so it cannot surface over the other app
            // section or reopen when the person returns.
            closeMaterial()
            if previewNotice != nil { previewNotice = nil }
        }
    }
    var materialPresentation: MaterialPresentation?
    var previewNotice: PreviewNotice?

    private var previewFileURL: URL?
    private var materialRequestID: UUID?

    func openConversation(_ id: UUID) {
        #if !os(macOS)
        destination = .chats
        #endif
        NotificationCenter.default.post(
            name: .openConversationDeepLink,
            object: nil,
            userInfo: [NotificationDeepLink.conversationIDKey: id.uuidString]
        )
    }

    func openGatewaySettings() {
        #if !os(macOS)
        destination = .chats
        #endif
        NotificationCenter.default.post(name: .openPersonalAISettings, object: nil)
    }

    func present(_ material: WorkboardMaterialSnapshot) async {
        closeMaterial()
        let requestID = UUID()
        materialRequestID = requestID
        do {
            switch material.kind {
            case .note:
                commit(
                    MaterialPresentation(
                        title: material.name,
                        content: .note(material.textContent ?? material.detail ?? "")
                    ),
                    requestID: requestID
                )
            case .link:
                guard let value = material.urlString, let url = URL(string: value) else {
                    throw WorkbenchPreviewError.unavailable
                }
                commit(
                    MaterialPresentation(title: material.name, content: .link(url)),
                    requestID: requestID
                )
            case .image:
                if let localURL = try await ConversationStore.shared.localURLForWorkMaterial(id: material.id) {
                    let previewURL = try await Self.makePreviewCopy(
                        from: localURL,
                        displayName: material.name
                    )
                    commit(
                        MaterialPresentation(
                            title: material.name,
                            content: .file(previewURL, extractedText: nil)
                        ),
                        previewURL: previewURL,
                        requestID: requestID
                    )
                    return
                }
                guard let data = try await ConversationStore.shared.loadWorkMaterialPayload(id: material.id)
                    ?? material.thumbnailData else {
                    throw WorkbenchPreviewError.unavailable
                }
                commit(
                    MaterialPresentation(title: material.name, content: .image(data)),
                    requestID: requestID
                )
            case .file:
                if let localURL = try await ConversationStore.shared.localURLForWorkMaterial(id: material.id) {
                    let previewURL = try await Self.makePreviewCopy(
                        from: localURL,
                        displayName: material.name
                    )
                    commit(
                        MaterialPresentation(
                            title: material.name,
                            content: .file(previewURL, extractedText: material.textContent)
                        ),
                        previewURL: previewURL,
                        requestID: requestID
                    )
                    return
                }
                guard let data = try await ConversationStore.shared.loadWorkMaterialPayload(id: material.id) else {
                    throw WorkbenchPreviewError.unavailable
                }
                let filename = Self.safePreviewFilename(material.name)
                let url = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Conduck-Workboard-Preview", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    let url = directory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .appendingPathComponent(filename, isDirectory: false)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try data.write(to: url, options: .atomic)
                    return url
                }.value
                commit(
                    MaterialPresentation(
                        title: material.name,
                        content: .file(url, extractedText: material.textContent)
                    ),
                    previewURL: url,
                    requestID: requestID
                )
            }
        } catch {
            guard materialRequestID == requestID else { return }
            previewNotice = PreviewNotice(message: error.localizedDescription)
        }
    }

    func closeMaterial() {
        materialRequestID = nil
        if materialPresentation != nil { materialPresentation = nil }
        if let previewFileURL {
            Self.removePreviewCopy(at: previewFileURL)
            self.previewFileURL = nil
        }
    }

    private func commit(
        _ presentation: MaterialPresentation,
        previewURL: URL? = nil,
        requestID: UUID
    ) {
        guard materialRequestID == requestID else {
            if let previewURL { Self.removePreviewCopy(at: previewURL) }
            return
        }
        previewFileURL = previewURL
        materialPresentation = presentation
    }

    private nonisolated static func removePreviewCopy(at fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().lastPathComponent
                == "Conduck-Workboard-Preview" else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private nonisolated static func safePreviewFilename(_ rawValue: String) -> String {
        let replaced = rawValue
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = replaced == "." || replaced == ".." ? "" : replaced
        return safe.isEmpty ? "Workboard material" : String(safe.prefix(120))
    }

    /// External preview/open/share surfaces receive a disposable snapshot,
    /// never WorkAssetVault's authoritative URL. An editor may freely mutate
    /// this copy without changing the bytes covered by Work's revision and
    /// immutable dispatch preflight.
    private nonisolated static func makePreviewCopy(
        from sourceURL: URL,
        displayName: String
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Conduck-Workboard-Preview", isDirectory: true)
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fallbackExtension = sourceURL.pathExtension
            var filename = safePreviewFilename(displayName)
            if (filename as NSString).pathExtension.isEmpty, !fallbackExtension.isEmpty {
                filename += ".\(fallbackExtension)"
            }
            let destination = directory.appendingPathComponent(filename, isDirectory: false)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                #if os(iOS)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
                #endif
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }
}

private enum WorkbenchPreviewError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(
            localized: "workboard.material.preview.unavailable",
            defaultValue: "This material is not available on this device. Reattach it here to open or send it."
        )
    }
}

@MainActor
private final class WorkboardBriefingSpeaker {
    private var continuation: CheckedContinuation<Void, Never>?

    func read(_ text: String) async {
        finish()
        #if os(macOS)
        SpeechExclusivity.shared.claim(ReplyVoice.shared)
        #endif
        ReplyVoice.shared.cancel()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            ReplyVoice.shared.speak(text, sanitize: true) { [weak self] _ in
                self?.finish()
            }
        }
    }

    func stop() {
        ReplyVoice.shared.cancel()
        finish()
    }

    private func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

/// Keeps durable capture ingestion independent from the cancelable/debounced UI
/// reload task. `WorkCaptureInbox` posts a change while a claim is moved and
/// again when it is acknowledged; those notifications may request another pass,
/// but they can never cancel the pass that owns the claimed private bytes.
@MainActor
final class WorkCaptureRefreshCoordinator {
    typealias Operation = @MainActor () async -> Void
    typealias DrainOperation = @MainActor () async -> Bool

    private let refreshDelay: Duration
    private let drainCaptures: DrainOperation
    private let refresh: Operation
    private var refreshTask: Task<Void, Never>?
    private var captureDrainTask: Task<Void, Never>?
    private var captureDrainRequested = false

    init(
        refreshDelay: Duration = .milliseconds(180),
        drainCaptures: @escaping DrainOperation,
        refresh: @escaping Operation
    ) {
        self.refreshDelay = refreshDelay
        self.drainCaptures = drainCaptures
        self.refresh = refresh
    }

    /// A capture-triggered refresh is durable and serialized. Ordinary model
    /// notifications remain debounced and cancelable because they own no queue
    /// claim or payload lifetime.
    func schedule(includeCaptureDrain: Bool) {
        if includeCaptureDrain {
            refreshTask?.cancel()
            refreshTask = nil
            captureDrainRequested = true
            startCaptureDrainIfNeeded()
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: refreshDelay)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func startCaptureDrainIfNeeded() {
        guard captureDrainRequested, captureDrainTask == nil else { return }
        captureDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Claim/ack notifications set this flag again while a pass is in
            // flight. Loop once more to close that race and also catch a genuine
            // capture published just as the previous pass reached an empty queue.
            while captureDrainRequested {
                captureDrainRequested = false
                let succeeded = await drainCaptures()
                if !succeeded {
                    // `release` posts its own change notification. A durable
                    // storage failure must not turn that notification into a
                    // hot MainActor retry loop; preserve the capture and wait
                    // for the next foreground/manual wake.
                    captureDrainRequested = false
                    break
                }
            }

            await refresh()
            captureDrainTask = nil
            // `refresh()` suspends, so a new cross-process wake can arrive before
            // ownership is cleared. Never lose that edge.
            startCaptureDrainIfNeeded()
        }
    }
}

@MainActor
@Observable
final class PersonalWorkbenchModel {
    var router: PersonalWorkbenchRouter
    let repository: WorkboardLiveRepository
    let workboardViewModel: WorkboardViewModel

    @ObservationIgnored private let refreshCoordinator: WorkCaptureRefreshCoordinator
    @ObservationIgnored private let speaker: WorkboardBriefingSpeaker

    init() {
        let router = PersonalWorkbenchRouter()
        let speaker = WorkboardBriefingSpeaker()
        let shapingHandler: (@MainActor (WorkboardEditDraft) async throws -> WorkboardEditDraft)?
        if WorkBriefAssistant.availability == .available {
            shapingHandler = { draft in
                let source = [
                    draft.title,
                    draft.objective,
                    draft.context,
                    draft.desiredResult,
                    draft.constraints
                ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
                let suggestion = try await WorkBriefAssistant.shared.shape(transcript: source)
                var shaped = draft
                if !suggestion.title.isEmpty { shaped.title = suggestion.title }
                if !suggestion.objective.isEmpty { shaped.objective = suggestion.objective }
                if !suggestion.context.isEmpty { shaped.context = suggestion.context }
                if !suggestion.desiredResult.isEmpty { shaped.desiredResult = suggestion.desiredResult }
                // Constraints, dates, materials, pinning and identity are never
                // model-authored. The person stays in control of those facts.
                return shaped
            }
        } else {
            shapingHandler = nil
        }

        let repository = WorkboardLiveRepository(
            dispatch: { request, gatewayName in
                try await WorkboardDispatchCoordinator.shared.dispatch(
                    request,
                    gatewayName: gatewayName
                )
            },
            openConversation: { id in router.openConversation(id) },
            openMaterial: { material in
                Task { @MainActor in await router.present(material) }
            },
            openGatewaySettings: { router.openGatewaySettings() },
            shapeDraft: shapingHandler,
            readBriefingAloud: { text in await speaker.read(text) },
            stopBriefingAloud: { speaker.stop() }
        )

        let workboardViewModel = WorkboardViewModel(dependencies: repository.makeDependencies())
        let refreshCoordinator = WorkCaptureRefreshCoordinator(
            drainCaptures: {
                do {
                    _ = try await repository.drainCaptures()
                    return true
                } catch {
                    let message = String(localized: LocalizedStringResource(
                        "workboard.capture.retry.message",
                        defaultValue: "Conduck couldn’t add this capture yet. Its private copy is safe and will be tried again the next time you open the app."
                    ))
                    workboardViewModel.notice = WorkboardNotice(
                        kind: .error,
                        title: LocalizedStringResource(
                            "workboard.capture.retry.title",
                            defaultValue: "Shared item waiting"
                        ),
                        message: message
                    )
                    AccessibilityAnnouncer.announce(message)
                    return false
                }
            },
            refresh: {
                await workboardViewModel.load()
            }
        )

        self.router = router
        self.speaker = speaker
        self.repository = repository
        self.workboardViewModel = workboardViewModel
        self.refreshCoordinator = refreshCoordinator
    }

    func scheduleRefresh(includeCaptureDrain: Bool = false) {
        refreshCoordinator.schedule(includeCaptureDrain: includeCaptureDrain)
    }
}

struct PersonalWorkbenchView<Chats: View>: View {
    @State private var model = PersonalWorkbenchModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let chats: Chats

    init(@ViewBuilder chats: () -> Chats) {
        self.chats = chats()
    }

    var body: some View {
        shell
            .task {
                // A cold launch cannot rely on a Darwin wake surviving app
                // suspension. The durable queue is authoritative, so request a
                // serialized pass whenever this root experience is mounted.
                model.scheduleRefresh(includeCaptureDrain: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == ScenePhase.active {
                    model.scheduleRefresh(includeCaptureDrain: true)
                    Task { await WorkboardUploadJournal.shared.reconcile() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
                model.scheduleRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                model.scheduleRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: WorkCaptureInbox.didChangeNotification)) { _ in
                model.scheduleRefresh(includeCaptureDrain: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openConversationDeepLink)) { note in
                #if !os(macOS)
                routeConversationDeepLink(note)
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWorkboardDeepLink)) { note in
                routeWorkboardDeepLink(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openPersonalAISettings)) { _ in
                #if !os(macOS)
                activateChatsIfNeeded()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGatewayFixRoute)) { _ in
                #if !os(macOS)
                activateChatsIfNeeded()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWorkboard)) { _ in
                model.router.destination = .work
            }
            .onReceive(NotificationCenter.default.publisher(for: .showChats)) { _ in
                model.router.destination = .chats
            }
            .modifier(WorkbenchPlatformRoutingModifier(router: model.router))
            .sheet(item: $model.router.materialPresentation) { presentation in
                WorkboardMaterialPreviewView(
                    presentation: presentation,
                    onClose: model.router.closeMaterial
                )
            }
            .alert(item: $model.router.previewNotice) { notice in
                Alert(
                    title: Text(LocalizedStringResource(
                        "workboard.material.preview.failed.title",
                        defaultValue: "Material unavailable"
                    )),
                    message: Text(verbatim: notice.message),
                    dismissButton: .default(Text(LocalizedStringResource(
                        "common.ok",
                        defaultValue: "OK"
                    )))
                )
            }
    }

    #if !os(macOS)
    private func routeConversationDeepLink(_ note: Notification) {
        // The mounted ContentView consumes the original public notification.
        // Selecting its tab is the only routing work this shell owns on iOS.
        model.router.destination = .chats
    }
    #endif

    private func routeWorkboardDeepLink(_ note: Notification) {
        guard let value = note.userInfo?[NotificationDeepLink.workItemIDKey] as? String,
              let itemID = UUID(uuidString: value) else { return }
        model.router.destination = .work
        Task { @MainActor in
            await model.workboardViewModel.load()
            if model.workboardViewModel.item(withID: itemID) != nil {
                model.workboardViewModel.selectedItemID = itemID
            }
        }
    }

    @ViewBuilder
    private var shell: some View {
        #if os(macOS)
        mountedWideDestinations
        #else
        if horizontalSizeClass == .compact {
            TabView(selection: $model.router.destination) {
                Tab(
                    String(localized: LocalizedStringResource("workbench.work", defaultValue: "Work")),
                    systemImage: "tray.full",
                    value: PersonalWorkbenchRouter.Destination.work
                ) {
                    WorkboardView(viewModel: model.workboardViewModel)
                        .environment(
                            \.workbenchDestinationIsActive,
                            model.router.destination == .work
                        )
                }

                Tab(
                    String(localized: LocalizedStringResource("workbench.chats", defaultValue: "Chats")),
                    systemImage: "bubble.left.and.bubble.right",
                    value: PersonalWorkbenchRouter.Destination.chats
                ) {
                    chats
                        .environment(
                            \.workbenchDestinationIsActive,
                            model.router.destination == .chats
                        )
                }
            }
        } else {
            mountedWideDestinations
        }
        #endif
    }

    /// Keep both primary workspaces mounted on wide layouts. Chat owns its
    /// selected thread, unsent composer, drops, and recording state internally;
    /// conditionally replacing the entire tree on every Work/Chats toggle would
    /// silently reset that high-value transient state. The active-destination
    /// environment silences toolbar, title, and modal preferences from the
    /// hidden tree; opacity, hit-testing, and accessibility gating then provide
    /// the segmented control's visual and interaction semantics while preserving
    /// each workspace's identity.
    private var mountedWideDestinations: some View {
        #if os(macOS)
        chats
            .environment(
                \.workbenchDestinationIsActive,
                model.router.destination == .chats
            )
            .environment(\.personalWorkbenchModel, model)
        #else
        ZStack {
            WorkboardView(viewModel: model.workboardViewModel)
                .environment(
                    \.workbenchDestinationIsActive,
                    model.router.destination == .work
                )
                .toolbar {
                    if model.router.destination == .work {
                        sectionToolbar
                    }
                }
                .workbenchDestinationLayer(
                    isActive: model.router.destination == .work,
                    reduceMotion: reduceMotion
                )

            chats
                .environment(
                    \.workbenchDestinationIsActive,
                    model.router.destination == .chats
                )
                .toolbar {
                    if model.router.destination == .chats {
                        sectionToolbar
                    }
                }
                .workbenchDestinationLayer(
                    isActive: model.router.destination == .chats,
                    reduceMotion: reduceMotion
                )
        }
        #endif
    }

    @ToolbarContentBuilder
    private var sectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            sectionPicker
        }
    }

    private var sectionPicker: some View {
        WorkbenchSectionControl(selection: $model.router.destination)
    }

    #if !os(macOS)
    private func activateChatsIfNeeded() {
        guard model.router.destination != .chats else { return }
        model.router.destination = .chats
    }
    #endif
}

private struct WorkbenchPlatformRoutingModifier: ViewModifier {
    let router: PersonalWorkbenchRouter

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: .openConversationsWindow)) { _ in
                // This event's consumer is the scene/window host, which already
                // received the original. Only reveal Chats here; reposting would
                // ask the host to open the same window twice.
                activateChatsIfNeeded()
            }
        #else
        content
        #endif
    }

    #if os(macOS)
    private func activateChatsIfNeeded() {
        guard router.destination != .chats else { return }
        router.destination = .chats
    }
    #endif
}

private struct WorkboardMaterialPreviewView: View {
    let presentation: PersonalWorkbenchRouter.MaterialPresentation
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch presentation.content {
                case .note(let text):
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                case .link(let url):
                    ContentUnavailableView {
                        Label(
                            LocalizedStringResource("workboard.material.link", defaultValue: "Link"),
                            systemImage: "link"
                        )
                    } description: {
                        Text(verbatim: url.absoluteString)
                            .textSelection(.enabled)
                    } actions: {
                        Link(destination: url) {
                            Label(
                                LocalizedStringResource("workboard.material.openLink", defaultValue: "Open Link"),
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .image(let data):
                    WorkboardPreviewImage(data: data)
                case .file(let url, let text):
                    ScrollView {
                        VStack(spacing: 18) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(AppColors.brandAmber)
                            if let text, !text.isEmpty {
                                Text(text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(LocalizedStringResource(
                                    "workboard.material.file.ready",
                                    defaultValue: "The original file is ready to open or share."
                                ))
                                .foregroundStyle(AppColors.textSecondary)
                            }
                            HStack {
                                Link(destination: url) {
                                    Label(
                                        LocalizedStringResource("workboard.material.openFile", defaultValue: "Open File"),
                                        systemImage: "arrow.up.right.square"
                                    )
                                }
                                ShareLink(item: url) {
                                    Label(
                                        LocalizedStringResource("common.share", defaultValue: "Share"),
                                        systemImage: "square.and.arrow.up"
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(24)
                    }
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: presentation.title))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.done", defaultValue: "Done"), action: onClose)
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 360, minHeight: 340)
    }
}

private struct WorkboardPreviewImage: View {
    let data: Data

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                unavailable
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                unavailable
            }
            #endif
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            LocalizedStringResource("workboard.material.preview.unavailable.title", defaultValue: "No Preview"),
            systemImage: "photo.badge.exclamationmark",
            description: Text(LocalizedStringResource(
                "workboard.material.preview.unavailable.message",
                defaultValue: "The original image could not be decoded on this device."
            ))
        )
    }
}

#endif
