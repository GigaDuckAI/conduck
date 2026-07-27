// SPDX-License-Identifier: Apache-2.0

import Foundation
import AVFoundation

/// Container of the bytes handed to `compress`/`compressToWAV`, resolved by
/// magic-byte sniff (mirrors `ImageFormatSniffer` — bytes are the only source
/// of truth shared by every producer). Known producers: the Watch/iOS
/// `AVAudioRecorder` captures (AAC M4A) and CarPlay's PCM tap file (CAF).
enum SourceAudioContainer: String, Sendable, Equatable {
    case m4a, caf, wav

    var mimeType: String {
        switch self {
        case .m4a: return "audio/mp4"
        case .caf: return "audio/x-caf"
        case .wav: return "audio/wav"
        }
    }

    /// File extension WITHOUT the leading dot (matches `rawValue`).
    var fileExtension: String { rawValue }

    /// Map leading magic bytes to a container. Total: unrecognised/short data
    /// falls back to `.m4a` — the recorders' native container, so the dominant
    /// producers stay labelled correctly even for a husk too short to carry
    /// its `ftyp` box. Reads at most the first 12 bytes.
    static func sniff(_ data: Data) -> SourceAudioContainer {
        let bytes = [UInt8](data.prefix(12))

        // M4A / MP4: ISO-BMFF `ftyp` box tag at bytes 4..<8 (bytes 0..<4 are
        // the box size, not a fixed magic, so we anchor on the tag).
        if ascii(bytes, 4..<8) == "ftyp" {
            return .m4a
        }

        // CAF: "caff" at 0..<4.
        if ascii(bytes, 0..<4) == "caff" {
            return .caf
        }

        // WAV: RIFF container — "RIFF" at 0..<4 AND "WAVE" at 8..<12
        // (bytes 4..<8 are the little-endian file size, skipped).
        if ascii(bytes, 0..<4) == "RIFF", ascii(bytes, 8..<12) == "WAVE" {
            return .wav
        }

        return .m4a
    }

    /// Decode a fixed byte range of `bytes` as ASCII (the `ftyp` / `caff` /
    /// RIFF four-char tags). Returns nil if the range is out of bounds.
    private static func ascii(_ bytes: [UInt8], _ range: Range<Int>) -> String? {
        guard range.upperBound <= bytes.count else { return nil }
        return String(bytes: bytes[range], encoding: .ascii)
    }
}

/// Audio format produced by compression
enum AudioFormat: Sendable, Equatable {
    case aac
    case wav
    /// Compression fell back — the result carries the INPUT's untouched bytes,
    /// so mime/extension truth comes from the sniffed source container (the
    /// recorder's AAC M4A on Watch/iOS, CAF on CarPlay), never a hardcoded
    /// label a stricter provider could reject.
    case original(SourceAudioContainer)

    var mimeType: String {
        switch self {
        case .aac: return "audio/mp4"
        case .wav: return "audio/wav"
        case .original(let source): return source.mimeType
        }
    }

    var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        case .original(let source): return source.fileExtension
        }
    }
}

/// Result of audio compression operation
struct CompressionResult {
    /// Compressed (or original on failure) audio data
    let data: Data

    /// Original audio size in bytes
    let originalSizeBytes: Int

    /// Compressed audio size in bytes
    let compressedSizeBytes: Int

    /// Time spent compressing in milliseconds
    let compressionTimeMs: Int

    /// Whether compression was successful (false = fallback to original)
    let didCompress: Bool

    /// The format of the output audio data
    let format: AudioFormat

    /// Compression ratio (compressedSize / originalSize)
    var compressionRatio: Double {
        guard originalSizeBytes > 0 else { return 1.0 }
        return Double(compressedSizeBytes) / Double(originalSizeBytes)
    }
}

/// Compresses audio to optimal format for STT APIs (16kHz mono).
///
/// Uses AAC encoding on both iOS and macOS (unified path, no platform branching).
/// Falls back to WAV if AAC encoding fails, then to original if WAV is larger.
///
/// This reduces file sizes without affecting transcription quality,
/// since STT models internally downsample to 16kHz mono anyway.
enum AudioCompressor {

    /// Target sample rate for STT APIs (16kHz is standard for speech recognition)
    static let compressionSampleRate: Double = 16000

    /// Target channels (mono - STT models process mono internally)
    static let compressionChannels: UInt32 = 1

    // MARK: - Public API

    /// Compress audio data for faster upload to STT APIs.
    ///
    /// - Parameter audioData: Original audio data from Shortcuts or AudioRecorder
    /// - Returns: CompressionResult with compressed data, or original data on failure
    ///
    /// Produces AAC (M4A) on both iOS and macOS with WAV fallback if AAC
    /// encoding fails. This method never throws - on any error, it falls back
    /// to WAV, then to the original audio.
    static func compress(_ audioData: Data) async -> CompressionResult {
        let startTime = Date()
        let originalSize = audioData.count

        // Attempt AAC compression — identical path on iOS and macOS
        do {
            let compressedData = try await performCompression(audioData)
            let compressionTime = Int(Date().timeIntervalSince(startTime) * 1000)

            // Only use compressed version if it's actually smaller
            if compressedData.count < audioData.count {
                return CompressionResult(
                    data: compressedData,
                    originalSizeBytes: originalSize,
                    compressedSizeBytes: compressedData.count,
                    compressionTimeMs: compressionTime,
                    didCompress: true,
                    format: .aac
                )
            } else {
                #if DEBUG
                print("⚠️ AAC >= original (\(compressedData.count) >= \(originalSize)), trying WAV fallback")
                #endif
            }
        } catch {
            #if DEBUG
            print("⚠️ AAC failed: \(error.localizedDescription), trying WAV fallback")
            #endif
        }

        // WAV fallback (guaranteed to work with all STT providers)
        return await compressToWAV(audioData)
    }

    /// Compress audio to 16kHz mono 16-bit PCM WAV (no AAC encoding).
    /// Used by benchmarks (consistent STT input) and as AAC fallback.
    /// Never throws - returns original audio on error.
    static func compressToWAV(_ audioData: Data) async -> CompressionResult {
        let startTime = Date()
        let originalSize = audioData.count
        // Sniffed up front so BOTH `.original` fallback returns below describe
        // the input's true container (the bytes go out untouched).
        let sourceContainer = SourceAudioContainer.sniff(audioData)

        do {
            let tempDir = FileManager.default.temporaryDirectory
            let inputURL = tempDir.appendingPathComponent("wav_input_\(UUID().uuidString).m4a")
            let wavURL = tempDir.appendingPathComponent("wav_output_\(UUID().uuidString).wav")

            defer {
                try? FileManager.default.removeItem(at: inputURL)
                try? FileManager.default.removeItem(at: wavURL)
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let pcmBuffer = try convertToPCMBuffer(audioData: audioData, inputURL: inputURL)

                        // Write PCM buffer to WAV file
                        let wavSettings: [String: Any] = [
                            AVFormatIDKey: Int(kAudioFormatLinearPCM),
                            AVSampleRateKey: AudioCompressor.compressionSampleRate,
                            AVNumberOfChannelsKey: AudioCompressor.compressionChannels,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false
                        ]

                        let wavFile = try AVAudioFile(
                            forWriting: wavURL,
                            settings: wavSettings,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false
                        )
                        try wavFile.write(from: pcmBuffer)

                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            let wavData = try Data(contentsOf: wavURL)
            let compressionTime = Int(Date().timeIntervalSince(startTime) * 1000)

            #if DEBUG
            print("🎵 WAV output: \(wavData.count) bytes from \(originalSize) bytes in \(compressionTime)ms")
            #endif

            // If WAV is larger than original (e.g., original was already compressed AAC),
            // return original — no point uploading a bigger file
            if wavData.count >= originalSize {
                #if DEBUG
                print("   ⚠️ WAV >= original, using original (\(originalSize) bytes)")
                #endif
                return CompressionResult(
                    data: audioData,
                    originalSizeBytes: originalSize,
                    compressedSizeBytes: originalSize,
                    compressionTimeMs: compressionTime,
                    didCompress: false,
                    format: .original(sourceContainer)
                )
            }

            return CompressionResult(
                data: wavData,
                originalSizeBytes: originalSize,
                compressedSizeBytes: wavData.count,
                compressionTimeMs: compressionTime,
                didCompress: true,
                format: .wav
            )
        } catch {
            #if DEBUG
            print("⚠️ WAV conversion failed, using original: \(error.localizedDescription)")
            #endif

            let compressionTime = Int(Date().timeIntervalSince(startTime) * 1000)
            return CompressionResult(
                data: audioData,
                originalSizeBytes: originalSize,
                compressedSizeBytes: originalSize,
                compressionTimeMs: compressionTime,
                didCompress: false,
                format: .original(sourceContainer)
            )
        }
    }

    // MARK: - Private Implementation

    /// Perform compression: Convert to 16kHz mono PCM, then write directly to M4A with AAC encoding
    private static func performCompression(_ audioData: Data) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("compress_input_\(UUID().uuidString).m4a")
        let outputURL = tempDir.appendingPathComponent("compress_output_\(UUID().uuidString).m4a")

        // Ensure cleanup on exit
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Convert to PCM buffer and write directly to M4A (sync, on background thread)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pcmBuffer = try convertToPCMBuffer(audioData: audioData, inputURL: inputURL)
                    try writePCMToM4A(buffer: pcmBuffer, outputURL: outputURL)
                    let m4aData = try Data(contentsOf: outputURL)
                    continuation.resume(returning: m4aData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Convert audio data to a 16kHz mono Float32 PCM buffer (synchronous)
    private static func convertToPCMBuffer(audioData: Data, inputURL: URL) throws -> AVAudioPCMBuffer {
        // Write input data to temp file
        try audioData.write(to: inputURL)

        // Open input file and get format
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let inputFrameCount = AVAudioFrameCount(inputFile.length)

        #if DEBUG
        let inputDuration = Double(inputFrameCount) / inputFormat.sampleRate
        print("🎵 Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels, \(inputFrameCount) frames")
        print("🎵 Input duration: \(String(format: "%.2f", inputDuration))s, file size: \(audioData.count) bytes")
        #endif

        // Create PCM buffer for input
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCount
        ) else {
            throw CompressionError.bufferCreationFailed
        }

        // Read entire input file into buffer
        try inputFile.read(into: inputBuffer)

        // Create output format: 16kHz mono Float32 PCM
        guard let outputPCMFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCompressor.compressionSampleRate,
            channels: AudioCompressor.compressionChannels,
            interleaved: false
        ) else {
            throw CompressionError.formatCreationFailed
        }

        // Create converter from input format to output PCM format
        guard let converter = AVAudioConverter(from: inputFormat, to: outputPCMFormat) else {
            throw CompressionError.converterCreationFailed
        }

        // Medium quality is sufficient for speech recognition
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        // If input is stereo, mix down to mono (use left channel)
        if inputFormat.channelCount > 1 {
            converter.channelMap = [0]
        }

        // Calculate output frame count based on sample rate ratio
        let sampleRateRatio = AudioCompressor.compressionSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * sampleRateRatio)

        // Create output PCM buffer
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputPCMFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw CompressionError.bufferCreationFailed
        }

        // Perform conversion
        var inputBufferConsumed = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if inputBufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBufferConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error else {
            throw CompressionError.conversionFailed
        }

        return outputBuffer
    }

    /// Write a PCM buffer to an M4A file with AAC encoding via AVAudioFile.
    ///
    /// Note: AVAudioFile silently ignores AVEncoderBitRateKey and
    /// AVEncoderAudioQualityKey for compressed formats (Apple known issue).
    /// The encoder chooses its own profile and bitrate. On iOS this produces
    /// AAC-LC; on macOS the profile may differ. Either way, the output is
    /// valid AAC that STT APIs accept.
    private static func writePCMToM4A(buffer: AVAudioPCMBuffer, outputURL: URL) throws {
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioCompressor.compressionSampleRate,
            AVNumberOfChannelsKey: AudioCompressor.compressionChannels,
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: aacSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: buffer)

        #if DEBUG
        let m4aSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("🎵 M4A output: \(m4aSize) bytes (AVAudioFile AAC)")
        #endif
    }
}

// MARK: - Errors

/// Internal errors for compression (not exposed to users)
enum CompressionError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case bufferCreationFailed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .conversionFailed:
            return "Audio conversion failed"
        }
    }
}
