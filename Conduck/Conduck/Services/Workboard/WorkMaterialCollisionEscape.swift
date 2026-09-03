// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialCollisionEscape.swift
//
// The one id a capture may fall back to when its own id already names a card of
// another kind.
//
// A material id names ONE card, so the desk write refuses a capture whose id is
// already held by a card of a different kind rather than answering with that
// card. The refusal is right — it is what stops a shared file overwriting a
// screenshot's bytes — but a refusal on its own strands the capture: the id
// never becomes free, so every replay refuses identically, and a queue entry
// that can never be acknowledged blocks every capture behind it. This is the
// way out of that state.
//
// It is deliberately NOT a fresh random id. The app and the headless intent
// process drain the same queue file, and either may replay it after a crash;
// they have to land on the same card or one capture becomes two. So the escape
// is derived — UUIDv5 over a compile-time namespace, the same shape as
// `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` and
// `WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture:)` — in a namespace of
// its OWN, which is what keeps the ids one capture can need from ever naming
// each other.

import CryptoKit
import Foundation

enum WorkMaterialCollisionEscape {

    /// The id a capture's bytes land under when the capture's own id already
    /// names a card of another kind; a pure function of the capture id so every
    /// process and every retry derives the same card.
    ///
    /// THERE IS NO SECOND ESCAPE. If this id also names a card of another kind
    /// the refusal is terminal and the capture is retired with its bytes
    /// preserved, because a chain of derived ids has no end and every link is
    /// one more card the person never asked for.
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

    /// Compile-time derivation namespace, a literal in the same spirit as the
    /// desk's own fixed id. Changing it re-homes every escaped card that has
    /// already been written and lets a replay publish a second copy of one, so
    /// it is pinned by a test against a fixed input rather than left to be
    /// "tidied".
    private static let namespace = UUID(uuidString: "C0111DE0-0000-4000-A000-000000000001")!
}
