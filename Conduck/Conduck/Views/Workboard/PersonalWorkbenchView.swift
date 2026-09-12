// SPDX-License-Identifier: Apache-2.0

// Conduck
// PersonalWorkbenchView.swift
//
// The top-level Work / Chats shell. Work is a first-class personal surface with
// for collecting and preparing ideas. This host owns presentation routing and local
// preview conveniences; capture persistence remains in its dedicated seam.
// A section switch animates ONLY root opacity: a cheap composited dissolve,
// while title, toolbar, lifecycle and accessibility state change immediately
// outside the animation transaction. Mac suppresses split-view layout motion
// during a section change so the dissolve happens at the destination's width.
// Chat stays mounted across the switch; Mac retains Work after its first visit
// so both keep their scroll views and view-owned composition state.

#if !os(watchOS)

import SwiftUI
// SwiftUI's `.quickLookPreview` lives in the SwiftUI×QuickLook cross-import
// overlay — both imports are required for the modifier to resolve.
import QuickLook
import UniformTypeIdentifiers
#if canImport(UIKit)
// For `UITabBar.appearance()`: the native tab bar's brand colour is installed on
// the UIKit proxy rather than written as a SwiftUI tint. See
// `WorkbenchTabBarTint`.
import UIKit
#endif

/// Hands a platform shell the section router, on every platform that has one.
/// The macOS window shell reads it so both modes inhabit one persistent
/// NavigationSplitView; the wide iOS shell injects it into BOTH of its mounted
/// layers, and each layer's own navigation container is what declares the
/// wide section control. Compact layouts omit this model; iPhone supplies its
/// own `phoneWorkbenchRouter` for the expandable section control, while compact
/// iPad uses the native tab bar. The optional default also keeps
/// MainWindowView usable in isolated previews and tests.
private struct PersonalWorkbenchModelKey: EnvironmentKey {
    static let defaultValue: PersonalWorkbenchModel? = nil
}

extension EnvironmentValues {
    var personalWorkbenchModel: PersonalWorkbenchModel? {
        get { self[PersonalWorkbenchModelKey.self] }
        set { self[PersonalWorkbenchModelKey.self] = newValue }
    }
}

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

/// The motion contract for retained Work / Chats layers on Mac and iPad.
/// Only opacity receives an animation transaction. The host can suppress native
/// split-view layout animation without suppressing this dissolve or animating
/// toolbar preferences, child layout, or lifecycle changes. Separate visibility
/// lets a lazily mounted layer begin its first fade one update after insertion.
struct WorkbenchDestinationLayerModifier: ViewModifier {
    static let duration: Double = 0.18
    static let reduceMotionDuration: Double = 0.08

    let isActive: Bool
    let isVisible: Bool
    let reduceMotion: Bool

    private var animation: Animation {
        reduceMotion
            ? .linear(duration: Self.reduceMotionDuration)
            : .easeInOut(duration: Self.duration)
    }

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                transaction.disablesAnimations = false
                transaction.animation = animation
            } body: { animatedContent in
                animatedContent.opacity(isVisible ? 1 : 0)
            }
            // These semantics switch immediately. Only pixels dissolve.
            .zIndex(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

extension View {
    /// For hosts that keep BOTH layers permanently mounted, where pixels can
    /// follow the destination directly.
    func workbenchDestinationLayer(
        isActive: Bool,
        reduceMotion: Bool
    ) -> some View {
        workbenchDestinationLayer(
            isActive: isActive,
            isVisible: isActive,
            reduceMotion: reduceMotion
        )
    }

    func workbenchDestinationLayer(
        isActive: Bool,
        isVisible: Bool,
        reduceMotion: Bool
    ) -> some View {
        modifier(WorkbenchDestinationLayerModifier(
            isActive: isActive,
            isVisible: isVisible,
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
        // Chats leads, Work follows. `segment(_:title:)` derives the action,
        // label and accessibility identifier from the destination it is handed,
        // so the two halves carry their own wiring and order is purely visual.
        HStack(spacing: 0) {
            segment(
                .chats,
                title: LocalizedStringResource("workbench.chats", defaultValue: "Chats")
            )
            segment(
                .work,
                title: LocalizedStringResource("workbench.work", defaultValue: "Work")
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
        // The standard touch target. Whether an iPad navigation bar seats 44pt
        // without growing is a measurement on a real bar, taken by the
        // integration pass rather than assumed here.
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

/// The ONE toolbar declaration every iPad host uses, so the control is
/// identical in both sections instead of two call sites drifting apart. A host
/// declares this INSIDE its own navigation container: toolbar items are
/// collected in view-tree order, so an item declared above a container lands in
/// no bar at all.
///
/// The shared background is suppressed here rather than at each call site
/// because the control draws one continuous filled container itself; without
/// this it ships double-wrapped in the system's glass capsule (same reason the
/// Mac shell sets it on its own section host).
struct WorkbenchSectionToolbarItem: ToolbarContent {
    /// The router the control drives, taken as the model a host already holds
    /// rather than as a `@Binding`: the binding is rebuilt in this body, so the
    /// destination read happens inside the control's own body and stays
    /// observation-tracked from every host.
    let model: PersonalWorkbenchModel

    /// The control's two-way seam onto the router, as a value rather than a
    /// literal inside `body`. Both halves are silent when wrong — a `get` that
    /// read a copy would leave the highlighted half stuck on the section the
    /// user just left, and a `set` that wrote anywhere else would make the
    /// control a decoration — and neither shows up in an opaque `ToolbarContent`
    /// body a test cannot mount. Named here, the seam is a value a test drives
    /// directly, and the guard suite pins that `body` is the thing consuming it.
    static func selectionBinding(
        for router: PersonalWorkbenchRouter
    ) -> Binding<PersonalWorkbenchRouter.Destination> {
        Binding(
            get: { router.destination },
            set: { router.destination = $0 }
        )
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            WorkbenchSectionControl(selection: Self.selectionBinding(for: model.router))
        }
        .sharedBackgroundVisibility(.hidden)
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
                .opacity(isEnabled ? 1 : MacPointer.disabledOpacity)
                .animation(reduceMotion ? nil : MacPointer.highlightAnimation, value: isSelected)
                .animation(reduceMotion ? nil : MacPointer.highlightAnimation, value: isHovering)
                .animation(reduceMotion ? nil : MacPointer.highlightAnimation, value: configuration.isPressed)
        }

        /// The selected half already carries the amber fill, so it takes the
        /// brightness treatment instead of a wash over its own colour.
        private var washFill: Color {
            guard !isSelected else { return .clear }
            return MacPointer.highlightFill(
                hovering: isHovering,
                pressed: configuration.isPressed,
                enabled: isEnabled
            )
        }

        private var brightness: Double {
            guard isEnabled, isSelected else { return 0 }
            if configuration.isPressed { return -0.07 }
            return isHovering ? 0.10 : 0
        }
    }
}

extension Notification.Name {
    static let showWorkboard = Notification.Name("showWorkboard")
    static let showChats = Notification.Name("showChats")
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
        /// App-owned details keep editable notes reachable for every kind,
        /// including unavailable files. Native source preview remains a separate
        /// explicit action with its existing byte-readability and lifetime gates.
        enum Content {
            case note(String)
            case details(WorkboardMaterialSnapshot)
            /// Every openable image on the desk, in board order, with the tapped
            /// card's position. The whole desk rather than the one card because
            /// a picture is looked at NEXT to its neighbours; the tapped card
            /// alone would make the swipe gesture a dead end.
            case imageGallery(GallerySelection)
        }

        let id = UUID()
        let title: String
        let content: Content

        /// Whether this sheet draws a share refusal itself. Only the gallery
        /// does — it is the one that carries a Share control — so a refusal
        /// raised behind any other sheet still reaches the desk's alert rather
        /// than being swallowed by a surface with nowhere to put it.
        var rendersShareFailure: Bool {
            switch content {
            case .imageGallery, .details: return true
            case .note: return false
            }
        }
    }

    struct PreviewNotice: Identifiable {
        let id = UUID()
        let message: String
    }

    /// The pages of an image gallery, where the tap landed in them, and the
    /// recordings folded into them.
    ///
    /// The companions are keyed by PICTURE id — the page's own id — because
    /// that is what the gallery's cursor names, and they are carried here
    /// rather than on `AttachmentGalleryPage` so the gallery stays model-free:
    /// a page holding a `WorkboardCompanionSnapshot` would put a Work type
    /// inside the component Chat also draws.
    ///
    /// Like the pages themselves this is a SNAPSHOT taken when the sheet opens.
    /// A transcript that lands, or bytes that finish arriving, while the sheet
    /// is up do not change it; the desk behind it is what refreshes.
    struct GallerySelection {
        let pages: [AttachmentGalleryPage]
        let startIndex: Int
        var companions: [UUID: WorkboardCompanionSnapshot] = [:]
        var materials: [UUID: WorkboardMaterialSnapshot] = [:]

        /// The recording folded into the page the cursor is on, if any.
        func companion(forPage pageID: UUID?) -> WorkboardCompanionSnapshot? {
            guard let pageID else { return nil }
            return companions[pageID]
        }
    }

    // Preserve Conduck's existing launch behavior. Chat owns OnLaunchMode and
    // must be mounted first so voice/text launch choices remain immediately
    // visible; the section control routes through this same destination.
    var destination: Destination = .chats {
        didSet {
            guard destination != oldValue else { return }
            #if os(iOS)
            dismissPhoneSection()
            #endif
            guard destination != .work else { return }
            // A Work preview is transient presentation, not workspace state.
            // Switching to Chats cancels an in-flight load and removes any
            // disposable preview copy so it cannot surface over the other app
            // section or reopen when the person returns. A share being prepared
            // is the same kind of thing and is dropped here for the same
            // reason — its copy is reclaimed when the load loses its claim.
            closeMaterial()
            share.cancelPendingShare()
            if previewNotice != nil { previewNotice = nil }
        }
    }

    #if os(iOS)
    /// Expansion belongs to the section that opened it. A deep link or a stale
    /// button from the departing tab cannot reopen or select on its behalf.
    private(set) var expandedPhoneSection: Destination?

    func isPhoneSectionExpanded(for owner: Destination) -> Bool {
        expandedPhoneSection == owner && destination == owner
    }

    func togglePhoneSection(for owner: Destination) {
        guard destination == owner else { return }
        expandedPhoneSection = isPhoneSectionExpanded(for: owner) ? nil : owner
    }

    func dismissPhoneSection() {
        expandedPhoneSection = nil
    }

    /// A departing tab may finish disappearing after the next one is active.
    /// Its cleanup can close only its own expansion, never the next tab's.
    func dismissPhoneSection(for owner: Destination) {
        guard expandedPhoneSection == owner else { return }
        dismissPhoneSection()
    }

    func selectPhoneSection(_ selection: Destination) {
        guard isPhoneSectionExpanded(for: destination) else { return }
        dismissPhoneSection()
        destination = selection
    }
    #endif
    var materialPresentation: MaterialPresentation?
    var previewNotice: PreviewNotice?

    /// Work's own Quick Look presenter. ONE per surface and never shared with
    /// Chat's: `QLPreviewPanel` is application-shared on macOS, so the two
    /// sections must be able to invalidate each other — which is exactly what
    /// `closeMaterial()` does on the way out of Work, mirroring the
    /// `cancelPendingPresentation()` Chat runs when its own thread is hidden.
    @ObservationIgnored let filePreview: FilePreviewCoordinator
    private(set) var nativePreviewLease: WorkMaterialPreviewLease?

    /// Work's own share presenter, owned exactly where Quick Look's is and for
    /// the same reason: it holds one in-flight claim and one window anchor, and
    /// a presenter living in the desk shell would lose both every time a
    /// platform host remounted that shell.
    @ObservationIgnored let share: WorkMaterialShareCoordinator

    /// The desk as the board currently holds it, in board order.
    ///
    /// A closure rather than a stored array because the desk is the view
    /// model's, and a copy taken at construction would go stale on the first
    /// capture. It is read once, at the moment of the tap, so the gallery's
    /// pages are the cards that were on screen when the person tapped one.
    @ObservationIgnored var deskMaterials: @MainActor () -> [WorkboardMaterialSnapshot] = { [] }

    /// Hand an address to the person's browser.
    ///
    /// A seam rather than a call inside `present` so the one thing a link card
    /// does can be driven by a test without a browser. The desk makes NO
    /// request of its own here — no title, no favicon, no preview: the click is
    /// the person's, and fetching what is behind the address would be the desk
    /// phoning out unasked.
    @ObservationIgnored var openExternalURL: @MainActor (URL) -> Void = { url in
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private var materialRequestID: UUID?
    private var textEditorSessions: [WorkMaterialTextEditorID: WorkMaterialTextEditorSession] = [:]
    @ObservationIgnored var openSourceConversation: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var hasSourceConversation: @MainActor (UUID) -> Bool = { _ in false }

    func textEditor(for material: WorkboardMaterialSnapshot, field: WorkMaterialTextField) -> WorkMaterialTextEditorSession {
        let key = WorkMaterialTextEditorID(materialID: material.id, field: field)
        if let existing = textEditorSessions[key] { return existing }
        let session = WorkMaterialTextEditorSession(material: material, field: field)
        textEditorSessions[key] = session
        return session
    }

    func textState(for material: WorkboardMaterialSnapshot) -> WorkMaterialTextState {
        let current = Self.currentDeskCard(in: deskMaterials(), for: material)
        var state = WorkMaterialTextState(material: current)
        for field in [WorkMaterialTextField.annotation, .source] {
            let key = WorkMaterialTextEditorID(materialID: material.id, field: field)
            if let saved = textEditorSessions[key]?.saved, saved.revision >= state.revision { state = saved }
        }
        return state
    }

    func hasUnsavedNotes(for materialID: UUID) -> Bool {
        textEditorSessions[.init(materialID: materialID, field: .annotation)]?.isDirty == true
    }

    /// `nil` rather than a default-constructed coordinator: a default argument
    /// is evaluated in the CALLER's context, which is nonisolated, and the
    /// coordinator is main-actor isolated. Building it inside the initialiser
    /// keeps that construction on the actor that owns it.
    init(
        filePreview: FilePreviewCoordinator? = nil,
        share: WorkMaterialShareCoordinator? = nil
    ) {
        self.filePreview = filePreview ?? FilePreviewCoordinator()
        self.share = share ?? WorkMaterialShareCoordinator()
    }

    /// Reading metadata never requires local source bytes. Only a readable
    /// image enters the full gallery; an unavailable one gets an honest details
    /// shell with notes and the current availability explanation.
    func present(_ tapped: WorkboardMaterialSnapshot) async {
        closeMaterial()
        let requestID = UUID()
        materialRequestID = requestID
        let desk = deskMaterials()
        let material = Self.currentDeskCard(in: desk, for: tapped)
        if material.kind == .image, WorkboardCardActionPolicy.allows(.open, when: material.availability) {
            commit(MaterialPresentation(title: material.name,
                content: .imageGallery(Self.gallerySelection(desk: desk, tapped: material))), requestID: requestID)
        } else {
            commit(MaterialPresentation(title: material.name, content: .details(material)), requestID: requestID)
        }
    }

    func openOriginal(_ tapped: WorkboardMaterialSnapshot) async {
        // A file's native preview can cover its details without discarding the
        // app-owned notes shell. Direct callers retain the original lifecycle.
        if case .details(let shown) = materialPresentation?.content, shown.id == tapped.id {
            previewNotice = nil
        } else {
            closeMaterial()
        }
        let requestID = UUID()
        materialRequestID = requestID
        // Minted here, at the moment of user intent, and NOT next to the
        // `present` that follows the load: completion order must not decide
        // which file wins the application-shared Quick Look panel.
        let previewToken = filePreview.beginRequest()
        let desk = deskMaterials()
        // The card as the desk holds it NOW. Presentation is scheduled from the
        // tap rather than run inside it, so the snapshot the gesture carried can
        // already be one write behind: a peer's reattach landing in that gap
        // moves the card to `.syncPending` while its replacement bytes travel.
        // The gate below has to answer for the card that exists, not for the one
        // that was tapped — otherwise a stale readable snapshot walks a refused
        // card into the gallery and presents its thumbnail as the picture.
        let material = Self.currentDeskCard(in: desk, for: tapped)
        do {
            // Opening, previewing, sharing and playing all run through this one
            // presenter, so the readability gate belongs HERE and not only in
            // the surface that called it: a caller that skipped the desk's own
            // gate must not be able to open a thumbnail in place of the image,
            // or hand a share sheet bytes this device does not hold.
            guard WorkboardCardActionPolicy.allows(.open, when: material.availability) else {
                throw material.availability == .syncPending
                    ? WorkbenchPreviewError.syncPending
                    : WorkbenchPreviewError.unavailable
            }
            switch material.kind {
            // Typed words and spoken words open the same way, because opening
            // either one can only mean reading it: neither has bytes behind it
            // to preview.
            case .note, .transcript:
                commit(
                    MaterialPresentation(
                        title: material.name,
                        content: .note(material.textContent ?? material.detail ?? "")
                    ),
                    requestID: requestID
                )
            // A link opens where links open. There is nothing of the card to
            // draw — its whole content IS the address — so a sheet could only
            // restate the URL and offer the button the click already stood for.
            case .link:
                guard let value = material.urlString, let url = URL(string: value) else {
                    throw WorkbenchPreviewError.unavailable
                }
                openExternalURL(url)
            // EVERY image lane. A camera original parked in the device-local
            // vault is a picture exactly as much as a small synced one is, and
            // routing by lane would open the large one as a document — the size
            // of a photograph is not a fact about what it is.
            // No bytes are read here: the gallery resolves each page's original
            // itself, when that page is the one being looked at.
            case .image:
                // The SAME desk read the gate above answered from: reading it
                // twice would let a card pass the gate in one snapshot and be
                // filtered out of the pages in the next.
                let selection = Self.gallerySelection(
                    desk: desk,
                    tapped: material
                )
                commit(
                    MaterialPresentation(
                        title: material.name,
                        content: .imageGallery(selection)
                    ),
                    requestID: requestID
                )
            // A recording reaches this presenter only through Open, where Quick
            // Look plays it; the board's own audio card never routes here.
            case .file, .audio:
                let snapshot: WorkMaterialExportSnapshot
                do {
                    snapshot = try await WorkMaterialExportSnapshot.make(
                        for: material,
                        bytes: .live
                    )
                } catch WorkMaterialExportError.bytesUnavailable {
                    // The export type carries no copy of its own, so the
                    // preview lane keeps naming the verb the person asked for.
                    // Only THIS case is remapped: a file-system refusal must
                    // still reach the person as what it actually was.
                    throw WorkbenchPreviewError.unavailable
                }
                // The desk moved on while the copy was being made — a newer tap,
                // or a switch to Chats. The copy is this request's own work, so
                // this request reclaims it rather than leaving it for the sweep.
                guard filePreview.isCurrent(previewToken), materialRequestID == requestID else {
                    snapshot.reclaim()
                    return
                }
                let lease = WorkMaterialPreviewLease(url: snapshot.url, reclaim: { snapshot.reclaim() })
                filePreview.present(
                    PreviewedFile(url: snapshot.url, reclaim: { lease.requestReclaim() }),
                    token: previewToken
                )
                nativePreviewLease = lease
            }
        } catch {
            guard materialRequestID == requestID else { return }
            previewNotice = PreviewNotice(message: error.localizedDescription)
        }
    }

    func closeMaterial() {
        materialRequestID = nil
        if materialPresentation != nil { materialPresentation = nil }
        // A refusal the gallery drew inline goes with the gallery: the person
        // has already read it, and leaving it set would raise the desk's alert
        // for the same sentence a second time.
        share.clearFailure()
        // Invalidate the visible Quick Look AND every in-flight claim. Without
        // this a Work preview could stay on screen over Chats — and on macOS the
        // panel both sections share would be owned by the hidden one.
        filePreview.cancelPendingPresentation()
        nativePreviewLease = nil
    }

    /// The card the desk holds under the tapped card's id, or the tapped card
    /// itself when the desk no longer carries it.
    ///
    /// The tap's snapshot is a value copied at gesture time; the desk is read
    /// when the presentation actually runs. Where the two disagree the DESK
    /// wins — it is the state the person's other devices have already changed —
    /// and the fall back to the tapped card keeps a board that reloaded
    /// underneath the gesture from turning into a dead tap.
    ///
    /// The lookup reaches COMPANIONS too. A recording drawn inside its picture
    /// is not one of the desk's cards, so searching only the top level would
    /// send every Open Recording down the stale-snapshot fallback — the one path
    /// that cannot answer for a card the desk has since refused.
    static func currentDeskCard(
        in desk: [WorkboardMaterialSnapshot],
        for tapped: WorkboardMaterialSnapshot
    ) -> WorkboardMaterialSnapshot {
        WorkboardDeskMember.find(tapped.id, among: desk) ?? tapped
    }

    /// The pages a tap on one image card opens, and where that tap landed.
    ///
    /// The desk is filtered through the SAME gate the tap itself passed, so a
    /// card whose bytes are still arriving is never a page — swiping onto it
    /// would present its thumbnail as though the picture had landed, which is
    /// the exact confusion `WorkboardCardActionPolicy` exists to prevent.
    ///
    /// A tapped card that is not in the desk it was tapped on (a board reloaded
    /// underneath the gesture) still opens, alone: refusing it would turn a
    /// stale read into a dead tap on a card the person is looking at.
    ///
    /// That lone-card fallback is for an ABSENT card only. `present` resolves
    /// the tap against this same desk through `currentDeskCard` and refuses a
    /// card the desk still holds but the policy will not open, so a card that
    /// was filtered out of the pages can never be reinstated here by a snapshot
    /// taken before it changed.
    static func gallerySelection(
        desk: [WorkboardMaterialSnapshot],
        tapped: WorkboardMaterialSnapshot
    ) -> GallerySelection {
        let openable = desk.filter { candidate in
            candidate.kind == .image
                && WorkboardCardActionPolicy.allows(.open, when: candidate.availability)
        }
        let materials = openable.contains { $0.id == tapped.id } ? openable : [tapped]
        let startIndex = materials.firstIndex { $0.id == tapped.id } ?? 0
        // Built from the pages that ACTUALLY open, after the lone-card
        // fallback: a folded picture the desk no longer carries still opens on
        // its own, and its recording has to come with it.
        //
        // A companion whose own bytes are not readable here is kept rather than
        // filtered out. The picture's readability is not the recording's, and a
        // band that says what it is waiting for beats one that vanishes.
        var companions: [UUID: WorkboardCompanionSnapshot] = [:]
        for material in materials {
            if let companion = material.companion {
                companions[material.id] = companion
            }
        }
        return GallerySelection(
            pages: materials.map(galleryPage(for:)),
            startIndex: startIndex,
            companions: companions,
            materials: Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        )
    }

    /// One card as the gallery sees it. The accessibility label is the card's
    /// own name rather than a position, because that name is what the person
    /// reads on the desk and VoiceOver speaks it verbatim.
    static func galleryPage(
        for material: WorkboardMaterialSnapshot
    ) -> AttachmentGalleryPage {
        AttachmentGalleryPage(
            id: material.id,
            thumbnailData: material.thumbnailData,
            accessibilityLabel: material.name,
            // The header names the card exactly as the desk does. Work cards
            // always carry a name, so unlike a chat attachment there is nothing
            // to fall back from.
            title: material.name
        )
    }

    /// The ORIGINAL bytes behind one image card, for one gallery page.
    ///
    /// One store call for both lanes: `loadWorkMaterialPayload` already resolves
    /// a synced blob and a device-local vault leaf, so the gallery never has to
    /// know which one a card is on — which is the same reason the router stopped
    /// branching on the lane in the first place.
    ///
    /// Throwing rather than returning empty bytes is the contract the gallery
    /// page relies on: it turns a throw into its Retry state, while empty bytes
    /// would decode to nothing and spin. A thumbnail is never substituted here —
    /// this is the surface a person opens to see the picture itself.
    nonisolated static func imageBytes(materialID: UUID) async throws -> Data {
        guard let data = try await ConversationStore.shared.loadWorkMaterialPayload(id: materialID) else {
            throw WorkbenchPreviewError.unavailable
        }
        return data
    }

    private func commit(
        _ presentation: MaterialPresentation,
        requestID: UUID
    ) {
        guard materialRequestID == requestID else { return }
        materialPresentation = presentation
    }

}

private enum WorkbenchPreviewError: LocalizedError {
    /// The bytes are not on this device and nothing but the person can bring
    /// them back, so the copy names the repair.
    case unavailable
    /// The bytes are on their way through the person's own iCloud. Waiting is
    /// the whole answer, so this must never read as a request to replace them.
    case syncPending

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(
                localized: "workboard.material.preview.unavailable",
                defaultValue: "This material is not available on this device. Reattach it here to open it."
            )
        case .syncPending:
            return String(localized: ContentSyncPresentationPolicy.missingFileExplanation(
                enabled: ContentSyncPresentationSnapshot.shared.isEnabled, sharing: false
            ))
        }
    }
}

/// Keeps durable capture ingestion independent from the cancelable/debounced UI
/// reload task. `WorkCaptureInbox` posts a change while a claim is moved and
/// again when it is acknowledged; those notifications may request another pass,
/// but they can never cancel the pass that owns the claimed private bytes.
///
/// It is also the board's SOLE load owner. Every reload — launch, foreground,
/// capture drain, Chat mutation, remote settings change — arrives here, so the
/// visibility gate below is total and no second mount can double-load.
@MainActor
final class WorkCaptureRefreshCoordinator {
    typealias Operation = @MainActor () async -> Void
    typealias DrainOperation = @MainActor () async -> Bool
    typealias VisibilityCheck = @MainActor () -> Bool

    private let refreshDelay: Duration
    private let boardIsVisible: VisibilityCheck
    private let drainCaptures: DrainOperation
    private let refresh: Operation
    private var refreshTask: Task<Void, Never>?
    private var captureDrainTask: Task<Void, Never>?
    private var captureDrainRequested = false
    private var boardIsStale = false
    private var hasLoadedBoard = false

    init(
        refreshDelay: Duration = .milliseconds(180),
        boardIsVisible: @escaping VisibilityCheck,
        drainCaptures: @escaping DrainOperation,
        refresh: @escaping Operation
    ) {
        self.refreshDelay = refreshDelay
        self.boardIsVisible = boardIsVisible
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
            await refreshIfVisible()
        }
    }

    /// Work became reachable again: run whatever reload was deferred while it
    /// was hidden. Debounced like any other reload, which also lets the section
    /// dissolve finish before the fetch lands; the board on screen is already
    /// the warm one, so nothing is waiting on it.
    func drainDeferredRefresh() {
        guard boardIsVisible(), boardIsStale else { return }
        schedule(includeCaptureDrain: false)
    }

    /// The board is the only reader of what `refresh()` fetches, and one pass is
    /// an unbounded board fetch plus a gateway roster read. While Work is hidden
    /// a reload is therefore RECORDED, not run — a chat turn posts one of these
    /// per store mutation — and `drainDeferredRefresh()` replays the newest one.
    ///
    /// The FIRST pass always runs, hidden or not: it warms the board so opening
    /// Work shows the cards already on the desk rather than the empty-board
    /// copy, and it is the pass that adopts whatever the share extension left
    /// in the queue before launch.
    private func refreshIfVisible() async {
        guard boardIsVisible() || !hasLoadedBoard else {
            boardIsStale = true
            return
        }
        boardIsStale = false
        hasLoadedBoard = true
        await refresh()
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

            await refreshIfVisible()
            captureDrainTask = nil
            // `refreshIfVisible()` suspends, so a new cross-process wake can
            // arrive before ownership is cleared. Never lose that edge.
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

    init() {
        let router = PersonalWorkbenchRouter()
        let repository = WorkboardLiveRepository(
            openMaterial: { material in
                Task { @MainActor in await router.present(material) }
            },
            // By ID, not by snapshot: the coordinator resolves the card against
            // the desk as it stands when the tap lands, so a menu that closed
            // over an older board cannot walk a changed card into a share sheet.
            shareMaterial: { material in
                router.share.share(materialID: material.id)
            }
        )

        let workboardViewModel = WorkboardViewModel(dependencies: repository.makeDependencies())
        let refreshCoordinator = WorkCaptureRefreshCoordinator(
            boardIsVisible: { router.destination == .work },
            drainCaptures: {
                do {
                    let report = try await repository.drainCaptures()
                    // A malformed envelope is destroyed by the inbox before it
                    // can reach persistence, and the share sheet has already
                    // told the person the capture succeeded. Without this the
                    // only signal is an item that silently never appears.
                    if report.invalidCaptureCount > 0 {
                        let message = report.invalidCaptureCount == 1
                            ? String(localized: LocalizedStringResource(
                                "workboard.capture.discarded.message.one",
                                defaultValue: "Conduck couldn’t read one shared item, so it wasn’t added to your board."
                            ))
                            : String.localizedStringWithFormat(
                                String(localized: LocalizedStringResource(
                                    "workboard.capture.discarded.message",
                                    defaultValue: "Conduck couldn’t read %lld shared items, so they weren’t added to your board."
                                )),
                                Int64(report.invalidCaptureCount)
                            )
                        workboardViewModel.notice = WorkboardNotice(
                            kind: .error,
                            title: report.invalidCaptureCount == 1
                                ? LocalizedStringResource(
                                    "workboard.capture.discarded.title.one",
                                    defaultValue: "Shared item not added"
                                )
                                : LocalizedStringResource(
                                    "workboard.capture.discarded.title",
                                    defaultValue: "Shared items not added"
                                ),
                            message: message
                        )
                        AccessibilityAnnouncer.announce(message)
                    } else if report.refusedEntryCount > 0 {
                        // A sibling of the discarded-capture notice, not a
                        // variant of it: nothing failed, the rest of the capture
                        // is on the board, and the sentence has to name the door
                        // that does keep a recording. No count in it — one
                        // sentence for one recording and for five is the honest
                        // answer here, and a number would buy a plural rule for
                        // every language.
                        let message = String(localized: LocalizedStringResource(
                            "workboard.capture.recordingRefused.message",
                            defaultValue: "Work keeps recordings only when you add them yourself. Open Work and use the attachment button."
                        ))
                        workboardViewModel.notice = WorkboardNotice(
                            kind: .error,
                            title: LocalizedStringResource(
                                "workboard.capture.recordingRefused.title",
                                defaultValue: "Recording not added"
                            ),
                            message: message
                        )
                        AccessibilityAnnouncer.announce(message)
                    }
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
        self.repository = repository
        self.workboardViewModel = workboardViewModel
        self.refreshCoordinator = refreshCoordinator

        // The gallery's other pages. Weak and read at tap time: the board is the
        // view model's to own, so the router asks for it rather than holding a
        // copy that the next capture would make wrong.
        router.deskMaterials = { [weak workboardViewModel] in
            workboardViewModel?.desk?.materials ?? []
        }
        // The share coordinator reads the STORE, not this board. The board
        // reloads behind a debounce, so it still draws a card the store has
        // already replaced or deleted — while the bytes are resolved from the
        // store by id, which is how a replacement leaves the device under the
        // previous revision's name and type.
        router.hasSourceConversation = { [weak workboardViewModel] materialID in
            workboardViewModel?.deskWorkspace.results[materialID] != nil
        }
        router.openSourceConversation = { [weak router, weak workboardViewModel] materialID in
            guard let workboardViewModel, let source = workboardViewModel.deskWorkspace.results[materialID] else { return }
            router?.closeMaterial()
            workboardViewModel.deskWorkspace.openResultSource(source)
        }
        router.share.currentMaterial = { materialID in
            try await WorkboardLiveRepository.currentMaterialSnapshot(id: materialID)
        }
    }

    func scheduleRefresh(includeCaptureDrain: Bool = false) {
        refreshCoordinator.schedule(includeCaptureDrain: includeCaptureDrain)
    }

    /// Called when the section changes. A reload deferred while Work was hidden
    /// lands here, so the board is current by the time its pixels are.
    func drainDeferredBoardRefresh() {
        refreshCoordinator.drainDeferredRefresh()
    }
}

#if !os(macOS)
/// The native tab bar uses brand amber without tinting the content it hosts.
/// Compact iPad displays this bar; iPhone hides it in favor of its own chooser.
///
/// The colour goes on the UIKit tab-bar appearance rather than on a SwiftUI
/// `.tint(AppColors.brandAmber)` written on the `TabView`, because that tint
/// does not stay in the bar. A tint is one environment value AND SwiftUI hands
/// it to the tab-bar controller's own view; a UIKit `tintColor` cascades to
/// every view hosted under that controller, and `Color.accentColor` resolves
/// through it, so ambient-tint controls inside the tabs turn amber as well —
/// `PendingRetryCard`'s `.borderedProminent` Retry button, which names no tint
/// of its own, and the composer's own text selection. The same controls render
/// in the system accent on wide iPad, which builds no `TabView`, and inside a
/// presented sheet, which sits outside the bar's view tree. Measured on iOS
/// 26.5 by classifying the composer's selection highlight: amber under the
/// SwiftUI tint, system blue here. Writing the environment tint back to the
/// unset state at each tab root does not undo it, because the leak travels the
/// UIKit path, which no environment value reaches.
///
/// The appearance proxy reaches `UITabBar` instances and nothing else, so the
/// scoping is structural rather than remembered: a control inside a tab is not
/// a subview of the bar, and a tab added later cannot forget to opt out of a
/// colour it never inherits. The app's only other `TabView` — the attachment
/// gallery — is `.page` styled, which builds a page controller carrying no
/// `UITabBar`, so the proxy cannot reach that either.
///
/// The colour has to be written into the per-layout appearances, not into the
/// proxy's `tintColor`: on iOS 26.5 the bar reads its selected item's colour
/// from the appearance objects, and a proxy `tintColor` alone leaves the
/// selected tab in the system accent (measured: zero amber pixels in the
/// selected tab's box). Both the standard and the scroll-edge appearance carry
/// it, and all three layouts within each, so the bar keeps its colour in every
/// state it draws.
///
/// A `static let` because the install has to happen exactly once and before the
/// bar it paints reaches a window: UIKit applies an appearance proxy's values
/// as a view ENTERS a window, and does not repaint one already there, so a late
/// install leaves that bar in the system accent until something rebuilds it.
/// `PersonalWorkbenchView.init` is the touch that runs this, and it is early
/// enough — it returns before that view's body builds the bar. It lives out
/// here rather than on that view because a generic type holds no static stored
/// property. The app ships an EMPTY AccentColor asset on purpose so the Mac
/// honours the user's system accent, which is why no app-root tint exists and
/// none may be added.
private enum WorkbenchTabBarTint {
    static let installed: Void = {
        let amber = UIColor(AppColors.brandAmber)
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for layout in [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ] {
            layout.selected.iconColor = amber
            layout.selected.titleTextAttributes = [.foregroundColor: amber]
        }
        let bar = UITabBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }()
}
#endif

struct PersonalWorkbenchView<Chats: View>: View {
    @State private var model = PersonalWorkbenchModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let chats: Chats

    init(@ViewBuilder chats: () -> Chats) {
        self.chats = chats()
        #if !os(macOS)
        // Here rather than in `shell`: UIKit applies an appearance proxy's
        // values as a view ENTERS a window and does not repaint one already
        // there, and this initializer returns before this view's body builds
        // the tab bar — so the colour is in place before that bar reaches a
        // window.
        _ = WorkbenchTabBarTint.installed
        #endif
    }

    var body: some View {
        shell
            #if os(iOS)
            // This presenter stays above the regular/compact shell branches, so
            // resizing an iPad cannot destroy a Settings editor opened in Work.
            .modifier(WorkSettingsPresentationModifier(router: model.router))
            #endif
            // The window view the system's share UI pops out of. It has to be a
            // real platform view in a real window: `NSSharingServicePicker`
            // shows relative to one, and `UIActivityViewController` traps on
            // iPad without a popover anchor.
            .sharePresentationAnchor(model.router.share.anchor)
            .appReviewBusy(
                model.workboardViewModel.isCapturingIntoDesk
                    || model.workboardViewModel.notice != nil
                    || model.router.materialPresentation != nil
                    || model.router.filePreview.previewURL != nil
                    || model.router.previewNotice != nil
                    || model.router.share.isPreparing
            )
            .requestAppReviewAfterActiveDays(anchor: model.router.share.anchor)
            .overlay(alignment: .top) { sharePreparingBanner }
            // ONE failure, rendered by whichever surface is on top. A gallery
            // sheet is opaque and draws it inline, so raising the desk's alert
            // underneath would queue the same sentence to be read twice.
            // Routing only. The announcement is the COORDINATOR's, made the
            // moment the refusal exists, because both surfaces here are silent
            // on their own and one of these two arms returns without drawing
            // anything at all.
            .onChange(of: model.router.share.failure) { _, failure in
                guard let failure,
                      model.router.materialPresentation?.rendersShareFailure != true else { return }
                model.workboardViewModel.notice = WorkboardNotice(
                    kind: .error,
                    title: failure.title,
                    message: failure.message
                )
                model.router.share.clearFailure()
            }
            .task {
                // A cold launch cannot rely on a Darwin wake surviving app
                // suspension. The durable queue is authoritative, so request a
                // serialized pass whenever this root experience is mounted.
                model.scheduleRefresh(includeCaptureDrain: true)
                reconcileDurableWorkStorage()
            }
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                if phase != .active { model.router.dismissPhoneSection() }
                #endif
                if phase == ScenePhase.active {
                    model.scheduleRefresh(includeCaptureDrain: true)
                    reconcileDurableWorkStorage()
                }
            }
            .onChange(of: model.router.destination) { _, _ in
                model.drainDeferredBoardRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
                model.scheduleRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                model.scheduleRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .contentSyncPreferenceDidChange)) { _ in
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
            .onReceive(NotificationCenter.default.publisher(for: .openWorkboardDeepLink)) { _ in
                workboardDeepLinkRoute.open()
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
            .onChange(of: model.router.materialPresentation?.id) { oldValue, newValue in
                if oldValue != nil && newValue == nil && model.router.materialPresentation == nil { model.router.closeMaterial() }
            }
            .sheet(item: $model.router.materialPresentation) { presentation in
                WorkboardMaterialPreviewView(
                    presentation: presentation,
                    router: model.router,
                    onClose: model.router.closeMaterial,
                    onSharePage: { pageID in
                        model.router.share.share(materialID: pageID)
                    },
                    // The sheet is opaque, so the desk's own banner and alert
                    // are invisible behind it. It draws the SAME coordinator
                    // state rather than a copy of it.
                    share: model.router.share
                )
                // The sheet registers its OWN anchor, so a share fired from the
                // gallery pops out of the gallery rather than out of the desk it
                // is covering. The registry prefers the newest attached anchor,
                // and falls back to the desk's when this one goes away.
                .sharePresentationAnchor(model.router.share.anchor)
            }
            // A SEPARATE presenter from the sheet above, not a case inside it:
            // Quick Look is the system's own window (a panel on macOS, a full
            // screen controller on iOS) and it is what already knows how to draw
            // a PDF, play a recording and offer Open with / Share.
            .quickLookPreview(workMaterialPreviewURL)
            // The modifier nils the binding on user dismissal, and ONLY on user
            // dismissal — that edge is what tells the coordinator the file may
            // be reclaimed where the platform allows it.
            .onChange(of: model.router.filePreview.previewURL) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    model.router.filePreview.handleDismiss()
                }
            }
            .alert(item: Binding(
                get: { model.router.materialPresentation == nil ? model.router.previewNotice : nil },
                set: { model.router.previewNotice = $0 }
            )) { notice in
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

    /// What a Share tap looks like while the bytes are being copied.
    ///
    /// It exists because the menu is GONE by the time the copy starts: a
    /// several-hundred-megabyte recording takes a visible moment to snapshot,
    /// and without this the tap reads as having done nothing. It is not a
    /// control and never blocks the board — the person can keep working, and a
    /// second Share supersedes this one.
    @ViewBuilder
    private var sharePreparingBanner: some View {
        WorkShareStatusBanner(
            share: model.router.share,
            // The desk raises a refusal as its own alert, which is the pattern
            // every other Work failure already uses.
            rendersFailure: false,
            reduceMotion: reduceMotion
        )
    }

    /// The Quick Look binding. `@Bindable` because the coordinator is an
    /// `@Observable` reference the router owns rather than this view's own
    /// state — the desk shell is remounted by the platform shells, and a
    /// presenter living here would lose an in-flight claim with it.
    private var workMaterialPreviewURL: Binding<URL?> {
        Binding(get: {
            model.router.materialPresentation == nil ? model.router.filePreview.previewURL : nil
        }, set: { value in
            if model.router.materialPresentation == nil { model.router.filePreview.previewURL = value }
        })
    }

    /// Launch/foreground repair for device-local Work storage. Both passes have
    /// delete or write authority and scale with what is on disk, so they belong
    /// on this edge and never in the board's read path, which re-runs on
    /// ordinary Chat activity.
    ///
    /// One `Task`, in order: the vault sweep decides which materials still HAVE
    /// bytes, and the thumbnail backfill then reads those bytes. Running the
    /// backfill first would spend decodes on rows the sweep is about to write
    /// off. The backfill never throws and self-limits to one pass per store, so
    /// both of this view's edges (`task` and a foreground `scenePhase`) can call
    /// it freely.
    private func reconcileDurableWorkStorage() {
        Task {
            _ = try? await ConversationStore.shared.reconcileWorkAssetVault()
            await ConversationStore.shared.repairMissingWorkThumbnails()
        }
    }

    #if !os(macOS)
    private func routeConversationDeepLink(_ note: Notification) {
        // The mounted ContentView consumes the original public notification.
        // Selecting its tab is the only routing work this shell owns on iOS.
        model.router.destination = .chats
    }
    #endif

    /// The Work deep link's landing, as the value that owns it. The reasoning
    /// lives with the type; what this shell owns is handing it the router it
    /// reveals and the coordinator call it schedules through.
    private var workboardDeepLinkRoute: WorkboardDeepLinkRoute {
        WorkboardDeepLinkRoute(router: model.router) {
            model.scheduleRefresh()
        }
    }

    @ViewBuilder
    private var shell: some View {
        #if os(macOS)
        mountedWideDestinations
        #else
        // BOTH conditions, and the same pair `ContentView` gates its split
        // layout on (`horizontalSizeClass == .regular && DeviceCapabilities.isiPad`).
        // `.regular` alone asks a different question: a large iPhone reports a
        // REGULAR horizontal size class in landscape, so a size-class-only test
        // hands that geometry the two-layer wide shell while ContentView keeps
        // it on `phoneLayout` — one device, two shells disagreeing about which
        // chrome exists. Gating on the iPad idiom keeps every phone geometry,
        // portrait and landscape, on the same tab lifecycle. Only its visible
        // chrome changes: iPhone routes from a compact top-right control while
        // compact iPad retains its native bottom bar.
        if horizontalSizeClass == .regular && DeviceCapabilities.isiPad {
            mountedWideDestinations
        } else {
            // Chats leads, Work follows — the same reading order as the wide
            // shell's `WorkbenchSectionControl`, so the phone's section switch
            // and the iPad's never disagree about which side a mode sits on.
            //
            // The bar's brand amber arrives through `WorkbenchTabBarTint`,
            // never through a `.tint` written here — that type carries why the
            // difference decides whether the colour stays inside the bar.
            TabView(selection: $model.router.destination) {
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
                        .environment(\.phoneWorkbenchRouter, DeviceCapabilities.isiPad ? nil : model.router)
                        .toolbar(DeviceCapabilities.isiPad ? .visible : .hidden, for: .tabBar)
                }

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
                        .environment(\.phoneWorkbenchRouter, DeviceCapabilities.isiPad ? nil : model.router)
                        .toolbar(DeviceCapabilities.isiPad ? .visible : .hidden, for: .tabBar)
                }
            }
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
        // Each layer owns its own navigation container, so there is no shared bar
        // this shell could put the section control in: a `.toolbar` attached to a
        // layer from OUT HERE sits above that layer's container, is collected by
        // nothing, and renders no item at all. The control is declared by the
        // HOSTS instead, each inside its own container — `ConversationLibraryView`'s
        // detail column for Chats, `WorkboardExperience`'s split for Work — and
        // this shell's whole job is handing them the router. Presence is the
        // flag for the wide control. The compact shell uses a separate phone
        // router, so the wide control never appears alongside the phone one.
        ZStack {
            WorkboardView(viewModel: model.workboardViewModel)
                .environment(
                    \.workbenchDestinationIsActive,
                    model.router.destination == .work
                )
                .environment(\.personalWorkbenchModel, model)
                .workbenchDestinationLayer(
                    isActive: model.router.destination == .work,
                    reduceMotion: reduceMotion
                )

            chats
                .environment(
                    \.workbenchDestinationIsActive,
                    model.router.destination == .chats
                )
                .environment(\.personalWorkbenchModel, model)
                .workbenchDestinationLayer(
                    isActive: model.router.destination == .chats,
                    reduceMotion: reduceMotion
                )
        }
        #endif
    }

    #if !os(macOS)
    private func activateChatsIfNeeded() {
        guard model.router.destination != .chats else { return }
        model.router.destination = .chats
    }
    #endif
}

#if os(iOS)
/// Work opens the existing Settings containers from one retained presenter.
/// Its location above the shell keeps editor state through iPad window resizing;
/// the presentation style is chosen once when opening, never from live width
/// while a sheet or cover is already on screen. A conversation request closes a
/// clean Settings screen; a dirty editor keeps the existing Done/Discard guard,
/// with the requested conversation selected underneath, as on macOS.
private struct WorkSettingsPresentationModifier: ViewModifier {
    let router: PersonalWorkbenchRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var settingsViewModel = SettingsViewModel()
    @State private var presentation: Presentation?

    private struct Presentation: Identifiable {
        let id = UUID()
        let usesFullScreen: Bool
    }

    func body(content: Content) -> some View {
        content
            .environment(\.workDeskOpenSettings, openSettings)
            .sheet(item: sheetPresentation) { route in
                SettingsView(viewModel: settingsViewModel)
                    .id(route.id)
                    .environment(\.workbenchDestinationIsActive, true)
                    .interactiveDismissDisabled(settingsViewModel.editorHasUnsavedChanges)
            }
            .fullScreenCover(item: fullScreenPresentation) { route in
                IpadSettingsView(viewModel: settingsViewModel, onDone: { presentation = nil })
                    .id(route.id)
                    .environment(\.workbenchDestinationIsActive, true)
            }
            .onChange(of: router.destination) { _, destination in
                guard destination != .work, !settingsViewModel.editorHasUnsavedChanges else { return }
                presentation = nil
            }
            .appReviewBusy(presentation != nil)
    }

    private func openSettings() {
        guard router.destination == .work else { return }
        router.dismissPhoneSection(for: .work)
        presentation = Presentation(
            usesFullScreen: horizontalSizeClass == .regular && DeviceCapabilities.isiPad
        )
    }

    private var sheetPresentation: Binding<Presentation?> {
        Binding(
            get: { presentation?.usesFullScreen == false ? presentation : nil },
            set: { route in
                guard presentation?.usesFullScreen == false else { return }
                presentation = route
            }
        )
    }

    private var fullScreenPresentation: Binding<Presentation?> {
        Binding(
            get: { presentation?.usesFullScreen == true ? presentation : nil },
            set: { route in
                guard presentation?.usesFullScreen == true else { return }
                presentation = route
            }
        )
    }
}
#endif

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

/// The sheet half of Work's preview. Files never reach it — those go to Quick
/// Look — so what remains is the two surfaces the system has no presenter for
/// (a note's text, a link) and the image gallery, which is Chat's zoomable
/// gallery driven by desk cards instead of message attachments.
/// The share coordinator's transient state, drawn identically wherever it is
/// needed.
///
/// TWO surfaces render it because either can be frontmost, and a Work sheet is
/// opaque: a banner living only on the desk shell is invisible behind the image
/// gallery, which is exactly where a slow export of a camera original is most
/// likely to look like a dead tap. Both read the SAME coordinator, so there is
/// one piece of state and two renderers rather than two states to keep in step.
struct WorkShareStatusBanner: View {
    let share: WorkMaterialShareCoordinator
    /// Whether this surface also draws refusals. The desk does not — it has an
    /// alert for that — so only a surface covering the desk sets this.
    let rendersFailure: Bool
    let reduceMotion: Bool

    /// Moves the VoiceOver cursor onto the refusal. The announcement says it
    /// once; this is what lets somebody find it again, and reach the control
    /// that dismisses it, without hunting a black full-screen gallery.
    @AccessibilityFocusState private var failureIsFocused: Bool

    var body: some View {
        Group {
            if share.isPreparing {
                capsule {
                    ProgressView()
                        .controlSize(.small)
                    Text(WorkMaterialShareCoordinator.preparingCopy)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .allowsHitTesting(false)
            } else if rendersFailure, let failure = share.failure {
                Button {
                    share.clearFailure()
                } label: {
                    capsule {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                        Text(verbatim: failure.message)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(LocalizedStringResource(
                    "workboard.material.share.dismissFailure",
                    defaultValue: "Dismisses this message"
                )))
                .accessibilityFocused($failureIsFocused)
                .onAppear { failureIsFocused = true }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private func capsule<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct WorkboardMaterialPreviewView: View {
    let presentation: PersonalWorkbenchRouter.MaterialPresentation
    let router: PersonalWorkbenchRouter
    let onClose: () -> Void
    /// Share the page currently on screen. The gallery hands over the CURRENT
    /// selection's card id, so a swipe changes what a tap here shares.
    let onSharePage: (UUID) -> Void
    /// The share state the gallery draws itself, because it covers the desk's.
    let share: WorkMaterialShareCoordinator

    @ViewBuilder
    var body: some View {
        switch presentation.content {
        case .imageGallery(let selection):
            WorkboardGallerySheet(
                selection: selection,
                router: router,
                onSharePage: onSharePage,
                share: share
            )
        case .details(let material):
            WorkMaterialDetailsSheet(material: material, router: router)
        case .note:
            textualPreview
        }
    }

    private var textualPreview: some View {
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
                case .imageGallery, .details:
                    // Unreachable: the gallery is drawn above, outside this
                    // navigation chrome, because it carries its own Done control
                    // and its own black ground.
                    EmptyView()
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

/// Work's gallery: the shared component, plus the two things only this surface
/// has — the share state it must draw itself because the sheet covers the
/// desk's, and the recording folded into the picture on screen.
///
/// IT OWNS THE CURSOR. `AttachmentGallerySelection` is created here and handed
/// to the gallery, so the band below the picture and the Share control inside
/// the header resolve the SAME page: a folded card's transport that read its
/// own index would play the previous recording over the current picture after
/// one swipe.
private struct WorkboardGallerySheet: View {
    let selection: PersonalWorkbenchRouter.GallerySelection
    let router: PersonalWorkbenchRouter
    @State private var transcriptEditor: WorkMaterialTextEditorSession?
    @State private var inlineEditor: WorkMaterialTextEditorSession?
    let onSharePage: (UUID) -> Void
    let share: WorkMaterialShareCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one cursor. `@State` of a reference this view owns, so it survives
    /// redraws and the gallery writes the value this view reads.
    @State private var cursor: AttachmentGallerySelection

    /// ONE player for the sheet, not one per band: the process-wide
    /// exclusivity registry only means something while a surface holds a single
    /// player, and two bands each holding a copy of the same clip is exactly
    /// what it exists to prevent.
    @State private var companionPlayer = WorkboardAudioCardPlayer()

    init(
        selection: PersonalWorkbenchRouter.GallerySelection,
        router: PersonalWorkbenchRouter,
        onSharePage: @escaping (UUID) -> Void,
        share: WorkMaterialShareCoordinator
    ) {
        self.selection = selection
        self.router = router
        self.onSharePage = onSharePage
        self.share = share
        _cursor = State(initialValue: AttachmentGallerySelection(
            startIndex: selection.startIndex,
            pageCount: selection.pages.count
        ))
    }

    private var currentPageID: UUID? {
        cursor.pageID(in: selection.pages)
    }

    private var currentCompanion: WorkboardCompanionSnapshot? {
        guard let companion = selection.companion(forPage: currentPageID) else { return nil }
        let current = PersonalWorkbenchRouter.currentDeskCard(in: router.deskMaterials(), for: companion.material)
        var snapshot = WorkboardCompanionSnapshot(current)
        let text = router.textState(for: current)
        snapshot.textContent = text.textContent
        snapshot.annotation = text.annotation
        snapshot.revision = text.revision
        return snapshot
    }

    var body: some View {
        AttachmentFullScreenView(
            pages: selection.pages,
            startIndex: selection.startIndex,
            // Lazy, per page, and by card id: the gallery asks only for the
            // page being looked at, and a card whose bytes are unreadable
            // throws so that page offers Retry instead of spinning.
            loadFullBytes: { materialID in
                try await PersonalWorkbenchRouter.imageBytes(materialID: materialID)
            },
            // A card captured before the desk sized its pictures still holds
            // its original bytes, so a camera photo there is a 40+ megapixel
            // decode; a newer card is already at
            // `Constants.workboardImageMaxPixel` and the bound is a no-op. The
            // bound is what makes a desk-wide gallery affordable; the STRICT
            // path behind it reports failure rather than silently falling back
            // to an unbounded decode.
            fullDecodeMaxPixel: 4096,
            selection: cursor
        ) { pageID in
            // The ORIGINAL bytes, resolved by the coordinator from the card
            // id — never the bounded image this gallery decoded to draw.
            Button {
                onSharePage(pageID)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .pointerIconButton(size: 40, shape: .circle)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workboard.material.share",
                defaultValue: "Share"
            )))
        }
        // The gallery's own copy of the share state. Without it a large
        // original exports behind an opaque black sheet with nothing on
        // screen, and a refusal lands on an alert nobody can see. Inset below
        // the gallery's header, which owns that strip.
        .overlay(alignment: .top) {
            WorkShareStatusBanner(
                share: share,
                rendersFailure: true,
                reduceMotion: reduceMotion
            )
            .padding(.top, AttachmentGalleryChrome.headerHeight)
        }
        // The folded card, opened as ONE sheet: the picture in the gallery, its
        // recording's transport along the bottom of that page.
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let companion = currentCompanion {
                    WorkboardGalleryCompanionBand(companion: companion, player: companionPlayer)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(LocalizedStringResource("workdesk.material.companionNotes", defaultValue: "Notes for attached material…")) {
                                transcriptEditor = router.textEditor(for: companion.material, field: .annotation)
                            }.inlineLinkButton()
                            Spacer()
                            if companion.kind == .transcript {
                                Button(LocalizedStringResource("workboard.material.transcript.edit", defaultValue: "Edit transcript")) {
                                    transcriptEditor = router.textEditor(for: companion.material, field: .source)
                                }.inlineLinkButton()
                            }
                        }
                        .font(.caption)
                        if let notes = companion.annotation, !notes.isEmpty {
                            Text(verbatim: notes).font(.caption).lineLimit(3)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .background(AppColors.cardBackgroundElevated)
                }
                if let pageID = currentPageID, let material = selection.materials[pageID] {
                    Group {
                        if let inlineEditor, inlineEditor.id.materialID == pageID {
                            ScrollView {
                                WorkMaterialInlineNotesEditor(session: inlineEditor) { self.inlineEditor = nil }
                                    .padding(12)
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .frame(maxHeight: 220)
                        } else {
                            WorkMaterialNotesSummary(material: material, router: router) {
                                // Freeze this page's identity before editing.
                                inlineEditor = router.textEditor(for: material, field: .annotation)
                            }.padding(12)
                        }
                    }
                    .background(AppColors.cardBackgroundElevated)
                }
            }
        }
        .onChange(of: currentPageID) { _, _ in inlineEditor = nil }
        .sheet(item: $transcriptEditor) { session in WorkMaterialTextEditor(session: session) }
        .interactiveDismissDisabled(inlineEditor?.isDirty == true || inlineEditor?.isBusy == true)
        // Watched on the SHEET, not inside the band: moving from a folded
        // picture to an ordinary one removes the band, and a paused player
        // resumes the clip it already holds — so a player left alive here would
        // start the previous picture's recording under the next one.
        .onChange(of: currentCompanion?.id) { _, _ in companionPlayer.deactivate() }
        .onDisappear { companionPlayer.deactivate() }
    }
}

/// The voice material along the bottom of the picture it was captured with: a
/// recording with its transport, or the words alone.
///
/// THE WORDS-ONLY BAND IS WHY THE PICTURE WAS OPENED. On the board its card can
/// spare two lines for them; here the sheet is the full view of the pair, so the
/// band spends its height on the text and draws no transport, no availability
/// chip and no progress track — a control, a waiting sentence and a filling bar
/// would all be about bytes that do not exist.
///
/// ACCESSIBILITY IS THIS VIEW'S OWN JOB. `WorkboardAudioTransport(.control)`
/// hides itself from VoiceOver because on the board its card supplies the
/// matching custom actions; there is no card here, so the band states what the
/// voice material is, what it is doing, and offers the one action itself.
private struct WorkboardGalleryCompanionBand: View {
    let companion: WorkboardCompanionSnapshot
    let player: WorkboardAudioCardPlayer

    /// The recording's OWN readability, never the picture's. A picture that
    /// opened can be folded with a recording whose bytes are still arriving.
    /// Words alone are never playable: nothing is behind them to reach for.
    private var isPlayable: Bool {
        companion.kind == .audio
            && WorkboardCardActionPolicy.allows(.play, when: companion.availability)
    }

    /// How much of the words the band shows. A recording's band is a caption
    /// under a transport — the clip is the material and two lines name it —
    /// while a words-only band IS the material, and the picture was opened to
    /// read it.
    private var transcriptLineLimit: Int {
        companion.kind == .audio ? 2 : 8
    }

    /// Why the transport is not offering to play, IN WORDS.
    ///
    /// The board's card carries this sentence beside its glyph and names the
    /// repair in its menu; the gallery has neither, so without it the only
    /// account a sighted person got of a dead control was a 13-point symbol.
    /// `hasReattachAction: false` is the honest argument: reattachment is the
    /// desk's flow — it picks a replacement file through the capture canvas's
    /// own importer — and this sheet wires nothing to it, so the chip states
    /// what is true ("Not on this device") instead of naming an action that
    /// would do nothing here.
    ///
    /// Only a recording has bytes that can be somewhere else, so a words-only
    /// companion draws none: it is unplayable by construction rather than by
    /// misfortune, and "Not on this device" about text the band is displaying
    /// would be false.
    private var availabilityChip: WorkboardAudioCardChip? {
        guard companion.kind == .audio, !isPlayable else { return nil }
        return WorkboardAudioCardPresentation.chip(
            for: companion.availability,
            hasReattachAction: false
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if companion.kind == .audio {
                WorkboardAudioTransport(
                    materialID: companion.id,
                    player: player,
                    availability: companion.availability,
                    activation: .control,
                    dimension: 40,
                    placement: .scrim
                )
            }
            let face = WorkboardCompanionBand.face(for: companion)
            VStack(alignment: .leading, spacing: 3) {
                if let lead = face.leadLine {
                    Text(verbatim: lead)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                }
                if let transcript = face.trailingExcerpt {
                    Text(verbatim: transcript)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(transcriptLineLimit)
                        .multilineTextAlignment(.leading)
                }
                if let chip = availabilityChip {
                    HStack(spacing: 4) {
                        Image(systemName: chip.glyphName)
                        Text(chip.label)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    // The scrim's own literals, not the semantic tint: what is
                    // underneath is a photograph, exactly as for the words
                    // above.
                    .foregroundStyle(Color.white.opacity(0.85))
                }
                if companion.kind == .audio {
                    WorkboardAudioProgressTrack(player: player, placement: .scrim)
                }
            }
            // Only the transport is a control. The words let the touch through
            // to the picture underneath, exactly as the board's own band does.
            .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        // The SAME sentence the board's folded card speaks — availability,
        // what the transport is doing, and the clock once a clip has decoded.
        .accessibilityValue(Text(verbatim: WorkboardCompanionBand.accessibilityValue(
            for: companion,
            phase: player.phase,
            elapsed: player.elapsed,
            duration: player.duration
        )))
        // Offered ONLY where it does something. The sheet deliberately keeps a
        // companion whose bytes are still arriving — the label and the value
        // say so — but an action that returns the moment it is invoked is a
        // silent refusal, which is the one thing VoiceOver cannot report.
        .accessibilityActions {
            if isPlayable {
                Button {
                    play()
                } label: {
                    Text(WorkboardAudioTransport.actionTitle(for: player.phase))
                }
            }
        }
    }

    private func play() {
        guard isPlayable else { return }
        let id = companion.id
        player.toggle { try await ConversationStore.shared.loadWorkMaterialPayload(id: id) }
    }

    private var accessibilityLabel: String {
        var parts = [String(
            localized: WorkboardCompanionBand.accessibilityKindLabel(for: companion)
        )]
        // The same deduplicated pair the band draws: a recording named after
        // its own opening line said that line twice here.
        parts.append(contentsOf: WorkboardCompanionBand.face(for: companion).spokenParts)
        return parts.joined(separator: ", ")
    }
}

#endif
