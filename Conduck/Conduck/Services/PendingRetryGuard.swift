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
/// Armed state means the audio is in `PendingRetryStore`, a RESERVATION over
/// that queue entry is held by this process, *and* a local notification is
/// queued ~90 s out. Disarming clears the entry through the reservation and
/// cancels the notice. If neither disarm nor a catch handler fires (because the
/// OS terminated the intent process), the audio + notification both persist via
/// App Groups + `UNUserNotificationCenter`'s system-side queue, giving the user
/// a path back into the app to retry.
///
/// THE RESERVATION IS WHAT MAKES THE DISARM SAFE. The queue is shared with the
/// app's retry card and the menu bar, and each of those selects a capture and
/// holds it while it works. An id-keyed clear cannot tell whether the capture it
/// is deleting is still this process's — so a Shortcut completing at the same
/// moment the person tapped Retry deleted the recording out from under the
/// surface transcribing it, and for Chat that is two turns and two gateway
/// effects for one recording. Every operation this guard performs against the
/// entry is therefore token-checked, and a refusal means another surface owns
/// the capture now: this process does nothing further with it.
///
/// ARMING CAN PARTLY FAIL, and the failure is not cosmetic. `save` writes with
/// `.completeFileProtection`, so the write is at its least certain in exactly
/// the window this guard matters most — a device that has rebooted and not been
/// unlocked, which is also when the Keychain cannot answer for the STT key. A
/// save that fails leaves NO bytes on disk, so `Token.audioPreserved` reports
/// it and the deferred notification is not scheduled: a system alert titled
/// "Recording Saved" offering a retry that has nothing to retry is a worse
/// outcome than silence. `Token.isDurable` is the stricter reading — saved AND
/// reserved — and is what a lane consults before it deletes its own copy of the
/// recording or tells the person the audio is kept, because a saved entry
/// nobody holds is one another surface may take mid-flight.
///
/// A save that lands the RECORDING and loses only the screenshot is not one of
/// those failures. `PendingRetrySaveOutcome.recordingParkedWithoutPicture` says
/// the entry is committed and claimable, so the arm stands and takes its
/// reservation: an armed entry whose author believes it does not exist is worse
/// than either half of the write failing outright, because nothing then refuses
/// a second surface that claims it.
enum PendingRetryGuard {
    /// Window before the deferred notification fires. Larger than the
    /// STT-client retry budget (~3 s × 3 attempts + ~120 s timeout) so
    /// successful runs disarm before the notification dispatches; small
    /// enough that an OS kill is surfaced to the user promptly.
    static let deferredNotificationDelay: TimeInterval = 90

    /// How long the reservation this guard takes is respected, and why it is
    /// the notification delay rather than the store's own ten minutes: at
    /// `deferredNotificationDelay` the user is told to open the app and retry,
    /// so a hold that outlived that notice would refuse them their own
    /// recording behind a card whose button does nothing. A process that is
    /// still alive `renew`s; one the OS killed gives the capture back within a
    /// single notification window.
    static let leaseDuration: TimeInterval = deferredNotificationDelay

    /// How often a live caller extends that reservation. Comfortably inside
    /// `leaseDuration`, so one missed tick is not a lost capture.
    static let leaseRenewalInterval: TimeInterval = 45

    /// Identifier prefix so we can also clean up stragglers if needed.
    private static let notificationIDPrefix = "conduck-pending-retry-"

    #if CONDUCK_TESTING
    // TEST SEAM — the queue this guard arms against.
    //
    // WHY IT MUST EXIST: what this guard now guarantees is a property of the
    // RESERVATION — that a disarm deletes a capture only while this process
    // still holds it — and no assertion about that is possible without two
    // holders over one entry. `PendingRetryStore.shared` is a process-global
    // singleton over one App-Group file every capture test in this bundle
    // shares, so a case that drove it would be asserting against, and
    // corrupting, its neighbours' state. Nil in every other build, and the whole
    // declaration compiles only under `CONDUCK_TESTING`.
    nonisolated(unsafe) static var storeForTesting: PendingRetryStore?
    #endif

    private static var store: PendingRetryStore {
        #if CONDUCK_TESTING
        return storeForTesting ?? .shared
        #else
        return .shared
        #endif
    }

    struct Token: Sendable {
        let retryID: UUID
        let notificationID: String
        /// Whether the audio actually reached `PendingRetryStore`. False means
        /// the save threw and there are NO bytes to come back for, so nothing
        /// downstream may promise the user their recording survived.
        let audioPreserved: Bool
        /// The reservation this process holds over the entry it armed, issued
        /// by the store against the id this capture minted.
        ///
        /// Nil when nothing was preserved — there is no entry to reserve — and,
        /// in the state that should not occur, when the store refused the
        /// reservation. Both readings are answered by `stillOwnsCapture`, which
        /// is what every caller asks rather than testing this for nil.
        let claim: PendingRetryClaim?

        /// Did this arm actually PARK the capture — bytes on disk under an
        /// entry this process holds a reservation over?
        ///
        /// The question a lane asks before it destroys its own copy of the
        /// recording or tells the person their audio is safe. `audioPreserved`
        /// alone is not enough: a save can land and the reservation still be
        /// refused, and an entry nobody holds is one another surface may take
        /// and finish while this lane believes it owns it. False therefore
        /// means "nothing is parked as far as this process is concerned" —
        /// keep the bytes, promise nothing, delete nothing.
        ///
        /// `nonisolated` because it reads two immutable fields of a `Sendable`
        /// value and the lanes that ask it are headless: an App Intent host, a
        /// CarPlay scene's capture path. A computed property that inherited the
        /// module's actor would have to be awaited from exactly the contexts
        /// that need it most.
        nonisolated var isDurable: Bool { audioPreserved && claim != nil }
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
    ///
    /// The RESERVATION is taken here, immediately after the write and against
    /// the id this caller minted — never by selection. `claimNext` answers "the
    /// newest capture nobody has reserved", which is a stranger's recording the
    /// moment anything armed after this one, and reading a stranger's bytes into
    /// the most memory-constrained process in the app to hold a capture it will
    /// never finish is the opposite of what this guard is for.
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
            try await store.save(
                audioData: audio,
                metadata: metadata,
                workImageData: workImageData
            )
        } catch PendingRetrySaveOutcome.recordingParkedWithoutPicture {
            // THE RECORDING IS PARKED. Only the screenshot — the last byte
            // written before the index row — failed, and the store commits the
            // row anyway, so the queue holds a live entry any surface can claim.
            // Reading this as a failed save is the state that makes the arm
            // dangerous rather than merely incomplete: the lane that made the
            // entry would hold no reservation over it, `stillOwnsCapture` would
            // answer true on the no-entry rule below, and a second surface
            // finishing the same capture would meet no refusal from either side.
            // So the arm stands, the reservation is taken, and the notification
            // is honest — a recording really is saved. The picture is the thing
            // that is gone, and its own lane still holds the only copy.
            #if DEBUG
            print("🛡️ PendingRetryGuard: screenshot not written — recording parked, arm stands")
            #endif
        } catch {
            preserved = false
            #if DEBUG
            print("🛡️ PendingRetryGuard: save failed (\(error.localizedDescription)) — retry card will not appear")
            #endif
        }
        // Reserve the capture just written, by the id it was written under. A
        // save that failed queued nothing, so there is nothing to reserve and
        // no other surface that could be holding it.
        // Held as the reservation ALONE: the bytes it answers with are the ones
        // this process just wrote and still holds, and a second copy of a
        // recording that may be `Constants.maxAudioSize` would sit beside the
        // first for the whole span of the work, in the most memory-constrained
        // process in the app.
        let reservation: PendingRetryClaim?
        if preserved {
            reservation = await store.claim(
                id: metadata.id,
                duration: leaseDuration
            )?.reservationOnly
        } else {
            reservation = nil
        }
        let token = Token(
            retryID: metadata.id,
            notificationID: notificationID(for: metadata.id),
            audioPreserved: preserved,
            claim: reservation
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
    ///
    /// It goes through the RESERVATION, so it deletes only a capture this
    /// process still holds. A capture another surface took over while this one
    /// was suspended is left entirely alone — its bytes, its entry AND its
    /// notice, because that surface is the one that will cancel the notice when
    /// it finishes. Nothing was reserved (the save failed, so nothing is
    /// queued and no notice was scheduled) is the same no-op.
    static func disarm(_ token: Token) async {
        guard let claim = token.claim else { return }
        guard await store.clear(claim) else {
            #if DEBUG
            print("🛡️ PendingRetryGuard disarm refused — another surface holds this capture")
            #endif
            return
        }
        cancelDeferredNotification(for: token.retryID)
        #if DEBUG
        print("🛡️ PendingRetryGuard disarmed (id=\(token.notificationID.suffix(8)))")
        #endif
    }

    /// Extend the reservation while this process is still working on the
    /// capture. Callers drive it on a timer inside `leaseDuration`; a process
    /// the OS killed stops renewing by dying, which is the whole point of a
    /// horizon this short.
    @discardableResult
    static func renew(_ token: Token) async -> Bool {
        guard let claim = token.claim else { return false }
        return await store.renew(claim)
    }

    /// Does this process still own the capture it armed?
    ///
    /// The question EVERY caller asks before it acts on the transcript — before
    /// a Chat turn is stored, before the desk decision is taken, before the
    /// notice is cancelled. False means another surface reserved the capture
    /// after this one's hold lapsed and is finishing it now, so acting would
    /// duplicate whatever that surface is about to do.
    ///
    /// An arm that preserved NOTHING answers true: no entry exists, so no other
    /// surface can be holding one, and the bytes in this process are the only
    /// copy there is. Refusing there would abandon a recording to protect an
    /// entry that was never written.
    static func stillOwnsCapture(_ token: Token) async -> Bool {
        guard token.audioPreserved else { return true }
        guard let claim = token.claim else { return false }
        return await store.confirmOwnership(claim)
    }

    /// Write what this process OBSERVED about the capture onto its queue entry,
    /// through the reservation, so a recovery in another process can tell a
    /// recording the desk never took from a card somebody deleted.
    ///
    /// False when nothing is reserved or the reservation was overtaken — the
    /// entry then belongs to whichever surface holds it, and its own observation
    /// is the one that counts.
    @discardableResult
    static func recordPublicationState(
        _ token: Token,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState
    ) async -> Bool {
        guard let claim = token.claim else { return false }
        return await store.recordPublicationState(
            claim,
            transcript: transcript,
            publicationState: publicationState
        )
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
