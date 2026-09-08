// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialImagePolicy.swift
//
// The single place that decides what pixels an image card keeps. Every ingest
// lane — in-app drop, picker, paste, share inbox, headless intent, reattach —
// hands its bytes to the desk write, and the desk write asks here before it
// stages anything: a picture is normalised to `Constants.workboardImageMaxPixel`
// through the same `ImageProcessor` a chat turn uses, so a card costs the
// person's iCloud quota once at vision size and carries no camera metadata.
//
// The sibling of `WorkMaterialStoragePolicy`: that one decides WHERE bytes
// live, this one decides WHICH bytes, and it runs first so the lane is chosen
// on the size the card will actually keep.
//
// WHAT IS LEFT ALONE, and why each is a rule rather than a fallback:
//   - a card of any other kind, whatever its bytes look like (kind decides,
//     exactly as the thumbnail does);
//   - a source whose size disagrees with what its capture declared — staging
//     refuses that, and converting it first would let a lie about its length
//     through as a valid JPEG;
//   - an EXISTING card — a replay or a repair — whose row already names the
//     bytes on offer. The desk write pairs a card with the hash of the bytes it
//     was published with, and treats a different hash under the same id as a
//     superseded payload to delete. Normalising the raw bytes of a card
//     published before this rule would produce exactly that: a new hash, the
//     healthy blob retired, and — because a replayed envelope is older than the
//     row it repairs — a row the transaction may not repoint. So a replay
//     always reproduces the representation the row already holds: raw for a
//     card that was published raw, normalised for one published normalised,
//     and the hash then matches and nothing is deleted;
//   - an animation (any multi-frame container, and every GIF — by type, so a
//     one-frame GIF passes too: it still promises a palette and a loop the
//     JPEG sink cannot keep, and it costs nothing to keep);
//   - a JPEG that is already within the cap and carries nothing identifying —
//     a voice-lane screenshot, a chat capture — stored byte-for-byte rather
//     than encoded a second time;
//   - bytes ImageIO cannot decode. The decoder cannot tell an unsupported
//     format from a corrupt file, and a refusal here would wedge the drainer's
//     queue on one item; the person's bytes are stored as they arrived, as
//     they always were, and the card still opens in Quick Look.
//
// Isolation: `@concurrent`, because the header read and the hash must not run
// on the store's actor (the reason `imagePresentationThumbnail` is spelled the
// same way), while the encode itself hops to the `ImageProcessor` actor.

#if !os(watchOS)

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum WorkMaterialImagePolicy {

    /// Why the bytes were left exactly as the caller handed them over.
    enum Reason: Sendable, Equatable {
        case notAnImageCard
        case noBytes
        case sourceMismatch
        case keepsExistingRepresentation
        case animated
        case alreadyConforming
        case undecodable
    }

    enum Outcome: Sendable, Equatable {
        case unchanged(Reason)
        case normalised(jpeg: Data, width: Int, height: Int)
    }

    /// Decide the representation one capture's bytes take on the desk.
    ///
    /// The source is read the way staging reads it: a file URL outranks bytes
    /// in hand, and `declaredByteCount` is the length the capture claimed for
    /// that file (`sourceFileByteSize`, else the draft's `byteSize`; nil or
    /// negative means unmeasured). `existing` is the card this id already
    /// names, when there is one — a replay or a repair — and it is what keeps
    /// a card published before this rule from ever being converted.
    ///
    /// Throws only for cancellation: the encode is the long step, and a person
    /// can abandon the capture across it; nothing durable exists yet, so the
    /// caller keeps its bytes and publishes on the next attempt.
    @concurrent
    nonisolated static func prepare(
        kind: WorkMaterialKind,
        payload: Data?,
        sourceFileURL: URL?,
        declaredByteCount: Int64?,
        existing: WorkMaterialRecord?,
        maxPixel: Int = Constants.workboardImageMaxPixel
    ) async throws -> Outcome {
        guard kind == .image else { return .unchanged(.notAnImageCard) }
        guard payload != nil || sourceFileURL != nil else { return .unchanged(.noBytes) }

        if let sourceFileURL, let declaredByteCount, declaredByteCount >= 0 {
            let measured = (try? sourceFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)
            guard measured == declaredByteCount else { return .unchanged(.sourceMismatch) }
        }

        if let existing {
            guard existing.storageMode == .syncedPayload,
                  let promised = existing.contentHash else {
                return .unchanged(.keepsExistingRepresentation)
            }
            if try rawContentHash(payload: payload, sourceFileURL: sourceFileURL) == promised {
                return .unchanged(.keepsExistingRepresentation)
            }
        }

        let source: CGImageSource?
        if let sourceFileURL {
            source = CGImageSourceCreateWithURL(sourceFileURL as CFURL, nil)
        } else if let payload {
            source = CGImageSourceCreateWithData(payload as CFData, nil)
        } else {
            source = nil
        }
        guard let source else { return .unchanged(.undecodable) }

        let facts = ImageProcessor.inspect(source)
        if facts.isAnimated { return .unchanged(.animated) }
        if facts.isJPEG,
           let longEdge = facts.longEdge,
           longEdge <= maxPixel,
           !facts.carriesIdentifyingMetadata {
            return .unchanged(.alreadyConforming)
        }

        let processed: ProcessedImage
        do {
            if let sourceFileURL {
                processed = try await ImageProcessor.shared.process(fileAt: sourceFileURL, maxPixel: maxPixel)
            } else if let payload {
                processed = try await ImageProcessor.shared.process(payload, maxPixel: maxPixel)
            } else {
                return .unchanged(.noBytes)
            }
        } catch is ImageProcessorError {
            return .unchanged(.undecodable)
        }
        // The length check above was taken BEFORE ImageIO reopened the file
        // for the encode. A source swapped for another underneath it in that
        // window would have been sized from bytes the capture never described,
        // and staging — which measures the JPEG, not the file — could no longer
        // notice. So the file is measured once more, after.
        if let sourceFileURL, let declaredByteCount, declaredByteCount >= 0 {
            let measured = (try? sourceFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)
            guard measured == declaredByteCount else { return .unchanged(.sourceMismatch) }
        }
        // Checked AFTER the encode, the long step, and before the caller stages
        // anything: past this line the bytes become durable, and a cancel that
        // arrived during the encode would otherwise be reported as a picture
        // that was saved after all. Deliberately NOT checked on the
        // pass-through returns above: those change nothing about what the desk
        // write was going to do, and every lane already publishes a cancelled
        // pass-through capture today — an in-app drop whose view has gone away
        // still lands, and must.
        try Task.checkCancellation()
        return .normalised(jpeg: processed.jpegData, width: processed.width, height: processed.height)
    }

    /// SHA-256 of the bytes exactly as handed over, lowercase hex — the same
    /// shape the desk write pairs a card with, so the two compare directly. A
    /// file is streamed in bounded chunks: this runs for a replay against an
    /// existing synced card, and the file it hashes may be far larger than the
    /// picture the card keeps.
    private static func rawContentHash(payload: Data?, sourceFileURL: URL?) throws -> String? {
        var hasher = SHA256()
        if let sourceFileURL {
            let handle = try FileHandle(forReadingFrom: sourceFileURL)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: hashChunkBytes), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else if let payload {
            hasher.update(data: payload)
        } else {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let hashChunkBytes = 1024 * 1024
}

#endif
