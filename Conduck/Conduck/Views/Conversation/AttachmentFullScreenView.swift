// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentFullScreenView.swift
//
// The full-screen image gallery presented when a user taps a thumbnail in
// a chat bubble. A swipeable `TabView(.page)` over the message's image
// attachments, each page a pinch-zoom (Magnify + Drag, double-tap reset) on a
// black background with a Done/X control.
//
// Load policy (key UX decision #4): render the `AttachmentRecord.thumbnailData`
// INSTANTLY (never a black screen), then swap to the full bytes loaded from
// `ConversationStore.loadAttachmentData(for:)` with a spinner overlay until the
// full image is ready. The store returns ALL image bytes for the message
// ordered by sequence, so a single load resolves every page.
//
// Accepts the image attachments + a start index (the tapped thumb).

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct AttachmentFullScreenView: View {
    /// The IMAGE attachments of the message (already filtered to `isImage`),
    /// ordered by sequence — index aligns with `loadAttachmentData`'s result.
    let imageAttachments: [AttachmentRecord]
    /// The owning message id — drives the full-bytes load.
    let messageID: UUID
    /// Initial page (the tapped thumbnail's index into `imageAttachments`).
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
    /// Full image bytes by index (sequence-aligned). Empty until loaded.
    @State private var fullBytesByIndex: [Int: Data] = [:]
    @State private var isLoading = true

    init(imageAttachments: [AttachmentRecord], messageID: UUID, startIndex: Int) {
        self.imageAttachments = imageAttachments
        self.messageID = messageID
        self.startIndex = startIndex
        _selection = State(initialValue: min(max(0, startIndex), max(0, imageAttachments.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(imageAttachments.enumerated()), id: \.offset) { index, attachment in
                    ZoomableImagePage(
                        thumbnailData: attachment.thumbnailData,
                        fullData: fullBytesByIndex[index],
                        showSpinner: isLoading && fullBytesByIndex[index] == nil
                    )
                    .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: imageAttachments.count > 1 ? .automatic : .never))
            #endif
            .ignoresSafeArea()

            doneButton
        }
        .task { await loadFullBytes() }
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

    private func loadFullBytes() async {
        defer { isLoading = false }
        guard let bytes = try? await ConversationStore.shared.loadAttachmentData(for: messageID),
              !bytes.isEmpty else { return }
        var map: [Int: Data] = [:]
        for (index, data) in bytes.enumerated() { map[index] = data }
        fullBytesByIndex = map
    }
}

// MARK: - Zoomable page

/// One page of the gallery: renders the thumbnail instantly, swaps to full
/// bytes when available, and supports pinch-zoom + drag + double-tap-reset.
private struct ZoomableImagePage: View {
    let thumbnailData: Data?
    let fullData: Data?
    let showSpinner: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let image = displayImage {
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
                } else {
                    // No thumbnail and no full bytes yet — keep it black-free
                    // with a spinner so it never looks broken.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }

                if showSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .padding(10)
                        .background(.black.opacity(0.35), in: Circle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Prefer the full bytes when loaded; otherwise the instant thumbnail.
    private var displayImage: Image? {
        if let fullData, let img = Image.platformImage(from: fullData) { return img }
        if let thumbnailData, let img = Image.platformImage(from: thumbnailData) { return img }
        return nil
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
