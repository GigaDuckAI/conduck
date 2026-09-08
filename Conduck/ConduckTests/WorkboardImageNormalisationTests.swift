// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardImageNormalisationTests.swift
//
// The desk write sizes every picture it stores, and these cases hold that
// promise where it is kept — through `upsertDeskMaterial` and a reattach,
// against the real store — rather than at the policy alone. The two cases that
// matter most are the ones that must NOT convert: a card published before the
// rule, replayed with the raw bytes it was published with, keeps its blob and
// its name, and a card published sized, replayed with the raw capture, pairs
// with the blob already there and deletes nothing.

#if !os(watchOS)

import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Conduck

final class WorkboardImageNormalisationTests: XCTestCase {

    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - Synthesis

    private func imageBytes(width: Int, height: Int, as utType: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, utType.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func temporaryFile(_ bytes: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-normalise-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func facts(of data: Data) throws -> ImageSourceFacts {
        ImageProcessor.inspect(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)))
    }

    // MARK: - What a fresh capture stores

    func testAPictureAddedToTheDeskIsStoredAsASizedJPEG() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 3000, height: 2000)

        let record = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "shot.png",
                filename: "shot.png",
                mimeType: "image/png",
                payload: png,
                byteSize: Int64(png.count)
            )
        )

        XCTAssertEqual(record.mimeType, "image/jpeg")
        XCTAssertEqual(record.filename, "shot.jpg")
        XCTAssertEqual(record.title, "shot.jpg", "the export names a copy after the title, so it follows the bytes")
        XCTAssertEqual(record.storageMode, .syncedPayload)
        XCTAssertLessThan(record.byteSize, Int64(png.count))
        XCTAssertNotNil(record.thumbnailData)
        let storedValue = try await store.loadWorkMaterialPayload(id: record.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(Int64(stored.count), record.byteSize, "the row measures the bytes it keeps")
        XCTAssertEqual(record.contentHash, hex(stored), "the card is paired with the sized bytes")
        let shape = try facts(of: stored)
        XCTAssertTrue(shape.isJPEG)
        XCTAssertEqual(shape.longEdge, Constants.workboardImageMaxPixel)
        XCTAssertFalse(shape.carriesIdentifyingMetadata)
    }

    func testAFileBackedPictureIsSizedFromDiskAndTheSourceIsLeftInPlace() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 2500, height: 2500)
        let source = try temporaryFile(png, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }

        let record = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "IMG_0001.PNG",
                filename: "IMG_0001.PNG",
                mimeType: "image/png"
            ),
            sourceFileURL: source,
            sourceFileByteSize: Int64(png.count)
        )

        XCTAssertEqual(record.mimeType, "image/jpeg")
        XCTAssertEqual(record.filename, "IMG_0001.jpg")
        XCTAssertEqual(record.title, "IMG_0001.jpg")
        XCTAssertEqual(record.storageMode, .syncedPayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the share inbox retires its own copy; the desk write consumes nothing")
        let storedValue = try await store.loadWorkMaterialPayload(id: record.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(try facts(of: stored).longEdge, Constants.workboardImageMaxPixel)
    }

    func testAFileWhoseLengthDisagreesWithItsCaptureIsStillRefused() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 2500, height: 2500)
        let source = try temporaryFile(png, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(kind: .image, title: "IMG.png", filename: "IMG.png", mimeType: "image/png"),
                sourceFileURL: source,
                sourceFileByteSize: Int64(png.count) + 7
            )
            XCTFail("a source that is not the payload the caller described must be refused, sized or not")
        } catch WorkboardStoreError.materialPayloadUnavailable {
            // The refusal staging has always made; sizing did not let it through.
        }
    }

    func testTheProcessorSizesAFileWithoutBeingHandedItsBytes() async throws {
        let png = try imageBytes(width: 2000, height: 500)
        let source = try temporaryFile(png, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }

        let processed = try await ImageProcessor.shared.process(fileAt: source)

        XCTAssertEqual(processed.width, ImageProcessor.defaultMaxPixel)
        XCTAssertEqual(processed.height, ImageProcessor.defaultMaxPixel / 4)
        XCTAssertEqual(processed.byteSize, processed.jpegData.count)
        XCTAssertTrue(try facts(of: processed.jpegData).isJPEG)
    }

    // MARK: - Replays never convert and never delete

    func testAReplayOfASizedCardWithTheRawCapturePairsWithTheBlobAlreadyThere() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 3000, height: 2000)
        let draft = WorkMaterialDraft(
            kind: .image,
            title: "shot.png",
            filename: "shot.png",
            mimeType: "image/png",
            payload: png,
            createdAt: Date().addingTimeInterval(-600)
        )
        let first = try await store.upsertDeskMaterial(draft)
        let blobsBefore = await store._workMaterialBlobRowsForTesting(materialID: first.id)
        XCTAssertEqual(blobsBefore.count, 1)

        // The drainer replays the same envelope — same id, same raw bytes, the
        // capture's own older timestamp — after a claim it could not acknowledge.
        let replayed = try await store.upsertDeskMaterial(draft)

        let blobsAfter = await store._workMaterialBlobRowsForTesting(materialID: first.id)
        XCTAssertEqual(blobsAfter.count, 1, "the replay re-sizes deterministically and adopts the blob; nothing is inserted")
        XCTAssertEqual(blobsAfter.first?.contentHash, blobsBefore.first?.contentHash, "…and nothing is deleted")
        XCTAssertEqual(replayed.contentHash, first.contentHash)
        XCTAssertEqual(replayed.mimeType, "image/jpeg")
        let stillReadable = try await store.loadWorkMaterialPayload(id: first.id)
        XCTAssertNotNil(stillReadable, "the card still reads")
    }

    func testARepairWithTheRawCaptureRestoresTheSizedBytes() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 3000, height: 2000)
        let draft = WorkMaterialDraft(kind: .image, title: "shot.png", filename: "shot.png", mimeType: "image/png", payload: png)
        let first = try await store.upsertDeskMaterial(draft)
        let sizedHash = try XCTUnwrap(first.contentHash)
        // The payload store lost its bytes; the card stands, claiming them.
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: first.id)
        let lost = try await store.loadWorkMaterialPayload(id: first.id)
        XCTAssertNil(lost)

        let repaired = try await store.upsertDeskMaterial(
            WorkMaterialDraft(id: first.id, kind: .image, title: "shot.png", filename: "shot.png", mimeType: "image/png"),
            repairPayload: png
        )

        XCTAssertEqual(repaired.contentHash, sizedHash, "the repair restores the bytes the row promised — the sized ones")
        let restoredValue = try await store.loadWorkMaterialPayload(id: first.id)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(hex(restored), sizedHash)
    }

    func testAReplayOfACardPublishedBeforeTheRuleKeepsItsRawBytes() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 3000, height: 2000)
        let rawHash = hex(png)
        // A card as an earlier build left it: its rows and its blob name the
        // PNG exactly as captured. Built through the seams because the desk
        // write itself no longer produces this state.
        let draft = WorkMaterialDraft(
            kind: .image,
            title: "shot.png",
            filename: "shot.png",
            mimeType: "image/png",
            payload: png,
            createdAt: Date().addingTimeInterval(-600)
        )
        let sized = try await store.upsertDeskMaterial(draft)
        await store._deleteWorkMaterialBlobRowsForTesting(materialID: sized.id)
        let legacyStamp = sized.updatedAt.addingTimeInterval(60)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: sized.id,
            payload: png,
            byteSize: Int64(png.count),
            contentHash: rawHash,
            updatedAt: legacyStamp
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: sized.id,
            updatedAt: legacyStamp,
            contentHash: rawHash,
            byteSize: Int64(png.count)
        )
        let legacyValue = try await store.loadWorkMaterial(id: sized.id)
        let legacy = try XCTUnwrap(legacyValue)
        XCTAssertEqual(legacy.record.contentHash, rawHash, "the fixture must read as a raw card, or this case proves nothing")
        XCTAssertEqual(legacy.payload, png)

        // The same capture replayed by the drainer on the new build, carrying
        // the raw bytes under the capture's own older timestamp.
        let replayed = try await store.upsertDeskMaterial(draft)

        XCTAssertEqual(replayed.contentHash, rawHash, "the card keeps the representation it was published with")
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: sized.id)
        XCTAssertEqual(blobs.map(\.contentHash), [rawHash], "no sized blob was inserted and the raw blob was not retired as superseded")
        let kept = try await store.loadWorkMaterialPayload(id: sized.id)
        XCTAssertEqual(kept, png, "the person's bytes are exactly where they were")
        XCTAssertEqual(replayed.mimeType, legacy.record.mimeType,
                       "a replay repoints bytes; it never re-applies the draft's names to an existing card")
        XCTAssertEqual(replayed.filename, legacy.record.filename)
    }

    /// The drainer replays an envelope captured minutes ago; meanwhile the
    /// person reattached a different picture onto that card. The stale replay
    /// must neither repoint the card back nor retire the replacement's blob as
    /// "superseded" — that blob is what the newer row names — and the bytes the
    /// replay staged, named by nothing, must not be left behind as a stray.
    func testAStaleReplayNeverRetiresTheFileAReattachPutOnTheCard() async throws {
        let store = isolated.make()
        let original = try imageBytes(width: 3000, height: 2000)
        let capture = WorkMaterialDraft(
            kind: .image,
            title: "a.png",
            filename: "a.png",
            mimeType: "image/png",
            payload: original,
            createdAt: Date().addingTimeInterval(-600)
        )
        let first = try await store.upsertDeskMaterial(capture)

        let replacement = try imageBytes(width: 2400, height: 2400)
        let source = try temporaryFile(replacement, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: first.id,
            from: source,
            byteSize: Int64(replacement.count),
            filename: "b.png",
            mimeType: "image/png",
            sourceDevice: nil,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)
        let replacementHash = try XCTUnwrap(reattached.contentHash)
        XCTAssertNotEqual(replacementHash, first.contentHash, "the fixture must change the card's bytes, or this case proves nothing")
        let replacementBytesValue = try await store.loadWorkMaterialPayload(id: first.id)
        let replacementBytes = try XCTUnwrap(replacementBytesValue)

        // The original capture, replayed after the reattach, under its own
        // older timestamp.
        let replayed = try await store.upsertDeskMaterial(capture)

        XCTAssertEqual(replayed.contentHash, replacementHash,
                       "a stale replay never repoints the card off the file the person put there last")
        XCTAssertEqual(replayed.availability, .synced)
        let after = try await store.loadWorkMaterialPayload(id: first.id)
        XCTAssertEqual(after, replacementBytes, "…and never retires that file's blob as superseded")
        let blobs = await store._workMaterialBlobRowsForTesting(materialID: first.id)
        XCTAssertEqual(blobs.compactMap(\.contentHash), [replacementHash],
                       "the replay's own bytes, named by no row, are taken back rather than left as a stray")
    }

    func testAConformingPictureSharedUnderAnotherNameIsRenamedNotReEncoded() async throws {
        let store = isolated.make()
        // A clean JPEG within the cap that the share sheet declared as PNG —
        // the names lie, the bytes are already the desk's shape.
        let jpeg = try imageBytes(width: 800, height: 600, as: .jpeg)

        let record = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "IMG_7.png", filename: "IMG_7.png", mimeType: "image/png", payload: jpeg)
        )

        XCTAssertEqual(record.mimeType, "image/jpeg")
        XCTAssertEqual(record.filename, "IMG_7.jpg")
        XCTAssertEqual(record.title, "IMG_7.jpg")
        let stored = try await store.loadWorkMaterialPayload(id: record.id)
        XCTAssertEqual(stored, jpeg, "already conforming, so stored byte for byte — never encoded a second time")
    }

    // MARK: - Reattach

    func testAReattachOfAConformingJPEGStillRenamesTheCard() async throws {
        let store = isolated.make()
        // A card whose title kept a PNG name — an undecodable capture, stored
        // as received, so nothing rewrote it.
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "IMG.png", filename: "IMG.png", mimeType: "image/png", payload: Data("not a picture".utf8))
        )
        let clean = try imageBytes(width: 900, height: 300, as: .jpeg)
        let source = try temporaryFile(clean, extension: "jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)

        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: material.id,
            from: source,
            byteSize: Int64(clean.count),
            filename: "clean.jpg",
            mimeType: "image/jpeg",
            sourceDevice: nil,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.title, "IMG.jpg", "the export names the copy after the title, so it must not claim PNG over JPEG bytes")
        XCTAssertEqual(reattached.filename, "clean.jpg")
        XCTAssertEqual(reattached.mimeType, "image/jpeg")
        let stored = try await store.loadWorkMaterialPayload(id: material.id)
        XCTAssertEqual(stored, clean, "already conforming, so staged from the file byte for byte")
    }

    func testAReattachedPictureIsSizedAndRenamedToo() async throws {
        let store = isolated.make()
        let original = try imageBytes(width: 400, height: 400)
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "sketch.png", filename: "sketch.png", mimeType: "image/png", payload: original)
        )
        XCTAssertEqual(material.title, "sketch.jpg")
        let firstThumbnail = try XCTUnwrap(material.thumbnailData)

        let replacement = try imageBytes(width: 3000, height: 1000)
        let source = try temporaryFile(replacement, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)

        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: material.id,
            from: source,
            byteSize: Int64(replacement.count),
            filename: "big.png",
            mimeType: "image/png",
            sourceDevice: nil,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.mimeType, "image/jpeg")
        XCTAssertEqual(reattached.filename, "big.jpg")
        XCTAssertEqual(reattached.title, "sketch.jpg", "a title that already names a JPEG stays")
        XCTAssertEqual(reattached.storageMode, .syncedPayload)
        XCTAssertLessThan(reattached.byteSize, Int64(replacement.count))
        XCTAssertNotEqual(reattached.thumbnailData, firstThumbnail)
        let storedValue = try await store.loadWorkMaterialPayload(id: material.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(try facts(of: stored).longEdge, Constants.workboardImageMaxPixel)
        XCTAssertEqual(reattached.contentHash, hex(stored))
    }

    func testAReattachOntoATitleNamingTheOldFormatRenamesTheTitle() async throws {
        let store = isolated.make()
        // A card whose title kept a PNG name — an undecodable capture, stored
        // as received, so nothing rewrote it.
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(kind: .image, title: "IMG.png", filename: "IMG.png", mimeType: "image/png", payload: Data("not a picture".utf8))
        )
        XCTAssertEqual(material.title, "IMG.png")
        let replacement = try imageBytes(width: 900, height: 300)
        let source = try temporaryFile(replacement, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)

        let reattachedValue = try await store.replaceWorkMaterialPayloadFile(
            id: material.id,
            from: source,
            byteSize: Int64(replacement.count),
            filename: "IMG.png",
            mimeType: "image/png",
            sourceDevice: nil,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )
        let reattached = try XCTUnwrap(reattachedValue)

        XCTAssertEqual(reattached.title, "IMG.jpg", "the export names the copy after the title, so the title must not claim PNG")
        XCTAssertEqual(reattached.filename, "IMG.jpg")
        XCTAssertEqual(reattached.mimeType, "image/jpeg")
    }
}

#endif
