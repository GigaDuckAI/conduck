// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsExplainer.swift
//
// Pure helpers for the Diagnostics screen — turn an `AppError` numeric code
// into plain-English cause + fix, normalize provider IDs to their archetype,
// and give each code a short stable slug for the copyable report.
//
// Design: the cause/fix copy is DELEGATED to `AppError`'s existing curated
// `errorDescription` / `recoverySuggestion`, reconstructed from the code with
// `message: nil`. That keeps one source of truth AND is privacy-safe: with no
// message, the opaque provider-message cases collapse to generic copy, so a
// live provider error string can never reach the screen or the clipboard.

import Foundation

enum DiagnosticsExplainer {

    /// Codes whose `errorDescription` would echo a raw/opaque payload (provider
    /// message, decoding/unknown wrappers). With `message: nil` these are already
    /// neutral, but we substitute an explicit generic cause so a row never shows
    /// an empty or ambiguous line.
    private static let opaqueCodes: Set<Int> = [1, 6, 7, 9, 10, 25, 99]

    /// Plain-English cause + fix for an `AppError` numeric code. Safe to show on
    /// screen and to place (as `slug`) in the copyable report.
    static func explain(code: Int) -> (cause: String, fix: String) {
        let error = AppError.from(errorCode: code, message: nil)
        let genericCause = String(
            localized: "diagnostics.cause.generic",
            defaultValue: "The last request didn't go through."
        )
        let genericFix = String(
            localized: "diagnostics.fix.generic",
            defaultValue: "Try again in a moment."
        )
        let cause: String
        if opaqueCodes.contains(code) {
            cause = genericCause
        } else {
            let described = error.errorDescription ?? ""
            cause = described.isEmpty ? genericCause : described
        }
        let suggested = error.recoverySuggestion ?? ""
        let fix = suggested.isEmpty ? genericFix : suggested
        return (cause, fix)
    }

    /// Strip the per-uuid suffix so a provider ID reduces to its locked
    /// archetype (`"custom-openai_A1B2"` → `"custom-openai"`,
    /// `"custom-openai-tts_A1B2"` → `"custom-openai-tts"`). Built-in IDs carry
    /// no underscore and pass through unchanged. Used to keep custom endpoint
    /// UUIDs/labels out of the copyable report.
    static func archetype(forProviderID id: String) -> String {
        guard let underscore = id.firstIndex(of: "_") else { return id }
        return String(id[..<underscore])
    }

    /// Short stable kebab slug for a code — the machine-friendly marker in the
    /// copyable report (`"code 26 (remote-agent-auth-failed)"`). Falls back to
    /// `"error-<code>"` for the rare opaque/reserved tail.
    static func slug(forCode code: Int) -> String {
        codeSlugs[code] ?? "error-\(code)"
    }

    private static let codeSlugs: [Int: String] = [
        1: "network-error", 2: "invalid-url", 3: "no-internet", 4: "request-timeout",
        5: "network-persistent-fail", 6: "invalid-response", 7: "decoding-error",
        8: "stt-auth-failed", 9: "invalid-request", 10: "api-failure", 11: "audio-invalid",
        12: "gateway-not-configured", 13: "stt-quota-exceeded", 14: "audio-missing-data",
        15: "settings-load-failed", 16: "stt-rate-limited", 17: "stt-server-error",
        18: "apple-speech-model-missing", 19: "gateway-unreachable", 20: "stt-unreachable",
        21: "no-speech-detected", 22: "audio-too-large", 23: "stt-missing-key",
        24: "audio-processing-failed", 25: "stt-decoding-failure", 26: "gateway-auth-failed",
        28: "gateway-timeout", 29: "gateway-server-error", 30: "gateway-cert-mismatch",
        31: "gateway-invalid-response", 32: "vision-unsupported", 33: "image-too-large",
        34: "custom-stt-not-configured", 35: "custom-stt-cert-mismatch", 36: "tts-unreachable",
        37: "tts-synthesis-failed", 38: "tts-empty-audio", 39: "tts-unauthorized",
        40: "tts-rate-limited", 41: "tts-content-blocked", 42: "custom-tts-not-configured",
        43: "custom-tts-cert-mismatch", 44: "file-not-configured", 45: "file-unreachable",
        46: "file-auth-failed", 47: "file-cert-mismatch", 48: "file-server-error",
        49: "file-upload-failed", 50: "file-unavailable", 51: "speech-permission-denied",
        52: "gateway-out-of-credits", 53: "audio-mic-busy", 54: "apple-speech-language-unsupported",
        55: "gateway-model-unavailable", 56: "gateway-context-too-long", 57: "gateway-rate-limited",
        58: "gateway-endpoint-unexpected-response", 59: "gateway-endpoint-not-found",
        60: "gateway-model-required", 61: "file-not-a-file-server",
        62: "gateway-endpoint-wrong-envelope",
        99: "unknown",
    ]
}
