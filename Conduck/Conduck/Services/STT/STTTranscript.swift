// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTTranscript.swift
//
// THE speech-to-text transcript boundary: the single normalization every
// provider's result passes through before Conduck shows it, stores it in the
// conversation, or sends it to the gateway.
//
// WHY THE BOUNDARY IS A TYPE AND NOT A CALL SITE. A transcript reaches the app
// down at least six independent routes — the multipart decoder
// (`STTResponseDecoder`), the three JSON-family provider decoders (Gemini ·
// Qwen · OpenRouter), the in-process Apple runner (`AppleSpeechRunner`, which
// `InAppAudioRecorder` and `AppleSpeechRelayCoordinator` call DIRECTLY, never
// through `STTClient`), the foreground and background `STTClient` lanes, and
// the Watch's own foreground/background upload lanes. No function sits on all
// of them, so normalizing in one decoder covers some providers and leaves a
// false sense of completeness. `STTResponse` DOES sit on all of them: every
// route ends in `STTResponse(text:language:)`, so that initializer calls
// `normalized(_:)` and the boundary becomes impossible to route around —
// including for a provider added later, which gets it by construction.
//
// WHY NORMALIZE RATHER THAN REJECT. A BYO speech endpoint is remote text a
// user pointed Conduck at, so it is untrusted — but the user SPOKE WORDS,
// never a bidi override and never an ESC. Removing non-spoken formatting is a
// faithful rendering of the utterance; discarding the turn over it would throw
// away something the user actually said, and dictation is the one input mode
// with no keyboard fallback on CarPlay or the wrist. (The opposite policy,
// outright refusal, is correct for IDENTITY fields, which are read back by an
// operator and persisted as a gateway's name — see
// `PairingPayload.sanitizedDisplayText`.)
//
// WHAT THE PROJECTION COSTS. `ReplySanitizer.displayLine` maps tabs, line
// breaks and the U+2028 / U+2029 separators to single spaces, so a transcript
// is ONE line. That is deliberate: a dictated turn is one utterance, the line
// structure a provider invents around it carries nothing the user said, and a
// break left in the canonical text renders as extra rows in every label
// surface and rides onto the wire that way.

import Foundation

/// The transcript normalization boundary. Deliberately not a general text
/// utility — it exists so `STTResponse` has exactly one rule to apply, and so
/// that rule has exactly one home.
enum STTTranscript {

    /// Uncapped, and it has to be spelled out because
    /// `ReplySanitizer.displayLine` takes its cap as a parameter. A transcript
    /// is the user's OWN words and it goes on the wire to the agent, so a cap
    /// here would silently delete part of what they said. Label surfaces that
    /// need a short line cap their own render instead.
    nonisolated private static let uncappedLength = Int.max

    /// The empty result stands, deliberately. `displayLine` returns its
    /// `fallback` VERBATIM, so any app-owned placeholder here would become text
    /// the user never spoke — and would be sent to the agent as their turn. The
    /// decode sites turn an empty transcript into `AppError.noSpeechDetected`,
    /// which is the honest verdict for audio that yielded no spoken content.
    nonisolated private static let emptyTranscript = ""

    /// Project an untrusted provider transcript into well-formed text.
    ///
    /// Removes the scalars that have no spoken form and can misrepresent what
    /// the user said on screen — the C0 controls, DEL, the C1 block, and the
    /// bidi mark / embedding / override / isolate families (an unterminated RLO
    /// renders everything after it reversed, which is the classic label-spoof
    /// primitive) — maps every break to a single space, collapses whitespace
    /// runs, and trims both ends.
    ///
    /// RIGHT-TO-LEFT SCRIPT IS UNTOUCHED. Arabic, Hebrew, Persian and Urdu
    /// transcripts pass through character-for-character; only the explicit
    /// formatting controls go, and the system's own bidi algorithm lays the
    /// rest out from the characters themselves.
    ///
    /// Idempotent: normalizing already-normalized text returns it unchanged,
    /// so a value that crosses the boundary twice is not degraded.
    nonisolated static func normalized(_ raw: String) -> String {
        ReplySanitizer.displayLine(
            raw,
            maxLength: uncappedLength,
            fallback: emptyTranscript
        )
    }
}
