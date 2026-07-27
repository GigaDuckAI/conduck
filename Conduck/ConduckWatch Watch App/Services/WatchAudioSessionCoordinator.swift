// SPDX-License-Identifier: Apache-2.0

//
//  WatchAudioSessionCoordinator.swift
//  ConduckWatch Watch App
//
//  Record⇄playback ownership + config serialization for the ONE shared
//  `AVAudioSession`. Three parties reconfigure the session — `WatchRecordingService`
//  (`.record` at capture arm + interruption resume), the service-owned
//  `WatchReplySpeaker`, and the thread view's `ThreadSpeaker` engine (both
//  `.playback` at speak) — and every one of those calls is audio-server IPC
//  that can take hundreds of milliseconds (seconds when the daemon is
//  distressed). Off-main IPC for a turn that dies mid-flight must never land
//  on top of a NEWER turn's session config, and nothing may deactivate the
//  session without proof it still owns it.
//
//  Contract:
//  - `claim(_:)` supersedes any live claim (monotonic token — the old claim
//    goes stale, its later `release` is a no-op) and cancels a pending
//    deferred deactivation, so a claimant never races a scheduled teardown.
//  - `runConfig(for:_:)` is the ONLY sanctioned way to issue session-config
//    IPC (setCategory/setActive). Ops run strictly FIFO on a single chain,
//    and the claim is re-checked at ISSUE time — after the queue drains — so
//    a superseded turn's still-pending config is skipped, never issued. The
//    IPC itself runs `@concurrent` off-main. A dead turn's op that already
//    issued is harmless: the live claimant's own config is FIFO-ordered
//    after it and establishes the final state.
//  - `releaseAndDeactivate(_:)` is the ONLY session-deactivation path on the
//    watch: stale claims are ignored; a live release schedules
//    `setActive(false, .notifyOthersOnDeactivation)` after a short grace
//    (immediate re-claim — reply auto-speak after capture, tap-to-speak the
//    next bubble — cancels it, avoiding deactivate→reactivate IPC churn).
//    The deactivation rides the SAME FIFO chain with an unclaimed re-check
//    at issue time, so it cannot interleave with, or land after, a new
//    claimant's config.
//  - `release(_:)` (plain) drops ownership WITHOUT deactivating — the
//    recorder's posture once its `.record` config actually committed: the
//    session staying active is deliberate, the next speak re-categorizes it.
//
//  Out-of-band: the speaker's `activate(options:completionHandler:)` (the
//  watchOS async playback-activation API) does not ride the chain — its
//  request is issued to the daemon after the speaker's chained `setCategory`
//  returns, so per-connection ordering keeps it behind any prior turn's ops.
//
//  `deactivate` is injectable so unit tests can observe scheduling semantics
//  without an audio server.
//

import AVFoundation

@MainActor
final class WatchAudioSessionCoordinator {
    static let shared = WatchAudioSessionCoordinator()

    enum Owner: Equatable, Sendable {
        case recording
        case playback
    }

    /// Value handle for one ownership tenure. Compared by token — two claims
    /// by the same owner kind are still distinct tenures.
    struct Claim: Equatable, Sendable {
        let owner: Owner
        let token: Int
    }

    private(set) var current: Claim?
    private var nextToken = 1
    private var deactivation: Task<Void, Never>?
    /// Tail of the FIFO config chain. Every `runConfig`/deactivation op awaits
    /// the previous tail before its issue-time ownership check, so two config
    /// IPCs can never interleave and a stale op can never land last.
    private var configChain: Task<Void, Never>?

    /// Grace before a released session is actually deactivated; an incoming
    /// claim inside the window cancels it. Injectable for tests.
    let deactivationGrace: Duration
    /// The actual audio-server deactivation call — `@concurrent` off-main in
    /// production.
    let deactivate: @Sendable () async -> Void

    init(
        deactivationGrace: Duration = .milliseconds(200),
        deactivate: @escaping @Sendable () async -> Void = { await WatchAudioSessionCoordinator.deactivateSharedSession() }
    ) {
        self.deactivationGrace = deactivationGrace
        self.deactivate = deactivate
    }

    /// Take ownership for `owner`, superseding any live claim and cancelling
    /// a pending deferred deactivation.
    @discardableResult
    func claim(_ owner: Owner) -> Claim {
        deactivation?.cancel()
        deactivation = nil
        let claim = Claim(owner: owner, token: nextToken)
        nextToken += 1
        current = claim
        return claim
    }

    /// Drop ownership without touching the session. Returns `true` iff
    /// `claim` was still live. Stale (superseded) claims change nothing.
    @discardableResult
    func release(_ claim: Claim) -> Bool {
        guard current == claim else { return false }
        current = nil
        return true
    }

    /// Issue session-config IPC (`setCategory`/`setActive`) on behalf of
    /// `claim`. FIFO behind every previously scheduled op; returns `false`
    /// WITHOUT running `work` when the claim is stale at issue time (the turn
    /// was superseded while queued — its config must not land on the new
    /// owner's session). Rethrows `work`'s error. The IPC runs off-main.
    func runConfig(
        for claim: Claim,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let prior = configChain
        let op = Task { () throws -> Bool in
            await prior?.value
            guard self.current == claim else { return false }
            try await Self.issueOffMain(work)
            return true
        }
        configChain = Task { _ = try? await op.value }
        return try await op.value
    }

    /// Drop ownership and — iff the claim was still live — schedule the
    /// session deactivation after `deactivationGrace`. The deactivation rides
    /// the FIFO chain and re-checks that the session is still unclaimed at
    /// issue time, so a claim landing at ANY point before issue aborts it.
    func releaseAndDeactivate(_ claim: Claim) {
        guard release(claim) else { return }
        deactivation?.cancel()
        deactivation = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.deactivationGrace)
            guard !Task.isCancelled, self.current == nil else { return }
            let prior = self.configChain
            let op = Task { () -> Void in
                await prior?.value
                guard self.current == nil else { return }
                await self.deactivate()
            }
            self.configChain = op
            await op.value
        }
    }

    var isClaimed: Bool { current != nil }

    /// Hop the caller-supplied config work onto the concurrent pool — the
    /// audio-server IPC must never run on (or block) the main actor.
    @concurrent
    private nonisolated static func issueOffMain(
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await work()
    }

    /// `setActive(false)` restores anything the `.duckOthers` playback
    /// category ducked (the user's podcast/music resumes full volume).
    /// Errors are non-actionable at a terminal — swallowed by design.
    @concurrent
    private nonisolated static func deactivateSharedSession() async {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
