// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayResponseMetadata.swift
//
// The OPTIONAL, content-free facts a gateway may report alongside a reply:
// which model answered, the response id, why generation stopped, and the
// turn's token usage. Parsed from the SAME response bytes as the strict reply
// decoder, independently and non-throwingly, so that metadata can never
// weaken reply validation in either direction — a malformed `usage` cannot
// sink a perfectly good reply, and a valid `usage` cannot rescue an invalid
// one. Both halves observe the body; only the strict decoder decides whether
// a turn succeeded.
//
// WHY A SECOND PARSER AND NOT A WIDER `ConverseResponse`. `Codable` decodes a
// struct as a unit: one hostile `usage.total_tokens` would throw and take the
// other fields with it. `JSONSerialization` plus a per-field validator gives
// exactly the tolerance this data needs — every field stands or falls alone,
// and "absent" and "malformed" both mean nil. The two nested `*_details`
// dictionaries obey the same rule one level down: a `details` value that is not
// an object costs its own three fields and never the flat counts beside it.
//
// THE THREE DETAIL FIELDS ARE SUBSETS OF FIGURES ALREADY REPORTED, AND NOTHING
// ANYWHERE MAY ADD THEM INTO A TOTAL. Cached and cache-write input are parts of
// `prompt_tokens`; reasoning output is part of `completion_tokens`. Adding one
// to a sum double-counts tokens the gateway already counted once.
//
// CONTAINMENT IS DOCUMENTED AND NEVER ENFORCED. Cached input ought to be ≤ the
// prompt and reasoning output ≤ the completion, but a gateway that reports
// otherwise is preserved EXACTLY, the same way an inconsistent
// `reportedTotalTokens` is: repairing it would replace a gateway fact with a
// client guess no later reader could tell apart.
//
// CONTENT-FREE, AND THAT IS RELEASE-BLOCKING. Nothing here touches prompt or
// reply text, URLs, hosts, tokens, or provider error strings; the three
// strings it does keep come off the wire and are therefore bounded and
// scanned for rendering-control scalars before they are allowed to persist.
// Never log any of them, and never retain the raw response object for a later
// reparse — the observation this type carries is the whole of what survives
// the response bytes.
//
// IN the Watch target (pbxproj membership exception): the wrist uploader lands
// its own converse hop and assembles the same terminal observation.

import Foundation

/// What the gateway said about the turn it just answered, as far as any of it
/// could be believed. Every field is independently optional: a gateway is free
/// to report all of it, some of it, or none of it, and none of it is
/// provider-certified — `usage` is what the immediate gateway chose to report,
/// not a billing record.
nonisolated struct GatewayResponseMetadata: Sendable, Equatable {
    /// Top-level `model`, bounded. The model that ANSWERED, which a gateway is
    /// free to report differently from the one that was requested; it says
    /// nothing about models an agent called internally on its way to the reply.
    let reportedModel: String?
    /// Top-level `id`, bounded, exactly as reported. Kept so a user holding
    /// their own provider key can reconcile a turn by id later; never proof of
    /// provider identity, and never logged.
    let reportedResponseID: String?
    /// `choices[0].finish_reason`, bounded, exactly as reported. `length` is
    /// the one value with a user-visible consequence — it means the reply was
    /// cut off rather than finished.
    let finishReason: String?
    /// `usage.prompt_tokens`.
    let reportedInputTokens: Int64?
    /// `usage.completion_tokens`.
    let reportedOutputTokens: Int64?
    /// `usage.total_tokens`, PRESERVED EXACTLY as reported even when it
    /// disagrees with input + output. A gateway that reports an inconsistent
    /// total is reporting something — cached tokens, a tool hop, a rounding
    /// convention — and repairing it here would replace a gateway fact with a
    /// client guess that no later reader could tell apart.
    let reportedTotalTokens: Int64?
    /// `usage.prompt_tokens_details.cached_tokens` — the part of the prompt the
    /// gateway served from its own cache.
    let reportedCachedInputTokens: Int64?
    /// `usage.prompt_tokens_details.cache_write_tokens` — the part of the prompt
    /// the gateway wrote INTO that cache. Never a saving: several providers bill
    /// a cache write at a premium over an ordinary prompt token.
    let reportedCacheWriteInputTokens: Int64?
    /// `usage.completion_tokens_details.reasoning_tokens` — the part of the
    /// completion the model spent thinking rather than answering.
    let reportedReasoningOutputTokens: Int64?

    init(
        reportedModel: String? = nil,
        reportedResponseID: String? = nil,
        finishReason: String? = nil,
        reportedInputTokens: Int64? = nil,
        reportedOutputTokens: Int64? = nil,
        reportedTotalTokens: Int64? = nil,
        reportedCachedInputTokens: Int64? = nil,
        reportedCacheWriteInputTokens: Int64? = nil,
        reportedReasoningOutputTokens: Int64? = nil
    ) {
        self.reportedModel = reportedModel
        self.reportedResponseID = reportedResponseID
        self.finishReason = finishReason
        self.reportedInputTokens = reportedInputTokens
        self.reportedOutputTokens = reportedOutputTokens
        self.reportedTotalTokens = reportedTotalTokens
        self.reportedCachedInputTokens = reportedCachedInputTokens
        self.reportedCacheWriteInputTokens = reportedCacheWriteInputTokens
        self.reportedReasoningOutputTokens = reportedReasoningOutputTokens
    }

    /// True when the gateway reported nothing this type could keep. Callers
    /// that persist an observation use this to store nil rather than nine empty
    /// columns, so "the gateway reports no usage" and "the parse found nothing
    /// usable" stay one state rather than two.
    ///
    /// The three detail fields are part of the question, not an exception to
    /// it: a gateway that reported a cached-prompt count and nothing else has
    /// reported something, and excluding them here would make the persistence
    /// gate discard the one field it had.
    var isEmpty: Bool {
        reportedModel == nil && reportedResponseID == nil && finishReason == nil
            && reportedInputTokens == nil && reportedOutputTokens == nil
            && reportedTotalTokens == nil && reportedCachedInputTokens == nil
            && reportedCacheWriteInputTokens == nil && reportedReasoningOutputTokens == nil
    }

    /// Observe one complete HTTP response body. NEVER throws and never
    /// partially fails: an unparseable body, a JSON array at the root, a
    /// hostile `usage`, a 500's error envelope — all of them return a value,
    /// with nil standing for every field the body did not supply in a form
    /// worth keeping.
    ///
    /// Runs on NON-2xx bodies too, deliberately: a gateway can bill for work it
    /// then failed to return, so a failed turn's usage is exactly as real as a
    /// successful one's. The caller decides what the turn's outcome was; this
    /// only reports what the bytes said.
    static func parse(_ body: Data) -> GatewayResponseMetadata {
        guard
            let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else {
            return GatewayResponseMetadata()
        }

        let usage = root["usage"] as? [String: Any]
        // The two DETAIL dictionaries, read exactly like `usage` itself: a value
        // that is not an object — a number, a string, an array a hostile gateway
        // sent — yields nil here and every field below reads nil from it. A
        // malformed `details` therefore costs its own three fields and nothing
        // else; the flat counts beside it are untouched.
        let promptDetails = usage?["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage?["completion_tokens_details"] as? [String: Any]
        // `choices` is scanned only for its FIRST element's finish reason. A
        // multi-choice response is not a shape this client requests, and
        // guessing which of several completions the reply decoder kept would
        // attach a stop reason to text it does not describe.
        let firstChoice = (root["choices"] as? [Any])?.first as? [String: Any]

        return GatewayResponseMetadata(
            reportedModel: boundedWireString(root["model"]),
            reportedResponseID: boundedWireString(root["id"]),
            finishReason: boundedWireString(firstChoice?["finish_reason"]),
            reportedInputTokens: nonNegativeInteger(usage?["prompt_tokens"]),
            reportedOutputTokens: nonNegativeInteger(usage?["completion_tokens"]),
            reportedTotalTokens: nonNegativeInteger(usage?["total_tokens"]),
            // THESE THREE PATHS AND NO OTHERS. Anthropic's
            // `cache_creation_input_tokens`, DeepSeek's
            // `prompt_cache_hit_tokens` and every other vendor dialect are
            // deliberately NOT aliased here: a dialect read into a column named
            // for a different one is a fact the ledger can never unlearn, and
            // widening the parser later costs nothing because nothing was
            // written down wrong in the meantime.
            reportedCachedInputTokens: nonNegativeInteger(promptDetails?["cached_tokens"]),
            reportedCacheWriteInputTokens: nonNegativeInteger(promptDetails?["cache_write_tokens"]),
            reportedReasoningOutputTokens:
                nonNegativeInteger(completionDetails?["reasoning_tokens"])
        )
    }

    // MARK: - Per-field validation

    /// The cap the three wire strings share. Same budget the pairing payload
    /// applies to an imported model id (`PairingPayload.maxModelLength`), and
    /// for the same reason: machine-minted ids are legitimately long — an
    /// HF-style `hf.co/<org>/<repo>-GGUF:Q4_K_M` path runs 50–80 characters —
    /// while nothing legitimate approaches a kilobyte. That constant is private
    /// to its own parser, so the value is restated here rather than reached
    /// for; the two are one budget and move together.
    static let maxWireStringLength = 200

    /// A free-form string off the wire, or nil.
    ///
    /// REJECT, NEVER TRUNCATE OR STRIP. These values are shown back to the user
    /// as the model a turn ran on, and a silently shortened id names a model
    /// that does not exist. A gateway that reports a sane value loses nothing;
    /// one that reports a megabyte of text, or a right-to-left override that
    /// makes its id render as another gateway's, reports nothing at all.
    ///
    /// Empty is nil: a gateway that sends `"model": ""` has told us no more
    /// than one that omitted the key.
    private static func boundedWireString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        guard
            text.unicodeScalars.count <= maxWireStringLength,
            !text.unicodeScalars.contains(where: isRenderHostile)
        else { return nil }
        return text
    }

    /// Scalars barred from a wire string. Same denylist the pairing importer
    /// applies, and deliberately a denylist of RENDERING-CONTROL scalars rather
    /// than an allowlist of scripts: a model id may legitimately carry any
    /// script, and over-rejecting one is the worse failure.
    private static func isRenderHostile(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 controls + DEL + C1 controls: the ESC that starts an ANSI
        // sequence, and the CR/LF that forge extra lines in a one-line label.
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true
        // Bidi marks / embeddings / overrides / isolates. RLO reverses
        // everything after it, so one id can render as another — the classic
        // display-spoof primitive.
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        // LINE / PARAGRAPH SEPARATOR: break a single-line label the way LF
        // does without being caught by every newline API.
        case 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// A token count off the wire, or nil.
    ///
    /// Accepts ONLY a non-negative JSON integer that fits `Int64`. Three
    /// rejections are worth naming because each has a way of looking like a
    /// success:
    ///
    /// * **Booleans.** `JSONSerialization` bridges `true` to an `NSNumber`, so
    ///   `as? NSNumber` succeeds and `intValue` is 1 — a gateway that sends
    ///   `"total_tokens": true` would otherwise be recorded as having reported
    ///   one token. Only the CoreFoundation type id separates the two.
    /// * **Numbers written with a decimal point or exponent** (`12.0`, `1e3`).
    ///   These arrive as doubles, and a double cannot represent every `Int64`
    ///   exactly, so accepting them opens a silent-rounding path where
    ///   9007199254740993 lands as ...992. A count is an integer or it is not
    ///   reported.
    /// * **Values above `Int64.max`.** They arrive as unsigned, and truncating
    ///   one into a signed column would store a negative token count.
    ///
    /// Numeric STRINGS are rejected outright: `"usage": {"total_tokens": "42"}`
    /// is a gateway with a bug, and parsing around it teaches the ledger to
    /// trust a shape the contract never promised.
    private static func nonNegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q":
            let integer = number.int64Value
            return integer >= 0 ? integer : nil
        case "Q":
            let unsigned = number.uint64Value
            return unsigned <= UInt64(Int64.max) ? Int64(unsigned) : nil
        default:
            // "d" / "f": a floating-point literal, an out-of-range integer, or
            // anything else Foundation chose to widen. Not an exact count.
            return nil
        }
    }
}
