// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferPreviewEnrichmentTests.swift
//
// WS-2 bounded preview enrichment. Locks the pure, network-free seams:
//   1. `ImageProcessor.thumbnailOnly` — decode-as-validity (non-image bytes →
//      nil) + a real image producing a bounded JPEG.
//   2. `FileTransferOutputDetector.buildPreviewPatches` — budget / eligibility /
//      sequencing (skip-too-big-continue-to-smaller, stored-budget stops
//      production, sequential draft order, strict-UTF-8 rejection, image lane).
//      Fetch is injected (no live server) so the logic is exercised purely.
//
// PRIVACY: the pipeline never logs filenames / storedKeys / bytes; these tests
// assert only on returned values, never on any emitted log.

import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Conduck

final class FileTransferPreviewEnrichmentTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.test")!,
            username: "conduck",
            credential: "secret",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    /// A server-reference output draft (the shape `FileTransferOutputDetector`
    /// mints for a confirmed agent-written file). `byteSize` 0 == unknown.
    private func serverDraft(filename: String, storedKey: String, byteSize: Int, sequence: Int = 0) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "application/octet-stream",
            filename: filename,
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: byteSize,
            sequence: sequence
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        return draft
    }

    /// A small real raster image encoded to PNG — decodes cleanly through
    /// ImageIO so `thumbnailOnly` produces a JPEG.
    private func makePNG(width: Int = 16, height: Int = 16) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Records the injected fetch closure's calls + serves canned bytes by key.
    /// Mirrors the injected-fetch contract `buildPreviewPatches` is written
    /// against: bytes ACTUALLY received are reported on every outcome so budget
    /// accounting is exercised — an over-cap response bails with
    /// `(nil, maxBytes + 1)` (the server still cost that bandwidth); a missing key
    /// is a zero-byte failure `(nil, 0)`.
    private final class FetchRecorder {
        var responses: [String: Data] = [:]
        private(set) var requestedKeys: [String] = []
        func fetch(_ snapshot: SettingsManager.FileTransferSnapshot, _ storedKey: String, _ maxBytes: Int) async -> (data: Data?, received: Int64) {
            requestedKeys.append(storedKey)
            guard let data = responses[storedKey] else { return (nil, 0) }
            if data.count <= maxBytes { return (data, Int64(data.count)) }
            // Over-cap: the server delivered maxBytes + 1 before the client bailed.
            return (nil, Int64(maxBytes) + 1)
        }
    }

    // MARK: - 1. thumbnailOnly

    func testThumbnailOnlyRejectsNonImageBytes() {
        XCTAssertNil(ImageProcessor.thumbnailOnly(from: Data("this is not an image".utf8)),
                     "decode-as-validity: non-image bytes must fail rather than mint a bogus thumbnail")
    }

    func testThumbnailOnlyProducesBoundedJPEGFromRealImage() {
        let png = makePNG()
        let thumb = ImageProcessor.thumbnailOnly(from: png)
        let data = try? XCTUnwrap(thumb)
        XCTAssertNotNil(data, "a real image must downsample to a thumbnail JPEG")
        if let data {
            XCTAssertLessThanOrEqual(data.count, ImageProcessor.thumbnailPreviewByteCeiling)
            // The bytes are a real JPEG (ImageIO can re-open them).
            XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
        }
    }

    // MARK: - 2. buildPreviewPatches — budgets / eligibility / sequencing

    func testTextLaneProducesPreviewPatch() async {
        let recorder = FetchRecorder()
        let key = "conv/aaaa__notes.txt"
        recorder.responses[key] = Data("hello world".utf8)
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [serverDraft(filename: "notes.txt", storedKey: key, byteSize: 11)],
            messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].storedKey, key)
        XCTAssertEqual(patches[0].previewKind, "text")
        XCTAssertEqual(patches[0].previewData, Data("hello world".utf8))
        XCTAssertNil(patches[0].thumbnailData)
    }

    func testTextLaneRejectsInvalidUTF8() async {
        let recorder = FetchRecorder()
        let key = "conv/bbbb__data.json"
        recorder.responses[key] = Data([0xFF, 0xFE, 0xFD])   // invalid UTF-8
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [serverDraft(filename: "data.json", storedKey: key, byteSize: 3)],
            messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertTrue(patches.isEmpty, "invalid UTF-8 must never be stored as a text preview")
        XCTAssertEqual(recorder.requestedKeys, [key], "it still fetched before rejecting on decode")
    }

    func testKnownTooBigItemSkippedWithoutFetchThenSmallerSucceeds() async {
        let recorder = FetchRecorder()
        let bigKey = "conv/cccc__huge.txt"
        let smallKey = "conv/dddd__small.txt"
        recorder.responses[smallKey] = Data("tiny".utf8)
        // Source budget deliberately small so the FIRST (known-large) item is
        // over-budget and skipped WITHOUT a fetch; the later smaller item still
        // gets its turn (skip-too-big-continue-to-smaller).
        var source: Int64 = 1_000
        var stored = 512 * 1024
        let drafts = [
            serverDraft(filename: "huge.txt", storedKey: bigKey, byteSize: 5_000, sequence: 0),
            serverDraft(filename: "small.txt", storedKey: smallKey, byteSize: 4, sequence: 1),
        ]
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: drafts, messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertEqual(patches.map(\.storedKey), [smallKey])
        XCTAssertEqual(recorder.requestedKeys, [smallKey],
                       "the known-too-big item must be skipped WITHOUT a fetch")
    }

    func testStoredBudgetStopsProduction() async {
        let recorder = FetchRecorder()
        let key = "conv/eeee__report.csv"
        // Unknown byteSize (0) → eligible → fetches; the produced text exceeds
        // the tiny stored budget → skipped post-fetch, no patch.
        recorder.responses[key] = Data(repeating: 0x2C, count: 500)   // 500 commas (valid UTF-8)
        var source: Int64 = 8 * 1024 * 1024
        var stored = 100
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [serverDraft(filename: "report.csv", storedKey: key, byteSize: 0)],
            messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertTrue(patches.isEmpty, "a produced preview over the stored budget is not persisted")
        XCTAssertEqual(recorder.requestedKeys, [key], "it fetched (unknown size is eligible) then dropped on the stored guard")
    }

    func testSequentialDraftOrderPreserved() async {
        let recorder = FetchRecorder()
        let keys = ["conv/1__a.txt", "conv/2__b.md", "conv/3__c.log"]
        for k in keys { recorder.responses[k] = Data("ok-\(k)".utf8) }
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let drafts = keys.enumerated().map { serverDraft(filename: ($0.element as NSString).lastPathComponent, storedKey: $0.element, byteSize: 0, sequence: $0.offset) }
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: drafts, messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertEqual(recorder.requestedKeys, keys, "fetches happen strictly in draft order")
        XCTAssertEqual(patches.map(\.storedKey), keys, "patches preserve draft order")
    }

    func testImageLaneProducesThumbnailPatch() async {
        let recorder = FetchRecorder()
        let key = "conv/ffff__chart.png"
        recorder.responses[key] = makePNG()
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [serverDraft(filename: "chart.png", storedKey: key, byteSize: 0)],
            messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertEqual(patches.count, 1)
        XCTAssertNil(patches[0].previewData, "the image lane never sets previewData")
        XCTAssertNil(patches[0].previewKind, "the image lane never sets previewKind")
        XCTAssertNotNil(patches[0].thumbnailData, "the image lane patches thumbnailData")
    }

    func testImageLaneRejectsNonImageBytesAtStoredKey() async {
        let recorder = FetchRecorder()
        let key = "conv/gggg__fake.png"
        recorder.responses[key] = Data("not really a png".utf8)
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [serverDraft(filename: "fake.png", storedKey: key, byteSize: 0)],
            messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertTrue(patches.isEmpty, "a .png whose bytes don't decode mints no thumbnail (decode-as-validity)")
    }

    func testOverCapBailChargesSourceBudgetAndStopsFurtherFetches() async {
        // Two unknown-size image outputs. The first responds LARGER than the cap
        // (Range-ignoring server) → the recorder bails with (nil, cap+1). That
        // must charge the source budget so the second oversized item is skipped
        // WITHOUT a fetch — the exact N×8 MiB leak the fix closes.
        let recorder = FetchRecorder()
        let firstKey = "conv/oversized1__a.png"
        let secondKey = "conv/oversized2__b.png"
        recorder.responses[firstKey] = Data(repeating: 0x00, count: 9 * 1024 * 1024)   // > 8 MiB cap
        recorder.responses[secondKey] = makePNG()
        var source: Int64 = 8 * 1024 * 1024   // one image's worth of source budget
        var stored = 512 * 1024
        let drafts = [
            serverDraft(filename: "a.png", storedKey: firstKey, byteSize: 0, sequence: 0),
            serverDraft(filename: "b.png", storedKey: secondKey, byteSize: 0, sequence: 1),
        ]
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: drafts, messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertTrue(patches.isEmpty, "the over-cap image produced no thumbnail")
        XCTAssertEqual(recorder.requestedKeys, [firstKey],
                       "the over-cap bail charged the budget → the second item is skipped WITHOUT a fetch")
        XCTAssertLessThanOrEqual(source, 0, "the ~cap+1 bytes pulled were charged, exhausting the source budget")
    }

    func testZeroByteFailureChargesNothing() async {
        // First key is absent → the recorder returns (nil, 0): a zero-byte
        // failure must charge NOTHING, so the second (valid) item still fetches
        // and its small cost is the only decrement.
        let recorder = FetchRecorder()
        let missingKey = "conv/missing__a.txt"
        let realKey = "conv/real__b.txt"
        recorder.responses[realKey] = Data("hi".utf8)   // 2 bytes
        let start: Int64 = 8 * 1024 * 1024
        var source = start
        var stored = 512 * 1024
        let drafts = [
            serverDraft(filename: "a.txt", storedKey: missingKey, byteSize: 0, sequence: 0),
            serverDraft(filename: "b.txt", storedKey: realKey, byteSize: 0, sequence: 1),
        ]
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: drafts, messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertEqual(patches.map(\.storedKey), [realKey])
        XCTAssertEqual(recorder.requestedKeys, [missingKey, realKey], "both were attempted")
        XCTAssertEqual(source, start - 2,
                       "a zero-byte failure charges nothing — only the 2 real bytes are decremented")
    }

    func testNonServerReferenceDraftIsIneligible() async {
        let recorder = FetchRecorder()
        // An inline (non-server) text draft must never be enriched — no fetch.
        var draft = AttachmentDraft(
            mimeType: "text/plain", filename: "inline.txt", data: Data("x".utf8),
            thumbnailData: nil, width: 0, height: 0, byteSize: 1, sequence: 0)
        draft.storedKey = "conv/hhhh__inline.txt"   // isServerReference stays false
        var source: Int64 = 8 * 1024 * 1024
        var stored = 512 * 1024
        let patches = await FileTransferOutputDetector.buildPreviewPatches(
            for: [draft], messageID: UUID(), snapshot: snapshot(),
            sourceBudget: &source, storedBudget: &stored, fetch: recorder.fetch)
        XCTAssertTrue(patches.isEmpty)
        XCTAssertTrue(recorder.requestedKeys.isEmpty, "a non-server-reference draft is never fetched")
    }
}
