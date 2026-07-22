// Conduck
// DataURIBuilder.swift
//
// V1.1 Core Attachments. Pure, dependency-free builder turning raw JPEG bytes
// into the `data:image/jpeg;base64,…` data-URI that the OpenAI-compatible
// `image_url` content part requires. Base64 data-URIs are the ONLY portable
// image input across arbitrary BYO gateways (Chat Completions dropped portable
// file input Sept 2025) — so every image rides the wire this way.
//
// Pure enum (no instances, no state) → trivially unit-testable + Sendable by
// construction. CROSS-TARGET: a Watch-target membership exception (pbxproj
// `63E4A001…` set) — the shared `ConversationHistoryAssembler` builds
// prior-turn data-URIs on EVERY converse surface, including the Watch.

import Foundation

/// Builds base64 image data-URIs for the multimodal `image_url` wire part.
enum DataURIBuilder {
    /// Encode `jpegData` as a `data:image/jpeg;base64,<base64>` URI. The MIME
    /// is fixed to `image/jpeg` because `ImageProcessor` normalises every image
    /// (incl. HEIC / ProRAW) to JPEG before this point — there is no other
    /// image type on the wire.
    static func jpegDataURI(from jpegData: Data) -> String {
        "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }
}
