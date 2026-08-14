// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferCapabilityRefresher.swift
//
// Agent File Transfer. Silent, UPGRADE-ONLY capability refresh, run
// fire-and-forget once per launch (chained AFTER
// `SettingsManager.performInitialSync`, whose iCloud-KVS pull may have just
// hydrated the flags this reads).
//
// TWO INDEPENDENT PROBES, one per capability, because a lane can be narrowed on
// either axis alone and each has its own reason to be re-asked:
//
//   - FOLDER capability (`folderCapable`, the server's willingness to accept a
//     PUT into a folder it must create). It un-sticks a lane whose
//     `folderCapable=false` predates a probe-algorithm fix: the flag was written
//     false by an older/stricter nested-write probe, the server actually accepts
//     folder PUTs, and without this the lane would mint FLAT keys forever.
//   - RETURN capability (`returnCapable`, the server's willingness to answer
//     `PROPFIND` at all). It un-sticks a lane whose owner REPAIRED their server
//     — enabled the DAV ext module, dropped the `dav_methods` restriction — and
//     that is the difference in cadence between the two: a stale folder verdict
//     is a bug the app shipped, so it is re-asked once per algorithm revision,
//     while a stale return verdict is a change the USER made and can make on any
//     day, so it is re-asked every launch.
//
// WHY THE RETURN PROBE NEEDS NO BACKOFF WINDOW AND THE FOLDER PROBE DOES: the
// folder probe WRITES (a nested PUT, read back, deleted), so the
// `Constants.fileServerFolderProbeBackoff` floor keeps an automated write off a
// stranger's server; the return probe is two `Depth: 0`
// `PROPFIND`s that mutate nothing and read no body. Once per process is
// therefore the whole bound it needs, and it is what makes the durable
// `returnCapable` flag safe to use as `BackgroundFileTransfer.mintOutboxKey`'s
// gate: the dispatch path pays nothing per turn, and a repaired server is
// noticed at the next launch instead of never. The user's own faster route is
// the "Test again" button on the File transfer page, which the amber
// "Uploads only" status sits directly above.
//
// What it NEVER does:
//   - degrade capability — it never writes `folderCapable=false` and never
//     writes `returnCapable=false`; a narrowing is the staged Test Connection's
//     exclusive verdict, and the flag is already false whenever this probes
//     (upgrade-only),
//   - flip `available` — readiness is earned ONLY by the staged test,
//   - probe an un-trust-gated (un-`available`) server, or one THIS device has
//     not itself staged-tested at its current identity — a synced-only peer
//     that never ran a Test Connection HERE, and a device whose slot was
//     repointed at a stranger's server since its last one, both fire no
//     automated writes and raise no unexplained iOS Local-Network prompt at a
//     server they never saw.
//
// WHAT THE RETURN PROBE DOES NOT PROMISE, stated because the doc comments it
// backs would otherwise over-claim. It is fire-and-forget from launch wiring, so
// a very fast first turn (a cold-launch Shortcut) can dispatch before it
// answers, and a Mac app left running across the repair sees nothing until it is
// next started. The honest contract is "automatically at the next launch, and at
// once on Test again" — never "the moment `PROPFIND` is enabled".
//
// Topology limitation (documented + ACCEPTED), and it covers both probes: the
// upgrade is armed by device-local proof, held in App-Group storage. A lane
// whose ORIGINALLY-tested device is gone stays narrowed until SOME device
// re-runs a Test Connection — which both re-earns the proof and dual-writes any
// upgrade to peers via KVS. A device that only ever received the verdict through
// iCloud is a device that has never seen the server, and firing probes from it
// is exactly what the arming rule exists to prevent.
//
// THE ARMING RULE, and it is per-SERVER rather than per-slot: both probes gate
// on `SettingsManager.isFileServerLocallyProven(_:for:)`, which answers true
// only when the `testedLocally` flag is set AND the stored identity stamp equals
// the stamp of the lane in hand. The stamp is
// `FileTransferSnapshot.localProofStamp` — the durable lane (URL + credential)
// folded together with this device's certificate pin, hashed, and written beside
// the flag at the moment a staged test passes.
//
// The bare flag is keyed by gateway SLOT and so records only that this device
// tested this slot; three things move the server under it and each one voids the
// proof through that comparison: a peer repointing the URL, a rotated
// credential, and a changed pin. All three reach this device the same way — the
// URL and credential sync in through `handleICloudChange`, which grants no local
// proof — and the stamp is what makes the arriving lane stop matching, so no
// probe fires at a host this device has never opened a connection to. That
// matters most for the folder probe, which WRITES (a nested PUT) and can raise
// an unexplained iOS Local-Network prompt.
//
// A MISSING STAMP IS UNPROVEN, never grandfathered, and it is never back-filled
// on read: back-filling would stamp whichever server occupies the slot at that
// moment, which is the unproven server the rule exists to keep probes away from.
// So a proof that predates the stamp — the one-time migration seed's, which
// reconstructs a bare boolean and can recover no identity from it — arms
// nothing, and the whole cost is one Test Connection to re-arm the silent
// upgrades. `identitySignature` cannot serve here even though it covers the same
// three fields: its `Hasher` seed is process-random, so a value written on one
// launch never compares equal on the next. It stays the right tool for the
// apply-guards below, where both operands are minted in the same process.
//
// Privacy: never logs URLs / credentials / keys (no logging at all); both probes
// ride the same cert-pinned ephemeral session as the staged test
// (`FileServerClient.probeFolderCapability` / `probeListingCapability`).

import Foundation

enum FileTransferCapabilityRefresher {

    /// In-process single-flight latch. Concurrent launch calls (e.g. an app
    /// `init` plus a re-entrant scene event) collapse to one sweep.
    ///
    /// It also holds the return probe's ONCE-PER-PROCESS ledger, because that
    /// probe has no persisted bookkeeping to fall back on. The single-flight
    /// latch alone is not enough: it only collapses calls that OVERLAP, and the
    /// two launch call sites (`AppDelegate`, `ConduckApp`) can easily land one
    /// after the other has finished.
    private actor Gate {
        private var isRunning = false
        /// Refs whose return capability has already been re-probed in this
        /// process. Keyed by `RemoteAgentRef.rawString` — a ref repointed at a
        /// new server has its stored verdict reset to unknown by the commit, so
        /// it is not narrowed and not due, and needs no second key.
        private var returnProbed: Set<String> = []

        /// Acquire the gate. Returns true iff the caller may run (it was idle);
        /// false if a sweep is already in flight.
        func tryEnter() -> Bool {
            if isRunning { return false }
            isRunning = true
            return true
        }
        func leave() { isRunning = false }

        /// Claim this process's one return probe for `ref`. True iff the caller
        /// owns it; false if it has already been spent.
        ///
        /// No way to give it back, and no test seam to clear it: `refreshIfNeeded`
        /// refuses to run inside a test host at all, so a resettable ledger would
        /// be a production affordance with no production caller.
        func claimReturnProbe(_ ref: String) -> Bool {
            returnProbed.insert(ref).inserted
        }
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
    ///
    /// The two probes are separate calls, each re-reading the lane and deciding
    /// its own due-ness, because the two capabilities are independent: a lane can
    /// be folder-capable and return-incapable, or the reverse, and a shared early
    /// exit would silently make one axis's verdict park the other's re-probe.
    private static func sweep(now: Date) async {
        let refs = await SettingsManager.shared.configuredRemoteAgentRefs()
        for ref in refs {
            await refreshFolderCapability(for: ref, now: now)
            await refreshReturnCapability(for: ref)
        }
    }

    /// The nested-PUT re-probe. Upgrade-only, parked by algorithm revision, and
    /// floored by `Constants.fileServerFolderProbeBackoff` because it WRITES to
    /// the user's server.
    private static func refreshFolderCapability(for ref: RemoteAgentRef, now: Date) async {
        // Never probe an un-trust-gated / unready server: the ready-snapshot
        // is nil unless URL + credential are present AND `available`.
        guard let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) else { return }

        // IDENTITY-CHECKED proof, never the bare `getFileServerTestedLocally`
        // flag: this probe WRITES to the server the snapshot names, so what has
        // to be true is that THIS device tested THAT server — not merely this
        // gateway slot, which a peer can repoint at a stranger's host without
        // ever touching the flag.
        let locallyProven = await SettingsManager.shared.isFileServerLocallyProven(snapshot, for: ref)
        let recordedRevision = await SettingsManager.shared.getFolderProbeRevision(for: ref)
        let lastAttempt = await SettingsManager.shared.getFolderProbeAttempt(for: ref)
        guard isProbeDue(
            folderCapable: snapshot.folderCapable,
            locallyProven: locallyProven,
            recordedRevision: recordedRevision,
            currentRevision: Constants.fileServerFolderProbeRevision,
            lastAttempt: lastAttempt,
            backoff: Constants.fileServerFolderProbeBackoff,
            now: now
        ) else { return }

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
              after.identitySignature == snapshot.identitySignature else { return }

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
        case .certificateRefused:
            // The connection was refused, so this probe learned nothing about
            // folders. Handled like `.indeterminate` — no revision stamped —
            // but it is a separate arm because the reasoning is different:
            // there, a retry may succeed; here it cannot until something
            // outside the app changes, and stamping a definitive revision
            // would park the lane flat forever on the strength of a
            // certificate problem. This sweep is SILENT and has no surface to
            // report a refusal on; the user meets it on the next Test
            // Connection, which does say so.
            break
        }
    }

    /// The `PROPFIND` re-probe — the self-heal for a lane whose owner repaired
    /// their file server. Upgrade-only, once per process, no persisted
    /// bookkeeping: it reads two statuses and writes nothing to the server, so
    /// the launch itself is the only rate limit it needs.
    ///
    /// It is what keeps `mintOutboxKey`'s durable gate honest. That gate reads
    /// `returnCapable` before it spends anything, which is what stops the large
    /// plain-`nginx` population from paying a `PROPFIND` on the critical path of
    /// every turn — but a gate with no widener would leave a repaired server
    /// suppressed until the user thought to re-run a Test Connection. This is the
    /// widener, and the user's faster route is the "Test again" button that sits
    /// under the amber "Uploads only" status on the File transfer page.
    private static func refreshReturnCapability(for ref: RemoteAgentRef) async {
        guard let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) else { return }
        // Same identity-checked proof the folder probe arms on, for the weaker
        // but still binding half of the reason: this request writes nothing, but
        // it is still an unannounced connection, and a device that has not
        // tested THIS server has no business opening one at it.
        let locallyProven = await SettingsManager.shared.isFileServerLocallyProven(snapshot, for: ref)
        guard isReturnProbeDue(returnCapable: snapshot.returnCapable, locallyProven: locallyProven) else { return }
        // Claim the process's one probe LAST, after the cheap reads have shown
        // the lane is actually due — otherwise a lane that is not narrowed at all
        // would spend the claim and a later narrowing in the same process could
        // not be re-widened until the next launch.
        guard await gate.claimReturnProbe(ref.rawString) else { return }

        let outcome = await FileServerClient.probeListingCapability(snapshot: snapshot)

        // Same apply-guard as the folder probe, for the same reason: a lane
        // repointed mid-probe must not inherit the old server's answer.
        guard let after = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
              after.identitySignature == snapshot.identitySignature else { return }

        switch outcome {
        case .capable:
            // The ONE write this probe may make. It dual-writes to iCloud KVS, so
            // the badge, the Watch envelope and the peers' own dispatch gates all
            // widen from this single measurement.
            await SettingsManager.shared.setFileServerReturnCapable(true, for: ref)
            // And the in-process cache of the same verdict, which `mintOutboxKey`
            // consults immediately after the durable flag. A staged test earlier
            // in this process may have seeded `.cannotReturn` there; leaving it
            // would let the breaker keep refusing a lane the durable flag has
            // just widened, and the user would see the repair take effect only
            // after the NEXT launch.
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.noteStagedVerdict(
                lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: after),
                returnCapable: true)
        case .methodUnavailable, .unverified, .certificateRefused:
            // Nothing to do on any of the three, and they are collapsed
            // deliberately: the stored verdict is ALREADY `false` (that is why
            // this probe ran), so confirming it writes nothing, and neither a
            // probe that proved nothing nor a refused certificate may widen it.
            // The claim above is what stops any of them being re-asked this
            // process; the next launch asks again, because a server the user
            // repairs tomorrow is the case this whole probe exists for.
            break
        }
    }

    /// Pure decision: is a silent folder re-probe DUE for a lane? UPGRADE-ONLY.
    /// True iff ALL hold:
    ///   - `folderCapable == false` — true is already the ceiling, nothing to
    ///     upgrade (and this refresh never degrades),
    ///   - `locallyProven` — only a device that itself passed a staged Test
    ///     Connection AGAINST THE SERVER NOW IN THE SLOT may fire automated
    ///     writes / a Local-Network prompt at it; the stuck device is by
    ///     definition one that tested that server, and its upgrade dual-writes
    ///     to synced-only peers. Callers pass
    ///     `SettingsManager.isFileServerLocallyProven(_:for:)` and never the
    ///     bare `testedLocally` flag, which is keyed by SLOT and survives a peer
    ///     repointing that slot at a host this device has never seen,
    ///   - `recordedRevision != currentRevision` — a DEFINITIVE prior outcome
    ///     (capable or rejected) parks the probe until the algorithm revision
    ///     bumps; a bump re-arms it,
    ///   - `lastAttempt == nil || now - lastAttempt >= backoff` — an offline
    ///     server costs at most one probe per backoff window, not one per launch.
    static func isProbeDue(
        folderCapable: Bool,
        locallyProven: Bool,
        recordedRevision: Int?,
        currentRevision: Int,
        lastAttempt: Date?,
        backoff: TimeInterval,
        now: Date
    ) -> Bool {
        guard !folderCapable else { return false }
        guard locallyProven else { return false }
        guard recordedRevision != currentRevision else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < backoff { return false }
        return true
    }

    /// Pure decision: is a silent return re-probe DUE for a lane? UPGRADE-ONLY.
    /// True iff BOTH hold:
    ///   - `returnCapable == false` — true is already the ceiling, and this
    ///     refresh never narrows (only the staged Test Connection may, from a
    ///     structural refusal on a collection that certainly exists),
    ///   - `locallyProven` — same arming rule the folder probe uses, from the
    ///     same accessor, for the same reason: a device that received this
    ///     verdict over iCloud, or whose slot a peer has since repointed, has
    ///     never seen the server and must not fire an automated request at it.
    ///
    /// NO REVISION AND NO TIME BACKOFF, unlike `isProbeDue`. There is no
    /// algorithm revision to park against because the answer this probe chases
    /// changes when the USER changes their server, not when Conduck changes its
    /// probe; and there is no backoff window because the caller already bounds it
    /// to once per process and the request writes nothing. Adding either would
    /// re-create the defect this probe exists to fix — a repaired server that the
    /// app goes on treating as broken.
    static func isReturnProbeDue(returnCapable: Bool, locallyProven: Bool) -> Bool {
        guard !returnCapable else { return false }
        guard locallyProven else { return false }
        return true
    }

}
