// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechSegmenterTests.swift
//
// Pure unit tests for `SpeechSegmenter.segments(for:policy:)` — the chunker
// underneath the chunked-TTS pipeline (`SpeechChunkQueue`). The segmenter's
// guarantees are LOAD-BEARING for the queue's Apple-fallback contract:
// `onFallback` speaks `segments[k...].joined()`, so any character the
// segmenter drops or duplicates is a character the fallback mis-speaks or
// double-speaks. These tests lock:
//   - the LOSS-FREE concatenation property (`joined() == input`, EXACTLY),
//   - the single-chunk passthroughs (short reply / `.off` / one giant
//     unsplittable sentence / head-swallows-everything),
//   - head runway sizing (never a lone tiny interjection as chunk 1),
//   - the `maxChunks` request-count cap + the tiny-tail merge,
//   - chunk boundaries landing ONLY on sentence/line starts.
//
// DETERMINISM: no Date, no async, no fakes — the segmenter is a pure
// function. Where packing math is asserted exactly, inputs are built from
// punctuation-free fixed-length lines: the newline pass in `atoms(in:)`
// inserts a boundary after every newline unconditionally (pure code), and
// `NLTokenizer` has nothing to split inside an unpunctuated letter run, so
// atom sizes — and therefore head/tail/merge packing — are exact by
// construction. Sentence-level cases (abbreviations, decimals, unicode)
// assert only tokenizer-independent invariants (loss-free join, caps,
// non-empty chunks), never exact split positions.

import XCTest
@testable import Conduck

@MainActor
final class SpeechSegmenterTests: XCTestCase {

    // MARK: - Helpers

    /// A line of EXACTLY `length` characters (trailing "\n" included when
    /// `terminated`), starting with the uppercase marker "L" and containing
    /// no sentence punctuation. Line starts are guaranteed atom boundaries
    /// (the segmenter's newline pass), and the unpunctuated body gives
    /// `NLTokenizer` nothing extra to split — so atoms == lines exactly, and
    /// every packing assertion built on these lines is deterministic.
    private func line(exactly length: Int, terminated: Bool = true) -> String {
        let bodyCount = (terminated ? length - 1 : length) - 1  // minus the "L"
        precondition(bodyCount >= 0, "line too short to construct")
        return "L" + String(repeating: "a", count: bodyCount) + (terminated ? "\n" : "")
    }

    // MARK: - 1. LOSS-FREE property (the load-bearing one)

    /// INVARIANT: `segments(for:policy:).joined() == input` EXACTLY, for a
    /// battery of diverse reply shapes under `.standard`, `.wristConservative`
    /// AND `.off`. This is the contract the queue's Apple fallback stands on —
    /// the unplayed remainder is `segments[k...].joined()`, so one dropped or
    /// duplicated character here is a mis-spoken fallback there. The same loop
    /// locks the "every chunk non-empty, never whitespace-only" postcondition
    /// (providers 4xx on blank synth text — case 9) and the per-policy
    /// chunk-count cap (`maxChunks`) for ANY input.
    func testLossFreeJoinedEqualsInputAcrossPoliciesAndDiverseInputs() {
        // Every entry is long enough (> 400 chars) that BOTH chunking
        // policies actually engage — a short input would pass trivially.
        let battery: [(name: String, text: String)] = [
            ("plainProse",
             String(repeating: "The quick brown duck paddles across the calm morning lake. ", count: 12)),
            ("multiParagraph",
             String(repeating: "First paragraph sentence one lands here. Second sentence follows it closely.\n\nNext paragraph begins after a blank line and keeps going for a while longer.\n\n", count: 4)),
            ("bareListLines",
             (1...20).map { _ in "List item without terminal punctuation and a decent length" }.joined(separator: "\n")),
            ("abbreviations",
             String(repeating: "Dr. Smith visited Washington, D.C. on Jan. 5. Prof. Jones replied by 10 a.m. with further notes. ", count: 6)),
            ("decimals",
             String(repeating: "Pi is 3.14. Then more follows with 2.718 as well. Version 1.2.3 shipped exactly on time. ", count: 7)),
            ("questionsExclamations",
             String(repeating: "Is this really working? Yes! It absolutely is! What happens next then? We keep going. ", count: 7)),
            ("unicodeEmojiAdjacent",
             String(repeating: "The café's naïve étude 🎉 sounded lovely. Zürich straße čaj — mañana! ", count: 8)),
            ("leadingTrailingWhitespace",
             "\n\n  " + String(repeating: "A sentence after leading blank lines keeps the property intact. ", count: 8) + "  \n"),
        ]
        let policies: [(name: String, policy: SpeechSegmentationPolicy)] = [
            ("standard", .standard),
            ("wristConservative", .wristConservative),
            ("off", .off),
        ]

        for (inputName, text) in battery {
            for (policyName, policy) in policies {
                let result = SpeechSegmenter.segments(for: text, policy: policy)

                XCTAssertEqual(
                    result.joined(), text,
                    "[\(inputName)/\(policyName)] chunks must concatenate back to the input EXACTLY (Apple-fallback remainder depends on it)"
                )
                XCTAssertFalse(result.isEmpty, "[\(inputName)/\(policyName)] result must never be empty")
                for (i, chunk) in result.enumerated() {
                    XCTAssertFalse(
                        chunk.isEmpty,
                        "[\(inputName)/\(policyName)] chunk \(i) must be non-empty"
                    )
                    XCTAssertFalse(
                        chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "[\(inputName)/\(policyName)] chunk \(i) must never be whitespace-only (providers 4xx on it)"
                    )
                }
                XCTAssertLessThanOrEqual(
                    result.count, policy.maxChunks,
                    "[\(inputName)/\(policyName)] chunk count must respect the policy's maxChunks cap"
                )
            }
        }
    }

    // MARK: - 2. Short-reply single-chunk passthrough (boundary-exact)

    /// INVARIANT: a reply of EXACTLY `singleChunkMax` (280) chars stays ONE
    /// chunk under `.standard` — short replies keep today's proven one-POST
    /// path byte-identical (chunking must never make short replies worse).
    func testStandardAtSingleChunkMaxBoundaryStaysSingleChunk() {
        let text = line(exactly: 70) + line(exactly: 70) + line(exactly: 70)
            + line(exactly: 70, terminated: false)
        XCTAssertEqual(text.count, 280, "construction: exactly at the .standard boundary")
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .standard), [text],
            "a reply AT singleChunkMax must come back as the single original string"
        )
    }

    /// INVARIANT: ONE character over `singleChunkMax` engages chunking (given
    /// split points), and the head accumulates to at least `headTarget` (140)
    /// so the tail gets its synth runway. Line-built atoms [70,70,70,71]
    /// make the split deterministic: head = two lines, tail = the rest.
    func testStandardJustOverSingleChunkMaxSplitsWithHeadRunway() {
        let text = line(exactly: 70) + line(exactly: 70) + line(exactly: 70)
            + line(exactly: 71, terminated: false)
        XCTAssertEqual(text.count, 281, "construction: one char over the .standard boundary")

        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertEqual(result.count, 2, "just-over-boundary with split points must chunk")
        XCTAssertGreaterThanOrEqual(
            result[0].count, 140,
            "the head must accumulate whole atoms to at least headTarget (runway for the tail's synth)"
        )
        XCTAssertEqual(result.joined(), text)
    }

    /// INVARIANT: a reply of EXACTLY `singleChunkMax` (400) chars stays ONE
    /// chunk under `.wristConservative` — same passthrough contract, wrist knob.
    func testWristAtSingleChunkMaxBoundaryStaysSingleChunk() {
        let text = line(exactly: 100) + line(exactly: 100) + line(exactly: 100)
            + line(exactly: 100, terminated: false)
        XCTAssertEqual(text.count, 400, "construction: exactly at the wrist boundary")
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .wristConservative), [text],
            "a reply AT the wrist singleChunkMax must come back as the single original string"
        )
    }

    /// INVARIANT: one char over the wrist boundary splits into exactly TWO
    /// chunks (the ~180-char remainder is under tailTarget, so it packs as a
    /// single tail), with the head at or above headTarget (220).
    func testWristJustOverSingleChunkMaxSplitsIntoTwo() {
        let text = line(exactly: 100) + line(exactly: 100) + line(exactly: 100)
            + line(exactly: 101, terminated: false)
        XCTAssertEqual(text.count, 401, "construction: one char over the wrist boundary")

        let result = SpeechSegmenter.segments(for: text, policy: .wristConservative)

        XCTAssertEqual(result.count, 2, "the wrist policy splits a just-over reply into exactly two chunks")
        XCTAssertGreaterThanOrEqual(
            result[0].count, 220,
            "wrist head must reach headTarget — the jittery Bluetooth relay needs the extra runway"
        )
        XCTAssertEqual(result.joined(), text)
    }

    // MARK: - 3. `.off` never chunks

    /// INVARIANT: `.off` ALWAYS returns `[text]` — the whole-blob escape
    /// hatch must never produce a multi-chunk turn, no matter how long the
    /// reply is. 5000+ chars, plenty of split points.
    func testOffPolicyNeverChunksEvenForFiveThousandCharReply() {
        let text = String(repeating: "This sentence keeps the off policy honest and stays plain.\n", count: 85)
        XCTAssertGreaterThan(text.count, 5000, "construction: a genuinely long reply")
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .off), [text],
            ".off must return the whole reply as one chunk regardless of length"
        )
    }

    // MARK: - 4. One giant sentence: never split mid-sentence

    /// INVARIANT: a single giant sentence with NO split points (no terminal
    /// punctuation, no newlines) comes back whole even though it exceeds
    /// every size knob — chunk boundaries land ONLY on sentence/line starts,
    /// so an unsplittable input must never be cut mid-sentence.
    func testGiantSentenceWithNoSplitPointsStaysWhole() {
        let text = String(repeating: "duck ", count: 100)  // 500 chars, one "sentence" to the tokenizer
        XCTAssertGreaterThan(text.count, 400, "construction: over BOTH policies' singleChunkMax")
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .standard), [text],
            "no split points → the standard policy must return the text whole"
        )
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .wristConservative), [text],
            "no split points → the wrist policy must return the text whole"
        )
    }

    // MARK: - 5. Head sizing: never a lone tiny interjection

    /// INVARIANT: a reply opening with a tiny interjection ("Sure.") must NOT
    /// make that interjection the head chunk — the head ACCUMULATES sentences
    /// to >= headTarget (140 for .standard). A "Sure."-sized head gives the
    /// tail zero synth runway → audible gap at the first seam (the exact
    /// failure mode the accumulate-to-minimum rule exists to prevent).
    func testHeadAccumulatesPastTinyInterjection() {
        let text = "Sure. "
            + String(repeating: "That should work nicely for the setup you described earlier. ", count: 10)

        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertGreaterThanOrEqual(result.count, 2, "construction: long enough to chunk")
        XCTAssertTrue(result[0].hasPrefix("Sure."), "the interjection stays at the front of the head")
        XCTAssertNotEqual(result[0], "Sure. ", "the head must never be the lone tiny interjection")
        XCTAssertGreaterThanOrEqual(
            result[0].count, 140,
            "the head must accumulate whole sentences to at least headTarget"
        )
        XCTAssertEqual(result.joined(), text)
    }

    // MARK: - 6. maxChunks cap (request-count bound)

    /// INVARIANT: a very long reply never exceeds `maxChunks` (8 for
    /// .standard) — BYO keys mean the user pays per request and the rate
    /// limits are theirs, so the tail target INFLATES to fit rather than the
    /// chunk count growing. Verified at ~4200 chars and again at ~10500 chars
    /// (the cap must hold as the reply keeps growing, not just near it).
    func testStandardMaxChunksCapHoldsForVeryLongReplies() {
        let text4200 = (0..<60).map { _ in line(exactly: 70) }.joined()
        let result = SpeechSegmenter.segments(for: text4200, policy: .standard)
        XCTAssertGreaterThanOrEqual(result.count, 2, "construction: long enough to chunk")
        XCTAssertLessThanOrEqual(result.count, 8, "the .standard cap is 8 chunks per reply")
        XCTAssertEqual(result.joined(), text4200)

        let text10500 = (0..<150).map { _ in line(exactly: 70) }.joined()
        let longResult = SpeechSegmenter.segments(for: text10500, policy: .standard)
        XCTAssertLessThanOrEqual(
            longResult.count, 8,
            "the cap must hold for arbitrarily long replies (tail target inflates instead)"
        )
        XCTAssertEqual(longResult.joined(), text10500)
    }

    // MARK: - 7. Wrist: every tail chunk stays SMALL (timeout-bomb guard)

    /// INVARIANT: a long wrist reply must NEVER yield a tail spanning the
    /// whole remainder — `WatchTTSClient` is single-attempt with a 60 s
    /// timeout, and one giant synth request blows it (dead air, then the
    /// Apple-voice fallback for everything left). With 100-char line atoms
    /// the head is deterministic (three lines, 300 chars) and greedy packing
    /// closes each tail at the first atom crossing tailTarget (480), so no
    /// chunk can exceed 700 chars even at the even-split-inflated 4800-char
    /// case. The maxChunks cap (8) must hold throughout.
    func testWristLongInputBoundsEveryTailChunk() {
        for lineCount in [12, 24, 48] {  // 1200 / 2400 / 4800 chars
            let text = (0..<lineCount).map { _ in line(exactly: 100) }.joined()
            let result = SpeechSegmenter.segments(for: text, policy: .wristConservative)

            XCTAssertGreaterThanOrEqual(
                result.count, 3,
                "[\(lineCount) lines] a long wrist reply must split into head + MULTIPLE bounded tails"
            )
            XCTAssertLessThanOrEqual(result.count, 8, "[\(lineCount) lines] wrist cap is 8 chunks")
            XCTAssertGreaterThanOrEqual(result[0].count, 220, "[\(lineCount) lines] wrist head must reach headTarget")
            for (i, chunk) in result.enumerated() {
                XCTAssertLessThanOrEqual(
                    chunk.count, 700,
                    "[\(lineCount) lines] chunk \(i) must stay small — a remainder-spanning tail is a synth-timeout bomb on the wrist"
                )
            }
            XCTAssertEqual(result.joined(), text)
        }
    }

    /// INVARIANT: when the head accumulation swallows every atom (each atom
    /// under headTarget, but only reaching it on the last one), the segmenter
    /// returns `[text]` — a single chunk — instead of a head plus an empty
    /// tail. Locks the `guard i < atoms.count else { return [text] }` branch.
    func testWristHeadSwallowingEverythingReturnsWholeText() {
        // Two 210-char atoms: 420 > singleChunkMax(400) engages chunking;
        // head takes atom 1 (210 < 220), then atom 2 (420 >= 220) — nothing
        // is left for a tail.
        let text = line(exactly: 210) + line(exactly: 210, terminated: false)
        XCTAssertEqual(text.count, 420, "construction: over the wrist boundary, two sub-headTarget atoms")
        XCTAssertEqual(
            SpeechSegmenter.segments(for: text, policy: .wristConservative), [text],
            "head-swallows-everything must collapse to the single original string"
        )
    }

    // MARK: - 7b. Tail ramp: early tails stay small (first-seam runway bound)

    /// INVARIANT: the FIRST tails honor the RAMP targets, never the plateau —
    /// cloud TTS synthesizes ≈ real time and tail 1's fetch launches WITH the
    /// head's, so a plateau-sized tail 1 cannot finish inside the head's short
    /// runway (field-measured 15–20 s of dead air at the first seam on
    /// CarPlay). With 100-char line atoms every chunk closes at its first atom
    /// crossing: `.standard` (head 140, ramp [140, 280]) must yield
    /// [200, 200, 300, plateau…] — tail 1 HEAD-SIZED (the unconditionally
    /// safe first seam), tail 2 in between, then the long ones.
    func testStandardEarlyTailsHonorRampNotPlateau() {
        let text = (0..<24).map { _ in line(exactly: 100) }.joined()  // 2400 chars
        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertEqual(result[0].count, 200, "head closes at the first atom crossing headTarget (140)")
        XCTAssertEqual(result[1].count, 200, "tail 1 closes at the first atom crossing ramp[0] (140) — HEAD-sized, not the plateau")
        XCTAssertEqual(result[2].count, 300, "tail 2 closes at the first atom crossing ramp[1] (280)")
        XCTAssertGreaterThanOrEqual(result[3].count, 500, "post-ramp tails pack to the 480 plateau")
        XCTAssertLessThanOrEqual(result.count, 8)
        XCTAssertEqual(result.joined(), text)
    }

    /// INVARIANT: the ramp survives the `maxChunks` even-split inflation —
    /// only POST-ramp tails absorb a very long reply. Inflating the early
    /// tails would recreate the first-seam gap on exactly the longest replies,
    /// where the dead air hurts most.
    func testRampTailsExemptFromMaxChunksInflation() {
        let long = (0..<105).map { _ in line(exactly: 100) }.joined()  // 10500 chars
        let result = SpeechSegmenter.segments(for: long, policy: .standard)

        XCTAssertLessThanOrEqual(result.count, 8, "the cap must still hold")
        XCTAssertEqual(result[1].count, 200, "ramp tail 1 must NOT inflate under the cap")
        XCTAssertEqual(result[2].count, 300, "ramp tail 2 must NOT inflate under the cap")
        XCTAssertGreaterThan(result[4].count, 1000, "post-ramp tails absorb the length instead")
        XCTAssertEqual(result.joined(), long)
    }

    // MARK: - 8. Tiny-tail merge

    /// INVARIANT: a trailing scrap under `minTailChars` (80) merges into its
    /// predecessor — a lone "Thanks!"-sized tail is not worth a whole synth
    /// request plus an audible seam. Line atoms [80,80, 100x2, 40] make the
    /// naive packing deterministic: head(160) + one ramp-packed tail(200,
    /// closing at the first atom crossing ramp[0]=140) + scrap(40); the merge
    /// must fold the scrap into the tail → exactly two chunks.
    func testTinyTrailingScrapMergesIntoPreviousChunk() {
        let scrap = line(exactly: 40, terminated: false)
        let text = line(exactly: 80) + line(exactly: 80)                    // head accumulates to 160
            + (0..<2).map { _ in line(exactly: 100) }.joined()              // one 200-char ramp-packed tail
            + scrap                                                          // naive leftover: 40 < minTailChars

        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertEqual(result.count, 2, "the sub-minTailChars scrap must merge, not stand alone as a third chunk")
        XCTAssertTrue(
            result[result.count - 1].hasSuffix(scrap),
            "the last chunk must have absorbed the scrap"
        )
        XCTAssertGreaterThanOrEqual(
            result[result.count - 1].count, 80,
            "after the merge no chunk is smaller than minTailChars"
        )
        XCTAssertEqual(result.joined(), text)
    }

    // MARK: - 10. Chunk boundaries land on sentence/line starts

    /// INVARIANT: for line-shaped input (sanitized replies keep list items as
    /// bare lines), every chunk after the first begins at a LINE start — the
    /// constructed lines all open with the marker "L", so a chunk starting
    /// with anything else would mean a mid-line cut (broken prosody + a seam
    /// where no spoken pause belongs).
    func testChunkBoundariesLandOnLineStarts() {
        let text = (0..<60).map { _ in line(exactly: 70) }.joined()
        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertGreaterThanOrEqual(result.count, 2, "construction: long enough to chunk")
        for (i, chunk) in result.enumerated().dropFirst() {
            XCTAssertTrue(
                chunk.hasPrefix("L"),
                "chunk \(i) must begin at a line start, never mid-line"
            )
        }
        XCTAssertEqual(result.joined(), text)
    }

    /// INVARIANT: for prose, every chunk after the first begins at a SENTENCE
    /// start — the previous chunk carries the inter-sentence whitespace, so
    /// each seam opens directly on the next sentence's first word. Every
    /// sentence in the constructed prose opens with "The", making a mid-
    /// sentence (or whitespace-leading) cut detectable.
    func testChunkBoundariesLandOnSentenceStartsForProse() {
        let text = String(repeating: "The quick brown duck paddles across the calm morning lake. ", count: 12)
        let result = SpeechSegmenter.segments(for: text, policy: .standard)

        XCTAssertGreaterThanOrEqual(result.count, 2, "construction: long enough to chunk")
        for (i, chunk) in result.enumerated().dropFirst() {
            XCTAssertTrue(
                chunk.hasPrefix("The"),
                "chunk \(i) must begin at a sentence start (previous chunk carries the whitespace)"
            )
        }
        XCTAssertEqual(result.joined(), text)
    }
}
