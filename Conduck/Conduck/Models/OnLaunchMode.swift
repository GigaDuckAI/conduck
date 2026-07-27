// SPDX-License-Identifier: Apache-2.0

// Conduck
// OnLaunchMode.swift
//
// User preference deciding what the user lands on when Conduck cold-launches
// after a force-quit (onboarding already done). Independent of
// `SessionContinuationPolicy`, which governs send-routing for headless quick
// captures — this enum governs the LANDING UX only. Persisted via
// `SettingsManager` (App Groups key `Constants.onLaunchModeKey`, dual-written
// to iCloud KVS so the choice rides across the user's devices).

import Foundation

/// User preference for cold-launch landing. Raw values are load-bearing
/// (persisted) — do not rename.
enum OnLaunchMode: String, CaseIterable, Codable, Sendable {
    /// Cold launch lands on the empty-state composer; a fresh conversation
    /// is minted on the first send.
    case startNewConversation
    /// Cold launch resumes the most-recent conversation (ignores the
    /// `SessionContinuationPolicy` TTL — resumes unconditionally).
    case resumeLastConversation

    static let `default`: OnLaunchMode = .startNewConversation
}
