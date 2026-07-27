// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTBackgroundTaskMetadata.swift
//
// Codable envelope attached to `URLSessionTask.taskDescription` for the
// background-upload path (Watch surface). Cross-launch survival: when the
// app is killed mid-upload and rebooted via background-session
// completion handler, the delegate can decode metadata from
// `task.taskDescription` and recover both the audio file path (for
// cleanup) and the provider ID (for status-map dispatch).
//
// JSON-encoded so paths containing `|` characters parse correctly (a
// delimiter-based encoding would break on them).

import Foundation

/// Metadata persisted via `URLSessionTask.taskDescription` so a
/// background URLSession delegate can recover provider context even
/// after the app process is recycled.
struct STTBackgroundTaskMetadata: Codable {
    /// Absolute path to the source audio file (used for `removeItem`
    /// cleanup in the delegate completion handler).
    let audioPath: String

    /// Provider ID (matches `STTProvider.id`). Decode via
    /// `STTProvider.lookup(id:)` to recover the full provider record.
    let providerID: String

    /// Optional pinned SHA-256 leaf-cert fingerprint (lowercase hex) for the
    /// BYO custom STT endpoint. Written at task-creation ONLY when the custom
    /// provider is active AND the user configured a pin; recovered at
    /// server-trust-challenge time by `BackgroundSTT`'s delegate, which is how
    /// the shared background session (it can't carry a per-request delegate)
    /// pins PER TASK at all. Nil for the 6 frozen providers (and for an
    /// unpinned custom endpoint) → default ATS validation.
    ///
    /// This field is the whole scope of the pin: the delegate applies it
    /// HOST-BLIND, to every server-trust challenge the task raises (a redirect
    /// target's included — a background session follows redirects without ever
    /// delivering `willPerformHTTPRedirection`). So WRITING this value is the
    /// decision; there is no second, host-based gate at challenge time. Rationale
    /// and honest limits on `BackgroundSTT`'s challenge handler.
    /// Tolerant optional — an older `taskDescription` JSON that predates this
    /// field decodes with `pinnedFingerprintHex == nil`. Never logged.
    let pinnedFingerprintHex: String?

    /// Absolute path to the REQUEST-BODY temp file (multipart `.bin` or JSON
    /// `.json`), for `removeItem` cleanup in the delegate completion handler.
    ///
    /// LOAD-BEARING PRIVACY, not bookkeeping: that body embeds a complete second
    /// copy of the recording (raw bytes for multipart, base64 for JSON), and the
    /// architecture's invariant is that captured audio is never persisted. It was
    /// tracked ONLY in an in-memory registry, which dies with the process — and
    /// suspend+relaunch is the DESIGNED path for a wrist background upload
    /// (`.backgroundTask(.urlSession(...))` exists precisely for it), so every
    /// cross-launch completion orphaned one voice recording in
    /// `temporaryDirectory` with no owner left to reclaim it. Carrying the path
    /// in the envelope makes the completion handler's cleanup survive the
    /// relaunch, exactly as `RemoteAgentBackgroundMetadata.bodyPath` already does
    /// for the converse hop.
    ///
    /// Tolerant optional — an older `taskDescription` JSON that predates this
    /// field decodes with `bodyPath == nil` (the in-memory registry still covers
    /// the same-process case). Never logged.
    let bodyPath: String?

    /// Explicit memberwise init with the additive fields defaulting to nil —
    /// keeps the pre-Custom-STT call site (audioPath + providerID) compiling.
    /// Coexists with the synthesized `Codable` conformance (which decodes a
    /// missing key as nil for an `Optional`).
    init(
        audioPath: String,
        providerID: String,
        pinnedFingerprintHex: String? = nil,
        bodyPath: String? = nil
    ) {
        self.audioPath = audioPath
        self.providerID = providerID
        self.pinnedFingerprintHex = pinnedFingerprintHex
        self.bodyPath = bodyPath
    }

    /// JSON-encode + UTF-8 stringify for attachment to
    /// `URLSessionTask.taskDescription`.
    func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let str = String(data: data, encoding: .utf8) else {
            throw AppError.sttDecodingFailure
        }
        return str
    }

    /// Decode from the string previously written to `taskDescription`.
    static func decode(_ s: String) throws -> STTBackgroundTaskMetadata {
        guard let data = s.data(using: .utf8) else {
            throw AppError.sttDecodingFailure
        }
        return try JSONDecoder().decode(STTBackgroundTaskMetadata.self, from: data)
    }
}
