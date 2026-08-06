// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Transcript Appending

/// Merge a fresh STT transcript into the composer draft for the voice-populates-
/// the-field flow (Part 1). The transcript is APPENDED to whatever the user has
/// already typed/dictated — it NEVER replaces an existing draft — so a user can
/// dictate, edit, dictate again, then send once with attachments still staged.
///
/// SwiftUI's `TextField` exposes no caret position, so V1 appends at the end
/// rather than inserting at the cursor (acceptable per the approved plan).
///
/// Rules:
///   - the transcript is trimmed of surrounding whitespace/newlines first;
///   - an empty existing draft → return the trimmed transcript verbatim;
///   - otherwise append with a SINGLE separating space, but only when the
///     existing draft doesn't already end in whitespace/newline (so we never
///     double a space or stack a space after a trailing newline).
func appendingTranscript(_ transcript: String, to existing: String) -> String {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !existing.isEmpty else { return trimmed }
    guard !trimmed.isEmpty else { return existing }
    if let last = existing.last, last.isWhitespace || last.isNewline {
        return existing + trimmed
    }
    return existing + " " + trimmed
}

// MARK: - View Extensions

extension View {
    /// Card background with optional colored border
    @ViewBuilder
    func glassCardBackground(borderColor: Color? = nil, borderWidth: CGFloat = 1) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackgroundElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(borderColor ?? AppColors.borderSubtle, lineWidth: borderWidth)
                    }
            }
            .shadow(color: AppColors.shadow.opacity(0.15), radius: 10, y: 4)
    }

    /// Scrolls only when content exceeds available space; centers content when it fits.
    func scrollableWhenNeeded() -> some View {
        GeometryReader { geometry in
            ScrollView {
                self
                    .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Numbered Step Row (Onboarding)

/// Reusable numbered step indicator used across onboarding instruction cards.
/// The badge scales with Dynamic Type (`@ScaledMetric`) so the digit can't
/// outgrow the circle at accessibility sizes, and the row aligns on the first
/// text baseline so the badge stays paired with line 1 of a tall, wrapped
/// sentence rather than floating against its vertical center.
struct NumberedStepRow: View {
    let number: Int
    let text: LocalizedStringKey

    @ScaledMetric private var badgeSize: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: badgeSize, height: badgeSize)

                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.tint)
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cross-platform image decoding

extension Image {
    /// Decode raw image bytes into a SwiftUI `Image` (iOS `UIImage` / macOS
    /// `NSImage`); `nil` if undecodable. Shared by the attachment grid, preview
    /// strip, and full-screen gallery. (The Watch target keeps its own analogue.)
    ///
    /// SYNCHRONOUS, and therefore ON the caller's thread — `nonisolated` marks
    /// that fact rather than changing it (it is what lets `decoded` reach this
    /// as a fallback from its off-main hop; from a view `body` the caller is
    /// still the main actor). Only call it from a view `body` for bytes that are
    /// KNOWN small (an `ImageProcessor` thumbnail). For original picked bytes or
    /// stored full-size images use `decoded(from:maxPixel:)`, which moves the
    /// work off the main actor and can bound the decode.
    nonisolated static func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #elseif os(macOS)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }

    /// Decode `data` OFF the main actor, optionally bounding the result's long
    /// edge to `maxPixel`. The SwiftUI-facing wrapper over
    /// `ImageProcessor.displayCGImage(from:maxPixel:)`, which owns the ImageIO
    /// options — this deliberately re-implements none of them.
    ///
    /// `@concurrent` is what actually moves the decode off the main actor. A
    /// plain `nonisolated async` would NOT: this target builds with
    /// `SWIFT_APPROACHABLE_CONCURRENCY`, under which a `nonisolated async`
    /// function runs on the CALLER's executor — and a `.task { }` in a view body
    /// makes that caller the main actor. Awaiting a synchronous `nonisolated`
    /// helper from a view is likewise no hop at all.
    ///
    /// The `CGImage` is what crosses the actor boundary, not the platform image
    /// type: `NSImage`/`UIImage` are not `Sendable`, so both are constructed on
    /// the way out of the hop.
    /// FALLS BACK to `platformImage(from:)` when ImageIO declines the bytes,
    /// because the two decoders do not accept the same set of inputs and the
    /// composer's inline-only `.image` tile is staged from exactly the bytes
    /// ImageIO already refused: `stageImage` drops to `.image(original)` when
    /// `ImageProcessor.process` throws, which is when `CGImageSourceCreateWithData`
    /// or the thumbnail call failed. Routing that tile through ImageIO alone
    /// would show a permanent placeholder glyph for a picture that stages,
    /// sends, and displays fine everywhere else. `NSImage`/`UIImage` also take
    /// formats ImageIO thumbnailing does not (PDF-as-image, some TIFF/EPS
    /// variants off a drag or paste).
    ///
    /// The fallback is UNBOUNDED by `maxPixel` — it is a correctness net for
    /// bytes that would otherwise not render at all, and it is only reachable
    /// for payloads ImageIO refused, so it cannot become the common path.
    @concurrent
    nonisolated static func decoded(from data: Data, maxPixel: Int? = nil) async -> Image? {
        guard let cgImage = ImageProcessor.displayCGImage(from: data, maxPixel: maxPixel) else {
            return platformImage(from: data)
        }
        #if os(iOS)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #elseif os(macOS)
        return Image(nsImage: NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        ))
        #else
        return nil
        #endif
    }
}

/// A staged composer attachment's image tile: decodes ONCE per stable tile
/// identity, off the main actor, and re-reads the decoded result on every later
/// body pass.
///
/// Exists because the decode used to sit inline in the strip's `body`, so every
/// composer invalidation — a keystroke, an upload-progress tick, any staging
/// mutation — re-decoded the bytes on the main actor. For a `.dualImage` those
/// bytes were the user's ORIGINAL camera file.
struct StagedImageTile<Placeholder: View>: View {
    /// The staged tile's stable id. Half the decode key.
    let id: UUID
    /// Bytes to decode. Prefer an already-small payload (a processed thumbnail);
    /// `maxPixel` bounds the decode when the bytes are an original.
    let data: Data
    /// Long-edge decode bound, or nil for full resolution.
    let maxPixel: Int?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: Image?

    init(
        id: UUID,
        data: Data,
        maxPixel: Int?,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.id = id
        self.data = data
        self.maxPixel = maxPixel
        self.placeholder = placeholder
        // Seeded from the cache SYNCHRONOUSLY, before the first render. `.task`
        // cannot do this job: it runs after the view has already been laid out,
        // so a cache hit resolved there still shows the placeholder for a frame.
        // In a message bubble that frame is the whole problem — see the cache's
        // own note on lazy recycling.
        _image = State(initialValue: DecodedImageCache.shared[
            DecodeKey(id: id, byteCount: data.count, maxPixel: maxPixel)
        ])
    }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        // Keyed on identity + payload SIZE, never on the bytes: a `Data` id would
        // hash the whole payload on every body pass, reintroducing the per-render
        // cost in a different shape. The id is stable for a tile's lifetime and
        // the size moves if its payload is ever replaced, which together is
        // enough — a tile's resolved payload is written once at staging.
        .task(id: DecodeKey(id: id, byteCount: data.count, maxPixel: maxPixel)) {
            let key = DecodeKey(id: id, byteCount: data.count, maxPixel: maxPixel)
            if let cached = DecodedImageCache.shared[key] {
                image = cached
                return
            }
            let resolved = await Image.decoded(from: data, maxPixel: maxPixel)
            // `Image.decoded` is not cancellation-aware — it has no suspension
            // point to throw at — so a `.task` SwiftUI already cancelled still
            // resumes here with a fully decoded result. Without this guard that
            // result is written anyway, and a superseded decode that finishes
            // LAST wins: the full-screen viewer's thumbnail pass can land after
            // its full-resolution pass and pin the zoom surface to the blurry
            // copy for the life of the page.
            guard !Task.isCancelled else { return }
            if let resolved { DecodedImageCache.shared[key] = resolved }
            image = resolved
        }
    }
}

/// Cache key for a decoded display image. `maxPixel` is part of it because the
/// same payload is legitimately decoded at two different bounds (the strip's
/// 256px tile and the gallery's full-resolution page), and returning one where
/// the other was asked for would silently change what the user sees.
private struct DecodeKey: Hashable {
    let id: UUID
    let byteCount: Int
    let maxPixel: Int?

    var cacheKey: NSString {
        "\(id.uuidString)|\(byteCount)|\(maxPixel.map(String.init) ?? "full")" as NSString
    }
}

/// Process-wide cache of decoded display images.
///
/// `StagedImageTile` holds its decode in `@State`, which is scoped to the view's
/// structural identity — and both of its heavy callers live inside LAZY,
/// RECYCLING containers (`LazyVGrid` inside a message bubble, itself inside the
/// lazily-recycled thread list). Scrolling a bubble off screen therefore tears
/// the `@State` down, so scrolling back would flash the placeholder glyph on
/// every image and pay a fresh ImageIO decode for bytes that were already
/// decoded seconds ago. That is strictly worse than the synchronous decode this
/// tile replaced, which at least never flashed. The cache makes a scroll-back a
/// hit, so the tile keeps the off-main win on FIRST decode without regressing
/// the scroll path.
///
/// `NSCache` and not a dictionary: it is thread-safe by contract (hence
/// `@unchecked Sendable` over a `let`), and it evicts under memory pressure on
/// its own, which matters because the values are decoded bitmaps.
///
/// BOUNDED ENTRIES ONLY. The count limit is a safe ceiling because every
/// `StagedImageTile` call site passes a `maxPixel`, so an entry is at most
/// `thumbnailMaxPixel²×4` ≈ 262 KB and a full cache is tens of megabytes. The
/// full-resolution zoom viewer deliberately does NOT route through this tile —
/// it decodes per page with `Image.decoded` directly, because caching
/// 1568px bitmaps behind a count limit would bound the cache at hundreds of
/// megabytes. Keep it that way: a nil `maxPixel` reaching this cache turns the
/// limit below into a fiction.
private final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()

    /// Boxed because `NSCache` stores class instances only. `Image` is
    /// `Sendable`, so the box is genuinely safe to share.
    private final class Box: Sendable {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        // Bounded by COUNT, not bytes: a decoded `Image` does not expose its
        // backing size, so a cost limit would be a fiction. 96 covers a deep
        // scroll-back through an image-heavy thread; past that, eviction is
        // correct — the far end of the scroll is not coming back this frame.
        cache.countLimit = 96
    }

    subscript(key: DecodeKey) -> Image? {
        get { cache.object(forKey: key.cacheKey)?.image }
        set {
            guard let newValue else {
                cache.removeObject(forKey: key.cacheKey)
                return
            }
            cache.setObject(Box(newValue), forKey: key.cacheKey)
        }
    }
}
