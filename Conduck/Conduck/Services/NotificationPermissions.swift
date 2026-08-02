// SPDX-License-Identifier: Apache-2.0

// Conduck
// NotificationPermissions.swift
//
// Permission-UX rework (D4) — ONE central, idempotent notification-auth
// request. Local reply/failure notifications are the only feedback channel for
// headless asks (Shortcut / share-sheet / background converse), so the grant
// must exist before the first one fires. Onboarding USED to request it at
// completion; that's removed (we don't want a third onboarding prompt after
// mic + speech under the B baseline). Instead this helper is called at every
// FOREGROUND moment that can lead to a notification — Setup Guide completion,
// the first committed foreground converse dispatch (iOS + macOS), and the
// share-drain/recovery foreground moment.
//
// Idempotent + non-blocking by contract: it requests ONLY when the status is
// still `.notDetermined`, never re-prompts a determined status, and never
// throws or blocks the action it's attached to. A decline is respected (the
// system won't re-prompt).
//
// CONSUMED BY MULTIPLE CALL SITES — keep this exact API
// (`NotificationPermissions.ensureRequested()`).

import Foundation
import UserNotifications

/// Central idempotent notification-authorization request. Stateless enum.
enum NotificationPermissions {
    /// Request notification authorization once, only when undecided. No-op if
    /// the user has already allowed or denied. Never blocks or throws — a
    /// failed/declined request just leaves the existing status in place.
    static func ensureRequested() async {
        // Never PROMPT under XCTest: `requestAuthorization` blocks on a system
        // prompt that can't appear in the unsigned test host, hanging any suite
        // that drives a foreground path calling this (e.g. SharedInboxDrainer
        // .drain()). No-op in tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// True when the user tapped "Not now" on the Setup Guide notifications
    /// priming step (`EnableNotificationsStepView`). Honored ONLY by the
    /// low-urgency in-app composer send backstop (`ConversationDetailViewModel`)
    /// so an explicit defer isn't immediately undone by re-popping the OS dialog
    /// on the very next send. The genuinely-headless backstops (`ConverseIntent`,
    /// share-drain) still ask — there a notification is the only feedback channel.
    /// App-Group bool so the value is visible to every process.
    static var isNotificationsDeferred: Bool {
        SettingsDependencies.processDefault.defaults
            .bool(forKey: Constants.notificationsDeferredKey)
    }

    /// Record that the user deferred notifications ("Not now") in the Setup Guide.
    static func markNotificationsDeferred() {
        SettingsDependencies.processDefault.defaults
            .set(true, forKey: Constants.notificationsDeferredKey)
    }
}
