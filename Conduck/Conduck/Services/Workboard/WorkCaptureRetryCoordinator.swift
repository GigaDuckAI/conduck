// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureRetryCoordinator.swift
//
// One terminal handoff for voice captures whose explicit destination is Work.
// It publishes an inert, deterministic App-Group envelope and best-effort
// drains it into private Workboard persistence. There is deliberately no agent
// client or gateway dependency in this type.

#if !os(watchOS)

import Foundation

enum WorkCaptureRetryCoordinator {
    /// Publishes the recovered transcript under the caller-owned retry id. The
    /// id is stable across intent-process death and user retries, so a crash
    /// after atomic publication but before retry cleanup can only replay the
    /// same capture. Screenshot normalization is best-effort and strips source
    /// metadata before the bytes enter Work's local vault.
    @discardableResult
    static func publish(
        transcript: String,
        rawImageData: Data?,
        captureID: UUID,
        createdAt: Date
    ) async throws -> UUID {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.noSpeechDetected }

        let jpegData: Data?
        if let rawImageData, !rawImageData.isEmpty {
            jpegData = try? await ImageProcessor.shared.process(rawImageData).jpegData
        } else {
            jpegData = nil
        }

        let publishedID = try await WorkCaptureInbox.shared.publishAppCapture(
            note: trimmed,
            imageData: jpegData,
            imageFilename: "screenshot.jpg",
            imageMIMEType: "image/jpeg",
            imageTypeIdentifier: "public.jpeg",
            captureID: captureID,
            createdAt: createdAt
        )

        // Publication above is the durable boundary. A transient Core Data
        // failure must not turn a successful capture into an intent failure;
        // the foreground queue observer retries the still-published envelope.
        _ = try? await WorkCaptureDrainer(
            sourceDevice: SourceDevice.current
        ).drainAvailableCaptures()
        return publishedID
    }
}

#endif
