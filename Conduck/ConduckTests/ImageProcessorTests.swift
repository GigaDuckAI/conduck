// SPDX-License-Identifier: Apache-2.0

// Conduck
// ImageProcessorTests.swift
//
// V1.1 Core Attachments. Locks the `ImageProcessor` normalisation pipeline:
//   - long edge ≤ maxPixel after downsize
//   - aspect ratio preserved
//   - NO upscale of a source smaller than maxPixel
//   - output JPEG carries NO EXIF / GPS metadata (privacy — load-bearing)
//   - output is JPEG even from a non-JPEG (PNG) source
//   - thumbnailData is present and smaller than jpegData
//
// All source images are SYNTHESISED in-test via CoreGraphics + ImageIO (no
// committed binary fixtures). The GPS-strip test builds a source JPEG that
// embeds a `kCGImagePropertyGPSDictionary`, runs it through the processor, and
// asserts the GPS dict is absent from the OUTPUT via
// `CGImageSourceCopyPropertiesAtIndex`.
//
// HEIC NOTE: synthesising a true HEIC in-test is environment-dependent (the
// HEIC encoder is not guaranteed available on every simulator/runner), so the
// "JPEG-normalisation from a non-JPEG source" assertion uses a PNG source
// instead. The production path treats HEIC identically (both decode via
// ImageIO then re-encode through the same `CGImageDestinationAddImage` JPEG
// sink) — the PNG source exercises the same normalisation branch.
//
// `#if !os(watchOS)` mirrors the production file (ImageIO/CoreGraphics are not
// in the Watch compile set).

#if !os(watchOS)

import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Conduck

final class ImageProcessorTests: XCTestCase {

    // MARK: - Synthesis helpers

    /// Build an opaque RGB `CGImage` of the given pixel size with a simple
    /// non-uniform fill (so JPEG has real content to encode).
    private func makeCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), "Failed to create CGContext \(width)x\(height)")

        // Fill with a gradient-ish pattern: a few colored rects.
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))

        return try XCTUnwrap(ctx.makeImage(), "CGContext.makeImage returned nil")
    }

    /// Encode a `CGImage` to bytes of `utType`, optionally embedding extra
    /// image properties (e.g. a GPS dictionary).
    private func encode(
        _ image: CGImage,
        as utType: UTType,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData,
            utType.identifier as CFString,
            1,
            nil
        ), "Failed to create destination for \(utType.identifier)")
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest),
                      "Failed to finalize \(utType.identifier) encode")
        return out as Data
    }

    /// Read the pixel dimensions of encoded image bytes via ImageIO.
    private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil),
                                "Could not create image source from output bytes")
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            "Output bytes carry no image properties"
        )
        let w = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let h = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        return (w, h)
    }

    /// All properties ImageIO can read from encoded bytes (for metadata
    /// assertions).
    private func properties(of data: Data) throws -> [CFString: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    /// The UTType of encoded bytes (for the "output is JPEG" assertion).
    private func utType(of data: Data) -> UTType? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String? else { return nil }
        return UTType(uti)
    }

    // MARK: - Downsize

    func testDownsizesLongEdgeToMaxPixel() async throws {
        // A 4000x3000 landscape source; cap at 1568 → long edge must be ≤ 1568.
        let source = try encode(try makeCGImage(width: 4000, height: 3000), as: .png)
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)

        XCTAssertLessThanOrEqual(max(result.width, result.height), 1568,
                                 "Long edge must be downsized to ≤ maxPixel. Got \(result.width)x\(result.height)")
        // ImageIO targets the long edge at the cap (allow ±1 for rounding).
        XCTAssertEqual(max(result.width, result.height), 1568, accuracy: 1,
                       "Long edge should land at maxPixel for an oversized source.")

        // Cross-check the encoded bytes report the same dimensions.
        let onWire = try pixelSize(of: result.jpegData)
        XCTAssertEqual(onWire.width, result.width)
        XCTAssertEqual(onWire.height, result.height)
    }

    func testPreservesAspectRatio() async throws {
        // 4000x2000 = 2:1. After downsize the ratio must hold (±small rounding).
        let source = try encode(try makeCGImage(width: 4000, height: 2000), as: .png)
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1000)

        let ratio = Double(result.width) / Double(result.height)
        XCTAssertEqual(ratio, 2.0, accuracy: 0.02,
                       "Aspect ratio (2:1) must be preserved through downsize. Got \(result.width)x\(result.height)")
        XCTAssertEqual(max(result.width, result.height), 1000, accuracy: 1)
    }

    func testDoesNotUpscaleSmallSource() async throws {
        // A tiny 200x150 source with maxPixel 1568 must NOT be upscaled — it
        // stays at (or below) its native size.
        let source = try encode(try makeCGImage(width: 200, height: 150), as: .png)
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)

        XCTAssertLessThanOrEqual(result.width, 200,
                                 "Width must not be upscaled beyond the source.")
        XCTAssertLessThanOrEqual(result.height, 150,
                                 "Height must not be upscaled beyond the source.")
        // It should retain the original size (no spurious shrink either).
        XCTAssertEqual(result.width, 200, "Small source keeps its native width (no upscale).")
        XCTAssertEqual(result.height, 150, "Small source keeps its native height (no upscale).")
    }

    // MARK: - EXIF / GPS stripping (privacy — load-bearing)

    func testOutputHasNoGPSMetadata() async throws {
        // Build a source JPEG that EMBEDS a GPS dictionary.
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 59.4370,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 24.7536,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifUserComment: "secret-camera-note",
        ]
        let sourceProps: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyExifDictionary: exif,
        ]
        let source = try encode(try makeCGImage(width: 800, height: 600),
                                as: .jpeg, properties: sourceProps)

        // Sanity: the SOURCE actually carries GPS (otherwise the test is vacuous).
        let sourceReadback = try properties(of: source)
        XCTAssertNotNil(sourceReadback[kCGImagePropertyGPSDictionary],
                        "Precondition: synthesised source JPEG must carry a GPS dictionary.")

        // Process, then inspect the OUTPUT.
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)
        let outProps = try properties(of: result.jpegData)

        XCTAssertNil(outProps[kCGImagePropertyGPSDictionary],
                     "Output JPEG must NOT carry a GPS dictionary (CGImageDestinationAddImage strips it).")
        // EXIF UserComment must not survive either.
        if let outExif = outProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            XCTAssertNil(outExif[kCGImagePropertyExifUserComment],
                         "Output JPEG must not carry the source's EXIF UserComment.")
        }
    }

    // MARK: - JPEG normalisation from a non-JPEG source

    func testOutputIsJPEGFromPNGSource() async throws {
        // PNG in → JPEG out (the same normalisation branch HEIC takes; see file
        // header re: HEIC synthesis fallback).
        let source = try encode(try makeCGImage(width: 600, height: 600), as: .png)
        XCTAssertEqual(utType(of: source), .png, "Precondition: source is PNG.")

        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)

        // UTType check.
        XCTAssertEqual(utType(of: result.jpegData), .jpeg,
                       "Output must be JPEG regardless of source type.")
        // Magic-byte check (JPEG SOI = 0xFF 0xD8).
        let head = [UInt8](result.jpegData.prefix(2))
        XCTAssertEqual(head, [0xFF, 0xD8],
                       "Output bytes must begin with the JPEG SOI marker 0xFFD8. Got \(head)")
    }

    // MARK: - Thumbnail

    func testThumbnailPresentAndSmallerThanMain() async throws {
        let source = try encode(try makeCGImage(width: 3000, height: 3000), as: .png)
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)

        XCTAssertFalse(result.thumbnailData.isEmpty, "thumbnailData must be present.")
        XCTAssertLessThan(result.thumbnailData.count, result.jpegData.count,
                          "Thumbnail bytes must be smaller than the main JPEG. thumb=\(result.thumbnailData.count) main=\(result.jpegData.count)")

        // The thumbnail's long edge should be well under the main image's.
        let thumbSize = try pixelSize(of: result.thumbnailData)
        XCTAssertLessThan(max(thumbSize.width, thumbSize.height), max(result.width, result.height),
                          "Thumbnail must be lower-resolution than the main image.")
    }

    // MARK: - byteSize bookkeeping

    func testByteSizeMatchesJPEGDataCount() async throws {
        let source = try encode(try makeCGImage(width: 1200, height: 800), as: .png)
        let result = try await ImageProcessor.shared.process(source, maxPixel: 1568)
        XCTAssertEqual(result.byteSize, result.jpegData.count,
                       "byteSize must equal jpegData.count.")
    }

    // MARK: - Decode failure

    func testGarbageBytesThrowDecodeFailed() async {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        do {
            _ = try await ImageProcessor.shared.process(garbage, maxPixel: 1568)
            XCTFail("Non-image bytes must throw, not return a ProcessedImage.")
        } catch ImageProcessorError.decodeFailed {
            // expected
        } catch {
            XCTFail("Expected ImageProcessorError.decodeFailed, got \(error)")
        }
    }
}

#endif
