// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardThumbnailTests.swift
//
// Where a Work image card's preview comes from, and where it deliberately does
// not. Thumbnails are decoded at the ONE desk write every capture lane passes
// through, so these cases hold the property no individual lane can verify for
// itself: a picker, a drop, the share drainer and a chat capture all publish a
// card that renders its own artwork, and none of them had to know that.
//
// The two refusals matter as much as the fills. A device-local (vault) image
// gets NO persisted preview — its bytes are meant to stay on this device, and
// the material row is CloudKit-mirrored — and a non-image card never gets one
// at all. The bytes in the vault case are proved decodable in the same test, so
// a nil there is the LANE talking, not ImageIO.
//
// The backfill cases hold the legacy contract: rows written before the import
// site decoded previews are repaired in place, with no timestamp on the
// material or its desk, on EVERY physical row a CloudKit merge produced — and
// a card whose bytes are not an image is written off once rather than blocking
// the head of every future pass.

#if !os(watchOS)

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Conduck

final class WorkboardThumbnailTests: XCTestCase {

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - Synthesis

    /// Real encoded image bytes, synthesised rather than fixtured: the pipeline
    /// under test is ImageIO, so a checked-in file would only prove that the
    /// file still parses.
    private func imageBytes(
        width: Int,
        height: Int,
        as utType: UTType = .png
    ) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), "Failed to create a \(width)x\(height) CGContext")
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage(), "CGContext.makeImage returned nil")

        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, utType.identifier as CFString, 1, nil
        ), "Failed to create an image destination for \(utType.identifier)")
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination),
                      "Failed to finalize the \(utType.identifier) encode")
        return out as Data
    }

    /// Write bytes to a throwaway file and hand back a cleanup the caller runs.
    private func temporaryFile(_ bytes: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workboard-thumb-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    // MARK: - The import site

    func testAnInlineImageCaptureGetsAPresentationThumbnail() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 640, height: 400)

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Ferry board",
                filename: "ferry.png",
                mimeType: "image/png",
                payload: png
            )
        )

        XCTAssertEqual(material.storageMode, .syncedPayload,
                       "a small image must take the synced lane for this case to mean anything")
        let thumbnail = try XCTUnwrap(
            material.thumbnailData,
            "an inline image capture must carry the preview the desk write decoded"
        )
        XCTAssertFalse(thumbnail.isEmpty)
        XCTAssertLessThanOrEqual(thumbnail.count, ImageProcessor.thumbnailPreviewByteCeiling)
    }

    func testAFileBackedImageCaptureGetsAPresentationThumbnail() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 500, height: 500)
        let source = try temporaryFile(png, extension: "png")
        defer { try? FileManager.default.removeItem(at: source) }

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Scan",
                filename: "scan.png",
                mimeType: "image/png"
            ),
            sourceFileURL: source,
            sourceFileByteSize: Int64(png.count)
        )

        XCTAssertEqual(material.storageMode, .syncedPayload)
        XCTAssertNotNil(
            material.thumbnailData,
            "a file-backed image capture must be downsampled straight from the file it named"
        )
    }

    func testAnOversizedPictureIsSizedOntoTheSyncedLane() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 320, height: 240)
        // Decodable image bytes with a tail that pushes the payload past the
        // sync ceiling: PNG readers stop at IEND, so ImageIO still decodes it.
        // Before the desk sized its pictures this was the vault-lane fixture;
        // now the whole point is that a decodable picture never reaches the
        // vault on size alone — it is shrunk first, and the shrunk copy syncs.
        let oversized = png + Data(count: Int(Constants.workboardSyncCeilingBytes) + 1)
        XCTAssertNotNil(
            ImageProcessor.thumbnailOnly(from: oversized),
            "the fixture must stay decodable, or this case proves nothing about the lane"
        )

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Huge capture",
                filename: "huge.png",
                mimeType: "image/png",
                payload: oversized
            )
        )

        XCTAssertEqual(material.storageMode, .syncedPayload,
                       "a picture is sized before the lane is chosen, so it syncs")
        XCTAssertLessThan(material.byteSize, Constants.workboardSyncCeilingBytes)
        XCTAssertEqual(material.mimeType, "image/jpeg")
        XCTAssertEqual(material.filename, "huge.jpg")
        XCTAssertNotNil(material.thumbnailData, "a synced image card carries its preview")
    }

    func testAVaultLaneImageKeepsNoPersistedThumbnail() async throws {
        let store = isolated.make()
        // An animation is stored as received, so a decodable oversized GIF is
        // what still reaches the vault: GIF readers stop at the trailer, so
        // ImageIO still makes a preview of this — which is exactly the point.
        // A nil on the card has to be the LANE refusing to persist it, never a
        // decode that failed.
        let oversized = try animatedGIFBytes() + Data(count: Int(Constants.workboardSyncCeilingBytes) + 1)
        XCTAssertNotNil(
            ImageProcessor.thumbnailOnly(from: oversized),
            "the fixture must stay decodable, or this case proves nothing about the lane"
        )

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Huge capture",
                filename: "huge.gif",
                mimeType: "image/gif",
                payload: oversized
            )
        )

        XCTAssertEqual(material.storageMode, .localVault)
        XCTAssertEqual(material.mimeType, "image/gif", "bytes left alone keep the name they came with")
        XCTAssertNil(
            material.thumbnailData,
            "a device-local image must persist no preview: the row is CloudKit-mirrored"
        )
    }

    /// A two-frame GIF, synthesised like `imageBytes` — the one picture the
    /// desk write leaves exactly as it came.
    private func animatedGIFBytes() throws -> Data {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.gif.identifier as CFString, 2, nil
        ))
        for _ in 0..<2 {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func testANonImageCardGetsNoThumbnail() async throws {
        let store = isolated.make()
        // Image bytes under a `.file` card: the KIND decides, so a preview
        // cannot appear just because the payload happens to be decodable.
        let png = try imageBytes(width: 200, height: 200)

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "diagram.png",
                filename: "diagram.png",
                mimeType: "image/png",
                payload: png
            )
        )

        XCTAssertEqual(material.storageMode, .syncedPayload)
        XCTAssertNil(material.thumbnailData,
                     "only an image card carries a preview; a file card renders its type")
    }

    func testAReattachedImageGetsAFreshThumbnail() async throws {
        let store = isolated.make()
        let original = try imageBytes(width: 400, height: 400)
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Sketch",
                filename: "sketch.png",
                mimeType: "image/png",
                payload: original
            )
        )
        let firstThumbnail = try XCTUnwrap(material.thumbnailData)

        let replacement = try imageBytes(width: 900, height: 300, as: .jpeg)
        let source = try temporaryFile(replacement, extension: "jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)

        let reattached = try await store.replaceWorkMaterialPayloadFile(
            id: material.id,
            from: source,
            byteSize: Int64(replacement.count),
            filename: "sketch.jpg",
            mimeType: "image/jpeg",
            sourceDevice: nil,
            expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
        )

        let record = try XCTUnwrap(reattached)
        XCTAssertEqual(record.storageMode, .syncedPayload)
        let secondThumbnail = try XCTUnwrap(
            record.thumbnailData,
            "a reattached image must get a preview of the bytes that replaced the old ones"
        )
        XCTAssertNotEqual(secondThumbnail, firstThumbnail,
                          "the preview must describe the NEW payload, not the one it replaced")
    }

    // MARK: - Backfill

    func testTheBackfillFillsALegacyRowWithoutMovingAnyRevision() async throws {
        let store = isolated.make()
        let png = try imageBytes(width: 512, height: 384)
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Map",
                filename: "map.png",
                mimeType: "image/png",
                payload: png
            )
        )
        // A CloudKit merge of one logical card, with the duplicate NEWER than
        // the original: a backfill that reached only one row would still look
        // correct through the canonical read without this.
        await store._duplicateWorkMaterialRowForTesting(
            id: material.id,
            updatedAt: material.updatedAt.addingTimeInterval(60)
        )
        // The legacy shape: rows written before the import site decoded one.
        await store._clearWorkMaterialThumbnailForTesting(materialID: material.id)

        let beforeRows = await store._workMaterialRowsForTesting(id: material.id)
        XCTAssertEqual(beforeRows.count, 2)
        XCTAssertTrue(beforeRows.allSatisfy { $0.thumbnailByteCount == nil })
        let deskBeforeValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskBefore = try XCTUnwrap(deskBeforeValue)

        let report = await store.repairMissingWorkThumbnails()

        XCTAssertEqual(report, WorkThumbnailRepairReport(examined: 1, filled: 1, undecodable: 0))
        let afterRows = await store._workMaterialRowsForTesting(id: material.id)
        XCTAssertEqual(afterRows.count, 2)
        XCTAssertTrue(
            afterRows.allSatisfy { ($0.thumbnailByteCount ?? 0) > 0 },
            "every physical row must carry the preview, whichever wins the canonical read"
        )
        XCTAssertEqual(afterRows.map(\.updatedAt), beforeRows.map(\.updatedAt),
                       "a presentation write stamps no material timestamp")
        let deskAfterValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let deskAfter = try XCTUnwrap(deskAfterValue)
        XCTAssertEqual(
            WorkboardRevision.value(for: deskAfter.updatedAt),
            WorkboardRevision.value(for: deskBefore.updatedAt),
            "the desk revision must not move: a brief nobody edited cannot read as changed"
        )
    }

    func testTheBackfillWritesOffBytesThatAreNotAnImageAndDoesNotRetryThem() async throws {
        let store = isolated.make()
        // A mislabelled capture an older build could write: an image CARD whose
        // payload ImageIO will never decode. It reaches the synced lane exactly
        // as a real image would, so it is a legitimate backfill candidate.
        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Broken",
                filename: "broken.png",
                mimeType: "image/png",
                payload: Data("this was never an image".utf8)
            )
        )
        XCTAssertEqual(material.storageMode, .syncedPayload)
        XCTAssertNil(material.thumbnailData)

        let first = await store.repairMissingWorkThumbnails()
        XCTAssertEqual(first, WorkThumbnailRepairReport(examined: 1, filled: 0, undecodable: 1))

        let second = await store.repairMissingWorkThumbnails()
        XCTAssertEqual(
            second.examined, 0,
            "a card written off once must not spend a slot of the next bounded pass"
        )

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let card = try XCTUnwrap(desk.materials.first { $0.id == material.id })
        XCTAssertNil(card.thumbnailData)
    }

    /// A merge left one card with two physical rows naming DIFFERENT blobs, and
    /// the row without a preview is not the one the canonical read answers with.
    ///
    /// The preview a row gets has to be decoded from the bytes THAT ROW names.
    /// Reading the card's payload through the ordinary loader answers for the
    /// canonical row instead, so the picture of one payload would be written
    /// onto a row that still claims another — on a CloudKit-mirrored column,
    /// where it then travels to every device as that card's artwork.
    func testTheBackfillDecodesTheBytesTheRepairedRowNamesNotTheCanonicalRows() async throws {
        let store = isolated.make()
        // Two shapes, so the previews they produce cannot be confused: the
        // assertion below is meaningless if both decode to the same bytes.
        let ownBytes = try imageBytes(width: 640, height: 400)
        let peerBytes = try imageBytes(width: 300, height: 900, as: .jpeg)

        let material = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .image,
                title: "Ferry board",
                filename: "ferry.png",
                mimeType: "image/png",
                payload: ownBytes
            )
        )
        XCTAssertEqual(material.storageMode, .syncedPayload)
        // The row names the bytes the desk write STORED — the PNG sized to a
        // JPEG by `WorkMaterialImagePolicy` — read NOW, while this row is still
        // the canonical one: once the peer row below lands, the payload read
        // answers from the peer, which is the whole point of the case.
        let storedOwnValue = try await store.loadWorkMaterialPayload(id: material.id)
        let storedOwn = try XCTUnwrap(storedOwnValue)
        XCTAssertNotEqual(storedOwn, ownBytes, "the desk keeps the sized JPEG, not the PNG handed over")
        let originalRows = await store._workMaterialRowsForTesting(id: material.id)
        let ownHash = try XCTUnwrap(originalRows.first?.contentHash)
        let ownSize = try XCTUnwrap(originalRows.first?.byteSize)

        // The other device's payload, imported under the same material id...
        let peerHash = "peer-content-hash"
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: material.id,
            payload: peerBytes,
            byteSize: Int64(peerBytes.count),
            contentHash: peerHash,
            updatedAt: material.updatedAt.addingTimeInterval(120)
        )
        // ...and the merged row that names it, NEWER, so it — and not the row
        // being repaired — is what the canonical read resolves.
        await store._duplicateWorkMaterialRowForTesting(
            id: material.id,
            updatedAt: material.updatedAt.addingTimeInterval(120),
            contentHash: peerHash,
            byteSize: Int64(peerBytes.count)
        )
        // Only the ORIGINAL row is legacy-shaped. The merged row keeps its
        // preview, so it is not a candidate and cannot mask the mismatch.
        await store._clearWorkMaterialThumbnailForTesting(
            materialID: material.id,
            contentHash: ownHash
        )

        let report = await store.repairMissingWorkThumbnails()
        XCTAssertEqual(report.examined, 1)
        XCTAssertEqual(report.filled, 1, "the row still names complete bytes, so it is repairable")

        let expectedOwn = try XCTUnwrap(ImageProcessor.thumbnailOnly(from: storedOwn))
        let expectedPeer = try XCTUnwrap(ImageProcessor.thumbnailOnly(from: peerBytes))
        XCTAssertNotEqual(
            expectedOwn.count, expectedPeer.count,
            "the two fixtures must produce distinguishable previews, or this case proves nothing"
        )

        let afterRows = await store._workMaterialRowsForTesting(id: material.id)
        let repaired = try XCTUnwrap(
            afterRows.first { $0.contentHash == ownHash && $0.byteSize == ownSize }
        )
        XCTAssertEqual(
            repaired.thumbnailByteCount, expectedOwn.count,
            "the preview must be decoded from the payload this row names, never the canonical row's"
        )
        XCTAssertNotEqual(
            repaired.thumbnailByteCount, expectedPeer.count,
            "a merged duplicate's payload must never become another row's artwork"
        )
    }
}

#endif
