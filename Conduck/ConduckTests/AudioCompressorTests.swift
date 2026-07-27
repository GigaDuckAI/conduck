// SPDX-License-Identifier: Apache-2.0

// Conduck
// AudioCompressorTests.swift
//
// Locks AudioCompressor's two load-bearing contracts. (1) Never-throw
// fallback: undecodable input (empty data, garbage bytes, a header-only
// 0-frame M4A — the shape a 0.0s wrist capture produces) must come back as
// `didCompress == false` with the ORIGINAL bytes untouched, never a crash.
// (2) Format truth: `.original` fallbacks ship the INPUT's bytes, so their
// mime/extension must describe the sniffed source container (the recorders'
// AAC M4A, CarPlay's CAF) — a WAV-declared M4A can be rejected or mis-decoded
// by stricter STT providers. The happy path is locked too: a real small AAC
// capture round-trips to a smaller 16 kHz `.aac` result.

import XCTest
import AVFoundation
@testable import Conduck

final class AudioCompressorTests: XCTestCase {

    // MARK: - Format truth (pure mapping)

    func testFormatMimeAndExtensionTruth() {
        // `.original` carries the source container's truth — never a
        // hardcoded audio/wav label.
        let cases: [(format: AudioFormat, mime: String, ext: String)] = [
            (.aac, "audio/mp4", "m4a"),
            (.wav, "audio/wav", "wav"),
            (.original(.m4a), "audio/mp4", "m4a"),
            (.original(.caf), "audio/x-caf", "caf"),
            (.original(.wav), "audio/wav", "wav"),
        ]
        for c in cases {
            XCTAssertEqual(c.format.mimeType, c.mime)
            XCTAssertEqual(c.format.fileExtension, c.ext)
        }
    }

    func testSourceContainerSniff() {
        // ISO-BMFF: 4-byte box size, then "ftyp" (brand irrelevant here).
        let m4a = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypM4A ".utf8))
        XCTAssertEqual(SourceAudioContainer.sniff(m4a), .m4a)

        // CAF: "caff" leads the file.
        let caf = Data(Array("caff".utf8) + [0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(SourceAudioContainer.sniff(caf), .caf)

        // WAV: "RIFF" + 4-byte size + "WAVE".
        let wav = Data(Array("RIFF".utf8) + [0x24, 0x00, 0x00, 0x00] + Array("WAVE".utf8))
        XCTAssertEqual(SourceAudioContainer.sniff(wav), .wav)

        // Unrecognised / too-short data defaults to the recorders' native
        // container, so the dominant producers stay labelled correctly.
        XCTAssertEqual(SourceAudioContainer.sniff(Data()), .m4a)
        XCTAssertEqual(SourceAudioContainer.sniff(Data([0x01, 0x02])), .m4a)
        XCTAssertEqual(SourceAudioContainer.sniff(Data(repeating: 0xAB, count: 64)), .m4a)
    }

    // MARK: - Never-throw fallback on undecodable input

    func testEmptyDataFallsBackToOriginal() async {
        let result = await AudioCompressor.compress(Data())
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.data, Data())
        XCTAssertEqual(result.format, .original(.m4a))
    }

    func testGarbageBytesFallBackToOriginal() async {
        // Sub-1KB non-audio bytes — AVAudioFile can't open them on either
        // the AAC or the WAV path; both must fall through gracefully.
        let garbage = Data(repeating: 0xAB, count: 600)
        let result = await AudioCompressor.compress(garbage)
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.data, garbage)
        XCTAssertEqual(result.originalSizeBytes, garbage.count)
        XCTAssertEqual(result.format, .original(.m4a))
    }

    func testHeaderOnlyM4AFallsBackToOriginalWithM4ATruth() async throws {
        // The 0.0s-capture husk: a finalized AAC container holding zero
        // frames. Both compression paths fail on the empty buffer; the husk
        // must come back untouched and labelled as the M4A it really is.
        let husk = try makeHeaderOnlyM4A()
        let result = await AudioCompressor.compress(husk)
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.data, husk)
        XCTAssertEqual(result.format, .original(.m4a))
        XCTAssertEqual(result.format.mimeType, "audio/mp4")
        XCTAssertEqual(result.format.fileExtension, "m4a")
    }

    func testCompressToWAVGarbageFallsBackToOriginal() async {
        // The direct WAV entry (benchmarks + AAC fallback) shares the
        // never-throw / original-bytes contract.
        let garbage = Data(repeating: 0xCD, count: 512)
        let result = await AudioCompressor.compressToWAV(garbage)
        XCTAssertFalse(result.didCompress)
        XCTAssertEqual(result.data, garbage)
        XCTAssertEqual(result.format, .original(.m4a))
    }

    // MARK: - Happy path

    func testRealRecordingCompressesToAAC() async throws {
        // A 48 kHz mono AAC sine (the recorders' capture shape) re-encodes to
        // 16 kHz mono AAC — smaller bytes, `.aac` truth.
        let input = try makeSineM4A()
        let result = await AudioCompressor.compress(input)
        XCTAssertTrue(result.didCompress)
        XCTAssertEqual(result.format, .aac)
        XCTAssertLessThan(result.data.count, input.count)
        XCTAssertEqual(result.originalSizeBytes, input.count)
        XCTAssertEqual(result.compressedSizeBytes, result.data.count)
    }

    // MARK: - Fixtures

    /// Finalized AAC/M4A container with ZERO audio frames — the on-disk shape
    /// an instant-stopped `AVAudioRecorder` capture leaves behind.
    private func makeHeaderOnlyM4A() throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressor-husk-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
        ]
        // Opened for writing and released without a single `write` — the
        // dealloc finalizes a header-only file.
        try autoreleasepool {
            _ = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
        return try Data(contentsOf: url)
    }

    /// Small real recording: a 440 Hz sine encoded as 48 kHz mono AAC/M4A
    /// (mirrors the Watch/iOS recorder output). Two seconds keeps the encode
    /// fast while leaving the 16 kHz re-encode clearly smaller.
    private func makeSineM4A(seconds: Double = 2.0, sampleRate: Double = 48_000) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressor-sine-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let pcmFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
