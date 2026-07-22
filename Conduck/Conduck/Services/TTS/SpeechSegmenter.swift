// Conduck
// SpeechSegmenter.swift
//
// Splits a sanitized agent reply into TTS-sized chunks so the FIRST chunk can
// be synthesized + spoken immediately while the rest synthesize underneath the
// audio already playing (see `SpeechChunkQueue`). This is the whole
// time-to-first-word fix: one whole-reply POST makes the wait scale with reply
// LENGTH; a small head chunk makes it scale with the first few sentences only.
//
// CROSS-PLATFORM: compiles into BOTH the iOS/macOS `Conduck` target and the
// `ConduckWatch Watch App` target (like `SpeakEngine.swift`). Foundation +
// NaturalLanguage only — no AVFoundation, no UI.
//
// GUARANTEES (load-bearing for the queue's Apple-fallback contract):
//   - `segments(for:policy:).joined() == text` EXACTLY. Chunks are contiguous
//     slices of the input carrying their original inter-sentence whitespace,
//     so "speak the remaining text via Apple after chunk N failed" is a plain
//     `segments[N...].joined()` with zero loss and zero double-speak.
//   - Chunk boundaries land ONLY on sentence starts (NLTokenizer) or line
//     starts — never mid-sentence, so each chunk is natural prosody for the
//     provider and a seam falls where a spoken pause belongs anyway.
//   - A short reply returns a SINGLE chunk — callers keep today's one-POST
//     path byte-identical (chunking must never make short replies worse).
//
// SIZING MODEL (why these knobs): spoken English ≈ 14 chars/sec, and cloud
// TTS synthesizes at roughly REAL-TIME speed (a 30 s clip takes ~30 s to
// make, network included). The head chunk's PLAYBACK TIME is the synth runway
// for everything behind it — the queue launches the next fetch concurrently,
// so chunk 2 gets (head synth + head playback) seconds to cook. A too-tiny
// head ("Sure.") gives the tail no runway → audible gap; that's why the head
// ACCUMULATES sentences to a minimum size instead of taking the first
// sentence alone. Tails RAMP small-to-big (`tailRamp`, then the `tailTarget`
// plateau): the first tail's runway is only ~2× the head's audio, so at
// real-time synth speed it must stay ≈2× the head or the seam gaps (a flat
// 480-char first tail field-measured 15–20 s of dead air on CarPlay); each
// later tail also banks the full playback of every chunk before it, so the
// plateau can be coarse — fewer seams, fewer requests.

import Foundation
import NaturalLanguage

// MARK: - Policy

/// Per-surface chunking knobs. Character counts are a proxy for speech
/// duration (≈14 chars/sec spoken English).
struct SpeechSegmentationPolicy: Sendable, Equatable {
    /// Replies at or under this length stay ONE chunk (today's single-POST
    /// path, byte-identical). Short replies are already fast to synthesize —
    /// chunking them would double the request count for no felt win.
    var singleChunkMax: Int
    /// The head chunk accumulates whole sentences until it reaches this size.
    /// ≈10 s of audio — the runway that hides every later chunk's synth time.
    var headTarget: Int
    /// Tail chunks greedily pack whole sentences to roughly this size. Coarse
    /// on purpose (fewer seams); grows automatically when `maxChunks` would
    /// otherwise be exceeded.
    var tailTarget: Int
    /// Targets for the FIRST tails (index 0 = the chunk right after the head),
    /// before `tailTarget` takes over. Small-then-bigger because synthesis
    /// runs ≈ real time: tail 1's fetch launches WITH the head's, so its only
    /// runway is the head's synth + playback (~2× the head's audio) — a
    /// plateau-sized tail 1 can't finish in time and the seam gaps. Ramp
    /// entries are EXEMPT from the `maxChunks` inflation (inflating them
    /// would recreate the first-seam gap on exactly the longest replies).
    var tailRamp: [Int] = []
    /// Hard cap on total chunks per reply (request-count bound — BYO keys mean
    /// the user pays per request overhead; rate limits are theirs too). The
    /// tail target inflates to fit very long replies under the cap.
    var maxChunks: Int
    /// A trailing chunk smaller than this merges into its predecessor — a
    /// lone "Thanks!" tail is not worth a whole extra request/seam.
    var minTailChars: Int

    /// iOS / iPadOS / macOS chat + macOS menu-bar arrival speak + CarPlay.
    /// Ramp [140, 280]: tail 1 = HEAD-SIZED — that makes the first seam
    /// unconditionally safe (synth time r·a₂ ≤ runway r·a₁+a₁ holds for ANY
    /// synth speed r when a₂ = a₁); tail 2 ≈ 2× (bounded by the two banked
    /// playbacks); then the 480 plateau once runway is abundant. Geometric
    /// doubling: each chunk never exceeds the playback already banked ahead
    /// of it.
    static let standard = SpeechSegmentationPolicy(
        singleChunkMax: 280, headTarget: 140, tailTarget: 480, tailRamp: [140, 280], maxChunks: 8, minTailChars: 80
    )

    /// Apple Watch: `.standard`'s bounded-tail shape with a LONGER head and a
    /// LATER chunking trigger. The wrist's network path is jittery (Bluetooth →
    /// paired-iPhone relay) and `WatchTTSClient` is single-attempt with a 60 s
    /// timeout, so the load-bearing property is that NO chunk is ever big: a
    /// tail spanning a long reply's whole remainder is a timeout bomb (one
    /// giant synth request + multi-MB audio response > 60 s → dead air while
    /// the fetch runs out its clock, then Apple-voice fallback for everything
    /// left). Small bounded tails synthesize in seconds, and a mid-queue
    /// failure costs at most the remainder from that seam.
    /// Ramp [220]: tail 1 head-sized (the unconditionally-safe first seam,
    /// same geometry as `.standard`); the 220-char head banks enough runway
    /// that the 480 plateau can follow directly; every value stays well under
    /// the single-attempt 60 s synth window.
    static let wristConservative = SpeechSegmentationPolicy(
        singleChunkMax: 400, headTarget: 220, tailTarget: 480, tailRamp: [220], maxChunks: 8, minTailChars: 80
    )

    /// No chunking ever — the whole reply is one chunk. No production surface
    /// passes it (CarPlay adopted `.standard` once the pipeline proved out on
    /// the other surfaces); kept as the whole-blob escape hatch and the test
    /// baseline for the single-chunk passthrough contract.
    static let off = SpeechSegmentationPolicy(
        singleChunkMax: Int.max, headTarget: 0, tailTarget: 0, maxChunks: 1, minTailChars: 0
    )
}

// MARK: - Segmenter

enum SpeechSegmenter {

    /// Split `text` (already sanitized — callers run `ReplySanitizer.spoken`
    /// first) into TTS chunks per `policy`. Returns `[text]` whenever chunking
    /// is off, unnecessary (short reply), or impossible (one giant sentence).
    /// Postcondition: `result.joined() == text`; no chunk is empty or
    /// whitespace-only for any input that itself has speakable content
    /// (callers guard empty-after-sanitize before reaching here).
    static func segments(for text: String, policy: SpeechSegmentationPolicy) -> [String] {
        guard policy.maxChunks > 1,
              text.count > policy.singleChunkMax,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [text]
        }

        let atoms = atoms(in: text)
        guard atoms.count > 1 else { return [text] }

        // Grapheme counts are O(length) each — count every atom ONCE and run
        // integer accumulators through the packing loops. Repeated
        // `current.count` calls on the growing chunk would be O(n²) grapheme
        // walking on the main actor, inside the very speak path chunking
        // exists to speed up (worst on wrist-class CPUs).
        let lengths = atoms.map(\.count)

        // HEAD: whole sentences until the minimum runway size. Never a lone
        // tiny interjection — "Sure." bundles with the sentence after it.
        var chunks: [String] = []
        var current = ""
        var currentLength = 0
        var i = 0
        while i < atoms.count, currentLength < policy.headTarget {
            current += atoms[i]
            currentLength += lengths[i]
            i += 1
        }
        chunks.append(current)
        guard i < atoms.count else { return [text] }  // head swallowed everything

        // TAILS: greedy sentence packing against a PER-TAIL target — the ramp
        // entries first (small, seam-runway-bound; see `tailRamp`), then the
        // plateau. Post-ramp targets inflate (even split over the slots left)
        // so the total count stays under `maxChunks` — by then there is
        // minutes of runway, so bigger chunks' synth time is hidden. Ramp
        // tails are EXEMPT from inflation; the LAST slot swallows whatever
        // remains.
        var remaining = lengths[i...].reduce(0, +)
        var tailIndex = 0
        var lastLength = 0
        while i < atoms.count {
            let slotsLeft = policy.maxChunks - chunks.count
            let target: Int
            if slotsLeft <= 1 {
                target = Int.max
            } else if tailIndex < policy.tailRamp.count {
                target = policy.tailRamp[tailIndex]
            } else {
                let evenSplit = Int((Double(remaining) / Double(slotsLeft)).rounded(.up))
                target = max(policy.tailTarget, evenSplit)
            }
            current = ""
            currentLength = 0
            while i < atoms.count, currentLength < target {
                current += atoms[i]
                currentLength += lengths[i]
                remaining -= lengths[i]
                i += 1
            }
            chunks.append(current)
            lastLength = currentLength
            tailIndex += 1
        }
        // A trailing scrap ("Thanks!") isn't worth its own request/seam.
        if chunks.count > 1, lastLength < policy.minTailChars {
            let last = chunks.removeLast()
            chunks[chunks.count - 1] += last
        }

        return chunks
    }

    // MARK: - Atomization

    /// Split `text` into contiguous "atoms" — the indivisible packing units:
    /// sentences (NLTokenizer, which survives abbreviations/decimals that break
    /// regex splitting) further split at line starts (sanitized replies keep
    /// list items as bare lines with no terminal punctuation, which the
    /// tokenizer would otherwise lump into one mega-sentence). Each atom
    /// carries the whitespace up to the next atom's start, so
    /// `atoms.joined() == text` by construction. Whitespace-only atoms merge
    /// backward — a chunk must never be blank (providers 4xx on it).
    private static func atoms(in text: String) -> [String] {
        var boundaries: Set<String.Index> = [text.startIndex]

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            boundaries.insert(range.lowerBound)
            return true
        }

        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isNewline {
                let next = text.index(after: idx)
                if next < text.endIndex { boundaries.insert(next) }
            }
            idx = text.index(after: idx)
        }

        let sorted = boundaries.sorted()
        var atoms: [String] = []
        for (j, start) in sorted.enumerated() {
            let end = j + 1 < sorted.count ? sorted[j + 1] : text.endIndex
            guard start < end else { continue }
            let piece = String(text[start..<end])
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !atoms.isEmpty {
                atoms[atoms.count - 1] += piece
            } else {
                atoms.append(piece)
            }
        }
        return atoms
    }
}
