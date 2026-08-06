// SPDX-License-Identifier: Apache-2.0

// Conduck
// ImageProcessor.swift
//
// V1.1 Core Attachments. Memory-frugal image normalisation pipeline:
// arbitrary input (HEIC / ProRAW / PNG / JPEG, any size) → a downsized,
// EXIF/GPS-stripped JPEG + a small preview thumbnail. ImageIO's
// `CGImageSourceCreateThumbnailAtIndex` decodes-and-downsizes in one pass so a
// 48-megapixel ProRAW never inflates to its full uncompressed footprint in RAM
// (no full decode → resize spike).
//
// PRIVACY (load-bearing): re-encoding goes through
// `CGImageDestinationAddImage` (the CGImage), NOT
// `CGImageDestinationAddImageFromSource` — the latter copies the source's
// metadata (EXIF, **GPS coordinates**) into the output. Adding the bare
// CGImage drops all of it.
//
// NO size / count cap (locked decision — the user pays their own LLM bill, so
// the user decides). The inline copy is downsized to a fixed `defaultMaxPixel`
// (1568, the de-facto vision-tile sweet spot) — no user knob; the file-transfer
// route uploads the untouched original instead (path-level fidelity contract).
//
// WATCH: this file is deliberately NOT in the Watch compile set (it is not in
// the pbxproj Watch membership exception list). The `#if !os(watchOS)` guard is
// belt-and-suspenders so an accidental membership add still compiles to an
// empty module on the wrist rather than dragging ImageIO/CoreGraphics in.

#if !os(watchOS)

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Result of normalising one image: the re-encoded JPEG (what gets stored +
/// data-URI'd), a small preview thumbnail (~50 KB, for instant bubble render),
/// and the post-downsize pixel dimensions + byte size.
struct ProcessedImage: Sendable {
    /// EXIF/GPS-stripped JPEG bytes, long edge ≤ `maxPixel`, quality 0.7. The
    /// INLINE/persisted copy only — the file-transfer route uploads originals.
    let jpegData: Data
    /// Small JPEG preview (~256px long edge) for instant bubble / strip render.
    let thumbnailData: Data
    /// Width of `jpegData` in pixels (post-downsize).
    let width: Int
    /// Height of `jpegData` in pixels (post-downsize).
    let height: Int
    /// `jpegData.count` — convenience for the stored `byteSize`.
    let byteSize: Int
}

/// Image normalisation failures. Both non-recoverable for the given bytes
/// (the user must pick a different image).
enum ImageProcessorError: Error {
    /// ImageIO could not create a CGImage from the input bytes.
    case decodeFailed
    /// ImageIO could not encode the downsized CGImage to JPEG.
    case encodeFailed
}

/// Serialised image pipeline. An `actor` so concurrent attachment processing
/// (a user picks 6 photos at once) doesn't thrash memory with parallel full
/// decodes — they queue through one actor.
actor ImageProcessor {
    static let shared = ImageProcessor()
    private init() {}

    /// JPEG re-encode quality for the INLINE/persisted copy (the base64 vision
    /// data-URI + the Core Data draft + the bubble thumbnail). 0.7 (was 0.85):
    /// the file-transfer route now PUTs the ORIGINAL raw bytes (full quality,
    /// true format) so the agent's tools act on the real file, leaving this
    /// processed JPEG to serve only inline vision — where 0.7 is the de-facto
    /// sweet spot (visually indistinguishable to a vision model, ~30% smaller
    /// data-URI per turn, and that saving compounds since prior-turn images are
    /// replayed into history on every later turn). Does NOT affect the uploaded
    /// file (that is the untouched original).
    private static let jpegQuality: CGFloat = 0.7
    /// Fixed long-edge cap for the inline/persisted copy (the de-facto
    /// vision-tile sweet spot; no longer user-configurable).
    static let defaultMaxPixel = 1568
    /// Thumbnail long-edge target — the size `process` bakes into
    /// `ProcessedImage.thumbnailData`, and the display-decode bound the composer
    /// strip reuses for a staged image that has no processed thumbnail yet
    /// (`.image`, the inline-only route). One constant for both so a tile and a
    /// stored thumbnail can never disagree about what "preview size" means.
    static let thumbnailMaxPixel = 256

    /// Hard ceiling on a WS-2 preview thumbnail's JPEG size — a produced
    /// thumbnail above this is rejected rather than persisted. 128 KiB is
    /// generous headroom for a 256px-long-edge JPEG at quality 0.7 (typically
    /// ~10-50 KB); it exists so a pathological input can never mint an oversized
    /// preview blob.
    static let thumbnailPreviewByteCeiling = 128 * 1024

    /// Downsample `data` STRAIGHT to a preview thumbnail (256px long edge,
    /// quality 0.7) via ImageIO — WITHOUT producing the full-size main image the
    /// `process` pipeline makes (wasted work for the enrichment path, which only
    /// wants the thumbnail). `CGImageSourceCreateThumbnailAtIndex` decode-and-
    /// downsizes in one pass, so the full bitmap is never decoded into RAM. A
    /// successful decode is ALSO the content-validity proof — extensions are
    /// never trusted, so non-image bytes fail here and yield nil. Returns nil on
    /// a decode/encode failure OR when the produced JPEG exceeds
    /// `thumbnailPreviewByteCeiling`. `nonisolated` (touches no actor state) so
    /// the enrichment path runs the CPU downscale off the main actor without
    /// hopping onto the `ImageProcessor` actor's serial executor.
    nonisolated static func thumbnailOnly(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = try? downsizedCGImage(from: source, maxPixel: thumbnailMaxPixel),
              let jpeg = try? encodeJPEG(thumb) else {
            return nil
        }
        guard jpeg.count <= thumbnailPreviewByteCeiling else { return nil }
        return jpeg
    }

    /// Normalise raw image bytes into a `ProcessedImage`.
    ///
    /// - Parameters:
    ///   - data: the original image bytes (HEIC / ProRAW / PNG / JPEG / …).
    ///   - maxPixel: long-edge cap for the main JPEG (default 1568). NEVER
    ///     upscales — a source smaller than `maxPixel` is downsized to itself.
    /// - Returns: the downsized, EXIF/GPS-stripped JPEG + thumbnail + metadata.
    /// - Throws: `ImageProcessorError.decodeFailed` / `.encodeFailed`.
    func process(_ data: Data, maxPixel: Int = ImageProcessor.defaultMaxPixel) throws -> ProcessedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageProcessorError.decodeFailed
        }

        let main = try Self.downsizedCGImage(from: source, maxPixel: max(1, maxPixel))
        let jpegData = try Self.encodeJPEG(main)

        // Thumbnail: a SECOND small downsize pass off the same source (cheap —
        // ImageIO downsizes from the source, not the already-downsized main).
        let thumbCG = (try? Self.downsizedCGImage(from: source, maxPixel: Self.thumbnailMaxPixel)) ?? main
        let thumbData = (try? Self.encodeJPEG(thumbCG)) ?? jpegData

        return ProcessedImage(
            jpegData: jpegData,
            thumbnailData: thumbData,
            width: main.width,
            height: main.height,
            byteSize: jpegData.count
        )
    }

    // MARK: - Display decode (the ONE ImageIO decode primitive)

    /// Decode `data` for DISPLAY, optionally bounding the long edge to
    /// `maxPixel`. The single decode primitive every view-side image path goes
    /// through (`Image.decoded(from:maxPixel:)` is the SwiftUI wrapper) — so the
    /// ImageIO option block below exists exactly once, and a change to
    /// orientation handling or cache posture cannot apply to some surfaces only.
    ///
    /// `maxPixel` non-nil bounds the long edge, so a multi-megapixel original
    /// never inflates to its full bitmap to fill a small tile. Nil decodes at
    /// full resolution — correct only where the pixels are actually wanted (the
    /// zoom viewer).
    ///
    /// BOTH cases route through `downsizedCGImage`, nil by resolving the bound to
    /// the image's own long edge rather than by taking a second, plainer ImageIO
    /// call. That is the whole point of the shared primitive, and the two
    /// properties it exists to keep uniform are exactly the ones a bare
    /// `CGImageSourceCreateImageAtIndex(source, 0, nil)` would silently drop:
    ///
    ///   - `…ShouldCacheImmediately` — without it ImageIO hands back a LAZY
    ///     image whose decompression is deferred to the first draw, i.e. back
    ///     onto the main thread, which would make the `@concurrent` hop in
    ///     `Image.decoded` return having done no work at all.
    ///   - `…WithTransform` — without it EXIF orientation is never applied, so
    ///     any payload with an orientation tag ≠ 1 renders rotated or mirrored
    ///     on the surfaces that pass nil, while the bounded surfaces show it
    ///     upright.
    ///
    /// `nonisolated` + SYNCHRONOUS on purpose: it touches no actor state, and
    /// hopping onto this actor's serial executor would queue display decodes
    /// behind a staging `process` call. The CALLER owns getting off the main
    /// actor — `Image.decoded` does that with `@concurrent`.
    nonisolated static func displayCGImage(from data: Data, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let bound: Int
        if let maxPixel {
            bound = max(1, maxPixel)
        } else {
            guard let longEdge = pixelLongEdge(of: source) else { return nil }
            bound = longEdge
        }
        return try? downsizedCGImage(from: source, maxPixel: bound)
    }

    /// The source's stored pixel dimensions, read from metadata WITHOUT decoding
    /// anything — this is what lets the nil (full-resolution) case reuse the
    /// bounded path instead of needing its own decode call.
    ///
    /// Deliberately the PRE-orientation dimensions: the long edge is
    /// orientation-invariant (a 90° swap exchanges width and height), so it is
    /// the right bound either way, and asking for the larger of the two can only
    /// ever be a no-op downsize, never a crop.
    private nonisolated static func pixelLongEdge(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(1, max(width, height))
    }

    // MARK: - Private — ImageIO

    /// Decode-and-downsize in one pass via `CGImageSourceCreateThumbnailAtIndex`.
    /// `…FromImageAlways` forces a downsize even when an embedded thumbnail
    /// exists (so we always honour `maxPixel`); `…WithTransform` bakes the EXIF
    /// orientation into pixels (so the stored JPEG is upright with no
    /// orientation metadata to strip); `…ShouldCacheImmediately` decodes on the
    /// CALLING executor rather than lazily on the main thread at draw time —
    /// which is what makes an off-main decode hop actually buy anything.
    private static func downsizedCGImage(
        from source: CGImageSource,
        maxPixel: Int
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageProcessorError.decodeFailed
        }
        return cgImage
    }

    /// Re-encode a CGImage to JPEG via `CGImageDestinationAddImage` (NOT
    /// `…FromSource`) — adding the bare CGImage drops ALL source metadata
    /// (EXIF + GPS). HEIC / ProRAW / PNG all converge to JPEG here (every major
    /// model rejects HEIC).
    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessorError.encodeFailed
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessorError.encodeFailed
        }
        return mutableData as Data
    }
}

#endif
