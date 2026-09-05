// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentFullScreenView.swift
//
// The full-screen image gallery: a swipeable `TabView(.page)` over a list of
// pages, each a pinch-zoom (Magnify + Drag, double-tap reset) on a black
// background with a Done/X control.
//
// MODEL-FREE. A page is an `AttachmentGalleryPage` (id + optional thumbnail
// bytes + accessibility label) and the full bytes arrive through a caller-owned
// `loadFullBytes` closure, so the same gallery serves a chat message's
// attachments and the Work desk's image cards without either model reaching in
// here. Chat keeps its own initialiser, which maps `AttachmentRecord`s and
// closes over the store.
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
                )
            )
        }
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

struct AttachmentFullScreenView: View {
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

    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
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
        fullDecodeMaxPixel: Int? = nil
    ) {
        self.pages = pages
        self.startIndex = startIndex
        self.loadFullBytes = loadFullBytes
        self.fullDecodeMaxPixel = fullDecodeMaxPixel
        _selection = State(initialValue: min(max(0, startIndex), max(0, pages.count - 1)))
    }

    /// Chat's call site: the message's IMAGE attachments (already filtered to
    /// `isImage && !isServerFile`) plus the tapped index.
    ///
    /// The loader is keyed by ATTACHMENT ID, not by position: the store drops
    /// rows whose image bytes are empty, so an index-aligned lookup would show
    /// the wrong picture on every page after such a row. A page whose bytes are
    /// missing gets the failure state instead.
    init(imageAttachments: [AttachmentRecord], messageID: UUID, startIndex: Int) {
        let loader = MessageAttachmentBytesLoader(messageID: messageID)
        self.init(
            pages: AttachmentGalleryPage.pages(forImageAttachments: imageAttachments),
            startIndex: startIndex,
            loadFullBytes: { attachmentID in try await loader.bytes(for: attachmentID) },
            // Nil: this is the ZOOM surface for bytes the user already sent, so
            // Chat keeps decoding them at full resolution.
            fullDecodeMaxPixel: nil
        )
    }

    private var residentIndices: Set<Int> {
        AttachmentGalleryResidency.residentIndices(
            current: selection,
            count: pages.count,
            radius: residencyRadius
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
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
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
            #endif
            .ignoresSafeArea()

            doneButton
        }
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

    private var doneButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.25))
                        .padding(16)
                        .contentShape(Rectangle())
                }
                // Circular wash: the control is drawn as a filled circle, and a
                // rounded-square wash would tint only the corner slivers outside
                // it. The label's own 16pt padding already carries the frame well
                // past the 28pt floor, so `size` never binds here.
                .pointerIconButton(shape: .circle)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "attachment.fullscreen.done",
                    defaultValue: "Done"
                )))
            }
            Spacer()
        }
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
