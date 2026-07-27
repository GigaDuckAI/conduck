// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentImageGrid.swift
//
// The in-bubble image thumbnail layout for user-role messages, rendered
// ABOVE the caption from each `AttachmentRecord.thumbnailData`. Layout adapts
// to the image count (key UX decision #4 — intentional, no cap):
//   1   → one large thumb (~220pt)
//   2   → 50/50 side-by-side
//   3   → one large on top + two below
//   4   → 2×2 grid
//   5+  → 3-column grid
// Tapping a thumb fires `onTap(index)` so the host presents the swipeable
// full-screen gallery starting at that index.
//
// Also hosts the cross-platform `fullScreenCoverCompat(item:)` modifier the
// bubble uses to present `AttachmentFullScreenView` (`.fullScreenCover` on iOS,
// `.sheet` on macOS — the window has no full-screen cover).

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct AttachmentImageGrid: View {
    let attachments: [AttachmentRecord]
    let onTap: (Int) -> Void

    private let maxWidth: CGFloat = 240
    private let spacing: CGFloat = 4

    var body: some View {
        Group {
            switch attachments.count {
            case 0:
                EmptyView()
            case 1:
                thumb(0, side: 220)
            case 2:
                HStack(spacing: spacing) {
                    thumb(0, side: 118)
                    thumb(1, side: 118)
                }
            case 3:
                VStack(spacing: spacing) {
                    thumb(0, width: maxWidth, height: 150)
                    HStack(spacing: spacing) {
                        thumb(1, side: 118)
                        thumb(2, side: 118)
                    }
                }
            case 4:
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        thumb(0, side: 118)
                        thumb(1, side: 118)
                    }
                    HStack(spacing: spacing) {
                        thumb(2, side: 118)
                        thumb(3, side: 118)
                    }
                }
            default:
                gridLayout
            }
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
    }

    /// 5+ → a 3-column grid (intentional — no cap).
    private var gridLayout: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, _ in
                thumb(index, side: 76)
            }
        }
        .frame(width: maxWidth)
    }

    // MARK: - Thumbnail tile

    private func thumb(_ index: Int, side: CGFloat) -> some View {
        thumb(index, width: side, height: side)
    }

    private func thumb(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        Button {
            onTap(index)
        } label: {
            Group {
                if let data = attachments[index].thumbnailData, let image = Image.platformImage(from: data) {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppColors.cardBackground)
                        Image(systemName: "photo")
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "attachment.image.accessibility", defaultValue: "Image %lld of %lld")),
            index + 1, attachments.count
        )))
    }

}

// MARK: - Cross-platform full-screen presentation

/// `Int` start-index wrapper so it can drive an `item:`-style presentation.
private struct GalleryStartIndex: Identifiable {
    let id: Int
    var value: Int { id }
}

extension View {
    /// Present a full-screen gallery from an `Int?` start index —
    /// `.fullScreenCover` on iOS, `.sheet` on macOS (no full-screen cover in
    /// the menu-bar window).
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(
        item: Binding<Int?>,
        @ViewBuilder content: @escaping (Int) -> Content
    ) -> some View {
        let bound = Binding<GalleryStartIndex?>(
            get: { item.wrappedValue.map { GalleryStartIndex(id: $0) } },
            set: { item.wrappedValue = $0?.value }
        )
        #if os(iOS)
        self.fullScreenCover(item: bound) { wrapper in
            content(wrapper.value)
        }
        #else
        self.sheet(item: bound) { wrapper in
            content(wrapper.value)
                .frame(minWidth: 600, minHeight: 500)
        }
        #endif
    }
}
