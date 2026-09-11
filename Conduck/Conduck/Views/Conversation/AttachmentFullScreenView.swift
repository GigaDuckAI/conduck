// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentFullScreenView.swift
//
// The full-screen image gallery: one component, ONE cursor, and two containers.
// Each page is a pinch-zoom (Magnify + Drag, double-tap reset) on a black
// ground under a header that names what is on screen.
//
// TWO CONTAINERS, ONE COMPONENT. `.tabViewStyle(.page)` does not exist on
// native macOS, so a `TabView` there falls through to the default tab-bar style
// and — since no page sets a `.tabItem` — draws one UNLABELED segment per page:
// a segmented control escaping the sheet, not a page indicator. iOS therefore
// keeps the swipeable pager while macOS renders the CURRENT page alone with
// Previous/Next, arrow keys and the header's counter, which is how the Mac's
// own image viewers navigate. Both containers write the SAME
// `AttachmentGallerySelection`, so what the header names, what the actions slot
// acts on and what is drawn can never disagree. Separate galleries per platform
// would drift on exactly that contract.
//
// MODEL-FREE. A page is an `AttachmentGalleryPage` (id + optional thumbnail
// bytes + accessibility label + optional title) and the full bytes arrive
// through a caller-owned `loadFullBytes` closure, so the same gallery serves a
// chat message's attachments and the Work desk's image cards without either
// model reaching in here. Chat keeps its own initialiser, which maps
// `AttachmentRecord`s and closes over the store.
//
// ONE HEADER on both surfaces: the page's title, a counter while there is more
// than one page, the caller's own controls, and Close. The counter is why the
// iOS pager draws no index dots — the header already says which page this is,
// and the dots would repeat it over the bottom of the picture, where a caller
// (Work's folded recording) draws its transport.
//
// Load policy (key UX decision #4): render the page's thumbnail INSTANTLY
// (never a black screen), then swap to the full bytes with a spinner overlay
// until the full image is ready.
//
// MEMORY policy: loading is lazy PER PAGE and only the RESIDENT pages — the
// current one plus its neighbours — hold a decoded full-size image. A page that
// leaves that window drops its full image and keeps only the thumbnail, and
// system memory pressure — iOS's memory warning, the Mac's pressure source —
// shrinks the window to the current page alone. Without this a
// desk-wide gallery of originals would hold one full bitmap per card: at the
// 4096 px bound Work passes, three resident pages already cost ~192 MiB.

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// One page of the gallery. Deliberately carries no model type: the thumbnail
/// bytes are what renders instantly, `id` is the key the loader resolves, and
/// the label is whatever the presenting surface calls this picture.
struct AttachmentGalleryPage: Identifiable, Sendable {
    let id: UUID
    let thumbnailData: Data?
    let accessibilityLabel: String
    /// What the header calls this picture, or nil when the picture genuinely
    /// has no name — a pasted bitmap, a camera shot the source never named.
    ///
    /// NOT defaulted to the accessibility label: Chat's label is already the
    /// position ("Image 3 of 10") and the header draws its own counter, so
    /// falling back would print the same fact twice on the one surface that
    /// exists to say it once.
    var title: String?
}

extension AttachmentGalleryPage {
    /// Chat's mapping: image attachments (already filtered to local images and
    /// ordered by sequence) become numbered pages. Nonisolated because it is
    /// pure — it exists as a named function so the mapping is testable without
    /// building a view.
    nonisolated static func pages(
        forImageAttachments attachments: [AttachmentRecord]
    ) -> [AttachmentGalleryPage] {
        attachments.enumerated().map { index, attachment in
            AttachmentGalleryPage(
                id: attachment.id,
                thumbnailData: attachment.thumbnailData,
                accessibilityLabel: String(
                    format: String(localized: LocalizedStringResource(
                        "attachment.image.accessibility", defaultValue: "Image %lld of %lld")),
                    index + 1, attachments.count
                ),
                // The name the person's own source carried. A photo-library
                // pick, a camera shot or a pasted bitmap frequently has none,
                // and the header says nothing rather than inventing one.
                title: AttachmentGalleryHeader.displayTitle(attachment.filename)
            )
        }
    }
}

/// The header's text rules, as pure functions.
///
/// Split out because they are the two places a header lies: a title that is
/// really a placeholder ("" or a name of nothing but spaces), and a counter
/// drawn over a gallery that has only one page — which announces a collection
/// the person cannot page through.
enum AttachmentGalleryHeader {
    /// A page title, or nil when there is nothing worth naming.
    nonisolated static func displayTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// "3 of 10", or nil for a gallery of one page.
    ///
    /// The index is clamped for the same reason the cursor is: the pages can
    /// change under a value that was valid when the pager wrote it.
    nonisolated static func counter(index: Int, count: Int) -> String? {
        guard count > 1 else { return nil }
        let position = min(max(0, index), count - 1) + 1
        return String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "attachment.gallery.position",
                defaultValue: "%1$lld of %2$lld"
            )),
            Int64(position),
            Int64(count)
        )
    }
}

/// The chrome's fixed dimensions, named so a caller drawing its own overlay on
/// the gallery can stay clear of the header instead of guessing at it.
enum AttachmentGalleryChrome {
    /// The header's height, top of the safe area downwards.
    static let headerHeight: CGFloat = 52
}

extension AttachmentGalleryPage {
    /// The page a selection index names, clamped to the gallery, or nil when
    /// there are no pages.
    ///
    /// A named function rather than a line inside the view because it IS the
    /// actions slot's contract: what the slot is handed is the page CURRENTLY
    /// on screen, not the one the presentation opened on, and a swipe changes
    /// it. Clamped for the same reason `startIndex` is — the caller's index
    /// describes a list that may have changed underneath it.
    nonisolated static func id(
        atSelection selection: Int,
        in pages: [AttachmentGalleryPage]
    ) -> UUID? {
        guard !pages.isEmpty else { return nil }
        return pages[min(max(0, selection), pages.count - 1)].id
    }
}

/// The page the gallery is on.
///
/// A small reference type rather than a bare `@State Int` because THREE things
/// read it — the pager, the residency window, and the actions slot — and the
/// slot's contract is the one that cannot be checked by looking at the screen:
/// what a Share tap acts on must follow the swipe, not the index the gallery
/// opened at. Both look identical on the first page. Owning the cursor in one
/// object is what lets that chain be driven and asserted without a rendered
/// pager, so the contract is held by a test rather than by review.
@MainActor
@Observable
final class AttachmentGallerySelection {
    /// The current page's index. Clamped on read rather than on write, because
    /// the pages can change under a cursor that was valid when it was set.
    var index: Int

    init(startIndex: Int, pageCount: Int) {
        index = pageCount > 0 ? min(max(0, startIndex), pageCount - 1) : 0
    }

    /// The page id everything keyed by page — the loader, the actions slot —
    /// resolves against.
    func pageID(in pages: [AttachmentGalleryPage]) -> UUID? {
        AttachmentGalleryPage.id(atSelection: index, in: pages)
    }
}

/// Which pages may hold a decoded full-size image. Pure arithmetic, split out
/// so the window is provable without a running gallery.
enum AttachmentGalleryResidency {
    /// The indices within `radius` of `current`, clamped to the gallery.
    ///
    /// `current` is clamped rather than rejected: a caller's start index is
    /// user-supplied (a tapped tile in a list that may have changed underneath),
    /// and an out-of-range one must still leave a page resident to render.
    nonisolated static func residentIndices(current: Int, count: Int, radius: Int) -> Set<Int> {
        guard count > 0 else { return [] }
        let clampedCurrent = min(max(0, current), count - 1)
        let reach = max(0, radius)
        let lower = max(0, clampedCurrent - reach)
        let upper = min(count - 1, clampedCurrent + reach)
        return Set(lower...upper)
    }
}

/// - Parameter PageActions: the caller's own controls for the page currently on
///   screen. `EmptyView` — Chat's case — adds nothing to the chrome at all: the
///   slot is a generic parameter rather than an optional closure so a gallery
///   with no actions builds no view for them.
struct AttachmentFullScreenView<PageActions: View>: View {
    /// The pages, in display order.
    let pages: [AttachmentGalleryPage]
    /// Initial page (the tapped thumbnail's index into `pages`).
    let startIndex: Int
    /// Full-resolution bytes for one page id. Called lazily, once per page, when
    /// the page becomes resident — never up front for the whole gallery.
    let loadFullBytes: @Sendable (UUID) async throws -> Data
    /// Long-edge bound for the FULL decode, or nil for full resolution.
    ///
    /// Non-nil switches the page to the STRICT ImageIO path
    /// (`Image.decodedStrictlyBounded`), which reports failure instead of
    /// falling back to an UNBOUNDED platform decode — the fallback in
    /// `Image.decoded(from:maxPixel:)` would defeat the bound on exactly the
    /// payloads a bound exists for (a camera original the desk stores verbatim).
    let fullDecodeMaxPixel: Int?
    /// Controls for the page on screen, built from ITS id.
    ///
    /// By page id and not by index: the caller resolves the picture from the
    /// same key the loader does, so an action fired here can never act on a
    /// neighbour. It is re-evaluated on every swipe, which is what makes the
    /// action belong to the picture rather than to the presentation.
    ///
    /// The gallery decides nothing about what goes in here and reads nothing
    /// back — pages stay plain `Sendable` data with no UI closures on them.
    let pageActions: (UUID) -> PageActions

    @Environment(\.dismiss) private var dismiss

    /// The cursor the pager binds to. `@State` of a reference the view owns, so
    /// it survives redraws; injectable so a test can move it exactly as a swipe
    /// does.
    @State private var selection: AttachmentGallerySelection
    /// How far from the current page a decoded full image survives. Drops to 0
    /// under system memory pressure and STAYS there for the life of this
    /// presentation:
    /// re-widening the window would re-run the very allocation the system just
    /// complained about, and a fresh presentation starts at 1 again.
    @State private var residencyRadius = 1

    init(
        pages: [AttachmentGalleryPage],
        startIndex: Int,
        loadFullBytes: @escaping @Sendable (UUID) async throws -> Data,
        fullDecodeMaxPixel: Int? = nil,
        selection: AttachmentGallerySelection? = nil,
        @ViewBuilder pageActions: @escaping (UUID) -> PageActions
    ) {
        self.pages = pages
        self.startIndex = startIndex
        self.loadFullBytes = loadFullBytes
        self.fullDecodeMaxPixel = fullDecodeMaxPixel
        self.pageActions = pageActions
        _selection = State(
            initialValue: selection
                ?? AttachmentGallerySelection(startIndex: startIndex, pageCount: pages.count)
        )
    }

    /// The page the person is looking at. Derived from the CURSOR — never from
    /// `startIndex`, which describes only where the presentation opened.
    var currentPageID: UUID? {
        selection.pageID(in: pages)
    }

    /// The cursor's position inside the pages that exist right now, or nil for
    /// an empty gallery. Every page-dependent thing on screen — the drawn
    /// picture on macOS, the header, the actions slot — resolves through this
    /// one clamp rather than subscripting `pages` with a raw index.
    private var currentIndex: Int? {
        guard !pages.isEmpty else { return nil }
        return min(max(0, selection.index), pages.count - 1)
    }

    private var currentPage: AttachmentGalleryPage? {
        currentIndex.map { pages[$0] }
    }

    /// The caller's controls for the page on screen, exactly as the chrome
    /// draws them. Building this value invokes the caller's closure with the
    /// current page's id, which is the whole chain a Share tap runs through —
    /// so moving the cursor and building this again is what a swipe does.
    @ViewBuilder
    var currentPageActions: some View {
        if let currentPageID {
            pageActions(currentPageID)
        }
    }

    private var residentIndices: Set<Int> {
        AttachmentGalleryResidency.residentIndices(
            current: selection.index,
            count: pages.count,
            radius: residencyRadius
        )
    }

    /// The pager writes the cursor the actions slot reads, so a swipe and a
    /// Share tap can never disagree about which picture is on screen.
    private var pagerSelection: Binding<Int> {
        Binding(
            get: { selection.index },
            set: { selection.index = $0 }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            pager

            topControls
        }
        // ONE ideal frame for every surface that presents this gallery, set
        // here rather than at each call site: a picture wants the size it
        // deserves rather than the floor a minimum-only sheet opens at, and two
        // callers picking their own numbers is how the same component came to
        // open at two different sizes. The main window's default is 1100x760,
        // so this reads as a preview of what is behind it rather than as a
        // second window.
        .galleryDesktopFrame()
        #if os(iOS)
        // The neighbours are the discretionary half of the window — under
        // pressure the current page is the only one the user is looking at.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            residencyRadius = 0
        }
        #endif
        #if os(macOS)
        // The same rule on the Mac, where the system's signal is a dispatch
        // memory-pressure source rather than a notification: AppKit posts no
        // memory warning at all, so without this the neighbours a Mac gallery
        // decoded — up to two more 4096 px bitmaps — stay resident exactly when
        // the system is asking for memory back.
        //
        // The `.task` owns the source: it is torn down when this presentation
        // goes away, and the loop ends at the FIRST signal because the radius
        // stays 0 for the life of the presentation, as on iOS.
        .task {
            for await _ in MemoryPressureSignal.warnings() {
                residencyRadius = 0
                break
            }
        }
        #endif
    }

    /// The picture itself, in the container its platform can actually draw.
    @ViewBuilder
    private var pager: some View {
        #if os(iOS)
        TabView(selection: pagerSelection) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                ZoomableImagePage(
                    thumbnailData: page.thumbnailData,
                    isResident: residentIndices.contains(index),
                    fullDecodeMaxPixel: fullDecodeMaxPixel,
                    loadFullBytes: { [loadFullBytes] in try await loadFullBytes(page.id) }
                )
                .accessibilityLabel(Text(page.accessibilityLabel))
                .tag(index)
            }
        }
        // No index dots: the header's counter says which page this is, and the
        // dots sit exactly where a caller draws its own bottom chrome.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        macPage
        #endif
    }

    #if os(macOS)
    /// The Mac's container: the CURRENT page, drawn directly.
    ///
    /// `.id(page.id)` is the whole navigation contract — zoom, pan, the decoded
    /// original, a failed page's Retry are all state of `ZoomableImagePage`, so
    /// identity per page is what makes Next start clean instead of arriving
    /// magnified on the last picture's failure.
    @ViewBuilder
    private var macPage: some View {
        if let currentIndex, let page = currentPage {
            ZStack {
                ZoomableImagePage(
                    thumbnailData: page.thumbnailData,
                    isResident: residentIndices.contains(currentIndex),
                    fullDecodeMaxPixel: fullDecodeMaxPixel,
                    loadFullBytes: { [loadFullBytes] in try await loadFullBytes(page.id) }
                )
                .accessibilityLabel(Text(page.accessibilityLabel))
                .id(page.id)
                .ignoresSafeArea()

                if pages.count > 1 {
                    HStack {
                        stepButton(offset: -1, symbol: "chevron.left", shortcut: .leftArrow)
                        Spacer()
                        stepButton(offset: 1, symbol: "chevron.right", shortcut: .rightArrow)
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    /// One navigation control, which is also where the arrow key lands.
    ///
    /// The key is a `keyboardShortcut` on the button rather than an
    /// `onKeyPress` on the container: a sheet gives no control initial focus,
    /// so a key handler that needs focus does nothing until the person clicks
    /// first — while a shortcut on a control in the frontmost window does not.
    private func stepButton(
        offset: Int,
        symbol: String,
        shortcut: KeyEquivalent
    ) -> some View {
        let target = (currentIndex ?? 0) + offset
        let isReachable = pages.indices.contains(target)
        return Button {
            guard pages.indices.contains(target) else { return }
            selection.index = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
                .contentShape(Circle())
        }
        .pointerIconButton(size: 44, shape: .circle)
        .keyboardShortcut(shortcut, modifiers: [])
        .disabled(!isReachable)
        .opacity(isReachable ? 1 : 0)
        .accessibilityLabel(Text(offset < 0
            ? LocalizedStringResource(
                "attachment.gallery.previous",
                defaultValue: "Previous Image"
            )
            : LocalizedStringResource(
                "attachment.gallery.next",
                defaultValue: "Next Image"
            )))
    }
    #endif

    /// The chrome over the picture: what this page is called and where it sits
    /// in the collection on the leading side, the caller's own controls and
    /// Close on the trailing one. Everything is in the SAME row so a gallery
    /// that supplies actions cannot push Close off its corner, and the row is
    /// the one header both Chat and Work draw.
    private var topControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if let title = currentPage?.title,
                       let displayed = AttachmentGalleryHeader.displayTitle(title) {
                        Text(verbatim: displayed)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let counter = AttachmentGalleryHeader.counter(
                        index: selection.index,
                        count: pages.count
                    ) {
                        Text(verbatim: counter)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                currentPageActions

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.25))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                // Circular wash: the control is drawn as a filled circle, and a
                // rounded-square wash would tint only the corner slivers outside
                // it. The label's own frame already carries the target well past
                // the 28pt floor, so `size` never binds here.
                .pointerIconButton(shape: .circle)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "attachment.fullscreen.done",
                    defaultValue: "Done"
                )))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: AttachmentGalleryChrome.headerHeight)
            // A picture can be any colour, so the words above it carry their own
            // ground rather than trusting the pixels underneath.
            .background {
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }

            Spacer()
        }
    }
}

private extension View {
    /// The gallery's desktop sheet frame. Declared here rather than borrowed
    /// from a Work helper: the gallery belongs to neither surface, and a shared
    /// component reaching into one caller's folder for its own geometry is the
    /// dependency that keeps the two sizes drifting apart.
    func galleryDesktopFrame() -> some View {
        #if os(macOS)
        frame(
            minWidth: 640,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 640,
            maxHeight: .infinity
        )
        #else
        self
        #endif
    }
}

/// The galleries that add no chrome of their own. Written as a constrained
/// extension because Swift cannot default a generic parameter: this is what
/// makes `pageActions` genuinely optional at the call site, and it is why
/// Chat's two call sites are untouched by the slot's existence.
extension AttachmentFullScreenView where PageActions == EmptyView {
    init(
        pages: [AttachmentGalleryPage],
        startIndex: Int,
        loadFullBytes: @escaping @Sendable (UUID) async throws -> Data,
        fullDecodeMaxPixel: Int? = nil
    ) {
        self.init(
            pages: pages,
            startIndex: startIndex,
            loadFullBytes: loadFullBytes,
            fullDecodeMaxPixel: fullDecodeMaxPixel,
            selection: nil,
            pageActions: { _ in EmptyView() }
        )
    }

}

/// Chat's gallery: the same component, with the system's own Share control in
/// the header's actions slot.
extension AttachmentFullScreenView where PageActions == AttachmentGalleryShareLink {
    /// Chat's call site: the message's IMAGE attachments (already filtered to
    /// `isImage && !isServerFile`) plus the tapped index.
    ///
    /// The loader is keyed by ATTACHMENT ID, not by position: the store drops
    /// rows whose image bytes are empty, so an index-aligned lookup would show
    /// the wrong picture on every page after such a row. A page whose bytes are
    /// missing gets the failure state instead.
    ///
    /// ONE loader for both the gallery and the Share item, so a share reads the
    /// same bytes the page is showing and the in-flight fetch they may both be
    /// waiting on is shared rather than duplicated.
    init(imageAttachments: [AttachmentRecord], messageID: UUID, startIndex: Int) {
        let loader = MessageAttachmentBytesLoader(messageID: messageID)
        let pages = AttachmentGalleryPage.pages(forImageAttachments: imageAttachments)
        self.init(
            pages: pages,
            startIndex: startIndex,
            loadFullBytes: { attachmentID in try await loader.bytes(for: attachmentID) },
            // Nil: this is the ZOOM surface for bytes the user already sent, so
            // Chat keeps decoding them at full resolution.
            fullDecodeMaxPixel: nil,
            selection: nil
        ) { pageID in
            AttachmentGalleryShareLink(
                item: AttachmentGalleryShareItem(
                    name: AttachmentGalleryHeader.shareName(
                        for: pageID,
                        in: pages
                    ),
                    // The picker's row title and the file the destination
                    // writes are derived from the SAME name, so a person who
                    // recognised the row recognises the file.
                    filename: AttachmentGalleryShareItem.suggestedFilename(
                        for: pageID,
                        in: pages
                    ),
                    load: { try await loader.bytes(for: pageID) }
                )
            )
        }
    }
}

extension AttachmentGalleryHeader {
    /// What a shared page is called in the system's own preview.
    ///
    /// A page with no title still needs a name here — a blank share preview
    /// reads as a broken row — so the accessibility label ("Image 3 of 10")
    /// stands in, which is exactly what the header omits and the share sheet
    /// needs.
    nonisolated static func shareName(
        for pageID: UUID,
        in pages: [AttachmentGalleryPage]
    ) -> String {
        guard let page = pages.first(where: { $0.id == pageID }) else { return "" }
        return displayTitle(page.title) ?? page.accessibilityLabel
    }
}

#if os(macOS)
/// The Mac's memory-warning equivalent, as an async sequence.
///
/// macOS has no `didReceiveMemoryWarningNotification`; the system's signal is a
/// dispatch memory-pressure source. Wrapping it in an `AsyncStream` is what
/// keeps the gallery's rule in one place: the consumer is a `.task`, so the
/// source is created with the presentation and cancelled with it, and no view
/// state is mutated from a queue callback.
enum MemoryPressureSignal {
    /// Warning-level pressure or worse. The stream ends when the consuming task
    /// is cancelled, which cancels the underlying source with it.
    static func warnings() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .main
            )
            source.setEventHandler { continuation.yield(()) }
            continuation.onTermination = { _ in source.cancel() }
            source.activate()
        }
    }
}
#endif

// MARK: - Chat's byte loader

/// Single-flight loader for one message's local attachment bytes, keyed by
/// attachment id.
///
/// Holds NO bytes once a load resolves — the gallery's memory rule is that only
/// resident pages keep full-size pixels, and a cache here would quietly undo it.
/// The in-flight fetch IS shared, so the resident window's pages asking at the
/// same moment cost one Core Data fault instead of three.
private actor MessageAttachmentBytesLoader {
    enum LoadError: Error {
        /// No local bytes for this attachment (empty image row, or a row that
        /// vanished between the tap and the load).
        case bytesUnavailable
    }

    private let messageID: UUID
    private var inFlight: Task<[UUID: Data], Error>?

    init(messageID: UUID) {
        self.messageID = messageID
    }

    func bytes(for attachmentID: UUID) async throws -> Data {
        let payloads = try await loadAll()
        guard let data = payloads[attachmentID], !data.isEmpty else {
            throw LoadError.bytesUnavailable
        }
        return data
    }

    private func loadAll() async throws -> [UUID: Data] {
        if let inFlight { return try await inFlight.value }
        let messageID = self.messageID
        // Unstructured on purpose: one page's cancellation (it swiped out of the
        // resident window) must not cancel the fetch its neighbour is awaiting.
        let task = Task { try await ConversationStore.shared.loadLocalAttachmentPayloads(for: messageID) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

// MARK: - Zoomable page

/// One page of the gallery: renders the thumbnail instantly, loads and swaps to
/// full bytes while it is resident, and supports pinch-zoom + drag +
/// double-tap-reset.
private struct ZoomableImagePage: View {
    let thumbnailData: Data?
    /// True while this page may hold a decoded full image. Flipping it false
    /// releases that image (the thumbnail stays) and cancels an in-flight load.
    let isResident: Bool
    let fullDecodeMaxPixel: Int?
    let loadFullBytes: @Sendable () async throws -> Data

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// The DECODED images, held in state so a zoom/pan frame re-reads them
    /// instead of re-decoding. A computed property meant every
    /// `MagnifyGesture`/`DragGesture` update — dozens per second — re-ran
    /// `Image.platformImage(from:)` over the FULL-SIZE JPEG on the main actor.
    @State private var thumbnailImage: Image?
    @State private var fullImage: Image?
    @State private var isLoadingFull = false
    /// The loader threw, or the bytes did not decode. Terminal until Retry — a
    /// failed page must not spin forever, and must not re-attempt on every body
    /// pass either.
    @State private var didFail = false
    /// Bumped by Retry to re-run the load task.
    @State private var attempt = 0

    /// What the gestures act on: the full image once it is decoded, the
    /// thumbnail meanwhile.
    private var displayedImage: Image? { fullImage ?? thumbnailImage }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let image = displayedImage {
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify)
                        // Pan only WHEN zoomed in. An always-active one-finger
                        // DragGesture (even one that no-ops at scale 1) keeps its
                        // recognizer claiming the touch and blocks the parent
                        // `TabView(.page)` horizontal page-swipe — so the gallery
                        // can't page between images. Gate the recognizer off
                        // (`.none`) at scale 1 so swipes reach the TabView, and on
                        // (`.all`) once zoomed so the drag can pan.
                        .simultaneousGesture(drag, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) { resetZoom() }
                } else if didFail {
                    failureView
                } else {
                    // No thumbnail and no full bytes yet — keep it black-free
                    // with a spinner so it never looks broken.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }

                if displayedImage != nil, didFail {
                    // The thumbnail carried the page but the original did not
                    // arrive: offer the retry rather than a spinner that would
                    // never resolve.
                    retryButton
                } else if isLoadingFull, fullImage == nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .padding(10)
                        .background(.black.opacity(0.35), in: Circle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard thumbnailImage == nil, let thumbnailData else { return }
            // Thumbnails are small and stay for the life of the page — they are
            // what keeps a released page from going black.
            thumbnailImage = await Image.decoded(from: thumbnailData)
        }
        // Re-runs when the page enters the resident window and when Retry bumps
        // the attempt; leaving the window cancels the in-flight load.
        .task(id: FullLoadKey(isResident: isResident, attempt: attempt)) {
            await loadFullImage()
        }
        .onChange(of: isResident) { _, resident in
            guard !resident else { return }
            // Release the expensive half of the page. The thumbnail stays, so a
            // swipe back renders instantly while the original reloads.
            fullImage = nil
            isLoadingFull = false
            didFail = false
        }
    }

    /// The `.task` identity: both inputs must re-arm the load.
    private struct FullLoadKey: Equatable {
        let isResident: Bool
        let attempt: Int
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.85))
            Text(LocalizedStringResource(
                "attachment.gallery.loadFailed",
                defaultValue: "This image couldn't be opened."
            ))
            .font(.callout)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            retryButton
        }
        .padding(24)
    }

    private var retryButton: some View {
        Button {
            didFail = false
            attempt += 1
        } label: {
            Text(LocalizedStringResource(
                "attachment.gallery.retry",
                defaultValue: "Retry"
            ))
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func loadFullImage() async {
        guard isResident, fullImage == nil, !didFail else { return }
        isLoadingFull = true
        defer { isLoadingFull = false }
        do {
            let data = try await loadFullBytes()
            guard !Task.isCancelled else { return }
            let image: Image?
            if let fullDecodeMaxPixel {
                image = await Image.decodedStrictlyBounded(from: data, maxPixel: fullDecodeMaxPixel)
            } else {
                // Full resolution deliberately: this is the ZOOM surface, so a
                // bounded decode would cap what the user can magnify to.
                image = await Image.decoded(from: data)
            }
            guard !Task.isCancelled else { return }
            if let image {
                fullImage = image
            } else {
                didFail = true
            }
        } catch {
            // A cancelled load is the residency window doing its job, not a
            // failure — the page must stay retryable without showing an error.
            guard !Task.isCancelled else { return }
            didFail = true
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value.magnification, 6))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }

}
