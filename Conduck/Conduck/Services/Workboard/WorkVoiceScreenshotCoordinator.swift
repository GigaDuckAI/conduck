// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkVoiceScreenshotCoordinator.swift
//
// The screenshot half of a Shortcuts / Action-Button Work voice capture, and
// the only place its identity is decided.
//
// A capture carries at most two artifacts — the recording and the screenshot
// the Shortcut graph wired in — and they are two cards. The recording's card is
// named by the capture id itself (`WorkVoiceCaptureCoordinator`), so the
// screenshot needs an identity of its own: `WorkCaptureInbox.publishAppCapture`
// names its image entry after the envelope it rides, and an envelope minted at
// the capture id would put the screenshot at the recording's id, where the desk
// answers with the recording that already stands there and the picture is
// silently dropped. The derivation below is deterministic, so a replay of one
// capture repairs the same screenshot card instead of adding a second.
//
// Publication goes through the App-Group queue rather than straight into the
// store because `WorkCaptureInbox`'s published envelope is the durable
// boundary: a Core Data failure leaves the bytes in the queue for the
// foreground observer to drain rather than losing them, and the card it
// produces is byte-for-byte the one a shared image produces.

#if !os(watchOS)

import CryptoKit
import Foundation

enum WorkVoiceScreenshotCoordinator {

    /// The screenshot card's permanent identity, derived from the capture's.
    ///
    /// The same shape as `WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture:)`
    /// — UUIDv5 over a fixed namespace, so two devices replaying one capture
    /// derive the same card — in a namespace of its OWN, which is what keeps the
    /// three identities one capture can need (recording, screenshot, fallback
    /// note) from ever naming each other.
    static func materialID(forCapture captureID: UUID) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: captureID.uuid) { hasher.update(bufferPointer: $0) }
        var bytes = Array(hasher.finalize().prefix(16))
        // RFC 4122 §4.3: name-based, SHA-1 (version 5) and the standard variant.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Publish the screenshot a Work voice capture carried, as its own card.
    ///
    /// Idempotent in both halves: the queue refuses a second envelope under an
    /// id it already holds, and the desk write answers a replayed material with
    /// the card already standing there. So every surface that recovers this
    /// capture may call it, and a capture recovered twice still has one picture.
    ///
    /// Returns nil, having published nothing, when there is nothing publishable
    /// — no bytes, or bytes the image pipeline cannot normalize. Best-effort is
    /// the same stance the note-shaped publication takes: a picture that will not
    /// decode may not cost the words that came with it.
    ///
    /// A THROW means the queue itself refused the bytes, which is the one state
    /// a caller must not consume its pending retry through: the retry record
    /// holds the only remaining copy of this screenshot.
    /// `sourceDevice` and `normalize` default through nil rather than through
    /// their production values: a default-argument expression is evaluated in
    /// the CALLER's isolation, and the headless intent lane that calls this is
    /// nonisolated.
    @discardableResult
    static func publish(
        _ rawImageData: Data,
        forCapture captureID: UUID,
        createdAt: Date,
        inbox: WorkCaptureInbox = .shared,
        store: ConversationStore = .shared,
        sourceDevice: String? = nil,
        normalize: (@Sendable (Data) async -> Data?)? = nil
    ) async throws -> UUID? {
        let normalizer = normalize ?? Self.normalizeToJPEG
        guard !rawImageData.isEmpty, let jpegData = await normalizer(rawImageData) else {
            return nil
        }
        let materialID = materialID(forCapture: captureID)
        _ = try await inbox.publishAppCapture(
            note: "",
            imageData: jpegData,
            imageFilename: screenshotFilename,
            imageMIMEType: "image/jpeg",
            imageTypeIdentifier: "public.jpeg",
            captureID: materialID,
            createdAt: createdAt
        )
        // Publication above is the durable boundary, so a drain that cannot
        // reach the store is not a failed capture — the envelope stays queued
        // and the foreground observer imports it.
        _ = try? await WorkCaptureDrainer(
            inbox: inbox,
            store: store,
            sourceDevice: sourceDevice ?? SourceDevice.current
        ).drainAvailableCaptures()
        return materialID
    }

    /// Strips source metadata and normalizes to JPEG before the bytes leave the
    /// process, exactly as the note-shaped publication does.
    static let normalizeToJPEG: @Sendable (Data) async -> Data? = { raw in
        try? await ImageProcessor.shared.process(raw).jpegData
    }

    /// Names the payload for the card's file line, matching the name a
    /// GigaAction screenshot has always carried onto the desk.
    private static let screenshotFilename = "screenshot.jpg"

    /// Compile-time derivation namespace, a literal in the same spirit as the
    /// desk's own fixed id. Its only requirement is that no other derivation
    /// uses it: sharing one with `fallbackNoteID`'s would make a capture's
    /// screenshot and its fallback note the same card.
    private static let namespace = UUID(uuidString: "5C7E0000-0000-4000-A000-000000000001")!
}

#endif
