// SPDX-License-Identifier: Apache-2.0

// Conduck
// AccessibilityAnnouncer.swift
//
// Tiny cross-platform (iOS / iPadOS / macOS) helper for posting VoiceOver
// announcements at key voice-capture + read-aloud lifecycle points (recording
// started / transcribing / transcript added / reading reply / stopped). Uses
// SwiftUI's `AccessibilityNotification.Announcement`, which no-ops when VoiceOver
// isn't running, so callers don't need to gate on the running state themselves.
//
// Pure presentation glue — no recorder / TTS dependency. English-only V1
// (callers pass already-localized strings).

import SwiftUI

enum AccessibilityAnnouncer {
    /// Post a VoiceOver announcement. Safe to call unconditionally — it has no
    /// effect when VoiceOver is off. Marshals to the main actor.
    @MainActor
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    /// Convenience for `LocalizedStringResource` call sites.
    @MainActor
    static func announce(_ resource: LocalizedStringResource) {
        announce(String(localized: resource))
    }
}
