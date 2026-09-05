// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentGalleryPageTests.swift
//
// Pins the pure parts of the model-free full-screen gallery:
//
//   1. `AttachmentGalleryPage.pages(forImageAttachments:)` — Chat's mapping.
//      Page order and the 1-based numbering are what the accessibility label
//      and the loader's id lookup both depend on.
//   2. `AttachmentGalleryResidency.residentIndices` — the window that decides
//      which pages may hold a full-size bitmap. The clamped ends and the
//      radius-0 (memory-warning) case are the load-bearing ones.
//   3. `Image.decodedStrictlyBounded` — must return NIL for bytes that are not
//      an image instead of falling back to an unbounded platform decode, and
//      the bound it delegates to must actually cap the long edge.
//
// Privacy: synthetic bytes only; the "real image" is generated in-process.

import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Conduck

@MainActor
final class AttachmentGalleryPageTests: XCTestCase {

    // MARK: - Page mapping

    private func makeImageAttachment(sequence: Int, thumbnail: Data?) -> AttachmentRecord {
        AttachmentRecord(
            id: UUID(),
            mimeType: "image/jpeg",
            filename: "shot-\(sequence)",
            thumbnailData: thumbnail,
            extractedText: nil,
            width: 100,
            height: 80,
            byteSize: 1234,
            sequence: sequence,
            createdAt: Date(),
            isServerReference: false,
            storedKey: nil,
            previewKind: nil
        )
    }

    func testPagesCarryEveryAttachmentIdAndThumbnailInOrder() {
        let attachments = [
            makeImageAttachment(sequence: 0, thumbnail: Data([0x01])),
            makeImageAttachment(sequence: 1, thumbnail: nil),
            makeImageAttachment(sequence: 2, thumbnail: Data([0x03]))
        ]

        let pages = AttachmentGalleryPage.pages(forImageAttachments: attachments)

        XCTAssertEqual(pages.map(\.id), attachments.map(\.id), "page order must follow the attachments")
        XCTAssertEqual(pages.map(\.thumbnailData), attachments.map(\.thumbnailData),
                       "a thumbnail-less attachment still becomes a page (it loads its full bytes)")
    }

    func testPagesAreNumberedOneBasedInTheAccessibilityLabel() {
        let attachments = (0..<2).map { makeImageAttachment(sequence: $0, thumbnail: nil) }

        let pages = AttachmentGalleryPage.pages(forImageAttachments: attachments)

        XCTAssertEqual(pages.first?.accessibilityLabel, "Image 1 of 2")
        XCTAssertEqual(pages.last?.accessibilityLabel, "Image 2 of 2")
    }

    func testAnEmptyAttachmentListMapsToNoPages() {
        XCTAssertTrue(AttachmentGalleryPage.pages(forImageAttachments: []).isEmpty)
    }

    // MARK: - Residency window

    func testTheWindowKeepsTheCurrentPageAndBothNeighbours() {
        let resident = AttachmentGalleryResidency.residentIndices(current: 3, count: 8, radius: 1)
        XCTAssertEqual(resident, [2, 3, 4])
    }

    func testTheWindowClampsAtBothEnds() {
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 0, count: 5, radius: 1),
            [0, 1],
            "there is no page -1 to keep resident"
        )
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 4, count: 5, radius: 1),
            [3, 4]
        )
    }

    /// The memory-warning shape: neighbours are released, the page the user is
    /// looking at is not.
    func testRadiusZeroKeepsOnlyTheCurrentPage() {
        XCTAssertEqual(AttachmentGalleryResidency.residentIndices(current: 2, count: 6, radius: 0), [2])
    }

    func testAnOutOfRangeCurrentIndexStillLeavesAPageResident() {
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: 99, count: 3, radius: 1),
            [1, 2],
            "a stale start index must clamp, never leave the gallery with nothing to render"
        )
        XCTAssertEqual(
            AttachmentGalleryResidency.residentIndices(current: -4, count: 3, radius: 0),
            [0]
        )
    }

    func testAnEmptyGalleryHasNoResidentPages() {
        XCTAssertTrue(AttachmentGalleryResidency.residentIndices(current: 0, count: 0, radius: 1).isEmpty)
    }

    func testAWindowWiderThanTheGalleryKeepsEveryPage() {
        XCTAssertEqual(AttachmentGalleryResidency.residentIndices(current: 1, count: 3, radius: 9), [0, 1, 2])
    }

    // MARK: - Strict bounded decode

    /// A solid-colour JPEG of the requested pixel size, built through ImageIO so
    /// the test never ships an image asset.
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())

        let buffer = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    func testStrictDecodeReturnsNilForBytesThatAreNotAnImage() async {
        let notAnImage = Data("this is a note, not a picture".utf8)
        let image = await Image.decodedStrictlyBounded(from: notAnImage, maxPixel: 4096)
        XCTAssertNil(image, "the strict path must report failure, never fall back to a platform decode")
    }

    func testStrictDecodeReturnsNilForEmptyBytes() async {
        let image = await Image.decodedStrictlyBounded(from: Data(), maxPixel: 4096)
        XCTAssertNil(image)
    }

    func testStrictDecodeAcceptsRealImageBytes() async throws {
        let jpeg = try makeJPEG(width: 300, height: 200)
        let image = await Image.decodedStrictlyBounded(from: jpeg, maxPixel: 4096)
        XCTAssertNotNil(image)
    }

    /// The bound itself, measured on the CGImage the strict decoder returns
    /// wrapped — `displayCGImage` is the whole of its decode.
    func testTheBoundCapsTheLongEdgeOfARealImage() throws {
        let jpeg = try makeJPEG(width: 512, height: 256)

        let bounded = try XCTUnwrap(ImageProcessor.displayCGImage(from: jpeg, maxPixel: 128))
        XCTAssertEqual(bounded.width, 128, "the long edge is the bound")
        XCTAssertEqual(bounded.height, 64, "the aspect ratio survives the bound")

        let unbounded = try XCTUnwrap(ImageProcessor.displayCGImage(from: jpeg, maxPixel: nil))
        XCTAssertEqual(unbounded.width, 512)
        XCTAssertEqual(unbounded.height, 256)
    }

    func testTheBoundedPrimitiveAlsoRefusesNonImageBytes() {
        XCTAssertNil(ImageProcessor.displayCGImage(from: Data("nope".utf8), maxPixel: 128))
    }
}
