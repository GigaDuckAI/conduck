// SPDX-License-Identifier: Apache-2.0

// The phone and Watch share these non-secret wire contracts. Content-sync
// preferences retain their original revision on every transport; relaying one
// must never mint a newer preference. Explicit text captures are independent of
// automatic content sync: the phone acknowledges only after its durable inert
// Work inbox accepts the caller-owned id. No AI dispatch belongs on this lane.

import Foundation

nonisolated enum ContentSyncWatchWire {
    static func encodedPreference(_ preference: ContentSyncPreference?) -> Data? {
        guard let preference else { return nil }
        return try? JSONEncoder().encode(preference)
    }

    static func preference(in payload: [String: Any]) -> ContentSyncPreference? {
        guard let data = payload[ContentSyncPreferenceStore.watchMessageKey] as? Data,
              data.count <= 4_096 else { return nil }
        return ContentSyncPreference.decode(data)
    }
}

nonisolated struct WatchWorkTextCapture: Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
}

nonisolated enum WatchWorkTextCaptureWire {
    static let kindKey = "kind"
    static let requestKind = "work-text-capture-v1"
    static let maximumCharacters = 16_000
    // Leave room for the request's plist envelope on the interactive channel.
    static let maximumUTF8Bytes = 48_000

    static func request(_ capture: WatchWorkTextCapture) -> [String: Any] {
        [kindKey: requestKind, "version": 1, "id": capture.id.uuidString,
         "text": capture.text, "createdAt": capture.createdAt.timeIntervalSince1970]
    }

    static func decode(_ payload: [String: Any]) -> WatchWorkTextCapture? {
        guard payload[kindKey] as? String == requestKind,
              payload["version"] as? Int == 1,
              let rawID = payload["id"] as? String, let id = UUID(uuidString: rawID),
              let text = payload["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= maximumCharacters, text.utf8.count <= maximumUTF8Bytes,
              let instant = payload["createdAt"] as? Double,
              instant.isFinite, instant > 0 else { return nil }
        return WatchWorkTextCapture(id: id, text: text, createdAt: Date(timeIntervalSince1970: instant))
    }

    static func acknowledgement(id: UUID, accepted: Bool) -> [String: Any] {
        [kindKey: requestKind, "version": 1, "id": id.uuidString, "accepted": accepted]
    }

    static func accepted(_ payload: [String: Any], for id: UUID) -> Bool? {
        guard payload[kindKey] as? String == requestKind,
              payload["version"] as? Int == 1,
              payload["id"] as? String == id.uuidString else { return nil }
        return payload["accepted"] as? Bool
    }
}
