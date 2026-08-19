// SPDX-License-Identifier: Apache-2.0

// Conduck
// CloudSyncMonitor.swift
//
// SILENT iCloud-sync health monitor for the CloudKit-mirrored conversation
// store (`NSPersistentCloudKitContainer`). Two jobs, both deliberately quiet:
//
//   1. Observability (INVISIBLE). Observes `eventChangedNotification` (live) +
//      fetches recent events on launch/foreground (catches events fired while
//      the app was suspended) and writes a REDACTED one-line summary to `os_log`
//      + a small persisted ring buffer. No PII (domain/code only, never the
//      localized error text / record ids). This is pure debuggability — read it
//      when a sync complaint comes in; the user never sees it.
//
//   2. One user-actionable signal. Publishes `iCloudUnavailable` — true ONLY for
//      states the user can FIX (signed out / restricted / iCloud storage full).
//      NEVER for transient / network / throttled / first-sight errors (the system
//      retries those). Drives a single quiet banner + a Settings row; everything
//      else stays silent.
//
// Why no "force sync" / pull-to-refresh: `NSPersistentCloudKitContainer` exposes
// no public force-fetch/force-export API — its scheduling is opaque — so this
// monitor SURFACES state, it never commands sync. (Validated decision; see the
// sync-robustness plan.)
//
// Device-only: on the Simulator (and the in-memory test seam) the store is a
// plain `NSPersistentContainer` with no CloudKit, so the monitor stays inert
// except for the `-ConduckQAForceICloudUnavailable` QA override that lets the
// banner/Settings UI be exercised on a sim.

import CloudKit
import CoreData
import Foundation
import OSLog

// `SyncEventSummary` (the redacted, `Sendable` CloudKit-event snapshot) lives in
// `ConversationStore.swift` so it is visible in EVERY target that compiles that
// shared file — including the watchOS app target, which reuses the store but does
// NOT include this iOS/macOS-only monitor.

@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    /// The one user-actionable reason iCloud sync is broken. Mapped only from
    /// states the user can resolve; transient/network states never set it.
    enum Reason: Sendable {
        case noAccount
        case restricted
        case quotaExceeded

        /// Conversation-list banner copy (terse — it's a transient interruption).
        var bannerMessage: LocalizedStringResource {
            switch self {
            case .noAccount:
                return LocalizedStringResource(
                    "sync.icloud.banner.noAccount",
                    defaultValue: "iCloud is signed out — your conversations won't sync across your devices."
                )
            case .restricted:
                return LocalizedStringResource(
                    "sync.icloud.banner.restricted",
                    defaultValue: "iCloud is restricted on this device — your conversations can't sync."
                )
            case .quotaExceeded:
                return LocalizedStringResource(
                    "sync.icloud.banner.quota",
                    defaultValue: "Your iCloud storage is full — new conversations can't sync to your other devices."
                )
            }
        }

        /// Settings-row explainer copy (slightly fuller — the user navigated here).
        var settingsMessage: LocalizedStringResource {
            switch self {
            case .noAccount:
                return LocalizedStringResource(
                    "sync.icloud.settings.noAccount",
                    defaultValue: "Sign in to iCloud in Settings to sync your conversations across your devices."
                )
            case .restricted:
                return LocalizedStringResource(
                    "sync.icloud.settings.restricted",
                    defaultValue: "iCloud is restricted on this device (e.g. by Screen Time or a profile), so conversations can't sync."
                )
            case .quotaExceeded:
                return LocalizedStringResource(
                    "sync.icloud.settings.quota",
                    defaultValue: "Your iCloud storage is full. Free up space or upgrade your plan to resume syncing."
                )
            }
        }
    }

    /// True ONLY when iCloud is in a user-actionable bad state. Drives the
    /// Settings row directly and the banner (gated additionally on `bannerDismissed`).
    private(set) var iCloudUnavailable = false
    private(set) var unavailableReason: Reason?
    /// Sticky-per-episode banner dismissal (hydrated from / written to the
    /// App-Group flag), reset when the account recovers.
    private(set) var bannerDismissed = false

    /// Show the conversation-list banner: unavailable AND not yet dismissed this
    /// episode.
    var showsBanner: Bool { iCloudUnavailable && !bannerDismissed }

    private let log = Logger(subsystem: Constants.identityNamespace, category: "CloudSync")
    private static let ringBufferKey = "cloudSyncEventLog"
    private let ringBufferCap = 50

    // Diagnostics ring-buffer persistence runs OFF the main actor on a dedicated
    // serial queue: the App-Group `UserDefaults` read-modify-write is plist I/O
    // that fires per completed CloudKit event, so a mirroring storm would block
    // `.main` in lockstep. Writes coalesce — appends land cheaply in memory and
    // flush once (~1s throttle) so a burst does ONE plist write, not N. The
    // in-memory state below is touched ONLY on `ringBufferQueue`
    // (`nonisolated(unsafe)` = manually serialized, not a data race).
    private static let ringBufferQueue = DispatchQueue(label: Constants.identityNamespace + ".cloudsync.ringbuffer")
    nonisolated(unsafe) private static var ringBufferPending: [String] = []
    nonisolated(unsafe) private static var ringBufferFlushScheduled = false

    private var started = false
    private var eventObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// Wire the monitor once at app launch. Idempotent. On the Simulator only the
    /// QA override path runs (the real CloudKit stack is inert there).
    func start() {
        guard !started else { return }
        started = true
        bannerDismissed = SettingsManager.iCloudBannerDismissed()

        #if DEBUG
        if QAMode.forceICloudUnavailable {
            setUnavailable(.noAccount)
            log.notice("CloudSyncMonitor: QA-forced iCloud unavailable")
            return
        }
        #endif

        // A process without the container entitlement (a native macOS build —
        // unsigned in practice, but the probe reads the entitlement, not the
        // signature; see `Constants.hasICloudContainerEntitlement`) cannot
        // construct the CK container at all: `refreshAccountStatus()` below would raise on
        // `CKContainer(identifier:)` and take the process with it. Stay inert and
        // say so once, rather than crash. Never surfaces the user-facing banner —
        // this is a build that cannot sync, not an account the user can fix.
        guard Constants.hasICloudContainerEntitlement else {
            log.notice("CloudSyncMonitor: inert — no iCloud container entitlement in this build")
            return
        }

        #if !targetEnvironment(simulator)
        // Live mirroring telemetry. `object: nil` — there is exactly one CK
        // container in-process; the summary is built on the (.main) delivery
        // queue so only the `Sendable` snapshot crosses into the actor-isolated
        // ingest.
        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                event.endDate != nil  // only completed events; ignore "started"
            else { return }
            let summary = SyncEventSummary(event: event)
            Task { @MainActor in self?.ingest(summary) }
        }

        // Re-check account whenever iCloud sign-in state changes.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAccountStatus() }
        }

        Task { await refreshAccountStatus() }
        Task { await catchUpOnEvents() }
        #endif
    }

    /// Re-check on foreground (account state + suspended-window event catch-up).
    func refresh() async {
        #if DEBUG
        if QAMode.forceICloudUnavailable { return }
        #endif
        #if !targetEnvironment(simulator)
        await refreshAccountStatus()
        await catchUpOnEvents()
        #endif
    }

    /// User tapped the banner's dismiss. Sticky for this outage episode
    /// (persisted); reset automatically when the account recovers.
    func dismissBanner() {
        bannerDismissed = true
        SettingsManager.setICloudBannerDismissed(true)
    }

    // MARK: - Account status

    private func refreshAccountStatus() async {
        // THE construction point, and therefore where the invariant belongs:
        // `CKContainer(identifier:)` raises on an unentitled process, so no
        // caller — present or future — may reach it without this check. `start()`
        // additionally declines to wire the observers that would call this.
        guard Constants.hasICloudContainerEntitlement else { return }
        let container = CKContainer(identifier: Constants.iCloudCloudKitContainerID)
        do {
            let status = try await container.accountStatus()
            applyAccountStatus(status)
        } catch {
            // Couldn't read status (transient) — log only, never alarm.
            let ns = error as NSError
            log.error("iCloud accountStatus error \(ns.domain, privacy: .public)#\(ns.code, privacy: .public)")
        }
    }

    /// PURE classification (unit-tested): which `CKAccountStatus` values are
    /// user-actionable (→ a `Reason`) vs. silent. `.available` and the transient
    /// states (`.couldNotDetermine` / `.temporarilyUnavailable`, which the system
    /// retries) return nil — they NEVER alarm the user.
    static func actionableReason(for status: CKAccountStatus) -> Reason? {
        switch status {
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .available, .couldNotDetermine, .temporarilyUnavailable: return nil
        @unknown default: return nil
        }
    }

    private func applyAccountStatus(_ status: CKAccountStatus) {
        if let reason = Self.actionableReason(for: status) {
            setUnavailable(reason)
        } else if status == .available {
            clearUnavailable()
        } else {
            // Transient (couldNotDetermine / temporarilyUnavailable) — log only.
            log.notice("iCloud account status transient: \(status.rawValue, privacy: .public)")
        }
    }

    // MARK: - Event telemetry

    private func ingest(_ summary: SyncEventSummary) {
        record(summary)
        // Quota-full is sticky + user-actionable → promote a LIVE failure
        // immediately. Every other event error is transient/system-retried →
        // logged only (never promoted on first sight).
        if summary.isQuotaExceeded && !summary.succeeded {
            setUnavailable(.quotaExceeded)
        }
    }

    /// Pull events that fired while the app was suspended (the live observer
    /// misses those). Log-only — never promotes UI from historical events (avoids
    /// stale-error false alarms); live failures + account status drive the surface.
    private func catchUpOnEvents() async {
        let summaries = await ConversationStore.shared.recentSyncEventSummaries()
        for summary in summaries { record(summary) }
    }

    private func record(_ summary: SyncEventSummary) {
        if summary.succeeded {
            log.debug("sync \(summary.redactedLine, privacy: .public)")
        } else {
            log.error("sync \(summary.redactedLine, privacy: .public)")
        }
        appendToRingBuffer(summary.redactedLine)
    }

    private func appendToRingBuffer(_ line: String) {
        // Hand off to the serial queue: append in memory (cheap), then schedule a
        // single throttled flush ~1s later. Extra appends inside that window pile
        // into `ringBufferPending` and ride the same flush → one plist write per
        // burst instead of one per event on the main thread.
        let key = Self.ringBufferKey
        let cap = ringBufferCap
        let queue = Self.ringBufferQueue
        queue.async {
            Self.ringBufferPending.append(line)
            guard !Self.ringBufferFlushScheduled else { return }
            Self.ringBufferFlushScheduled = true
            queue.asyncAfter(deadline: .now() + 1.0) {
                Self.flushRingBuffer(key: key, cap: cap)
            }
        }
    }

    /// Persist the coalesced appends. Runs ONLY on `ringBufferQueue`. Preserves
    /// the original append-then-trim-to-`cap` semantics (keep the last `cap`
    /// lines) by folding the in-memory batch into the persisted array.
    private nonisolated static func flushRingBuffer(key: String, cap: Int) {
        ringBufferFlushScheduled = false
        guard !ringBufferPending.isEmpty else { return }
        let defaults = SettingsDependencies.processDefault.defaults
        var entries = defaults.stringArray(forKey: key) ?? []
        entries.append(contentsOf: ringBufferPending)
        ringBufferPending.removeAll()
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        defaults.set(entries, forKey: key)
    }

    /// READ side of `flushRingBuffer` — the persisted diagnostics ring buffer, in
    /// stored order (oldest-first, newest-last; the last `ringBufferCap` events).
    /// Reads the SAME App-Group suite + key the write path persists to. Each line
    /// is ALREADY redacted (`"<kind> <ok|FAIL> err=<domain>#<code>"` — domain/code
    /// only, never URLs / tokens / localized error text), so it is safe to surface
    /// directly in a Diagnostics screen.
    nonisolated static func recentSyncEventLines() -> [String] {
        SettingsDependencies.processDefault.defaults.stringArray(forKey: ringBufferKey) ?? []
    }

    // MARK: - State transitions

    private func setUnavailable(_ reason: Reason) {
        unavailableReason = reason
        iCloudUnavailable = true
        // Do NOT touch `bannerDismissed` — a dismissal stays sticky for the whole
        // episode; it resets only when the account recovers (`clearUnavailable`).
    }

    private func clearUnavailable() {
        iCloudUnavailable = false
        unavailableReason = nil
        // Account healthy again → reset the sticky dismissal so a FUTURE outage
        // re-surfaces the banner exactly once.
        if SettingsManager.iCloudBannerDismissed() {
            SettingsManager.setICloudBannerDismissed(false)
        }
        bannerDismissed = false
    }
}
