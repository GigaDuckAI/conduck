// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkMaterialImagePolicyTests.swift
//
// One decision governs which pixels an image card keeps, so these cases pin
// the whole matrix at the policy rather than per lane: a picture is shrunk to
// the desk cap and stripped, a picture already that shape is stored untouched,
// an animation and undecodable bytes are left alone, and — the one rule that
// protects existing data — a replay reproduces the representation its card was
// published with, never a new one. Every image is synthesised in-test, because
// the pipeline under test is ImageIO and a checked-in file would only prove
// that the file still parses.

#if !os(watchOS)

import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Conduck

final class WorkMaterialImagePolicyTests: XCTestCase {

    // MARK: - Synthesis

    private func makeImage(width: Int, height: Int, transparent: Bool = false) throws -> CGImage {
        let alpha = transparent
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha
        ))
        if transparent {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.55, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func png(width: Int, height: Int, transparent: Bool = false) throws -> Data {
        try encode(try makeImage(width: width, height: height, transparent: transparent), as: .png)
    }

    private func jpeg(width: Int, height: Int, properties: [CFString: Any] = [:]) throws -> Data {
        try encode(try makeImage(width: width, height: height), as: .jpeg, properties: properties)
    }

    /// A JPEG whose only metadata is XMP — no EXIF block, no GPS — of the kind
    /// an editor or a rights tool writes. Property dictionaries may not surface
    /// it; the metadata tag list does.
    private func jpegWithXMP(width: Int, height: Int) throws -> Data {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            metadata, nil, "xmpRights:WebStatement" as CFString, "https://example.com/owner" as CFString
        ))
        CGImageDestinationAddImageAndMetadata(
            destination, try makeImage(width: width, height: height), metadata, nil
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func animatedGIF() throws -> Data {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.gif.identifier as CFString, 2, nil
        ))
        CGImageDestinationAddImage(destination, try makeImage(width: 32, height: 32), nil)
        CGImageDestinationAddImage(destination, try makeImage(width: 32, height: 32), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func temporaryFile(_ bytes: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-image-policy-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func facts(of data: Data) throws -> ImageSourceFacts {
        ImageProcessor.inspect(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)))
    }

    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// A card as the desk would hand it back, on the lane and with the pairing
    /// the case needs; every other column is inert here.
    private func card(
        storageMode: WorkMaterialStorageMode,
        contentHash: String?
    ) -> WorkMaterialRecord {
        WorkMaterialRecord(
            id: UUID(),
            workItemID: Constants.workboardDeskItemID,
            kind: .image,
            title: "IMG.png",
            caption: "",
            textContent: nil,
            urlString: nil,
            filename: "IMG.png",
            mimeType: "image/png",
            thumbnailData: nil,
            width: nil,
            height: nil,
            byteSize: 1,
            hasPayload: true,
            storageMode: storageMode,
            availability: storageMode == .syncedPayload ? .synced : .availableLocally,
            contentHash: contentHash,
            localVaultKey: storageMode == .localVault ? "leaf" : nil,
            sourceDevice: nil,
            sequence: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func prepare(
        kind: WorkMaterialKind = .image,
        payload: Data? = nil,
        sourceFileURL: URL? = nil,
        declaredByteCount: Int64? = nil,
        existing: WorkMaterialRecord? = nil
    ) async throws -> WorkMaterialImagePolicy.Outcome {
        try await WorkMaterialImagePolicy.prepare(
            kind: kind,
            payload: payload,
            sourceFileURL: sourceFileURL,
            declaredByteCount: declaredByteCount,
            existing: existing
        )
    }

    // MARK: - The shape a card keeps

    func testALargePictureIsShrunkToTheDeskCapAsAJPEG() async throws {
        let source = try png(width: 4000, height: 3000)

        let outcome = try await prepare(payload: source)

        guard case .normalised(let jpeg, let width, let height) = outcome else {
            return XCTFail("a picture above the cap must be normalised, got \(outcome)")
        }
        XCTAssertEqual(width, Constants.workboardImageMaxPixel)
        XCTAssertEqual(height, Constants.workboardImageMaxPixel * 3 / 4)
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8]), "the stored bytes are a JPEG")
        XCTAssertLessThan(jpeg.count, source.count)
        let stored = try facts(of: jpeg)
        XCTAssertTrue(stored.isJPEG)
        XCTAssertEqual(stored.longEdge, Constants.workboardImageMaxPixel)
        XCTAssertFalse(stored.carriesIdentifyingMetadata)
    }

    func testTheDeskCapIsTheChatCap() {
        XCTAssertEqual(
            Constants.workboardImageMaxPixel, ImageProcessor.defaultMaxPixel,
            "Work holds exactly what a chat turn would have sent; the literal in Constants exists for the Watch target"
        )
    }

    func testAJPEGAlreadyWithinTheCapIsStoredByteForByte() async throws {
        let source = try jpeg(width: 800, height: 600)
        XCTAssertFalse(try facts(of: source).carriesIdentifyingMetadata,
                       "the fixture must carry nothing identifying, or this case proves nothing")

        let outcome = try await prepare(payload: source)

        XCTAssertEqual(outcome, .unchanged(.alreadyConforming))
    }

    func testTheProcessorsOwnOutputPassesThroughUnchanged() async throws {
        // What the voice lane and a chat capture hand over: a JPEG this same
        // pipeline already produced. Encoding it again would cost a second
        // generation for nothing.
        let first = try await prepare(payload: try png(width: 3000, height: 2000))
        guard case .normalised(let jpeg, _, _) = first else { return XCTFail("fixture did not normalise") }

        let second = try await prepare(payload: jpeg)

        XCTAssertEqual(second, .unchanged(.alreadyConforming))
    }

    func testASmallJPEGCarryingLocationIsReEncodedWithoutIt() async throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 59.4370,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 24.7536,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let source = try jpeg(width: 800, height: 600, properties: [kCGImagePropertyGPSDictionary: gps])
        XCTAssertTrue(try facts(of: source).carriesIdentifyingMetadata,
                      "the fixture must carry GPS, or this case proves nothing")

        let outcome = try await prepare(payload: source)

        guard case .normalised(let jpeg, let width, let height) = outcome else {
            return XCTFail("a JPEG carrying location must be re-encoded, got \(outcome)")
        }
        XCTAssertEqual(width, 800, "within the cap, so the size is kept")
        XCTAssertEqual(height, 600)
        XCTAssertFalse(try facts(of: jpeg).carriesIdentifyingMetadata)
    }

    func testASmallJPEGCarryingOnlyXMPIsReEncodedWithoutIt() async throws {
        let source = try jpegWithXMP(width: 800, height: 600)
        XCTAssertTrue(try facts(of: source).carriesIdentifyingMetadata,
                      "the fixture must carry XMP the tag list can see, or this case proves nothing")

        let outcome = try await prepare(payload: source)

        guard case .normalised(let jpeg, _, _) = outcome else {
            return XCTFail("a JPEG carrying a rights URL must be re-encoded, got \(outcome)")
        }
        XCTAssertFalse(try facts(of: jpeg).carriesIdentifyingMetadata)
    }

    func testAStillGIFIsLeftAloneByType() async throws {
        // The rule is GIF, not frame count: a one-frame GIF still promises a
        // palette and a loop the JPEG sink cannot keep, and it costs nothing.
        let still = try encode(try makeImage(width: 64, height: 64), as: .gif)
        XCTAssertEqual(try facts(of: still).frameCount, 1)

        let outcome = try await prepare(payload: still)

        XCTAssertEqual(outcome, .unchanged(.animated))
    }

    func testTransparentPixelsRenderWhiteNotBlack() async throws {
        let outcome = try await prepare(payload: try png(width: 64, height: 64, transparent: true))

        guard case .normalised(let jpeg, _, _) = outcome else { return XCTFail("did not normalise") }
        let decoded = try XCTUnwrap(ImageProcessor.displayCGImage(from: jpeg, maxPixel: nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Bottom-right quadrant was fully transparent in the source.
        let offset = (60 * 64 + 60) * 4
        for channel in 0..<3 {
            XCTAssertGreaterThan(pixels[offset + channel], 240,
                                 "a transparent pixel must land on white, not on black")
        }
    }

    // MARK: - What is left alone

    func testAnAnimationIsLeftAlone() async throws {
        let outcome = try await prepare(payload: try animatedGIF())
        XCTAssertEqual(outcome, .unchanged(.animated), "the JPEG sink keeps one frame, which is a different picture")
    }

    func testBytesThatDoNotDecodeAreLeftAlone() async throws {
        let outcome = try await prepare(payload: Data("the shared screenshot".utf8))
        XCTAssertEqual(outcome, .unchanged(.undecodable))
    }

    func testOnlyAnImageCardIsNormalised() async throws {
        let outcome = try await prepare(kind: .file, payload: try png(width: 3000, height: 3000))
        XCTAssertEqual(outcome, .unchanged(.notAnImageCard), "kind decides, exactly as the thumbnail does")
    }

    func testACardWithNoBytesIsLeftAlone() async throws {
        let outcome = try await prepare()
        XCTAssertEqual(outcome, .unchanged(.noBytes))
    }

    // MARK: - File-backed sources

    func testAFileSourceIsNormalisedFromDisk() async throws {
        let source = try png(width: 2500, height: 1000)
        let url = try temporaryFile(source, extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try await prepare(sourceFileURL: url, declaredByteCount: Int64(source.count))

        guard case .normalised(_, let width, let height) = outcome else {
            return XCTFail("a file source must normalise, got \(outcome)")
        }
        XCTAssertEqual(width, Constants.workboardImageMaxPixel)
        XCTAssertEqual(height, Constants.workboardImageMaxPixel * 1000 / 2500)
    }

    func testASourceWhoseLengthDisagreesWithItsCaptureIsLeftForStagingToRefuse() async throws {
        let source = try png(width: 2500, height: 1000)
        let url = try temporaryFile(source, extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try await prepare(sourceFileURL: url, declaredByteCount: Int64(source.count) + 1)

        XCTAssertEqual(outcome, .unchanged(.sourceMismatch),
                       "converting first would let a lie about the file's length through as a valid JPEG")
    }

    func testAnUnmeasuredDeclarationDoesNotBlockAFileSource() async throws {
        let source = try png(width: 2500, height: 1000)
        let url = try temporaryFile(source, extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        for declared in [nil, Int64(-1)] {
            let outcome = try await prepare(sourceFileURL: url, declaredByteCount: declared)
            guard case .normalised = outcome else {
                return XCTFail("an unmeasured declaration is not a disagreement, got \(outcome)")
            }
        }
    }

    // MARK: - Existing cards (replay and repair)

    func testAReplayAgainstACardPublishedRawKeepsRaw() async throws {
        let raw = try png(width: 3000, height: 3000)
        let existing = card(storageMode: .syncedPayload, contentHash: hex(raw))

        let outcome = try await prepare(payload: raw, existing: existing)

        XCTAssertEqual(outcome, .unchanged(.keepsExistingRepresentation),
                       "a card published before this rule names the raw bytes; a new hash would retire its healthy blob")
    }

    func testAReplayAgainstACardPublishedRawKeepsRawFromAFileToo() async throws {
        let raw = try png(width: 3000, height: 3000)
        let url = try temporaryFile(raw, extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = card(storageMode: .syncedPayload, contentHash: hex(raw))

        let outcome = try await prepare(
            sourceFileURL: url,
            declaredByteCount: Int64(raw.count),
            existing: existing
        )

        XCTAssertEqual(outcome, .unchanged(.keepsExistingRepresentation))
    }

    func testAReplayAgainstACardPublishedNormalisedReproducesTheSameBytes() async throws {
        let raw = try png(width: 3000, height: 3000)
        guard case .normalised(let firstJPEG, _, _) = try await prepare(payload: raw) else {
            return XCTFail("fixture did not normalise")
        }
        let existing = card(storageMode: .syncedPayload, contentHash: hex(firstJPEG))

        let outcome = try await prepare(payload: raw, existing: existing)

        guard case .normalised(let secondJPEG, _, _) = outcome else {
            return XCTFail("a card published normalised must be replayed normalised, got \(outcome)")
        }
        XCTAssertEqual(secondJPEG, firstJPEG,
                       "the encode is deterministic, so the replay pairs with the blob already there and nothing is deleted")
    }

    func testAReplayAgainstAVaultCardKeepsRaw() async throws {
        let raw = try png(width: 3000, height: 3000)

        let outcome = try await prepare(payload: raw, existing: card(storageMode: .localVault, contentHash: nil))

        XCTAssertEqual(outcome, .unchanged(.keepsExistingRepresentation),
                       "a repair restores what the row promises, in the lane it claims")
    }

    func testAReplayAgainstASyncedCardWithNoPairingKeepsRaw() async throws {
        let raw = try png(width: 3000, height: 3000)

        let outcome = try await prepare(payload: raw, existing: card(storageMode: .syncedPayload, contentHash: nil))

        XCTAssertEqual(outcome, .unchanged(.keepsExistingRepresentation),
                       "a row written before the pairing existed cannot be compared, so it is not converted")
    }

    // MARK: - The draft that describes the new bytes

    func testTheNormalisedDraftFollowsTheBytesInEveryNameThatStatesAFormat() {
        let draft = WorkMaterialDraft(
            id: UUID(),
            kind: .image,
            title: "IMG_1234.HEIC",
            caption: "from the share sheet",
            filename: "IMG_1234.HEIC",
            mimeType: "image/heic",
            payload: Data("raw".utf8),
            byteSize: 3,
            sourceDevice: "iPhone",
            attachedToMaterialID: nil
        )
        let jpeg = Data("jpeg".utf8)

        let normalised = draft.normalisedImage(jpeg: jpeg)

        XCTAssertEqual(normalised.id, draft.id)
        XCTAssertEqual(normalised.title, "IMG_1234.jpg",
                       "the export names a shared copy after the title first, so the title must not claim HEIC")
        XCTAssertEqual(normalised.filename, "IMG_1234.jpg")
        XCTAssertEqual(normalised.mimeType, "image/jpeg")
        XCTAssertEqual(normalised.payload, jpeg)
        XCTAssertEqual(normalised.byteSize, Int64(jpeg.count))
        XCTAssertEqual(normalised.caption, draft.caption)
        XCTAssertEqual(normalised.sourceDevice, draft.sourceDevice)
        XCTAssertEqual(normalised.createdAt, draft.createdAt)
    }

    func testAConformingCaptureIsRenamedWithoutTouchingItsBytes() {
        let draft = WorkMaterialDraft(kind: .image, title: "IMG_7.HEIC", filename: "IMG_7.HEIC", mimeType: "image/heic", payload: Data("jpeg".utf8), byteSize: 4)

        let renamed = draft.renamedAsJPEG()

        XCTAssertEqual(renamed.title, "IMG_7.jpg")
        XCTAssertEqual(renamed.filename, "IMG_7.jpg")
        XCTAssertEqual(renamed.mimeType, "image/jpeg")
        XCTAssertEqual(renamed.payload, draft.payload)
        XCTAssertEqual(renamed.byteSize, draft.byteSize)
    }

    func testANameThatAlreadySaysJPEGIsKeptAsSpelled() {
        XCTAssertEqual(WorkMaterialDraft.replacingExtension(of: "photo.jpeg", with: "jpg"), "photo.jpeg")
        XCTAssertEqual(WorkMaterialDraft.replacingExtension(of: "photo.JPG", with: "jpg"), "photo.JPG")
        XCTAssertEqual(WorkMaterialDraft.replacingExtension(of: "photo.png", with: "jpg"), "photo.jpg")
        XCTAssertEqual(WorkMaterialDraft.replacingExtension(of: "photo", with: "jpg"), "photo.jpg")
        XCTAssertEqual(WorkMaterialDraft.renamingTypedExtension(of: "Meeting v1.2", to: "jpg"), nil)
        XCTAssertEqual(WorkMaterialDraft.renamingTypedExtension(of: "Screenshot at 17.45.12", to: "jpg"), nil)
        XCTAssertEqual(WorkMaterialDraft.renamingTypedExtension(of: "report.pdf", to: "jpg"), "report.jpg",
                       "a JPEG must never leave under a name that says PDF — the export trusts the title first")
        XCTAssertEqual(WorkMaterialDraft.renamingTypedExtension(of: "IMG_1.HEIC", to: "jpg"), "IMG_1.jpg")
    }

    func testATitleThatIsNotAFilenameKeepsItsWords() {
        let draft = WorkMaterialDraft(kind: .image, title: "Meeting v1.2", filename: "shot.png", payload: Data("raw".utf8))

        let normalised = draft.normalisedImage(jpeg: Data("jpeg".utf8))

        XCTAssertEqual(normalised.title, "Meeting v1.2", "'.2' names no type, so it is not an extension to rewrite")
        XCTAssertEqual(normalised.filename, "shot.jpg", "a filename always describes its bytes")
    }

    func testTheExportOfANormalisedCardNamesAJPEG() {
        let draft = WorkMaterialDraft(kind: .image, title: "screenshot.png", filename: "screenshot.png", payload: Data("raw".utf8))
            .normalisedImage(jpeg: Data("jpeg".utf8))

        let filename = WorkMaterialExportSnapshot.filename(displayName: draft.title, mimeType: draft.mimeType)

        XCTAssertEqual(filename, "screenshot.jpg")
        XCTAssertEqual(WorkMaterialExportSnapshot.contentType(filename: filename, mimeType: draft.mimeType), .jpeg)
    }
}

#endif
