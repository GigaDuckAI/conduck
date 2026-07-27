// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferCapabilityRefresher.swift
//
// Agent File Transfer. Silent, UPGRADE-ONLY folder-capability refresh,
// run fire-and-forget once per launch (chained AFTER
// `SettingsManager.performInitialSync`, whose iCloud-KVS pull may have just
// hydrated the flags this reads). It un-sticks a lane whose
// `folderCapable=false` predates a probe-algorithm fix: the flag was written
// false by an older/stricter nested-write probe, the server actually accepts
// folder PUTs, and without this the lane would mint FLAT keys forever (a manual
// Test Connection re-run is otherwise the only re-probe).
//
// What it NEVER does:
//   - degrade capability — it never writes `folderCapable=false`; flat is the
//     staged Test Connection's exclusive verdict, and the flag is already false
//     whenever this probes (upgrade-only),
//   - flip `available` — readiness is earned ONLY by the staged test,
//   - probe an un-trust-gated (un-`available`) OR un-locally-tested server — a
//     synced-only peer that never ran a Test Connection HERE fires no automated
//     writes and raises no unexplained iOS Local-Network prompt at a server it
//     never saw.
//
// Topology limitation (documented + ACCEPTED): the upgrade is armed by
// `testedLocally`, a device-local App-Group flag. A lane whose ORIGINALLY-tested
// device is gone stays flat until SOME device re-runs a Test Connection — which
// both re-arms `testedLocally` and dual-writes any upgrade to peers via KVS.
//
// Privacy: never logs URLs / credentials / keys (no logging at all); the probe
// rides the same cert-pinned ephemeral session as the staged test
// (`FileServerClient.probeFolderCapability`).

import Foundation

enum FileTransferCapabilityRefresher {

    /// In-process single-flight latch. Concurrent launch calls (e.g. an app
    /// `init` plus a re-entrant scene event) collapse to one sweep.
    private actor Gate {
        private var isRunning = false
        /// Acquire the gate. Returns true iff the caller may run (it was idle);
        /// false if a sweep is already in flight.
        func tryEnter() -> Bool {
            if isRunning { return false }
            isRunning = true
            return true
        }
        func leave() { isRunning = false }
    }

    private static let gate = Gate()

    /// Sweep every configured gateway and upgrade any stuck-flat, locally-tested,
    /// trust-gated lane to folder-capable. Fire-and-forget from launch wiring.
    static func refreshIfNeeded(now: Date = Date()) async {
        // Unit-test hosts must not fire real network probes from launch wiring;
        // the decision logic is exercised directly via `isProbeDue`. Matches the
        // launch-service idiom already used by `VoicePermissions` /
        // `NotificationPermissions`.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Single-flight: a second concurrent launch call no-ops. `leave()` runs
        // after `sweep` (which cannot throw and has no early return past this
        // point), so the gate never latches shut.
        guard await gate.tryEnter() else { return }
        await sweep(now: now)
        await gate.leave()
    }

    /// The per-ref sweep body. Split from `refreshIfNeeded` so the single-flight
    /// acquire/release brackets it cleanly.
    private static func sweep(now: Date) async {
        let refs = await SettingsManager.shared.configuredRemoteAgentRefs()
        for ref in refs {
            // Never probe an un-trust-gated / unready server: the ready-snapshot
            // is nil unless URL + credential are present AND `available`.
            guard let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) else { continue }

            let testedLocally = await SettingsManager.shared.getFileServerTestedLocally(for: ref)
            let recordedRevision = await SettingsManager.shared.getFolderProbeRevision(for: ref)
            let lastAttempt = await SettingsManager.shared.getFolderProbeAttempt(for: ref)
            guard isProbeDue(
                folderCapable: snapshot.folderCapable,
                testedLocally: testedLocally,
                recordedRevision: recordedRevision,
                currentRevision: Constants.fileServerFolderProbeRevision,
                lastAttempt: lastAttempt,
                backoff: Constants.fileServerFolderProbeBackoff,
                now: now
            ) else { continue }

            // Record the attempt FIRST — an offline server then costs at most one
            // probe per backoff window, not one per launch, regardless of outcome.
            await SettingsManager.shared.setFolderProbeAttempt(now, for: ref)

            let outcome = await FileServerClient.probeFolderCapability(snapshot: snapshot)

            // Apply-guard: a config edited mid-probe must drop the stale result
            // (same guard DiagnosticsRunner runs at dispatch/apply). Re-fetch
            // and require the lane's IDENTITY (url + credential + pin) unchanged
            // — `FileTransferSnapshot.identitySignature`, the shared single
            // definition of what counts as an identity change.
            guard let after = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
                  after.identitySignature == snapshot.identitySignature else { continue }

            switch outcome {
            case .capable:
                // Definitive upgrade: dual-writes `folderCapable=true` to peers via
                // KVS and parks the probe at the current revision.
                await SettingsManager.shared.setFileServerFolderCapable(true, for: ref)
                await SettingsManager.shared.setFolderProbeRevision(Constants.fileServerFolderProbeRevision, for: ref)
            case .rejected:
                // Definitive flat verdict — park the probe until the next algorithm
                // revision bump. Never writes `folderCapable` (already false).
                await SettingsManager.shared.setFolderProbeRevision(Constants.fileServerFolderProbeRevision, for: ref)
            case .indeterminate:
                // Transient (offline / ambiguous) — the backoff timestamp recorded
                // above gates the retry; no definitive revision is stamped.
                break
            }
        }
    }

    /// Pure decision: is a silent folder re-probe DUE for a lane? UPGRADE-ONLY.
    /// True iff ALL hold:
    ///   - `folderCapable == false` — true is already the ceiling, nothing to
    ///     upgrade (and this refresh never degrades),
    ///   - `testedLocally` — only a device that itself passed a staged Test
    ///     Connection may fire automated writes / a Local-Network prompt at this
    ///     server; the stuck device is by definition one that tested locally, and
    ///     its upgrade dual-writes to synced-only peers,
    ///   - `recordedRevision != currentRevision` — a DEFINITIVE prior outcome
    ///     (capable or rejected) parks the probe until the algorithm revision
    ///     bumps; a bump re-arms it,
    ///   - `lastAttempt == nil || now - lastAttempt >= backoff` — an offline
    ///     server costs at most one probe per backoff window, not one per launch.
    static func isProbeDue(
        folderCapable: Bool,
        testedLocally: Bool,
        recordedRevision: Int?,
        currentRevision: Int,
        lastAttempt: Date?,
        backoff: TimeInterval,
        now: Date
    ) -> Bool {
        guard !folderCapable else { return false }
        guard testedLocally else { return false }
        guard recordedRevision != currentRevision else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < backoff { return false }
        return true
    }

}
