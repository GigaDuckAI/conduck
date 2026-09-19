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
//      Quota evidence is per store and ordered by event completion, for live
//      delivery AND catch-up. Only a newer successful export from the affected
//      store proves recovery; a signed-in account or successful import does not.
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

/// Small deterministic reducer shared by live events and persisted event
/// history. Keeping successful exports as well as failures makes replay order
/// irrelevant and prevents an older failure from resurrecting a cleared banner.
struct CloudSyncHealth {
    private struct StoreEvidence {
        var quotaFailure: Date?
        var successfulExport: Date?

        var isQuotaExceeded: Bool {
            guard let quotaFailure else { return false }
            return successfulExport.map { $0 <= quotaFailure } ?? true
        }
    }

    private var stores: [String: StoreEvidence] = [:]
    private var accountReason: CloudSyncMonitor.Reason?
    private(set) var ignoreEventsBefore: Date?

    init(ignoreEventsBefore: Date? = nil) {
        self.ignoreEventsBefore = ignoreEventsBefore
    }

    var reason: CloudSyncMonitor.Reason? {
        accountReason ?? (stores.values.contains(where: \.isQuotaExceeded) ? .quotaExceeded : nil)
    }

    private mutating func resetAfterSignOut(at date: Date) {
        stores.removeAll()
        accountReason = nil
        ignoreEventsBefore = max(ignoreEventsBefore ?? .distantPast, date)
    }

    mutating func applyAccountStatus(_ status: CKAccountStatus, at date: Date) {
        switch status {
        case .noAccount:
            if accountReason != .noAccount { resetAfterSignOut(at: date) }
            accountReason = .noAccount
        case .restricted: accountReason = .restricted
        case .available: accountReason = nil
        case .couldNotDetermine, .temporarilyUnavailable: break
        @unknown default: break
        }
    }

    mutating func ingest(_ summary: SyncEventSummary) {
        guard accountReason != .noAccount,
              let ended = summary.ended,
              let storeID = summary.storeID else { return }
        if let cutoff = ignoreEventsBefore, (summary.started ?? ended) <= cutoff { return }
        let quotaFailure = !summary.succeeded && summary.isQuotaExceeded
        let successfulExport = summary.succeeded && summary.kind == .exportEvent
        guard quotaFailure || successfulExport else { return }
        var evidence = stores[storeID] ?? StoreEvidence()
        if quotaFailure { evidence.quotaFailure = max(evidence.quotaFailure ?? .distantPast, ended) }
        if successfulExport { evidence.successfulExport = max(evidence.successfulExport ?? .distantPast, ended) }
        stores[storeID] = evidence
    }
}

@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    /// The one user-actionable reason iCloud sync is broken. Mapped only from
    /// states the user can resolve; transient/network states never set it.
    enum Reason: Equatable, Sendable {
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
                    "sync.icloud.settings.content.noAccount",
                    defaultValue: "Sign in to iCloud in Settings to sync conversations, Work and files across your devices."
                )
            case .restricted:
                return LocalizedStringResource(
                    "sync.icloud.settings.content.restricted",
                    defaultValue: "iCloud is restricted on this device, so conversations, Work and files can't sync."
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
    var showsBanner: Bool { contentSyncEnabled && iCloudUnavailable && !bannerDismissed }

    /// Intentional OFF suppresses account warnings, while account health remains
    /// available to Settings when the person turns content sync back on.
    private(set) var contentSyncEnabled = (try? ContentSyncPreferenceStore.shared.readEnabled()) ?? true
    private var preferenceObservers: [NSObjectProtocol] = []

    private let log = Logger(subsystem: Constants.identityNamespace, category: "CloudSync")
    private static let ringBufferKey = "cloudSyncEventLog"
    /// Device-local, content-free boundary: events from a signed-out account
    /// must not reappear after a later catch-up or app restart. No account ID is
    /// fetched or stored. Only confirmed sign-out resets this boundary: account
    /// notifications can also mean temporary unavailability. An account replaced
    /// without an observed sign-out conservatively retains quota evidence until
    /// newer successful exports prove recovery.
    private static let accountCutoffKey = "cloudSyncAccountEventCutoff"
    private let ringBufferCap = 50
    private var health = CloudSyncHealth(
        ignoreEventsBefore: SettingsDependencies.processDefault.defaults.object(forKey: CloudSyncMonitor.accountCutoffKey) as? Date
    )
    private var healthGeneration = 0
    private var accountRefreshGeneration = 0
    private var hasCaughtUp = false

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
        refreshContentSyncPreference()
        for name in [Notification.Name.contentSyncPreferenceDidChange, .contentSyncStateDidChange] {
            preferenceObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshContentSyncPreference() }
            })
        }
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

        // The notification also covers temporary account-status changes. It
        // invalidates in-flight lookups, but is not proof of sign-out and must
        // not discard quota evidence from a still-signed-in account.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accountStatusDidChange()
                await self.refresh()
            }
        }

        Task { await refresh() }
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

    private func refreshContentSyncPreference() {
        // Lock uncertainty is not a deliberate OFF; keep the last good value
        // and retry when the runtime announces policy recovery.
        if let enabled = try? ContentSyncPreferenceStore.shared.readEnabled() {
            contentSyncEnabled = enabled
        }
    }

    private func refreshAccountStatus() async {
        // THE construction point, and therefore where the invariant belongs:
        // `CKContainer(identifier:)` raises on an unentitled process, so no
        // caller — present or future — may reach it without this check. `start()`
        // additionally declines to wire the observers that would call this.
        guard Constants.hasICloudContainerEntitlement else { return }
        accountRefreshGeneration += 1
        let generation = accountRefreshGeneration
        let container = CKContainer(identifier: Constants.iCloudCloudKitContainerID)
        do {
            let status = try await container.accountStatus()
            guard generation == accountRefreshGeneration else { return }
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
        let previousCutoff = health.ignoreEventsBefore
        health.applyAccountStatus(status, at: Date())
        if previousCutoff != health.ignoreEventsBefore {
            healthGeneration += 1
            persistAccountCutoff()
        }
        publishHealth(allowClear: hasCaughtUp || iCloudUnavailable)
        if status == .couldNotDetermine || status == .temporarilyUnavailable {
            // Transient (couldNotDetermine / temporarilyUnavailable) — log only.
            log.notice("iCloud account status transient: \(status.rawValue, privacy: .public)")
        }
    }

    private func accountStatusDidChange() {
        healthGeneration += 1
        accountRefreshGeneration += 1
    }

    private func persistAccountCutoff() {
        SettingsDependencies.processDefault.defaults.set(health.ignoreEventsBefore, forKey: Self.accountCutoffKey)
    }

    private func publishHealth(allowClear: Bool = true) {
        if let reason = health.reason { setUnavailable(reason) }
        else if allowClear { clearUnavailable() }
    }

    // MARK: - Event telemetry

    private func ingest(_ summary: SyncEventSummary) {
        record(summary)
        health.ingest(summary)
        publishHealth(allowClear: hasCaughtUp || iCloudUnavailable)
    }

    /// Pull events that fired while the app was suspended (the live observer
    /// misses those). Read all retained evidence: a stream of later imports must
    /// not push an unresolved quota failure outside a fixed diagnostics window.
    /// Reduce before publishing, so a failure followed by recovery never flashes.
    private func catchUpOnEvents() async {
        let generation = healthGeneration
        guard let summaries = await ConversationStore.shared.recentSyncEventSummaries(limit: .max) else { return }
        guard generation == healthGeneration else { return }
        for summary in summaries { health.ingest(summary) }
        for summary in summaries.suffix(20) { record(summary, replayed: true) }
        hasCaughtUp = true
        publishHealth()
    }

    /// `replayed` marks a summary re-read from the store's event history
    /// (launch / every foreground) rather than delivered live. The tag is what
    /// keeps a field log honest: the catch-up re-prints the last N events on
    /// every activation, and untagged it reads as N fresh setups/imports.
    private func record(_ summary: SyncEventSummary, replayed: Bool = false) {
        let prefix = replayed ? "sync[replay]" : "sync"
        if summary.succeeded {
            log.debug("\(prefix, privacy: .public) \(summary.redactedLine, privacy: .public)")
        } else {
            log.error("\(prefix, privacy: .public) \(summary.redactedLine, privacy: .public)")
        }
        // The ring buffer keeps taking replays: it is how events that fired
        // while the app was suspended (the live observer misses those) reach
        // the diagnostics screen at all. Duplicates there are the known cost.
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
