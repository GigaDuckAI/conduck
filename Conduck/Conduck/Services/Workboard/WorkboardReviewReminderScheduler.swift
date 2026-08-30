// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardReviewReminderScheduler.swift
//
// Permission-aware local reminders for a human-authored Workboard review date.
// Notification text carries no private brief details on the lock screen and a
// deterministic identifier makes rescheduling replace the prior request.

#if !os(watchOS)
import Foundation
import UserNotifications

enum WorkboardReviewReminderScheduleResult: Equatable, Sendable {
    case scheduled
    case notAuthorized
    case failed
}

actor WorkboardReviewReminderScheduler {
    static let shared = WorkboardReviewReminderScheduler()

    nonisolated static let identifierPrefix = "workboard.review."

    func reconcile(_ items: [WorkItemRecord], now: Date = Date()) async {
        let retainedIDs = Set(items.compactMap { item -> String? in
            guard item.completedAt == nil, item.content.dueAt != nil else { return nil }
            return Self.identifier(for: item.id)
        })
        let scheduled = items.compactMap { item -> (UUID, Date)? in
            guard item.completedAt == nil, let dueAt = item.content.dueAt, dueAt > now else {
                return nil
            }
            return (item.id, dueAt)
        }
        let desiredPendingIDs = Set(scheduled.map { Self.identifier(for: $0.0) })

        // A Workboard deletion can arrive from another device, bypassing this
        // device's `deleteItem` callback. Reconcile the namespace itself so those
        // stale reminders do not survive indefinitely or open a missing card.
        let center = UNUserNotificationCenter.current()
        let stalePending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter {
                $0.hasPrefix(Self.identifierPrefix) && !desiredPendingIDs.contains($0)
            }
        if !stalePending.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stalePending)
        }
        let staleDelivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter {
                $0.hasPrefix(Self.identifierPrefix) && !retainedIDs.contains($0)
            }
        if !staleDelivered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: staleDelivered)
        }

        for (itemID, dueAt) in scheduled {
            // Reconciliation may be caused by CloudKit on a peer. Never summon
            // a permission prompt without an explicit local toggle action.
            _ = await schedule(itemID: itemID, at: dueAt, requestsAuthorization: false)
        }
    }

    /// Explicit editor action. The caller only presents the reminder as enabled
    /// after this returns `.scheduled`; denial and add failures stay honest.
    func scheduleFromUserAction(
        itemID: UUID,
        at date: Date
    ) async -> WorkboardReviewReminderScheduleResult {
        await schedule(itemID: itemID, at: date, requestsAuthorization: true)
    }

    func cancel(itemID: UUID) async {
        let center = UNUserNotificationCenter.current()
        let id = Self.identifier(for: itemID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    }

    private func schedule(
        itemID: UUID,
        at date: Date,
        requestsAuthorization: Bool
    ) async -> WorkboardReviewReminderScheduleResult {
        if requestsAuthorization {
            await NotificationPermissions.ensureRequested()
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        #if os(macOS)
        let canSchedule = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        #else
        let canSchedule = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        #endif
        guard canSchedule else {
            return .notAuthorized
        }

        let id = Self.identifier(for: itemID)
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "workboard.reminder.notification.title",
            defaultValue: "A brief is ready for your review"
        )
        content.body = String(
            localized: "workboard.reminder.notification.body",
            defaultValue: "Open Workboard to decide what happens next."
        )
        content.sound = .default
        content.userInfo = [NotificationDeepLink.workItemIDKey: itemID.uuidString]
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            // Adding the same identifier replaces its pending request. Do not
            // remove first: if the new add fails, the last honest reminder stays.
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed
        }
    }

    private nonisolated static func identifier(for itemID: UUID) -> String {
        identifierPrefix + itemID.uuidString.lowercased()
    }
}
#endif
