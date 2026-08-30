// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications

/// Coordinates audio preservation + a deferred local notification so a
/// recording survives even when the host App Intent never returns a typed
/// error to Shortcuts (e.g. the OS killing `perform()` mid-flight, or
/// parameter resolution failing before `perform()` runs).
///
/// Usage:
/// ```swift
/// let token = await PendingRetryGuard.arm(audio: bytes, metadata: meta)
/// do {
///     try await sendToServer(...)
///     await PendingRetryGuard.disarm(token)        // success
/// } catch let error as AppError where !error.shouldPreserveForRetry,
///         error.isKnownBadInput {
///     await PendingRetryGuard.disarm(token)        // cleanup
///     throw error
/// } catch {
///     throw error                                  // leave armed
/// }
/// ```
///
/// Armed state means the audio is in `PendingRetryStore` *and* a local
/// notification is queued ~90 s out. Disarming cancels both. If neither
/// disarm nor a catch handler fires (because the OS terminated the intent
/// process), the audio + notification both persist via App Groups +
/// `UNUserNotificationCenter`'s system-side queue, giving the user a path
/// back into the app to retry.
///
/// ARMING CAN PARTLY FAIL, and the failure is not cosmetic. `save` writes with
/// `.completeFileProtection`, so the write is at its least certain in exactly
/// the window this guard matters most — a device that has rebooted and not been
/// unlocked, which is also when the Keychain cannot answer for the STT key. A
/// save that fails leaves NO bytes on disk, so `Token.audioPreserved` reports
/// it and the deferred notification is not scheduled: a system alert titled
/// "Recording Saved" offering a retry that has nothing to retry is a worse
/// outcome than silence.
enum PendingRetryGuard {
    /// Window before the deferred notification fires. Larger than the
    /// STT-client retry budget (~3 s × 3 attempts + ~120 s timeout) so
    /// successful runs disarm before the notification dispatches; small
    /// enough that an OS kill is surfaced to the user promptly.
    static let deferredNotificationDelay: TimeInterval = 90

    /// Identifier prefix so we can also clean up stragglers if needed.
    private static let notificationIDPrefix = "conduck-pending-retry-"

    struct Token: Sendable {
        let retryID: UUID
        let notificationID: String
        /// Whether the audio actually reached `PendingRetryStore`. False means
        /// the save threw and there are NO bytes to come back for, so nothing
        /// downstream may promise the user their recording survived.
        let audioPreserved: Bool
    }

    /// Save audio + metadata to `PendingRetryStore` and schedule a deferred
    /// "Recording saved" notification. Caller invokes `disarm` on success or
    /// known-bad-input; leaving the token un-disarmed is intentional for
    /// transient/upstream errors and for the OS-kill path.
    ///
    /// A save failure does NOT block the caller's recovery path — the retry
    /// safety net is nice-to-have, not load-bearing for the user flow — but it
    /// is reported rather than swallowed, on the token and by withholding the
    /// notification that would otherwise announce a recording that is not there.
    static func arm(
        audio: Data,
        metadata: PendingRetryMetadata,
        workImageData: Data? = nil,
        requestNotificationAuthorization: Bool = true
    ) async -> Token {
        // PendingRetryStore.save is throwing (disk I/O can fail, and a
        // `.completeFileProtection` write is at its least certain before first
        // unlock).
        var preserved = true
        do {
            try await PendingRetryStore.shared.save(
                audioData: audio,
                metadata: metadata,
                workImageData: workImageData
            )
        } catch {
            preserved = false
            #if DEBUG
            print("🛡️ PendingRetryGuard: save failed (\(error.localizedDescription)) — retry card will not appear")
            #endif
        }
        let token = Token(
            retryID: metadata.id,
            notificationID: notificationID(for: metadata.id),
            audioPreserved: preserved
        )
        // The notification's entire content is a claim about the store ("Recording
        // Saved" / "Tap to retry your transcription"). With nothing in the store
        // it is false in both halves, and tapping it reaches an empty retry lane.
        if preserved {
            await scheduleDeferredNotification(
                id: token.notificationID,
                requestAuthorization: requestNotificationAuthorization
            )
        }
        #if DEBUG
        print("🛡️ PendingRetryGuard armed (id=\(token.notificationID.suffix(8)), preserved=\(preserved))")
        #endif
        return token
    }

    /// Cancel the deferred notification AND clear `PendingRetryStore`. Call
    /// on confirmed success and on known-bad-input errors (audio_too_large,
    /// no_speech_detected, invalid_audio, rate_limit_exceeded, etc.) where
    /// retrying the same audio cannot help.
    ///
    /// Capture-scoped cleanup is load-bearing: a second App Intent can arm while
    /// the first is suspended in STT or gateway work. Completing the first must
    /// never delete the newer recording or cancel its recovery notice.
    static func disarm(_ token: Token) async {
        cancelDeferredNotification(for: token.retryID)
        _ = await PendingRetryStore.shared.clear(ifCurrentID: token.retryID)
        #if DEBUG
        print("🛡️ PendingRetryGuard disarmed (id=\(token.notificationID.suffix(8)))")
        #endif
    }

    /// Cancel any pending or delivered "Recording Saved" notification scheduled
    /// by `arm`. Does NOT touch `PendingRetryStore` — used by
    /// `PendingRetryRunner` after it has cleared the store itself, so a stale
    /// "tap to retry" notification doesn't fire 90 s after a successful in-app
    /// retry.
    static func cancelAllDeferredNotifications() async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(notificationIDPrefix) }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }

        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(notificationIDPrefix) }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    static func cancelDeferredNotification(for retryID: UUID) {
        let center = UNUserNotificationCenter.current()
        let id = notificationID(for: retryID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func notificationID(for retryID: UUID) -> String {
        notificationIDPrefix + retryID.uuidString
    }

    // MARK: - Deferred Notification

    private static func scheduleDeferredNotification(
        id: String,
        requestAuthorization: Bool
    ) async {
        // `kind:` parameter dropped (PendingRetryMetadata simplified — no mode
        // discriminator any more). Notification copy is mode-agnostic.
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()

        // Lazily request permission on first use. If the user already
        // authorized for another notification, they get this notification
        // automatically with no second prompt.
        if settings.authorizationStatus == .notDetermined && requestAuthorization {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }

        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            // Notifications denied — silent no-op. The retry card in the app
            // still shows on next launch via PendingRetryStore.hasPending().
            return
        }

        let content = UNMutableNotificationContent()
        // Reuses the pre-existing "Recording Saved" key (12 locales translated)
        // rather than adding a sentence-case duplicate; iOS notification titles
        // display fine in title case.
        content.title = String(localized: "Recording Saved")
        content.body = String(localized: "Tap to retry your transcription.")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: deferredNotificationDelay,
            repeats: false
        )
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }
}
