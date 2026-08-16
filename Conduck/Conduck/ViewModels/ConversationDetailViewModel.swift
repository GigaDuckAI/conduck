// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModel.swift
//
// Observable view model backing a single conversation THREAD (the chat-bubble
// scroll — iOS home / Watch detail). Split 1→2 with
// `ConversationListViewModel`.
//
// Handles load + append + the deinit-safe `.conversationsDidChange`
// observer, plus the DEVICE-LOCAL in-flight state machine: optimistic user
// bubble, a "thinking" elapsed timer driving the staged copy, and a Cancel
// affordance that cancels the underlying `URLSessionTask`. That state is never
// persisted, and it answers a question the durable `Message.status` cannot: a
// stored `sending` row may have been written by another device and mirrored
// here via CloudKit, so it is no proof that anything is running HERE.
//
// The wait indicator and Stop are therefore DERIVED — from this VM's own stamp
// OR from `InFlightTurnRegistry`, which every dispatch lane on this device
// claims. That is what makes them survive the view model being discarded and
// re-minted by a navigation pop (`ContentView.syncDetailVM()` mints a fresh VM
// on every conversation switch), while the bubble row stays a plain snapshot of
// the store.

import Foundation
import SwiftUI

/// Whether a user turn was spoken (voice) or typed (text). Suffixed onto the
/// `Message.sourceDevice` tag (e.g. `iphone-text`) so the bubble footer can
/// render a subtle modality glyph alongside the device. Default `.voice`
/// preserves the historical (pre-text-composer) behaviour.
enum TurnModality: String {
    case voice
    case text
}

/// A raw, not-yet-processed attachment the composer staged for a turn. The VM
/// owns the heavy lifting (image downsize / text extraction) so the UI layer
/// only collects sources. `.image` carries the original picked bytes (HEIC /
/// ProRAW / …); `.textFile` carries a security-scoped URL the VM extracts +
/// stops accessing. Order in the array is the render / wire order.
///
/// iOS/macOS only — the Watch never stages attachments (no image pipeline on
/// the wrist; the VM itself is not in the Watch compile set).
enum PendingAttachment: Sendable {
    /// Original picked image bytes (library / camera / paste / drop). The
    /// INLINE-ONLY image route — the bound gateway has no file-server, so the VM
    /// processes these via `ImageProcessor` at send time and they ride the wire
    /// as base64 vision only.
    case image(Data)
    /// A DUAL-route image (inline vision + an editable file-server copy). The
    /// host already processed the image ONCE at staging (the bound gateway has a
    /// file-server) and eagerly uploaded the ORIGINAL RAW bytes (true format,
    /// metadata intact) — NOT the processed JPEG — so the agent's tools act on
    /// the real file. The VM does NOT re-run `ImageProcessor`: it builds the
    /// inline data-URI directly from `processedJPEG` (the downsized vision copy),
    /// persists a PLAIN inline image draft (NOT a server reference — the file-ref
    /// is this-turn-only), and — when `storedKey` is non-nil (the eager upload
    /// landed) — splices a one-turn "saved as <filename>" image ref into the
    /// outgoing turn. `storedKey == nil` → inline-only (upload not ready /
    /// failed), Send never gated on it. `filename` is the name the user's own
    /// source carried, or the numbered `image…` name with the sniffed extension
    /// that `ComposerImageName` supplies when the source has none — so the wire
    /// splice names the uploaded file the way the user would. NOTE (intentional
    /// asymmetry): vision
    /// reads `processedJPEG` while the uploaded file is the original — they are
    /// the same picture, different bytes.
    case dualImage(processedJPEG: Data, thumbnail: Data, width: Int, height: Int, byteSize: Int, storedKey: String?, filename: String)
    /// A security-scoped file URL for a text/code file. The INLINE-ONLY text
    /// route — the bound gateway has no file-server, so the VM extracts the text
    /// at send time via `TextFileExtractor` and it rides the wire as a fenced
    /// block (today's behavior).
    case textFile(URL)
    /// A DUAL-route text/code file (inline fenced text + an editable file-server
    /// copy). The host already extracted the text ONCE at staging (the bound
    /// gateway has a file-server) and eagerly uploaded the ORIGINAL raw file bytes
    /// (byte-faithful, the agent's tools act on the real file). The VM does NOT
    /// re-extract: it builds the inline fenced block from `extractedText`,
    /// persists an INLINE text draft that ALSO carries the upload `storedKey`
    /// (`isServerReference` STAYS false — `isText && storedKey != nil`, so it
    /// still renders/splices as inline text, never a download chip), and — when
    /// `storedKey` is non-nil (the eager upload landed) — splices a one-turn
    /// "also on disk at <storedKey>" reference into the outgoing turn. `storedKey
    /// == nil` → inline-only (upload not ready / failed), Send never gated on it.
    /// `url` is retained only so a later Retry can re-upload from source;
    /// `filename` is the chip + fence + wire-ref display name; `mimeType` is the
    /// UTType-derived text type.
    case dualText(url: URL, extractedText: String, filename: String, mimeType: String, storedKey: String?)
    /// An ALREADY-UPLOADED arbitrary file (file-transfer route). By the time a
    /// `.serverFile` reaches `sendUserTurn` its bytes are already on the user's
    /// gateway file-server (the host uploaded eagerly on attach), so the VM only
    /// persists a server-reference draft + splices the "saved as <storedKey>"
    /// wire line — it never re-reads `url` for bytes. `url` is retained only so
    /// a later Retry can re-upload from the source; `originalName` drives the
    /// chip label + wire line; `mimeType` is the UTType-derived type;
    /// `storedKey` is the server handle the upload minted.
    case serverFile(url: URL, originalName: String, mimeType: String, storedKey: String)
}
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(macOS)
import UserNotifications
#endif

/// Process-wide ownership of output scans, keyed by message ID. Every path that
/// reads the server on behalf of ONE turn claims it first — the automatic retro
/// pass, "Check again", and the name search — so two of them can never work the
/// same turn at once, including from two windows of one macOS process. It does
/// not pretend Core Data / CloudKit provides a distributed compare-and-set
/// across devices; `reconcileOutputScan`'s transaction-local dedupe covers that.
nonisolated final class OutputScanClaimRegistry: @unchecked Sendable {
    static let shared = OutputScanClaimRegistry()

    private let lock = NSLock()
    private var claimedMessageIDs: Set<UUID> = []

    private init() {}

    @discardableResult
    func claim(_ messageID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedMessageIDs.insert(messageID).inserted
    }

    func release(_ messageID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        claimedMessageIDs.remove(messageID)
    }

    func isClaimed(_ messageID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedMessageIDs.contains(messageID)
    }
}

/// Process-local circuit breaker for the retroactive output scan, keyed on the
/// FILE LANE rather than on a turn or a filename.
///
/// WHAT IT BOUNDS. A lane that cannot be read at all — a refused certificate, a
/// rejected credential, an SSO portal that answers every path with its own HTML,
/// a host that is down, or one that answers a folder which cannot exist and so
/// fails the listing's negative control — makes every listing `.unusable`, so
/// `FileTransferOutputDetector.scanMayClose` never opens and no turn ever
/// closes. The per-turn hold map then hands the same pending turns back for as
/// long as the thread stays open: against the user's own server, on their
/// battery, with nothing on screen to say so.
///
/// IT IS THE PER-LANE HALF OF A PAIR, and the halves bound different things.
/// `retroStallBackoff` widens the cadence of ONE turn that keeps getting
/// nowhere; that alone still lets a thread of twenty pending turns each spend a
/// request before any of the ladders has climbed. This measures the LANE once,
/// and a fault stops the remaining fan-out inside the same pass.
///
/// IT MEASURES; IT DOES NOT INFER, and the listing is what supplies the
/// measurement. A stall no longer has to be diagnosed: `FileServerListingVerdict`
/// separates "the folder is there and holds nothing", "the folder is not there"
/// and "nothing was learned" at the source, so the breaker is consulted ONLY on
/// the third. Counting stalls would silence a healthy lane on the strength of a
/// young turn whose folder is legitimately still empty; reading the verdict
/// cannot.
///
/// WHAT A MEASUREMENT COSTS: nothing. The listing that stalled IS the question a
/// synthetic control used to ask, and a stronger version of it — a `207` is
/// believed only after its own negative control, and a `404` is the server
/// saying no about a real path. So a fault is recorded from the verdict in hand,
/// with no second request, and no second route through the server that might not
/// be the one that failed.
///
/// PROCESS-LOCAL, DELIBERATELY. Nothing is persisted and no schema moves: the
/// drain is per-process, and a relaunch buying one more full pass is the
/// cheapest possible escape for a lane that has since been repaired. The key is
/// `durableLaneID` AND `identitySignature` together, so an edit to the URL, the
/// credential, or the device-local certificate pin lands on a brand-new key with
/// a clean slate — "I just fixed my settings" needs no reset path, because the
/// fixed lane is a different key.
///
/// IT BACKS OFF; IT DOES NOT LATCH SHUT. Most real repairs are invisible to the
/// app: a restarted server, a fixed reverse proxy, a DNS record, an expired
/// session behind a portal all leave the identity key untouched, so a trip only
/// an explicit user action could clear would be a silent trap. A measured fault
/// stops the FAN-OUT immediately, and what replaces it is one listing on a
/// widening cadence (5 → 15 → 30 → 60 minutes) — the request count cut by ~99%
/// while recovery stays bounded at an hour with no user action at all. A tap
/// (`recheckOutputs` / `searchMentionedFiles`) resets it outright, and those are
/// reachable from a context menu on EVERY agent turn, so the affordance exists
/// even for the turns the breaker is currently silencing.
///
/// PRIVACY (see the spec's Privacy & Security section): the lane key is an
/// opaque digest pair, never a URL and never a credential, and nothing in this
/// type is logged, thrown, or persisted.
nonisolated final class FileLaneScanBreaker: @unchecked Sendable {
    static let shared = FileLaneScanBreaker()

    /// What a pass that has just stalled should do about the lane it is
    /// scanning.
    enum Decision: Equatable {
        /// A fresh `404` proves the lane can still say no, so this stall belongs
        /// to the window or the filename. Keep scanning.
        case proceed
        /// The lane is known bad, or another view model is measuring it right
        /// now. Abandon this pass's fan-out and re-ask in `retryAfter` seconds.
        case suppress(retryAfter: TimeInterval)
        /// No usable verdict on hand: the caller owns the measurement and MUST
        /// report back exactly once with `record(_:ticket:)` or `abandon(_:)`.
        case measure(ticket: Ticket)
    }

    /// A single-flight reservation. The generation is what stops a verdict from
    /// a superseded lane state — reset by a user tap, or evicted by the ceiling
    /// — from committing on top of the state that replaced it.
    struct Ticket: Equatable, Sendable {
        let lane: String
        let generation: UInt64
    }

    enum Health: Equatable, Sendable {
        /// The lane answered a key that cannot exist with a clean `404`.
        case healthy
        /// It answered with anything else, which is a fact about the lane.
        case faulted
    }

    /// One lane's health state. Everything is monotonic-clock based: a
    /// user-visible wall-clock correction must not collapse a backoff to zero or
    /// stretch it to a day.
    private struct LaneState {
        var verdict: Health?
        var verdictAt: ContinuousClock.Instant?
        var consecutiveFaults: Int = 0
        var measurementInFlight = false
        var generation: UInt64
    }

    /// How long a HEALTHY verdict may be reused. Short on purpose: its only job
    /// is to collapse a reload storm into one measurement, and a longer window
    /// would keep fanning out at a lane that went down a minute ago.
    private static let healthyVerdictTTL: Duration = .seconds(60)

    /// The widening cadence a faulted lane is re-measured on, indexed by
    /// consecutive faults. The first entry matches `retroStalledRetryInterval`
    /// so one bad sample costs nothing beyond the rate the pending turns were
    /// already being retried at; the last is the steady state for a lane that is
    /// genuinely walled — one request an hour instead of hundreds.
    private static let faultBackoff: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]

    /// Bound on tracked lanes. A wholesale clear is safe here BECAUSE the
    /// breaker parks nothing: every turn a suppressed pass leaves behind carries
    /// its own dated hold, so a cleared breaker only means the next wake fans out
    /// once more and re-measures. Nothing can be stranded by eviction.
    private static let laneCeiling = 32

    private let lock = NSLock()
    private var lanes: [String: LaneState] = [:]
    private var generationCounter: UInt64 = 0

    private init() {}

    /// The identity a breaker entry is keyed on. `durableLaneID` alone would
    /// miss a certificate-pin change, which is device-local and deliberately
    /// excluded from the durable namespace id — and a pin change is one of the
    /// repairs that must reopen a suppressed lane instantly.
    static func laneKey(for snapshot: SettingsManager.FileTransferSnapshot) -> String {
        snapshot.durableLaneID + "\u{1}" + snapshot.identitySignature
    }

    static func backoff(forConsecutiveFaults faults: Int) -> TimeInterval {
        guard faults > 0 else { return faultBackoff[0] }
        return faultBackoff[min(faults, faultBackoff.count) - 1]
    }

    /// The interval a lane must not be fanned out over, or nil when it may be.
    /// READ-ONLY: it reserves nothing, which is why a pass can ask it before it
    /// has anything to measure. `evaluate` is the one that takes a ticket, and
    /// calling that speculatively would strand an in-flight reservation nobody
    /// ever reports back on.
    func suppressionInterval(lane: String, now: ContinuousClock.Instant = .now) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = lanes[lane] else { return nil }
        if state.measurementInFlight {
            return Self.backoff(forConsecutiveFaults: max(state.consecutiveFaults, 1))
        }
        guard state.verdict == .faulted, let verdictAt = state.verdictAt else { return nil }
        let backoff = Self.backoff(forConsecutiveFaults: state.consecutiveFaults)
        guard verdictAt.duration(to: now) < .seconds(backoff) else { return nil }
        return backoff
    }

    func evaluate(lane: String, now: ContinuousClock.Instant = .now) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        var state = self.state(for: lane)

        // Someone else owns the in-flight request. Adding a second one would
        // multiply exactly the traffic this type exists to remove, and counting
        // its answer twice would trip the ladder on one observation.
        if state.measurementInFlight {
            lanes[lane] = state
            return .suppress(retryAfter: Self.backoff(forConsecutiveFaults: max(state.consecutiveFaults, 1)))
        }

        if let verdict = state.verdict, let verdictAt = state.verdictAt {
            let ttl: Duration = verdict == .healthy
                ? Self.healthyVerdictTTL
                : .seconds(Self.backoff(forConsecutiveFaults: state.consecutiveFaults))
            if verdictAt.duration(to: now) < ttl {
                lanes[lane] = state
                switch verdict {
                case .healthy:
                    return .proceed
                case .faulted:
                    return .suppress(
                        retryAfter: Self.backoff(forConsecutiveFaults: state.consecutiveFaults)
                    )
                }
            }
        }

        state.measurementInFlight = true
        lanes[lane] = state
        return .measure(ticket: Ticket(lane: lane, generation: state.generation))
    }

    /// Commit a measured verdict. Returns the interval a faulted lane must not
    /// be fanned out over, or nil when the lane is healthy. A ticket whose
    /// generation has moved on is dropped: the state it described no longer
    /// exists.
    @discardableResult
    func record(_ health: Health, ticket: Ticket, now: ContinuousClock.Instant = .now) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard var state = lanes[ticket.lane], state.generation == ticket.generation else {
            return nil
        }
        state.measurementInFlight = false
        state.verdict = health
        state.verdictAt = now
        switch health {
        case .healthy:
            state.consecutiveFaults = 0
        case .faulted:
            state.consecutiveFaults = min(state.consecutiveFaults + 1, Self.faultBackoff.count)
        }
        lanes[ticket.lane] = state
        guard health == .faulted else { return nil }
        return Self.backoff(forConsecutiveFaults: state.consecutiveFaults)
    }

    /// Release a reservation that produced no verdict — the lane identity drifted
    /// mid-request, or the snapshot vanished. Never counts as a fault: the lane
    /// was not the thing that failed.
    func abandon(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = lanes[ticket.lane], state.generation == ticket.generation else { return }
        state.measurementInFlight = false
        lanes[ticket.lane] = state
    }

    /// Record health WITHOUT spending a request, from the thing the scan already
    /// produces: a DEFINITE listing verdict.
    ///
    /// `.entries` and `.absent` are both the server answering a real question
    /// about a real path with a yes or a no — which is exactly what the synthetic
    /// control was ever asked to establish, and stronger, because a `207` is
    /// believed only after its own negative control and a `404` IS the server
    /// saying no. So the listing is the measurement, and a second synthetic
    /// request would only add traffic and a second route through the server that
    /// might not be the one that failed.
    ///
    /// A CLOSED TURN IS NOT ADMISSIBLE, only a definite VERDICT is, and the
    /// distinction still matters: `reconcileOutbox` can report `conclusive` for a
    /// message already at its lifetime chip ceiling, which is a fact about the
    /// MESSAGE rather than about the server. Reading health off the verdict
    /// rather than off the close decision is what keeps that apart.
    func noteHealthyEvidence(lane: String, now: ContinuousClock.Instant = .now) {
        lock.lock()
        defer { lock.unlock() }
        var state = self.state(for: lane)
        state.verdict = .healthy
        state.verdictAt = now
        state.consecutiveFaults = 0
        lanes[lane] = state
    }

    /// Forget a lane entirely — an explicit user action ("Check again") saying
    /// the server is worth another look right now. Bumping the generation is
    /// what keeps an already-running measurement of the OLD state from landing
    /// on the clean one.
    func reset(lane: String) {
        lock.lock()
        defer { lock.unlock() }
        lanes[lane] = LaneState(generation: nextGeneration())
    }

    /// Test seam only — the singleton outlives an XCTest case.
    func resetAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        lanes.removeAll()
    }

    /// Caller MUST hold the lock.
    private func state(for lane: String) -> LaneState {
        if let existing = lanes[lane] { return existing }
        if lanes.count >= Self.laneCeiling { lanes.removeAll() }
        return LaneState(generation: nextGeneration())
    }

    /// Caller MUST hold the lock. Process-monotonic, never per-lane: a lane
    /// re-created after an eviction must not be able to reuse a generation an
    /// in-flight ticket still names.
    private func nextGeneration() -> UInt64 {
        generationCounter &+= 1
        return generationCounter
    }
}

/// Orders the macOS foreground reply landing so durable/UI-critical work cannot
/// sit behind slow output-file probes. `persist` completes first, then the
/// awaiting UI is released synchronously, and only then an unstructured task
/// starts detection + attachment patching. Internal + closure-injected so XCTest
/// can hold the probe open deterministically without a live gateway.
@MainActor
enum MacForegroundReplyLanding {
    struct Dependencies {
        let persist: @MainActor () async throws -> MessageRecord
        /// Existing reply-arrived work that must retain its historical ordering
        /// relative to the send claim (pointer stamp, popover state, speech).
        /// Runs only after persistence succeeds. A thrown store error bypasses
        /// every success effect and propagates to the send/retry failure handler.
        let afterPersistBeforeRelease: @MainActor (_ agentRecord: MessageRecord) async -> Void
        /// Takes the whole persisted record, not just its id: the output scan's
        /// age gate is anchored on the turn's durable `createdAt`, and reading a
        /// fresh `Date()` instead would make the anchor drift by however long
        /// persistence took.
        let reconcileOutputs: (@MainActor (_ agentRecord: MessageRecord) async -> Void)?
    }

    @discardableResult
    static func persistThenScheduleOutputs(
        dependencies: Dependencies,
        releaseAwaitingUI: @MainActor () -> Void
    ) async throws -> MessageRecord {
        let agentRecord = try await dependencies.persist()
        await dependencies.afterPersistBeforeRelease(agentRecord)
        releaseAwaitingUI()

        if let reconcileOutputs = dependencies.reconcileOutputs {
            Task { @MainActor in
                await reconcileOutputs(agentRecord)
            }
        }
        return agentRecord
    }
}

/// Reconstruct the server-backed portion of a FAILED user turn for Retry.
/// Stored keys are usable only when the caller has captured the exact durable
/// lane recorded on that message. This pure seam keeps foreground/background
/// retry parity compiler-visible and lets tests prove that a replacement lane
/// receives no foreign key.
enum RetryFileReferenceResolver {
    struct NamedReference: Equatable, Sendable {
        let originalName: String
        let storedKey: String
    }

    struct ImageReference: Equatable, Sendable {
        let storedKey: String
        let filename: String
    }

    struct References: Equatable, Sendable {
        var serverFiles: [NamedReference] = []
        var imageFiles: [ImageReference] = []
        var textFiles: [NamedReference] = []
        /// Every non-empty persisted key on the owned user turn, deduplicated
        /// in attachment order. Retry probes all of them, not just file-only
        /// rows: dual image and dual text copies can disappear too.
        var storedKeys: [String] = []
    }

    static func hasRequiredStoredKeys(
        _ message: MessageRecord,
        omittingPhotos: Bool
    ) -> Bool {
        message.attachments.contains { attachment in
            guard attachment.storedKey?.isEmpty == false else { return false }
            return !(omittingPhotos
                && attachment.isImage
                && !attachment.isServerReference)
        }
    }

    static func resolve(
        for message: MessageRecord,
        capturedLaneID: String?,
        omittingPhotos: Bool
    ) -> References {
        guard let ownerLaneID = message.fileTransferLaneID,
              ownerLaneID == capturedLaneID else {
            return References()
        }

        var references = References()
        var seenStoredKeys = Set<String>()
        for attachment in message.attachments {
            guard let storedKey = attachment.storedKey, !storedKey.isEmpty else {
                continue
            }
            // "Resend without photo" removes both halves of a dual image:
            // neither its inline JPEG nor its original-file disk ref is sent,
            // so that omitted key must not require a lane or a presence probe.
            if omittingPhotos,
               attachment.isImage,
               !attachment.isServerReference {
                continue
            }
            if seenStoredKeys.insert(storedKey).inserted {
                references.storedKeys.append(storedKey)
            }
            let fallbackName = attachment.filename.flatMap { $0.isEmpty ? nil : $0 }
                ?? storedKey

            // Server references are classified first: an output/download chip
            // may carry image MIME, but it is never a dual inline image.
            if attachment.isServerFile {
                references.serverFiles.append(.init(
                    originalName: fallbackName,
                    storedKey: storedKey
                ))
            } else if attachment.isImage {
                references.imageFiles.append(.init(
                    storedKey: storedKey,
                    filename: attachment.filename.flatMap { $0.isEmpty ? nil : $0 }
                        ?? legacyFilename(from: storedKey, fallback: "image")
                ))
            } else if attachment.isText {
                references.textFiles.append(.init(
                    originalName: fallbackName,
                    storedKey: storedKey
                ))
            }
        }
        return references
    }

    /// Modern dual-image rows persist the true original filename. Older rows
    /// predate that column write but their minted key ends in
    /// `<opaque>__<sanitized-original>`; recover only that leaf suffix (never a
    /// parent path) so Retry keeps the extension without exposing extra path
    /// material.
    static func legacyFilename(from storedKey: String, fallback: String) -> String {
        let leaf = (storedKey as NSString).lastPathComponent
        guard let separator = leaf.range(of: "__", options: .backwards),
              separator.upperBound < leaf.endIndex else {
            return fallback
        }
        return String(leaf[separator.upperBound...])
    }
}

/// Drives one conversation's thread: holds the `conversationID`, fetches its
/// messages (createdAt-ascending), re-fetches on `.conversationsDidChange`,
/// and owns the ephemeral in-flight turn state (optimistic bubble + thinking
/// indicator + Cancel).
@Observable
@MainActor
final class ConversationDetailViewModel {
    let conversationID: UUID
    var messages: [MessageRecord] = []
    var isLoading = false
    var loadError: String?

    /// False until the FIRST `reload()` completes (success OR failure). Gates
    /// the empty-thread mascot: a freshly minted VM (registry sweep / view
    /// remount) must never flash the empty state before the initial fetch
    /// lands. Monotonic — `isLoading` can't serve here (the first render can
    /// happen before the init-scheduled reload Task runs, and reload re-fires
    /// on every `.conversationsDidChange`, which would blink a genuinely-empty
    /// thread's mascot during import storms).
    private(set) var hasLoadedInitialMessages = false

    #if os(macOS)
    /// Closure seam for quick-lane speak-on-arrival — wired in `init` to the
    /// shared-engine leg (`speakArrivalOnSharedEngine`). Tests substitute a spy
    /// to assert the per-send gate is honoured (`dispatchReplySpeakIfNeeded`:
    /// count == 0 when `speaks == false`, count == 1 otherwise). ONE production
    /// reassignment: `MenuBarCoordinator.viewModel(for:)` rewires the VMs it
    /// mints with the popover-visibility-aware router (open popover → the
    /// view's own ThreadSpeaker via `AutoSpeakMailbox`; closed → the same
    /// shared-engine leg). `@MainActor`-typed (unlike the banner twin) because
    /// the production body calls the `@MainActor ReplyVoice` synchronously —
    /// no cross-actor hop between cancel and speak.
    var replySpeaker: @MainActor (String) async -> Void = { _ in }
    #endif

    /// Display name of the conversation's bound backend ("OpenClaw" /
    /// "Hermes"), resolved on `reload()`. Names the conversation's bound
    /// backend (the responder). Drives the "{Backend} is answering…" in-flight
    /// indicator. Under per-conversation routing every turn goes to the
    /// conversation's stored `backend` (not the global default), so the bound
    /// backend names whoever actually answers. Falls back to the default
    /// backend, then "Personal AI" when no backend is configured.
    var backendDisplayName: String = String(localized: "Personal AI")  // xcstrings: chat-ui

    /// Everything the chat header needs to draw its gateway pill, memoized per
    /// conversation for the length of the session. See `headerMemo`.
    struct HeaderIdentity: Sendable {
        var displayName: String
        var boundRef: RemoteAgentRef?
        var boundGatewayAvailable: Bool
        var customGateways: [CustomGateway]
        var configuredRefsForClone: [RemoteAgentRef]
        var hasTurns: Bool
    }

    /// Last resolved header identity per conversation, shared across VM
    /// instances. Load-bearing for the macOS header: `MenuBarCoordinator.
    /// sweepRegistry()` evicts every unreferenced VM, so a sidebar switch mints
    /// a FRESH VM whose `backendDisplayName` is still the generic "Personal AI"
    /// default while `resolveBackendDisplayName()` walks its 4 async hops — the
    /// header visibly flickered "Personal AI" (and popped its chevron in) for a
    /// beat on every thread switch. Seeding `init` from this memo makes the
    /// pill correct on frame one. Populated TWO ways: `warmHeaderMemo()` bulk-
    /// resolves every stored conversation at launch (so no thread is ever cold),
    /// and each VM's `reload()` overwrites its own entry with the authoritative
    /// resolve — so a stale warm entry (gateway renamed/deleted meanwhile)
    /// self-corrects on the next visit.
    /// `@ObservationIgnored` + `static` — pure cache, never drives a view directly.
    @ObservationIgnored private static var headerMemo: [UUID: HeaderIdentity] = [:]

    /// Bound so a long session can't grow the memo without limit; entries are a
    /// few strings each, so the cap is generous and eviction order irrelevant
    /// (a miss costs exactly the pre-fix flicker, once).
    @ObservationIgnored private static let headerMemoCap = 256

    /// `hasTurns` as of the seeded memo — the header's chevron affordance also
    /// gates on the thread having turns, and `messages` is likewise empty for a
    /// beat on a fresh VM.
    @ObservationIgnored private let seededHasTurns: Bool

    /// Whether this thread has turns, answered from the memo until the first
    /// fetch lands so the header pill doesn't change shape mid-switch.
    var hasTurns: Bool {
        hasLoadedInitialMessages ? !messages.isEmpty : seededHasTurns
    }

    /// The conversation's bound gateway ref, resolved on `reload()` from the
    /// persisted `Conversation.backend`. Nil when the stored value doesn't
    /// parse (garbage). Drives the active-thread gateway badge + the
    /// deleted-gateway recovery banner in `ConversationThreadView`.
    var boundRef: RemoteAgentRef?

    /// Whether the bound gateway is still configured (token + url present).
    /// `false` → the gateway was deleted/unconfigured → the thread shows the
    /// "no longer available" recovery banner instead of a live composer state.
    var boundGatewayAvailable: Bool = true

    /// Cached custom roster, for resolving the bound gateway's badge color +
    /// monogram + name without an actor hop inside the thread `body`.
    private(set) var customGateways: [CustomGateway] = []

    /// Configured refs the user can Clone-&-continue onto (built-ins first,
    /// then customs). Refreshed on `reload()`; drives the Clone sheet's picker.
    private(set) var configuredRefsForClone: [RemoteAgentRef] = []

    /// True only when at least one OTHER configured gateway exists besides the
    /// one this thread is bound to — i.e. switching (via Clone) is actually
    /// possible. Gates the read-only gateway badge: with a single configured
    /// gateway there's no ambiguity ("which gateway?") and nowhere to switch to,
    /// so the badge + its lock/clone sheet would be pure noise — mirrors the
    /// new-chat gateway picker, which is likewise hidden below 2 gateways.
    var canSwitchGateway: Bool {
        configuredRefsForClone.contains { $0 != boundRef }
    }

    // MARK: - In-flight turn state (device-local, never persisted)

    /// True while an agent turn is in flight for this conversation — and, on
    /// macOS, from the moment the send *claims* the VM, several `await`s before
    /// the turn is durably written. It is therefore the CORRECTNESS latch (one
    /// in-flight turn per VM, quick-lane re-fire guards, registry retention,
    /// composer disabling), NOT a statement about the gateway. Anything the user
    /// reads as "the agent is working" belongs on `showsGatewayWaitIndicator`.
    var isAwaitingReply = false

    /// When a turn dispatched by THIS instance started — the stamp its elapsed
    /// clock counts from. Nil when this instance has nothing in flight, which is
    /// NOT the same as "nothing is running for this conversation": a sibling VM
    /// the navigation stack discarded, the background converse session, CarPlay
    /// or the macOS share drainer can own a live turn here (see
    /// `liveTurnStartedAt`).
    ///
    /// Written in production only through `beginInFlight`/`endInFlight`, which
    /// keep the registry claim in lockstep with it.
    var inFlightStartedAt: Date?

    /// The registry claim `beginInFlight` minted, released by `endInFlight`.
    /// Token-keyed rather than conversation-keyed, which is what makes the two
    /// double-end sites on one macOS turn safe: `landMacForegroundReply`'s
    /// `releaseAwaitingUI` and the send Task's `defer` both fire for it. Ending
    /// an already-ended token is a no-op that cannot delete a NEWER claim taken
    /// by the share drainer or the background session in between.
    /// `@ObservationIgnored` — bookkeeping; every view reads the derived
    /// properties below, which observe the registry itself.
    @ObservationIgnored private var inFlightClaim: InFlightTurnRegistry.ClaimToken?

    /// Stamp of a turn running for this conversation ON THIS DEVICE, whoever
    /// dispatched it: this VM, a sibling instance the navigation stack
    /// discarded, the background converse session, CarPlay, or the macOS share
    /// drainer.
    ///
    /// DERIVED, never seeded into stored state. A seed taken in `init` could not
    /// un-set itself — the seeded instance owns no `Task`, so nothing would clear
    /// it, and a reply landing under a different owner would leave a permanently
    /// spinning thread that also blocks the send guard. Reading the registry
    /// instead means the indicator is correct on the FIRST frame of a re-minted
    /// VM and disappears the moment the claim is released, with no bookkeeping on
    /// either side. `InFlightTurnRegistry` is `@Observable` with in-memory stored
    /// state, so reading it here registers a real SwiftUI dependency.
    var liveTurnStartedAt: Date? {
        inFlightStartedAt ?? InFlightTurnRegistry.shared.liveSince(conversationID)
    }

    /// The single DISPLAY gate for the agent-side wait: the "{Gateway} is
    /// answering…" row, the popover's answering phase, and the composer's Send
    /// gating. True once a turn has entered its gateway dispatch phase — after
    /// attachment processing, the durable write, history assembly and credential
    /// resolution, immediately before the hop.
    ///
    /// Deliberately NOT "the gateway received it": replies are non-streamed, so
    /// neither transport exposes an early acceptance edge (macOS `data(for:)`
    /// returns the finished body; the iOS background task's first data callback
    /// is already the answer). A real "accepted" event would be a wire-contract
    /// change. This is the closest honest signal the client owns.
    ///
    /// NOT the Stop gate — see `canStopLiveTurn`. A turn this device can SEE but
    /// cannot cancel (a macOS share drain, a CarPlay upload) shows the wait and
    /// offers no Stop.
    var showsGatewayWaitIndicator: Bool { liveTurnStartedAt != nil }

    /// Whether the UI may offer Stop. True only for a turn THIS DEVICE holds a
    /// usable handle to: this VM's own `inFlightTask`, or a registry claim
    /// registered as cancellable (the background converse session). A Mac cannot
    /// cancel an iPhone-owned turn, and the macOS share drainer and the CarPlay
    /// uploader register `isCancellable: false` — so their turns render the wait
    /// indicator with no Stop, rather than a button that calls a cancel with no
    /// handle behind it and does nothing.
    var canStopLiveTurn: Bool {
        inFlightStartedAt != nil || InFlightTurnRegistry.shared.isCancellable(conversationID)
    }

    /// Identity of the turn currently in flight, for a caller that wants to act
    /// on THAT turn rather than on whatever happens to be in flight when its
    /// action runs — see `cancelInFlight(expecting:)`.
    ///
    /// DERIVED from `liveTurnStartedAt`, not from the stored stamp, so a Stop
    /// rendered for a registry-owned turn names the same identity
    /// `cancelInFlight` compares against — otherwise every such Stop would carry
    /// a nil token and be dropped. A separately-stored id would have to be
    /// cleared at every site that clears the start stamp, and would silently
    /// become a stale identity on the first one that was missed. Two turns
    /// cannot share a stamp: the re-entrancy guard (`inFlightTask == nil,
    /// !isAwaitingReply`) admits a second turn only after the first has fully
    /// resolved, and the registry reports the EARLIEST live claim, which is
    /// stable for as long as that turn runs.
    var inFlightTurnToken: Date? { liveTurnStartedAt }

    /// Enter the in-flight state: stamp this instance's clock AND claim the
    /// conversation in the shared registry, so every other surface on this
    /// device — the list row, a VM the navigation stack mints later, the macOS
    /// quit guard — sees the turn without this VM having to tell them.
    ///
    /// A method rather than a `didSet` on `inFlightStartedAt`: `@Observable`
    /// rewrites stored properties into accessors, so a property observer there is
    /// a compile hazard, not a hook.
    private func beginInFlight(at date: Date = Date()) {
        inFlightStartedAt = date
        inFlightClaim = InFlightTurnRegistry.shared.noteBegan(
            conversationID, lane: .viewModel, isCancellable: true, at: date)
    }

    /// Leave the in-flight state. Safe to call twice for one turn — the token is
    /// dropped on the first call and `noteEnded` on an already-ended token is a
    /// no-op — which is exactly what the two macOS release sites need.
    private func endInFlight() {
        inFlightStartedAt = nil
        if let token = inFlightClaim { InFlightTurnRegistry.shared.noteEnded(token) }
        inFlightClaim = nil
    }

    /// Whether a cancel qualified by `token` applies to the turn identified by
    /// `current`. A pure function rather than an inline guard because the
    /// alternative is untestable: both outcomes of the decision are no-ops on a
    /// VM with no live task, so only the decision itself can be asserted.
    ///
    /// nil `token` means "whatever is running" and always applies — that is the
    /// teardown caller, not a UI control.
    static func cancelApplies(expecting token: Date?, current: Date?) -> Bool {
        guard let token else { return true }
        return token == current
    }

    /// A transient error banner for the in-flight turn (cleared on the next
    /// send / cancel). Distinct from `loadError` (store-load failure).
    private(set) var sendError: String?

    /// Numeric `AppError` code paired with `sendError` (nil for a plain notice),
    /// so the banner's "Troubleshoot" button can deep-link into Diagnostics with
    /// the failure's taxonomy code. Kept in lockstep with `sendError` — mutate
    /// BOTH only via `setSendError`/`setSendNotice`/`clearSendError`, never by
    /// assigning `sendError` directly.
    private(set) var sendErrorCode: Int?

    /// The failed user `Message.id` the current `sendError` belongs to, when
    /// the failure has a persisted row in the thread. The thread view
    /// suppresses the transient banner while THAT row is visible — the inline
    /// error row is the richer surface; the banner is only the offscreen
    /// toast. Nil = pre-flight failure with no message row (unconfigured
    /// gateway, attachment notice): the banner always shows.
    private(set) var sendErrorMessageID: UUID?

    /// Compat-mode flag mirrored from the persisted conversation row
    /// (`Conversation.hideEarlierPhotos`) on every reload — drives the
    /// persistent "Earlier photos are hidden…" banner. Mutate ONLY via
    /// `enableHideEarlierPhotos`/`disableHideEarlierPhotos`/
    /// `resendWithoutPhoto` (which persist first, then reload).
    private(set) var hideEarlierPhotos = false

    /// Drives the "Clone & continue on another gateway" sheet. Hoisted onto the
    /// VM (not view-local @State) so triggers OUTSIDE the thread view — the macOS
    /// title-bar Clone button, the iOS/iPad toolbar Clone button — and the in-thread
    /// deletedGatewayBanner all flip ONE flag bound to the single `.sheet` in
    /// ConversationThreadView.
    var showingGatewaySheet = false

    #if os(macOS)
    /// macOS-only: the in-flight foreground converse `Task`. Held here (on the
    /// long-lived VM owned by `MenuBarCoordinator` owned by `AppDelegate`) so
    /// popover teardown during the multi-minute agent wait does NOT cancel the
    /// turn — only an explicit `cancelInFlight()` does. iOS uses the background
    /// session's task registry instead and never sets this.
    private var inFlightTask: Task<Void, Never>?
    #endif

    /// User `Message.id`s of turns sent with `stampsQuickPointer: true` (the
    /// implicit quick-capture lane) that haven't terminally succeeded yet.
    /// Retry must inherit the original turn's provenance: a retried quick turn
    /// keeps continuity (re-stamps the per-device pointer on success), while a
    /// retried window/in-app turn never stamps. Ids are removed on terminal
    /// success so the set can't grow unbounded; a `failed` turn keeps its entry
    /// (it stays retryable). `@ObservationIgnored` — pure bookkeeping, never
    /// drives a view.
    @ObservationIgnored private var quickStampMessageIDs: Set<UUID> = []

    // MARK: - Retroactive output-file scan (Watch / CarPlay landing turns)

    /// Agent-turn `Message.id`s this VM instance has ATTEMPTED a retro output
    /// scan on. Per-VM-instance (once per thread presentation) and deliberately
    /// NOT cleared on reloads: a conclusive pass marks `outputScanDone` in the
    /// store (durable), while a transient probe failure leaves the turn unmarked
    /// so the NEXT thread open retries it — not on every `.conversationsDidChange`
    /// echo. Matches the fail-fast, no-silent-retry philosophy.
    ///
    /// Three things return an id to this pool inside a single presentation, and
    /// each is a moment at which the question "does this file exist?" can have
    /// a different answer rather than silent retries: `retroScanWake` once the
    /// id's own hold has expired (see `retroScanHeldUntil`), a file-lane edit
    /// (see `refreshFileLaneDerivedState`), which is the user telling the app
    /// their setup changed, and a "Check again" tap, which says the same thing
    /// about a server whose settings did not move. A pass that CONFIRMED a file releases its id
    /// immediately — the confirmed keys are excluded next time, so the probe
    /// window has genuinely walked on to candidates nothing has asked about.
    /// `@ObservationIgnored` — pure bookkeeping, never drives a view.
    @ObservationIgnored private var retroScanAttempted: Set<UUID> = []

    /// Guards a single in-flight retro-scan pass per VM (a reload storm must not
    /// stack concurrent passes). `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanInFlight = false

    /// Set when a pass is requested while one is already running, so the running
    /// loop makes one more turn instead of silently dropping the request. The
    /// grace timer is the request that must not be dropped: it is the ONLY thing
    /// that will re-examine a turn whose age gate has just opened, so losing it
    /// to a concurrent reload pass would strand the turn until the next thread
    /// open. Same trailing-pass shape as `scheduleReload`.
    /// `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanTrailingPass = false

    /// The single pending wake. One task, replaced (not stacked) each time an
    /// earlier deadline appears, so a thread full of pending turns can never
    /// accumulate timers. `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanWake: Task<Void, Never>?

    /// Turn ids whose per-VM attempt ownership is HELD, each with the instant
    /// it may be released back into `retroScanAttempted`.
    ///
    /// PER ID, not one shared deadline: the wake releases only the ids that are
    /// actually due and re-arms for the rest. A single shared deadline releases
    /// every held id at the SOONEST one, which hands a turn back to the reload
    /// path before the thing it is waiting for can possibly have changed — a
    /// probe round that asks the user's home server a question it just
    /// answered. `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanHeldUntil: [UUID: Date] = [:]

    /// The wall-clock instant `retroScanWake` is currently waiting for.
    /// `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanWakeDeadline: Date?

    /// Consecutive stalls per turn — how many passes IN A ROW have examined this
    /// id and neither closed it nor confirmed anything. Reads out through
    /// `retroStallBackoff` as the interval the next hold runs for.
    ///
    /// An entry exists only while a turn is actively going nowhere: it is
    /// dropped the moment the turn releases, closes, ages out to its gate, or is
    /// handed back by a lane edit / "Check again", so the map is bounded by the
    /// pending turns of one thread rather than by session length — the same
    /// terminal-removal rule that bounds `retroScanAttempted`.
    /// `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanStallStreak: [UUID: Int] = [:]

    /// Max candidate turns probed per retro-scan pass — bounds fan-out on a
    /// thread carrying many un-scanned Watch/CarPlay turns; the rest catch up on
    /// later opens (each pass marks the conclusive ones durably).
    private static let retroScanCap = 20

    /// How long a probed turn that could NOT be closed and confirmed NOTHING
    /// keeps its attempt ownership before another pass may re-probe it.
    ///
    /// WHAT IT BOUNDS. Two shapes leave a turn pending after its age gate has
    /// opened: a window `FileTransferOutputDetector.maxCandidates` could not
    /// hold (which stays open until `truncatedScanHorizon`, an hour), and a
    /// lane-wide probe failure. Both re-ask the identical question, so without
    /// a hold every coalesced `.conversationsDidChange` echo — a CloudKit
    /// import, another device's reply, a sync storm — re-runs the whole window
    /// against the user's own file server. The truncated shape is the
    /// expensive one and it is not hypothetical: a coding agent listing eleven
    /// files it edited in subdirectories produces exactly it, because the
    /// regex sees only each path's last segment and the served root does not
    /// hold it, so all ten probes miss and the eleventh is never reached. A
    /// hostile gateway can mint that reply deliberately.
    ///
    /// WHY FIVE MINUTES. It is the RATE limit, not the recovery latency: a
    /// fresh thread presentation is a new view model with an empty attempt set,
    /// and a file-lane edit drops every hold immediately, so the two things a
    /// user actually does after fixing their server both recover at once. What
    /// remains is the passive case — a thread left mounted while a server comes
    /// back on its own — and five minutes bounds that at twelve probe rounds an
    /// hour, after which `truncatedScanHorizon` closes the turn anyway. Shorter
    /// buys a faster passive recovery of a case the user is not watching;
    /// longer saves nothing, because the horizon already caps the total.
    ///
    /// ONE INTERVAL FOR BOTH SHAPES, deliberately. Distinguishing them means
    /// threading the detector's truncation verdict and the failing outcome back
    /// out of `detect` (it collapses both into `conclusive`), and a lane
    /// failure is the cheap one anyway — `detect` abandons the turn on the
    /// first non-definitive probe, so it costs ONE request, not ten. Holding it
    /// for the same interval spends at most a few minutes of latency in the
    /// case the lane-edit release already covers.
    ///
    /// IT IS THE FIRST STEP OF A LADDER, not the whole policy — see
    /// `retroStallBackoff`. Five minutes is what ONE stall costs; a turn that
    /// keeps stalling is asked more slowly.
    static let retroStalledRetryInterval: TimeInterval = 5 * 60

    /// How long a turn that has now stalled `stalls` times IN A ROW keeps its
    /// attempt ownership before another pass may re-probe it.
    ///
    /// WHY A LADDER AND NOT A FLAT INTERVAL. A stall means the pass could not
    /// close the turn AND confirmed nothing, and one shape of that repeats
    /// forever with no exit: a probe that is non-definitive but NOT lane-wide
    /// (`FileProbeOutcome.ambiguous` — an HTML document under a `.pdf` name, a
    /// `206` whose body contradicts its own `Content-Range`) leaves
    /// `FileTransferOutputDetector.scanMayClose` shut with no horizon to close
    /// it, while `FileLaneScanBreaker` measures the lane as HEALTHY, because the
    /// lane genuinely can answer `404` — the failure is about one key. A hostile
    /// gateway mints that deterministically. At a flat five minutes the turn is
    /// re-probed twelve times an hour for the mounted lifetime of the thread,
    /// learning the identical nothing every time.
    ///
    /// THE RESIDUAL CLASS IS WIDER THAN `.ambiguous`, which is why this is keyed
    /// on stalling rather than on any particular outcome: a candidate that
    /// answers `.unauthorized` / `.serverError` / `.unknown` (per-file ACL, exact
    /// path routing, one dropped connection) also stalls the turn while the
    /// synthetic control still `404`s, so the breaker rightly calls the lane
    /// healthy and this turn alone is left going nowhere. The rule that covers
    /// every one of them without guessing which it was: a question that keeps
    /// returning the same non-answer gets asked less often.
    ///
    /// WHY THE STREAK AND NOT THE TURN'S AGE. Age is the wrong anchor for a
    /// retry policy even though it is the right one for closing: a turn synced
    /// from another device can be months old and suffer its FIRST transient
    /// probe failure today, and an age-keyed rule would send it straight to the
    /// slowest cadence for a fault one retry would have cleared. The streak is
    /// per-VM and starts at zero on every thread presentation, so what it
    /// measures is "how many times has THIS presentation asked and got nowhere".
    ///
    /// ONE LADDER, SHARED WITH THE LANE BREAKER (`FileLaneScanBreaker.backoff`).
    /// Both answer the same question — how fast to re-ask something that keeps
    /// not answering — and their first steps were already defined to be equal;
    /// two ladders that must stay in step is a drift waiting to happen. Five
    /// minutes for one stall, then 15 / 30 / 60, so a genuinely transient
    /// failure recovers at the old rate and a permanent one settles at one
    /// request an hour per turn.
    static func retroStallBackoff(forConsecutiveStalls stalls: Int) -> TimeInterval {
        FileLaneScanBreaker.backoff(forConsecutiveFaults: stalls)
    }

    // MARK: - Output discovery state

    /// The conversation's CURRENTLY configured READY file lane identity, or nil
    /// when the bound gateway has no ready lane. A turn may only be listed
    /// against the exact lane it was dispatched to, so a removed or repointed
    /// server silently stops every automatic pass rather than reading a folder
    /// on a setup the user no longer has. Refreshed on every `reload()` AND on
    /// `.settingsDidChangeRemotely` — a lane edit changes no conversation row,
    /// so nothing else would ever repaint this.
    var currentFileLaneID: String?

    /// The same lane's `identitySignature`. A SECOND field rather than a
    /// widening of `currentFileLaneID`, because the two answer different
    /// questions and only one of them may change meaning: `currentFileLaneID` is
    /// compared against each turn's PERSISTED `outputScanLaneID`, so it has to
    /// stay the durable URL+credential namespace id. The signature additionally
    /// covers the device-local certificate pin, which `durableLaneID`
    /// deliberately excludes — and a pin is one of the things a user fixes when
    /// their file lane stops answering. Without it, "I corrected my certificate"
    /// is the one repair that moves no tracked value, so every probe result gets
    /// discarded by `configuredLaneStillMatches` while nothing releases the held
    /// turns that would benefit. `@ObservationIgnored` — a bookkeeping baseline,
    /// never rendered.
    @ObservationIgnored private var currentFileLaneSignature: String?

    /// Set by `refreshCurrentFileLaneID` whenever the tracked identity pair
    /// actually moves, and consumed by `refreshFileLaneDerivedState`.
    ///
    /// A LATCH, not a comparison at the point of use, because the pair has more
    /// than one writer: `reload()` refreshes it as part of resolving the header,
    /// so a reload racing a settings write would otherwise absorb the change and
    /// leave the observer comparing a value to itself — the user edits their
    /// lane, a reload lands first, and the release never fires.
    /// `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var fileLaneIdentityMoved = false

    /// Whether the pair above has ever been resolved. `@ObservationIgnored` —
    /// bookkeeping only.
    @ObservationIgnored private var hasResolvedFileLaneIdentity = false

    /// Agent-turn `Message.id`s whose output folder could not be READ — the only
    /// discovery outcome worth showing the user.
    ///
    /// WHAT IS DELIBERATELY NOT IN HERE: an empty folder, and an absent one. A
    /// `404` is what an ordinary reply with no output looks like now that nothing
    /// creates the folder in advance, and it conflates "produced nothing", "the
    /// instruction was ignored", "a mkdir failed", "the agent wrote elsewhere"
    /// and "the served root is not the workspace" — so a row on it would be an
    /// accusation the app cannot support, on the most common turn there is. Only
    /// `.unusable` (transport, non-`207`, malformed body, a lane that answers
    /// everything) means the app learned nothing at all, and that IS worth a row
    /// because the remedy is the user's.
    ///
    /// DERIVED AND EPHEMERAL, never persisted: it describes this process's last
    /// attempt against a server that may be fixed a second later, and a stored
    /// verdict about someone's own file server is exactly the state this design
    /// refuses to keep. Observable — the thread renders one inline row per id.
    var outputDiscoveryFaultIDs: Set<UUID> = []

    /// Agent-turn `Message.id`s that went out with NO output folder because the
    /// configured file lane stopped answering the pre-dispatch freshness
    /// assertion. A DIFFERENT claim from `outputDiscoveryFaultIDs`, and it needs
    /// its own row: there was never a folder, so there is nothing on the server
    /// to reassure anyone about and nothing to re-read.
    ///
    /// THE THREE FOLDER-LESS TURNS THIS MUST NOT CATCH, all of which are
    /// indistinguishable from it in the persisted record (`outputScanLaneID`
    /// set, `outputBoxKey` nil): a wrist-originated turn (the Watch holds no
    /// file-server credential by design), a lane whose server does not implement
    /// `PROPFIND` at all, and a row a device synced from CloudKit before the
    /// attribute landed. None of them is a fault, and a row on any of them is a
    /// per-turn complaint about a standing, correct configuration.
    ///
    /// SO IT IS DERIVED FROM TWO LIVE FACTS, never from the record alone: the
    /// lane must currently be failing its witness
    /// (`FileLaneWitnessBreaker.faultedSince`), and the turn must have landed
    /// AFTER that failure streak began. The second clause is what keeps years of
    /// wrist turns from lighting up the moment one tunnel hostname rotates.
    ///
    /// DERIVED AND EPHEMERAL, like the fault set above and for the same reason —
    /// the spec refuses to persist a missing-file verdict, and this is one. It
    /// clears itself when the lane answers again, which is correct: the row's
    /// whole content is "your file server is not answering right now", and when
    /// it is answering that sentence is false.
    ///
    /// The one thing the live derivation cannot express on its own is the tap:
    /// a manual look RESETS the breaker before it probes, so the derivation
    /// would answer the empty set from the instant of the touch. `hold` below is
    /// what keeps this set honest across that window.
    var outputFolderUnnamedIDs: Set<UUID> = []

    /// Folder-less rows the thread is holding on screen across a manual look.
    ///
    /// WHY IT EXISTS. A tap on "Search mentioned files" (or "Check again")
    /// deliberately resets the pre-dispatch witness breaker, because a user who
    /// has just fixed their tunnel must not wait out a cooldown they cannot see.
    /// But the breaker's failure streak is ALSO the only live input to
    /// `unnamedFolderRowIDs`, so the reset would drop every folder-less row in
    /// the thread — including the one the user just tapped, mid-tap, before the
    /// look has run. A row that evaporates on touch reads as a crash, takes its
    /// own "Review file setup" affordance with it, and reports its outcome as an
    /// orphaned caption under a bubble.
    ///
    /// So the two halves are separated: the breaker reset is immediate (probing
    /// re-enabled, which is what the user asked for), and the ROWS are held at
    /// exactly the set that was on screen — no new turn may join them — until
    /// something EARNS their removal. Earning it means one of:
    ///   * the look got a real answer out of the server (`releaseUnnamedFolderHold`);
    ///   * a later turn on this lane got a folder, which is the pre-dispatch
    ///     witness itself answering (`unnamedFolderHoldIsSpent`);
    ///   * the lane identity moved, so the rows describe a setup that is gone.
    /// Intent to look earns nothing.
    ///
    /// `@ObservationIgnored` — it is an input to `outputFolderUnnamedIDs`, which
    /// is the observed value; nothing renders the hold itself.
    struct UnnamedFolderHold: Equatable {
        /// The lane the held rows were derived against. A hold never survives
        /// the lane moving — those rows describe a server that is no longer
        /// configured.
        let laneID: String
        let ids: Set<UUID>
        /// Wall clock at capture, compared against `MessageRecord.createdAt` for
        /// the same reason `faultedSince` is wall clock: there is no monotonic
        /// instant to compare a stored date against.
        let takenAt: Date
    }

    @ObservationIgnored private(set) var unnamedFolderHold: UnnamedFolderHold?

    /// Per-turn state of a user-initiated "Check again" / "Search mentioned
    /// files". Absent = nothing to report. Observable: drives the row's button +
    /// result caption.
    var outputRecheckStates: [UUID: OutputRecheckState] = [:]

    /// What a user-initiated look DID. Split first on whether it handed anything
    /// over, then — inside the empty half — on why it was empty, because three
    /// materially different things all end with no new chip on the row. An empty
    /// result from a lane-wide failure (bad credential, untrusted certificate,
    /// server down, timeout) is NOT the same claim as an empty result from a
    /// folder the server read out clean, and reporting the former as the latter
    /// would be the lie this state exists to prevent. Nor is either of those the
    /// same as a folder that held files this app is not able to hand over —
    /// reporting THAT as "nothing found" makes ten refused files look exactly
    /// like an empty folder.
    ///
    /// The FIRST split is the load-bearing one, because it is the one that failed
    /// silently: every case below except `.delivered` says, in one wording or
    /// another, that the look produced nothing, and a state carrying that claim
    /// must be unreachable from a look that produced something.
    enum OutputRecheckState: Equatable, Sendable {
        case checking
        /// The look HANDED FILES OVER — `fileCount` of them.
        ///
        /// A CASE OF ITS OWN, NOT A NUMBER ON THE OTHERS, and that is the whole
        /// point of it. "This look delivered" and "this look delivered nothing"
        /// are the two answers a tap can have, and while the difference was
        /// recoverable only by comparing one census against another, a look that
        /// handed over eight files could — and did — describe itself as one that
        /// handed over none. The two states below are now produced by exactly one
        /// branch of `commitTappedOutputs`, the branch guarded on having inserted
        /// nothing, so no edit can put a delivering look back in front of the
        /// sentence that denies it.
        ///
        /// `fileCount` is the number of entries the listing found that were not
        /// on the reply, every one of which is on it once the commit returns —
        /// the store skips a draft whose `storedKey` is ALREADY there, which
        /// means a skipped one is a file another device inserted first, not a
        /// file that failed to arrive. So the count describes the row, which is
        /// what the sentence claims, rather than this device's insert tally.
        ///
        /// Carries NO census, and needs none: it reports what the LOOK did, and
        /// no number of chips arriving afterwards can make that untrue.
        case delivered(fileCount: Int)
        /// The server answered, and there was nothing to hand over.
        ///
        /// `chipCount` is the row's server-file chip census AT THE MOMENT OF THE
        /// ANSWER, and it is what retires the caption. "Nothing found" is true
        /// only about the look that produced it: a turn tapped inside the grace
        /// window can still gain a chip a minute later from the automatic pass,
        /// and the caption would then sit under a visible file contradicting it
        /// for the rest of the session. A census that GREW means the row has
        /// outrun the answer — see `liveRecheckStates`.
        case noneFound(chipCount: Int)
        /// The server answered, and the folder held `count` entries this app is
        /// not able to hand over.
        ///
        /// NOT A FLAVOUR OF `.noneFound`. Both describe a look that handed over
        /// nothing, and only this one can say WHY the folder was empty-handed:
        /// "no returned files were discovered" is equally true of a folder the
        /// server read out clean and of one holding ten names this app will not
        /// address, and saying it of the second makes those ten invisible.
        ///
        /// `chipCount` is the same census `.noneFound` carries, retired by the
        /// same rule. It is a PRE-EXISTING count in both cases — the branch that
        /// sets either one inserted nothing, so there is no post-insert stamp to
        /// take.
        case undeliverableEntries(count: Int, chipCount: Int)
        /// The lane could not be reached / would not answer, or it no longer
        /// matches the lane this turn was dispatched to.
        case couldNotCheck
    }

    /// Prune the manual-look captions a reload has invalidated. Pure + testable;
    /// the single definition of when a transient answer stops being true.
    ///
    /// TWO reasons a caption dies. The row it annotates is GONE (a delete, a
    /// clone, a CloudKit import that dropped it) — an orphaned caption would
    /// otherwise float under whatever row inherited the position. Or the row has
    /// OUTRUN the answer: every caption that reports a FINDING reports one look
    /// at one instant, and the automatic pass that lists the same folder a minute
    /// later can find the agent's late write. Once an unaccounted-for chip is on
    /// screen, the caption underneath it is a contradiction, not a caveat.
    ///
    /// A census that merely stayed the same keeps the caption: the answer is
    /// still the most recent thing anyone learned about that row.
    static func liveRecheckStates(
        _ states: [UUID: OutputRecheckState],
        after messages: [MessageRecord]
    ) -> [UUID: OutputRecheckState] {
        guard !states.isEmpty else { return states }
        var census: [UUID: Int] = [:]
        for message in messages {
            census[message.id] = message.attachments.count(where: \.isServerFile)
        }
        return states.filter { id, state in
            guard let chipsNow = census[id] else { return false }
            // EXHAUSTIVE, WITH NO `default` — that is the point of the switch. A
            // finding state that forgets to be census-gated never retires, so it
            // sits under a contradicting chip for the rest of the session; a
            // default arm would let the next such case join silently, while this
            // shape makes it a compile error at the one place the rule lives.
            switch state {
            case .noneFound(let chipsThen), .undeliverableEntries(_, let chipsThen):
                return chipsNow <= chipsThen
            case .checking, .couldNotCheck, .delivered:
                // NOTHING TO OUTRUN. These report what the LOOK did, not what the
                // folder holds, so a chip arriving afterwards adds to them rather
                // than contradicting them: a file that lands later does not make
                // "the check couldn't finish" or "eight files came back" false.
                // Only a claim about what is THERE can be overtaken by what is
                // there.
                return true
            }
        }
    }

    /// The turn whose manual look is running, if any. VM-WIDE, not per-message: a
    /// thread of agent turns must not let one tap per row fan out into
    /// simultaneous bursts against the user's home server.
    /// `OutputScanClaimRegistry` separately keeps a manual look from stacking
    /// with a retro pass on the SAME turn (and across windows in this process).
    /// `@ObservationIgnored` — the observable `outputRecheckStates` is what the
    /// row reads.
    @ObservationIgnored private var outputRecheckInFlightID: UUID?

    enum RetroOutputScanRoute: Equatable {
        case probeCurrentLane
        case deferUntilMatchingLane
    }

    /// Result of the production per-candidate retro-scan executor. The executor
    /// owns the final route/preflight/claim boundary immediately before the
    /// injected listing closure, which lets tests prove that a removed or
    /// repointed durable lane performs zero network work.
    enum RetroOutputCandidateExecution {
        case deferred
        case claimUnavailable
        /// The box was listed. The reconciliation is what to persist; the
        /// verdict is what the lane breaker and the discovery row read.
        case listed(
            result: ConversationStore.OutputScanReconciliation,
            verdict: FileServerListingVerdict
        )
    }

    #if os(macOS)
    /// User `Message.id`s of turns sent with `speaksReply: true` (the macOS
    /// quick lane with the device-local "speak replies" toggle ON) that haven't
    /// terminally succeeded yet. Same lifecycle as `quickStampMessageIDs`:
    /// inserted BEFORE dispatch, removed on terminal success, kept by a
    /// `failed` turn so `retry()` inherits the original turn's speak verdict.
    /// Ids unknown to the set fail-safe to SILENT — a retried window/in-app
    /// turn (or any stale id) never speaks, mirroring the quick-stamp set's
    /// documented fail-safe semantics. `@ObservationIgnored` — pure
    /// bookkeeping, never drives a view.
    @ObservationIgnored private var speakMessageIDs: Set<UUID> = []

    /// User `Message.id`s of turns sent with `surfacesInPopover: true` (the
    /// macOS quick/hotkey lane — menu-bar click / ⌘⇧1 / ⌘⇧2) that haven't
    /// terminally succeeded yet. Same lifecycle as `speakMessageIDs`: inserted
    /// BEFORE dispatch, removed on terminal success, kept by a `failed` turn so
    /// `retry()` inherits the original turn's popover-surfacing verdict. Lets
    /// the menu-bar popover show ONLY replies to captures started from its OWN
    /// lane — never a window-typed or cross-device (iPhone/Watch) reply that
    /// merely landed in this shared VM's conversation via CloudKit.
    /// `@ObservationIgnored` — pure bookkeeping, never drives a view.
    @ObservationIgnored private var popoverReplyMessageIDs: Set<UUID> = []

    /// The agent reply to the most recent quick/hotkey-lane capture in THIS
    /// conversation — the ONLY reply the menu-bar popover renders (never "the
    /// last agent message", so a window-typed / iPhone / Watch reply that lands
    /// in this shared VM never populates the popover). Held as the record
    /// SNAPSHOT, not an id resolved against `messages`, deliberately: the record
    /// is self-contained, so the popover shows it the instant the send task sets
    /// it — no dependency on the coalesced `.conversationsDidChange` reload
    /// landing first (which the id-resolve form raced, flashing the empty state
    /// on the answering→reply swap) and no per-repaint history scan. Retained
    /// across popover close/reopen; replaced by each successful quick-lane
    /// reply. Observable (NOT `@ObservationIgnored`, unlike the sibling
    /// bookkeeping sets) because a view reads it directly
    /// (`DictationPopoverView.lastAgentReply`).
    var lastPopoverReply: MessageRecord?
    #endif

    /// Holder so the observer can be detached on `deinit` without touching
    /// main-actor state from a nonisolated context (verbatim NotesViewModel).
    private final class ObserverBox {
        var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private let observerBox = ObserverBox()

    /// Coalescing guard for `.conversationsDidChange` → `reload()`. A CloudKit
    /// import storm posts that notification dozens of times in a beat; without
    /// this each post spawned its own `Task { reload() }`, stacking overlapping
    /// full refetches (+ SettingsManager hops + `messages` re-diff) on the main
    /// actor — the reload storm behind the macOS beachball. `scheduleReload()`
    /// collapses a burst into at most one in-flight reload plus one trailing
    /// reload. `@ObservationIgnored` — pure bookkeeping, never drives a view.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    init(conversationID: UUID) {
        self.conversationID = conversationID

        // Seed the header from the session memo BEFORE the first render (the
        // async resolve below can't beat it) — otherwise the pill flashes the
        // generic "Personal AI" fallback on every sidebar switch.
        let memo = Self.headerMemo[conversationID]
        self.seededHasTurns = memo?.hasTurns ?? false
        if let memo {
            self.backendDisplayName = memo.displayName
            self.boundRef = memo.boundRef
            self.boundGatewayAvailable = memo.boundGatewayAvailable
            self.customGateways = memo.customGateways
            self.configuredRefsForClone = memo.configuredRefsForClone
        }

        #if os(macOS)
        // Quick-lane speak-on-arrival (gated upstream by
        // `dispatchReplySpeakIfNeeded`). DEFAULT wiring = the always-alive
        // shared engine (`Self.speakArrivalOnSharedEngine`) — right for a
        // reply that lands with the popover transient-dismissed, where no
        // view-owned speaker is guaranteed to exist. `MenuBarCoordinator.
        // viewModel(for:)` REWIRES this closure on the VMs it mints so a reply
        // landing while the popover is OPEN on its thread routes through the
        // popover's own `ThreadSpeaker` instead (visible speak state,
        // pause/resume, deterministic close teardown) — the iOS/Watch mailbox
        // pattern, applied to the one macOS surface that has a mounted view.
        self.replySpeaker = { reply in
            Self.speakArrivalOnSharedEngine(reply)
        }
        #endif

        // `.conversationsDidChange` = a store mutation / merged CloudKit import.
        // `.conversationsNeedLocalRefresh` = a foreground snapshot re-read so an
        // open thread picks up turns imported while the app was suspended. Both
        // → reload().
        for name in [Notification.Name.conversationsDidChange, .conversationsNeedLocalRefresh] {
            observerBox.observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Coalesce (not one `Task { reload() }` per post) — see
                    // `scheduleReload()`. `queue: .main` runs this on the main
                    // thread; hop into the actor to touch the guard state.
                    Task { @MainActor [weak self] in self?.scheduleReload() }
                }
            )
        }

        // A file-lane edit mutates NO conversation row, so it posts no
        // `.conversationsDidChange` — without this observer a notice would keep
        // naming a server the user just removed or repointed until some
        // unrelated reload happened to land.
        observerBox.observers.append(
            NotificationCenter.default.addObserver(
                forName: .settingsDidChangeRemotely,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshFileLaneDerivedState()
                }
            }
        )

        Task { await self.reload() }
    }

    // MARK: - Loading

    /// Coalesce a burst of `.conversationsDidChange` posts into at most one
    /// in-flight `reload()` plus one trailing reload. If a reload is already
    /// running, mark `reloadPending` and let the running loop pick it up when it
    /// finishes — so a CloudKit import storm drives ≤2 reloads, not N. All access
    /// is main-actor-serialized (no `await` between the pending-check and clearing
    /// `reloadTask`, so the tail is atomic).
    private func scheduleReload() {
        if reloadTask != nil {
            reloadPending = true
            return
        }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.reloadPending = false
                await self.reload()
            } while self.reloadPending
            self.reloadTask = nil
        }
    }

    func reload() async {
        isLoading = true
        loadError = nil
        // Header identity FIRST — a memo-miss cold open (fresh install, row
        // imported mid-session) must not keep the pill on "Personal AI" for
        // the length of a full history fetch + ForEach re-diff; the resolve is
        // a few actor hops and closes the gap before the first paint settles.
        await resolveBackendDisplayName()
        do {
            let fetched = try await ConversationStore.shared.fetchMessages(for: conversationID)
            // Skip the reassignment (and its ForEach re-diff) when a no-op import
            // echo re-fetches an identical thread — the storm's cheapest exit.
            if fetched != messages {
                messages = fetched
            }
            // Output discovery (non-awaited): THE automatic lane. Every dispatch
            // that persisted an explicit pending marker, an exact durable lane
            // AND the folder it named is listed once here. Rows with no folder —
            // a wrist-originated turn, a lane that cannot hold a nested
            // collection, a dispatch whose freshness was never witnessed, or a
            // row that synced before its attribute did — are selected OUT rather
            // than closed: missing metadata means UNKNOWN, never EMPTY. Guarded
            // to a single in-flight pass; the per-instance attempted-set + the
            // durable `outputScanDone` marker stop re-listing on reload echoes.
            Task { [weak self] in await self?.runRetroOutputScan() }
            // A fault row belongs to a turn that is still on screen. Pruning
            // here (compared before assigning, so a reload storm invalidates
            // nothing) keeps a stale row from outliving the message it annotates.
            let liveIDs = Set(messages.map(\.id))
            let liveFaults = outputDiscoveryFaultIDs.intersection(liveIDs)
            if liveFaults != outputDiscoveryFaultIDs {
                outputDiscoveryFaultIDs = liveFaults
            }
            // The folder-less set is DERIVED, not pruned: it is recomputed from
            // the messages just fetched and the lane's live witness verdict, so
            // it self-prunes and self-clears. This is the hook that matters —
            // `.conversationsDidChange` drives a reload the moment a reply
            // lands, whichever process landed it.
            refreshUnnamedFolderRows()
            // Same pruning for the transient manual-look captions, plus the one
            // thing a live-id filter cannot see: a row that has GAINED a chip
            // since it was told "nothing found" now contradicts its own caption.
            let survivingStates = Self.liveRecheckStates(outputRecheckStates, after: messages)
            if survivingStates != outputRecheckStates {
                outputRecheckStates = survivingStates
            }
        } catch {
            loadError = String(localized: "Couldn't load this conversation. Try again.")
        }
        hasLoadedInitialMessages = true
        rememberHeaderIdentity()
        isLoading = false
    }

    /// Pure, unit-testable candidate filter for the retro output scan. A turn
    /// qualifies only with an explicit pending marker, a durable lane identity,
    /// AND the folder that dispatch named — all three atomically persisted when
    /// the dispatch latched a READY file lane.
    ///
    /// `outputBoxKey != nil` IS THE LOAD-BEARING CLAUSE, and its job is to select
    /// rows OUT rather than close them. A reply with a lane but no folder can
    /// arrive four ways — a wrist-originated turn (the Watch holds no
    /// file-server credential and names no box), a lane that cannot hold a nested
    /// collection, a dispatch whose pre-flight freshness assertion did not come
    /// back a definite miss, and a row a device synced from CloudKit before the
    /// attribute landed. Every one of them means UNKNOWN. Marking such a turn
    /// scanned would make "we have not been told yet" permanently indistinguish-
    /// able from "there was nothing", on the device least able to know.
    ///
    /// Already-scanned and per-instance-attempted turns are excluded.
    /// Newest-first (messages are createdAt-ascending), capped. Existing server
    /// refs do not exclude a partial-success turn; store reconciliation dedupes
    /// them.
    static func retroScanCandidates(
        in messages: [MessageRecord],
        attempted: Set<UUID>,
        cap: Int
    ) -> [MessageRecord] {
        Array(
            messages
                .reversed()
                .filter { message in
                    guard message.role == "agent",
                          !attempted.contains(message.id) else {
                        return false
                    }
                    return message.outputScanDone == false
                        && message.outputScanLaneID != nil
                        && message.outputBoxKey != nil
                }
                .prefix(cap)
        )
    }

    /// Whether a candidate may be listed against the currently configured lane,
    /// or must wait until its dispatch lane is restored. Pure — nothing about the
    /// reply's TEXT enters this decision, which is what keeps a pass over
    /// `retroScanCap` turns free of any untrusted-input regex on every thread
    /// open.
    ///
    /// There is no local-conclusion route: the only evidence about what a reply
    /// produced lives in one folder on the user's server, so a turn either gets
    /// its listing or waits.
    static func retroOutputScanRoute(
        for message: MessageRecord,
        currentLaneID: String?
    ) -> RetroOutputScanRoute {
        guard let storedLaneID = message.outputScanLaneID,
              storedLaneID == currentLaneID else {
            return .deferUntilMatchingLane
        }
        return .probeCurrentLane
    }

    /// Execute the production decision boundary for one retro-scan candidate.
    /// The lane identity check comes before the claim and before `list` is
    /// invoked; a mismatched/removed lane stays pending and unattempted. Closure
    /// injection keeps the no-I/O guarantee deterministic in XCTest while
    /// `runRetroOutputScan` uses the live listing lane.
    static func executeRetroOutputScanCandidate(
        _ candidate: MessageRecord,
        currentLaneID: String?,
        snapshotAvailable: Bool,
        laneStillMatches: () async -> Bool,
        claim: () -> Bool,
        didClaim: () -> Void,
        list: (_ outboxKey: String, _ excludedKeys: Set<String>) async
            -> FileTransferOutputDetector.OutboxReconciliation
    ) async -> RetroOutputCandidateExecution {
        // Compiler-level backstops for callers that bypass candidate selection.
        // A row missing either half can neither be listed nor even receive a
        // marker-only mutation: there is no folder to read, and closing it would
        // turn "unknown" into "empty" permanently.
        guard let expectedLaneID = candidate.outputScanLaneID,
              let outboxKey = candidate.outputBoxKey else {
            return .deferred
        }
        switch retroOutputScanRoute(for: candidate, currentLaneID: currentLaneID) {
        case .deferUntilMatchingLane:
            return .deferred
        case .probeCurrentLane:
            guard snapshotAvailable, await laneStillMatches() else {
                return .deferred
            }
        }

        guard claim() else { return .claimUnavailable }
        didClaim()

        let excluded = Set(candidate.attachments.compactMap(\.storedKey))
        let reconciliation = await list(outboxKey, excluded)
        return .listed(
            result: .init(
                messageID: candidate.id,
                drafts: reconciliation.drafts,
                markScanned: reconciliation.conclusive,
                expectedLaneID: expectedLaneID,
                // CARRIED, NOT DROPPED. This is the ONLY path by which the
                // AUTOMATIC lane can tell anyone that a file was in the folder
                // and is not on the row: a tap can report it for as long as the
                // process lives, but a user who never taps had, without this,
                // no way to learn it at all. It rides INSIDE the reconciliation
                // so the post-listing lane-drift check drops it along with the
                // chips — a side channel would route around that guard.
                deliveryOutcome: deliveryOutcome(from: reconciliation)
            ),
            verdict: reconciliation.verdict
        )
    }

    /// Project one listing into the census the row persists, or nil when this
    /// pass took no census at all. PURE, so the nil-vs-zero rule is provable
    /// without a store, a server or a clock.
    ///
    /// NIL ON EVERY VERDICT BUT `.entries`, and this is the single most important
    /// rule in the feature. `.unusable` is a listing the app does not have and
    /// `.absent` is a folder that is not there — neither observed a folder, so
    /// neither may report zero withheld entries. Writing zero for them would
    /// retire a true standing refusal the moment someone's tunnel blinked.
    ///
    /// `.absent` is deliberately in that group even though it closes the turn: a
    /// folder that is gone held nothing to withhold, but it also says nothing
    /// about what an earlier pass legitimately found in it.
    static func deliveryOutcome(
        from reconciliation: FileTransferOutputDetector.OutboxReconciliation
    ) -> OutputDeliveryOutcome? {
        guard case .entries = reconciliation.verdict else { return nil }
        return OutputDeliveryOutcome(
            typeRefusedCount: reconciliation.typeRefusedEntries.count,
            shapeRefused: reconciliation.shapeRefused,
            // THE WHOLE CAP STATE, not just its count. What a budget left behind
            // and whether the message can still hold it are one fact, and the
            // count alone forced the row to re-derive the second from
            // `outputScanDone` — a column that also goes true when a truncated
            // pass merely ages out past `truncatedScanHorizon`. A reply whose
            // folder still holds deliverable files then claimed the ceiling was
            // reached and that nothing more would arrive, over a "Check again"
            // that would have delivered them.
            remainder: reconciliation.capState.remainder,
            // The persisted offer keeps the name and the size and drops the
            // storedKey the listing minted: `<outputBoxKey>/<name>` rebuilds it
            // from a column the row already carries, and one key stored twice is
            // one more pair of values that can drift apart.
            typeRefusedEntries: reconciliation.typeRefusedEntries.map {
                RefusedOutputEntry(name: $0.name, byteSize: $0.byteSize)
            }
        )
    }

    #if os(macOS)
    /// Persist a foreground Mac reply + sent flip, and record the folder this
    /// dispatch named alongside its lane.
    ///
    /// NO OUTPUT DISCOVERY HERE. The reply's row carries `outputBoxKey`, so
    /// listing that folder is the retro pass's job — and the store save below
    /// posts `.conversationsDidChange`, which drives that pass in the same beat.
    /// One implementation of "list the box and reconcile", with the grace window,
    /// the hold ladder, the lane breaker and the identity guards around it.
    private func landMacForegroundReply(
        reply: String,
        userMessageID: UUID,
        dispatchRef: RemoteAgentRef,
        dispatchFileLane: SettingsManager.FileTransferSnapshot?,
        /// The folder THIS dispatch named on the wire, captured at send time.
        /// Rides the same store transaction as the lane below, and the store
        /// drops it when that is nil. Pass BOTH or NEITHER: a folder with no
        /// owning lane names a path nothing is allowed to read.
        outputBoxKey: String?,
        /// The gateway config signature captured at DISPATCH. nil when the ref
        /// wasn't configured at send time (nothing to credit).
        dispatchChatSignature: String?,
        stampsQuickPointer: Bool,
        surfacesInPopover: Bool,
        speaksReply: Bool
    ) async throws -> MessageRecord {
        let conversationID = self.conversationID
        let agentMessageID = UUID()
        let laneID = dispatchFileLane?.durableLaneID
        let persist: @MainActor () async throws -> MessageRecord = {
            try await ConversationStore.shared.completeAgentTurn(
                userMessageID: userMessageID,
                userStatus: "sent",
                agentText: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current,
                agentMessageID: agentMessageID,
                outputScanLaneID: laneID,
                outputBoxKey: outputBoxKey
            )
        }
        let afterPersistBeforeRelease: @MainActor (MessageRecord) async -> Void = {
            [weak self] agentRecord in
            guard let self else { return }
            // Implicit-only pointer: only a quick-capture turn stamps the
            // per-device pointer; explicit window/in-app turns never do.
            if stampsQuickPointer {
                await SettingsManager.shared.recordActiveConversation(conversationID)
            }
            // "Chat works from this Mac, under this config." Recorded HERE —
            // after the reply is decoded AND persisted — so the claim can never
            // outrun the durable turn that backs it. The signature is the
            // DISPATCH-time one; the setter drops it if the live config has moved.
            if let dispatchChatSignature {
                await SettingsManager.shared.recordGatewayChatSuccess(
                    for: dispatchRef,
                    dispatchSignature: dispatchChatSignature
                )
            }
            self.recordPopoverReplyIfNeeded(
                agentReply: agentRecord,
                surfaces: surfacesInPopover
            )
            // Terminal success — drop the provenance entries (a failed
            // turn keeps them for Retry).
            self.quickStampMessageIDs.remove(userMessageID)
            self.speakMessageIDs.remove(userMessageID)
            self.popoverReplyMessageIDs.remove(userMessageID)
            self.dispatchReplyArrivedEffects()
            await self.dispatchReplySpeakIfNeeded(
                reply: reply,
                speaks: speaksReply
            )
        }
        let releaseAwaitingUI: @MainActor () -> Void = { [weak self] in
            self?.isAwaitingReply = false
            self?.endInFlight()
        }
        // `reconcileOutputs` stays on the ordering primitive but production
        // supplies none: discovery is the retro pass's single lane, and the
        // reload this save posts drives it. The seam remains because the
        // primitive's contract — persist, release the UI, THEN do slow optional
        // work — is what its tests pin.
        return try await MacForegroundReplyLanding.persistThenScheduleOutputs(
            dependencies: .init(
                persist: persist,
                afterPersistBeforeRelease: afterPersistBeforeRelease,
                reconcileOutputs: nil
            ),
            releaseAwaitingUI: releaseAwaitingUI
        )
    }
    #endif

    /// Single-flight wrapper around `runRetroOutputScanPass`. A request that
    /// arrives while a pass is running is remembered and served by one trailing
    /// pass, rather than dropped — see `retroScanTrailingPass`.
    private func runRetroOutputScan() async {
        guard !retroScanInFlight else {
            retroScanTrailingPass = true
            return
        }
        retroScanInFlight = true
        defer { retroScanInFlight = false }
        repeat {
            retroScanTrailingPass = false
            await runRetroOutputScanPass()
        } while retroScanTrailingPass
    }

    /// When a probed turn that stayed PENDING may be examined again. Pure +
    /// testable: this is the whole retry policy for the retro scan, and the
    /// rule behind all three cases is one thing — an id comes back only at an
    /// instant where the answer can differ from the one just collected.
    enum RetroScanHoldVerdict: Equatable {
        /// The delivery window has genuinely moved on, so the next pass asks
        /// questions this one did not.
        case release
        /// Too young to close. Nothing can change until the age gate opens.
        case untilAgeGate(Date)
        /// Neither closed nor productive — a box holding more entries than one
        /// pass may deliver, or a listing that could not be read at all. Re-
        /// running it is the definition of learning nothing, so it waits out an
        /// interval that WIDENS with the streak (see `retroStallBackoff`); the
        /// interval is carried on the case because it is a property of this
        /// turn's history, not a constant.
        case stalled(retryAfter: TimeInterval)
    }

    /// `consecutiveStalls` counts this pass's stall INCLUSIVE — 1 the first time
    /// a turn gets nowhere, 2 the next — so the caller increments before asking
    /// and drops the entry on any verdict but `.stalled`.
    static func holdVerdict(
        passStartedAt: Date,
        turnCreatedAt: Date,
        confirmedAnything: Bool,
        consecutiveStalls: Int
    ) -> RetroScanHoldVerdict {
        let ageGate = turnCreatedAt.addingTimeInterval(FileTransferOutputDetector.outputScanGrace)
        // The age gate outranks everything: before it, no pass can close the
        // turn no matter what it finds, so re-probing only repeats a verdict
        // the clock has already disqualified.
        if passStartedAt < ageGate {
            return .untilAgeGate(ageGate)
        }
        // A delivered file is excluded from the next listing's window
        // (`reconcileOutbox` drops keys already on the message), so the window
        // WALKS — and the message's lifetime chip ceiling bounds how often that
        // can happen.
        guard !confirmedAnything else { return .release }
        return .stalled(
            retryAfter: retroStallBackoff(forConsecutiveStalls: consecutiveStalls)
        )
    }

    /// The soonest instant any held turn may be released — what the single
    /// timer must wake for. nil when nothing is waiting on the clock. Pure +
    /// testable: the scheduling policy is "one timer, for the soonest thing
    /// that can change".
    static func earliestHoldDeadline(in holds: [UUID: Date]) -> Date? {
        holds.values.min()
    }

    /// The held ids whose OWN deadline has passed. The wake releases exactly
    /// these, never the whole set: an id whose window has not elapsed is
    /// waiting on something that cannot have changed yet, so handing it back to
    /// the reload path only buys a repeat of the answer it already has. Pure +
    /// testable.
    static func dueHoldIDs(in holds: [UUID: Date], asOf now: Date) -> Set<UUID> {
        Set(holds.filter { $0.value <= now }.keys)
    }

    /// Hold each id's attempt ownership until `deadline`, then re-arm the wake.
    /// The latest decision wins for an id already held — every hold is a fresh
    /// verdict from the pass that just examined that turn.
    private func holdRetroScan(_ messageIDs: [UUID], until deadline: Date) {
        guard !messageIDs.isEmpty else { return }
        for messageID in messageIDs {
            retroScanHeldUntil[messageID] = deadline
        }
        armRetroScanWake()
    }

    /// Arm (or re-arm) the single wake for the soonest held deadline. Keeps an
    /// already-armed earlier wake: it releases only what is due and re-arms for
    /// the rest, so an earlier wake is never wrong, merely early.
    ///
    /// The sleep is a duration derived from the deadline, so a wall-clock
    /// adjustment mid-sleep cannot stretch it indefinitely; on wake the
    /// deadlines are re-evaluated against wall time, which is the check that
    /// actually decides. A clock moved BACKWARDS therefore finds nothing due,
    /// releases nothing, and re-arms rather than spinning.
    private func armRetroScanWake() {
        guard let next = Self.earliestHoldDeadline(in: retroScanHeldUntil) else {
            retroScanWake?.cancel()
            retroScanWake = nil
            retroScanWakeDeadline = nil
            return
        }
        if let armed = retroScanWakeDeadline, armed <= next, retroScanWake != nil {
            return
        }
        retroScanWake?.cancel()
        retroScanWakeDeadline = next
        retroScanWake = Task { [weak self] in
            let wait = next.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, let self else { return }
            self.retroScanWake = nil
            self.retroScanWakeDeadline = nil
            let due = Self.dueHoldIDs(in: self.retroScanHeldUntil, asOf: Date())
            for messageID in due {
                self.retroScanHeldUntil.removeValue(forKey: messageID)
            }
            self.retroScanAttempted.subtract(due)
            // Whatever is still held owns the next wake — including the case
            // where NOTHING was due (a backward clock step), which re-arms and
            // runs no pass.
            self.armRetroScanWake()
            guard !due.isEmpty else { return }
            await self.runRetroOutputScan()
        }
    }

    /// Take attempt ownership of turns this pass deliberately did NOT settle,
    /// and hold them for `interval`. Both halves are needed: the hold is what
    /// the wake reads, and the ownership is what stops a `.conversationsDidChange`
    /// echo from re-selecting a turn the pass just decided not to ask about.
    ///
    /// Used only by the lane breaker. Ordinary stalls flow through
    /// `holdVerdict`, which owns the per-turn reasons; this is the lane-wide
    /// one, where the turn's own state is irrelevant because the server is what
    /// cannot answer.
    private func parkRetroScanCandidates(_ messageIDs: Set<UUID>, for interval: TimeInterval) {
        guard !messageIDs.isEmpty else { return }
        let next = Self.parkedRetroScanState(
            attempted: retroScanAttempted,
            holds: retroScanHeldUntil,
            parking: messageIDs,
            until: Date().addingTimeInterval(interval)
        )
        retroScanAttempted = next.attempted
        retroScanHeldUntil = next.holds
        armRetroScanWake()
    }

    /// WHICH candidates a suppressed pass has to park — every one it did not
    /// SETTLE. Pure + testable, because this arithmetic is what makes the
    /// breaker's request reduction true or false: an id left out here is an id a
    /// `.conversationsDidChange` echo re-selects immediately, and the pass that
    /// was supposed to stop fans out again against a lane already shown to be
    /// unable to answer.
    ///
    /// SETTLED means the turn is done with: a listed turn the pass actually
    /// CLOSED. A listed turn that came back open is NOT settled — it is exactly
    /// the shape the suppression exists to stop re-asking — and neither is a turn
    /// the loop never reached, which is why the input is the whole candidate list
    /// rather than the results.
    nonisolated static func retroScanParkSet(
        candidateIDs: [UUID],
        listedResults: [ConversationStore.OutputScanReconciliation]
    ) -> Set<UUID> {
        let settled = Set(listedResults.filter(\.markScanned).map(\.messageID))
        return Set(candidateIDs).subtracting(settled)
    }

    /// The attempt-ownership + hold-map pair a PARK produces. Pure + testable,
    /// and it returns both halves together because they are one decision: the
    /// hold is what the wake reads, the ownership is what stops a reload echo
    /// from re-selecting the turn in the meantime, and a park that moved only one
    /// of them would be silently ineffective in one direction or the other.
    nonisolated static func parkedRetroScanState(
        attempted: Set<UUID>,
        holds: [UUID: Date],
        parking: Set<UUID>,
        until deadline: Date
    ) -> (attempted: Set<UUID>, holds: [UUID: Date]) {
        var holds = holds
        for messageID in parking {
            holds[messageID] = deadline
        }
        return (attempted.union(parking), holds)
    }

    /// The same pair a RELEASE produces: exactly the held ids hand their attempt
    /// ownership back, and the map empties. Pure + testable — releasing an id
    /// that was never held would re-probe a turn nothing has held, and keeping a
    /// hold whose ownership was dropped would let one turn be probed twice.
    nonisolated static func releasedRetroScanState(
        attempted: Set<UUID>,
        holds: [UUID: Date]
    ) -> (attempted: Set<UUID>, holds: [UUID: Date]) {
        (attempted.subtracting(holds.keys), [:])
    }

    /// Drop every hold and hand the ids back to the scan path. Called for the
    /// two events that can change the answer for EVERY held turn at once: a
    /// file-lane edit — a restored credential, a fixed certificate, a repointed
    /// root — and a "Check again" tap, which is the same statement about a
    /// server the user repaired without touching any app setting. Waiting out an
    /// interval after the user has just fixed the thing is the wrong kind of
    /// patience.
    ///
    /// Releasing turns still inside their age gate too is deliberate and
    /// cheap: their next pass either defers with zero network (the lane no
    /// longer matches the one they were dispatched to) or re-probes one young
    /// turn, which is exactly what the landing path does anyway.
    ///
    /// EVERY CALLER MUST PAIR THIS WITH A PASS, on every path out — this is a
    /// hand-back, and the thing it hands the ids back TO is `runRetroOutputScan`.
    /// Nothing else will: the release empties the hold map, and an empty map is
    /// precisely what makes `armRetroScanWake` cancel the one timer that would
    /// have re-examined these turns. A caller that releases and then returns
    /// early has not deferred the recovery, it has deleted it — the turns are
    /// unheld, unattempted, and unscheduled, so on an idle single-device thread
    /// nothing short of reopening it ever asks about them again.
    private func releaseRetroScanHolds() {
        guard !retroScanHeldUntil.isEmpty else { return }
        let next = Self.releasedRetroScanState(
            attempted: retroScanAttempted,
            holds: retroScanHeldUntil
        )
        retroScanAttempted = next.attempted
        retroScanHeldUntil = next.holds
        // A released turn is being asked afresh, so its stall history goes with
        // the hold: the event that justified the release (a repaired server) is
        // exactly the thing that could make the next probe answer differently,
        // and carrying a streak over would meet it with the slowest cadence.
        retroScanStallStreak.removeAll()
        armRetroScanWake()
    }

    private func runRetroOutputScanPass() async {
        let candidates = Self.retroScanCandidates(
            in: messages,
            attempted: retroScanAttempted,
            cap: Self.retroScanCap
        )
        guard !candidates.isEmpty else { return }

        // ONE instant for the whole pass, captured before any listing. The age
        // gate is measured from when the pass STARTED, so a slow run of requests
        // can never carry an early empty answer past a deadline it did not meet.
        let passStartedAt = Date()
        let createdAtByMessageID = Dictionary(
            candidates.map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )

        // Resolve the CURRENT bound lane once. Every candidate may use it only
        // when its durable dispatch-lane ID matches; ownerless legacy rows were
        // filtered out before this point. A removed/repointed lane leaves the
        // reply pending and unattempted so restoring lane A can recover it.
        let rawBackend = try? await ConversationStore.shared.fetchConversation(id: conversationID)?.backend
        let ref = rawBackend.flatMap { RemoteAgentRef(rawString: $0) }
        let snapshot: SettingsManager.FileTransferSnapshot?
        if let ref {
            snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        } else {
            snapshot = nil
        }
        let currentLaneID = snapshot?.durableLaneID

        var listedResults: [ConversationStore.OutputScanReconciliation] = []
        var listedMessageIDs: [UUID] = []
        var claimedMessageIDs: [UUID] = []
        // Turns whose folder this pass could not READ. Applied to the observable
        // set in one write at the end, so a pass over twenty turns repaints once.
        var faultedMessageIDs: Set<UUID> = []
        var clearedFaultMessageIDs: Set<UUID> = []
        defer {
            for messageID in claimedMessageIDs {
                OutputScanClaimRegistry.shared.release(messageID)
            }
        }

        // Non-nil once the LANE — not this turn — has been shown to be the thing
        // that cannot answer. It ends the pass's fan-out and becomes the interval
        // every turn the pass could not settle is parked for. See
        // `FileLaneScanBreaker`.
        let laneKey = snapshot.map { FileLaneScanBreaker.laneKey(for: $0) }
        var laneSuppression: TimeInterval?
        // A lane already known bad inside its backoff window costs this pass
        // nothing at all: no fan-out, no request, one dated hold. The turns it
        // leaves unmarked lose nothing a user can see — `outputScanDone` gates
        // re-listing, and they close on the pass after the lane recovers.
        if let laneKey {
            laneSuppression = FileLaneScanBreaker.shared.suppressionInterval(lane: laneKey)
        }

        for candidate in candidates where laneSuppression == nil {
            let execution = await Self.executeRetroOutputScanCandidate(
                candidate,
                currentLaneID: currentLaneID,
                snapshotAvailable: snapshot != nil,
                laneStillMatches: {
                    guard let ref, let snapshot else { return false }
                    return await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: ref,
                        snapshot: snapshot
                    )
                },
                claim: {
                    OutputScanClaimRegistry.shared.claim(candidate.id)
                },
                didClaim: {
                    claimedMessageIDs.append(candidate.id)
                    retroScanAttempted.insert(candidate.id)
                },
                list: { outboxKey, excluded in
                    guard let snapshot else {
                        // NO LANE, SO NOTHING WAS LISTED — and `.unusable` is
                        // the honest encoding of that, which is why the census
                        // fields are left at their empty defaults rather than
                        // stated. A zero census here would claim a folder was
                        // read and found clean by a pass that never opened a
                        // socket, and that claim would overwrite a real one.
                        return .init(drafts: [], conclusive: false,
                                     verdict: .unusable(.transport))
                    }
                    return await FileTransferOutputDetector.reconcileOutbox(
                        outboxKey: outboxKey,
                        snapshot: snapshot,
                        excludedKeys: excluded,
                        turnCreatedAt: candidate.createdAt,
                        scanStartedAt: passStartedAt
                    )
                }
            )

            switch execution {
            case .listed(let result, let verdict):
                listedResults.append(result)
                listedMessageIDs.append(candidate.id)
                switch verdict {
                case .entries, .absent:
                    // The server answered a real question about a real path with
                    // a definite yes or no — which is precisely what the breaker's
                    // synthetic control was ever asked to establish. So the
                    // listing IS the health measurement, and a walled lane can no
                    // longer masquerade as a healthy one: a `207` is believed only
                    // after its own negative control, and a `404` is a server
                    // saying no. No extra request buys anything here.
                    clearedFaultMessageIDs.insert(candidate.id)
                    if let laneKey {
                        FileLaneScanBreaker.shared.noteHealthyEvidence(lane: laneKey)
                    }
                case .unusable:
                    // The ONE discovery outcome the user is told about, because
                    // it is the only one where the app learned nothing and the
                    // remedy is theirs.
                    faultedMessageIDs.insert(candidate.id)
                    guard let laneKey else { continue }
                    // Nothing in this pass has shown the lane can answer. Settle
                    // it ONCE before spending the rest of the window on a server
                    // that may be incapable of answering at all — that shape
                    // stalls every remaining turn identically, and it is the
                    // whole reason this pass could otherwise run forever.
                    switch FileLaneScanBreaker.shared.evaluate(lane: laneKey) {
                    case .proceed:
                        continue
                    case .suppress(let retryAfter):
                        laneSuppression = retryAfter
                    case .measure(let ticket):
                        // The measurement already happened: this turn's listing
                        // asked the lane and got no usable answer. Recording it
                        // from the verdict in hand is both free and strictly more
                        // faithful than a second synthetic request, which could
                        // take a different route through the server than the one
                        // that actually failed.
                        laneSuppression = FileLaneScanBreaker.shared.record(
                            .faulted,
                            ticket: ticket
                        )
                    }
                }
            case .deferred, .claimUnavailable:
                continue
            }
        }

        // A suppressed lane leaves turns behind in two states, and BOTH must be
        // parked or the pass is not actually bounded: the ones this pass never
        // reached (never claimed, so a reload echo would re-select them
        // immediately) and the one whose stall triggered the measurement. They
        // are parked for the breaker's current backoff rather than their own
        // place on `retroStallBackoff`, which is the entire mechanism: when the
        // LANE is what cannot answer, the rate that has to widen is the lane's,
        // and a per-turn hold would re-ask it once per pending turn instead.
        var parked: Set<UUID> = []
        if let interval = laneSuppression {
            parked = Self.retroScanParkSet(
                candidateIDs: candidates.map(\.id),
                listedResults: listedResults
            )
            parkRetroScanCandidates(parked, for: interval)
        }

        // A lane drift after the listings drops every network-derived result:
        // they describe a server this conversation is no longer pointed at.
        // Remove the dropped attempts so restoring the exact lane can retry in
        // this VM.
        var results: [ConversationStore.OutputScanReconciliation] = []
        if !listedResults.isEmpty,
           let ref,
           let snapshot,
           await FileTransferOutputDetector.configuredLaneStillMatches(
                ref: ref,
                snapshot: snapshot
           ) {
            results = listedResults
        } else if !listedResults.isEmpty {
            for messageID in listedMessageIDs {
                retroScanAttempted.remove(messageID)
            }
        }

        // The discovery-fault set is the pass's own reading, so it is applied
        // whether or not anything was persisted — a thread of turns whose folder
        // could not be read has nothing to save and everything to say. ONE write
        // for the whole pass; compared first so an unchanged set repaints nothing.
        let nextFaults = outputDiscoveryFaultIDs
            .subtracting(clearedFaultMessageIDs)
            .union(faultedMessageIDs)
        if nextFaults != outputDiscoveryFaultIDs {
            outputDiscoveryFaultIDs = nextFaults
        }

        guard !results.isEmpty else { return }
        guard (try? await ConversationStore.shared.reconcileOutputScan(results)) != nil else {
            for result in results {
                retroScanAttempted.remove(result.messageID)
            }
            return
        }
        // A closed turn leaves the candidate pool for good (`retroScanCandidates`
        // selects on `outputScanDone == false`), so its stall history goes with
        // it — this is what keeps the streak map bounded by a thread's PENDING
        // turns rather than by everything the session ever examined.
        for result in results where result.markScanned {
            retroScanStallStreak.removeValue(forKey: result.messageID)
        }
        // An inconclusive pass intentionally keeps the durable marker pending.
        // WHY the turn is pending decides when it may be asked again, and the
        // rule is the same in every case: an id comes back only at an instant
        // where the answer can differ.
        //   - The age gate has not opened yet ⇒ hold to `createdAt + grace`.
        //     Re-listing before then can only repeat the same too-early answer
        //     against the user's home server. This is the ordinary shape for a
        //     freshly-landed turn: nothing creates the folder in advance, so the
        //     first listing of a young turn is usually a `404` that a write
        //     seconds away could disprove.
        //   - The pass DELIVERED a file ⇒ release immediately. Its key is
        //     excluded next time, so the window walks forward onto entries
        //     nothing has handed over yet; the lifetime chip ceiling
        //     (`maxOutputChipsPerMessage`) bounds how far that can go.
        //   - Nothing delivered, nothing closed (a box holding more than one
        //     pass may deliver, or a folder that could not be read) ⇒ hold for
        //     this turn's place on the `retroStallBackoff` ladder. The identical
        //     request against the identical lane is the definition of learning
        //     nothing, and releasing it here is what let a reload storm re-run
        //     it.
        //   - The LANE itself could not answer ⇒ already parked above for the
        //     breaker's backoff, and skipped here: a stall hold would silently
        //     undo the widening cadence that bounds a walled lane.
        var stalled: [TimeInterval: [UUID]] = [:]
        for result in results
        where !result.markScanned && !parked.contains(result.messageID) {
            guard let createdAt = createdAtByMessageID[result.messageID] else {
                retroScanAttempted.remove(result.messageID)
                retroScanStallStreak.removeValue(forKey: result.messageID)
                continue
            }
            let streak = (retroScanStallStreak[result.messageID] ?? 0) + 1
            switch Self.holdVerdict(
                passStartedAt: passStartedAt,
                turnCreatedAt: createdAt,
                confirmedAnything: !result.drafts.isEmpty,
                consecutiveStalls: streak
            ) {
            case .release:
                retroScanAttempted.remove(result.messageID)
                retroScanStallStreak.removeValue(forKey: result.messageID)
            case .untilAgeGate(let deadline):
                // Waiting on the clock is not stalling: no pass could have
                // closed this turn yet, so the streak that widens the cadence
                // must not count it.
                retroScanStallStreak.removeValue(forKey: result.messageID)
                holdRetroScan([result.messageID], until: deadline)
            case .stalled(let retryAfter):
                retroScanStallStreak[result.messageID] = streak
                stalled[retryAfter, default: []].append(result.messageID)
            }
        }
        // Measured from NOW, not from `passStartedAt`: a pass against a slow
        // server can outlive the interval on its own, and a deadline already in
        // the past is no hold at all. Grouped by interval because turns in one
        // pass can sit on different rungs of the ladder.
        let stalledAt = Date()
        for (retryAfter, messageIDs) in stalled {
            holdRetroScan(messageIDs, until: stalledAt.addingTimeInterval(retryAfter))
        }

        // NO PREVIEW DOWNLOADS HERE, deliberately, and this was the largest
        // automatic byte-mover in the product: the pass runs from `reload()`, so
        // it fired on every CloudKit import echo, pulling slices of the user's
        // files off their own server and into their iCloud and onto their wrist
        // for content nobody had opened. A preview is now built from the bytes a
        // chip TAP already downloaded — see
        // `FileTransferOutputDetector.previewPatchesForDownloadedFile`.
    }

    // MARK: - Lane identity

    /// Re-resolve the lane identity and everything derived from it. The single
    /// entry point for "the user may have just changed their file server" —
    /// both the settings-change observer and the setup sheet's dismissal use it,
    /// so the two can't drift on which half they remembered to refresh.
    ///
    /// A lane edit mutates no conversation row and therefore posts no
    /// `.conversationsDidChange`, so the scan pass is driven from HERE: it is
    /// the only thing that re-examines the turns an unreachable or repointed
    /// lane left pending, and without it "fix your server, then wait for an
    /// unrelated reload" would be the recovery story. Restoring the exact lane
    /// a turn was dispatched to is the case that matters — a DIFFERENT lane
    /// never answers for an old turn, it just defers with zero network.
    ///
    /// Gated on the identity actually MOVING, not on the notification: any
    /// settings write posts `.settingsDidChangeRemotely` (a voice preset, a KVS
    /// import echo), and letting unrelated churn drop every hold would hand the
    /// listing window straight back to the storm that
    /// `retroStalledRetryInterval` exists to bound.
    ///
    /// "Moving" means EITHER half of the identity pair — the durable URL +
    /// credential namespace or the device-local certificate pin. A pin-only
    /// repair changes no durable id, but it is exactly what
    /// `configuredLaneStillMatches` tests before it will let a listing result
    /// commit, so a release keyed on the durable half alone leaves the user who
    /// fixed their certificate waiting out an interval for no reason.
    func refreshFileLaneDerivedState() async {
        await refreshCurrentFileLaneID()
        // Unconditional, because the breaker's verdict moves without the LANE
        // moving: a witness that failed (or recovered) since the last paint is
        // exactly the change this row is about, and gating it on `laneMoved`
        // would leave the row waiting for a settings edit to appear.
        refreshUnnamedFolderRows()
        let laneMoved = fileLaneIdentityMoved
        fileLaneIdentityMoved = false
        guard laneMoved else { return }
        releaseRetroScanHolds()
        // Every fault row describes an attempt against the lane that just moved,
        // so it describes a setup that no longer exists. Drop them all and let
        // the pass below say what is true of the NEW one.
        if !outputDiscoveryFaultIDs.isEmpty {
            outputDiscoveryFaultIDs = []
        }
        // The folder-less set needs no equivalent clear: the lane it was keyed
        // to no longer exists, so the recompute above already answered the empty
        // set for the new one — including any tap-held rows, which
        // `unnamedFolderHoldIsSpent` drops on the lane mismatch. The ordering is
        // load-bearing: `refreshCurrentFileLaneID` above has already moved
        // `currentFileLaneID`, so the hold is compared against the NEW lane.
        await runRetroOutputScan()
    }

    /// The lane key the witness breaker tracks this conversation's lane under.
    /// Nil when the bound gateway has no ready lane. Assembled from the SAME
    /// pair `refreshCurrentFileLaneID` resolved, so the VM and the breaker
    /// cannot end up talking about two different lanes.
    private var currentFileLaneWitnessKey: String? {
        guard let laneID = currentFileLaneID, let signature = currentFileLaneSignature else {
            return nil
        }
        return laneID + "\u{1}" + signature
    }

    /// Which agent turns should carry the folder-less row. PURE, so the whole
    /// selection rule is unit-testable without a server, a store, or a clock.
    ///
    /// `faultedSince` nil means the lane is answering, and the answer is then
    /// the empty set — no history, no residue, nothing to clear by hand.
    ///
    /// THE `createdAt` COMPARISON IS THE CAUSALITY GATE. A turn that landed
    /// before the streak started cannot have been folder-less because of it, and
    /// the persisted record cannot tell the two apart (see
    /// `outputFolderUnnamedIDs`). Non-strict (`>=`) because a reply always lands
    /// after the dispatch whose witness failed, so the boundary case is the one
    /// this row exists for.
    ///
    /// The lane clause is `==`, not `!= nil`: a turn dispatched to a DIFFERENT
    /// server than the one currently failing is not evidence about that server.
    static func unnamedFolderRowIDs(
        in messages: [MessageRecord],
        currentLaneID: String?,
        faultedSince: Date?
    ) -> Set<UUID> {
        guard let currentLaneID, let faultedSince else { return [] }
        return Set(
            messages
                .filter { message in
                    message.role == "agent"
                        && message.outputScanLaneID == currentLaneID
                        && message.outputBoxKey == nil
                        && message.createdAt >= faultedSince
                }
                .map(\.id)
        )
    }

    /// Whether a hold has been EARNED AWAY by evidence rather than by time.
    /// PURE, so the release rule is unit-testable without a server or a breaker.
    ///
    /// Two ways to spend it, and neither is "the user asked":
    ///   * the lane moved — the held rows describe a server that is no longer
    ///     the configured one, so they are no longer about anything;
    ///   * a turn dispatched on this lane AFTER the hold was taken came back
    ///     WITH a folder. Only a passing pre-dispatch witness mints a box key,
    ///     so that turn is the server answering — which makes "your file server
    ///     didn't answer" false, and the row goes.
    ///
    /// `>=` for the same causality reason `unnamedFolderRowIDs` uses it: the
    /// boundary instant belongs to the turn, not to the hold.
    static func unnamedFolderHoldIsSpent(
        _ hold: UnnamedFolderHold,
        in messages: [MessageRecord],
        currentLaneID: String?
    ) -> Bool {
        guard hold.laneID == currentLaneID else { return true }
        return messages.contains { message in
            message.role == "agent"
                && message.outputScanLaneID == hold.laneID
                && message.outputBoxKey != nil
                && message.createdAt >= hold.takenAt
        }
    }

    /// The WHOLE visibility rule in one pure step — which turns carry the row,
    /// and what survives of a tap's hold. Pure for the same reason
    /// `unnamedFolderRowIDs` is: the interaction between a live failure streak
    /// and a user-held set is exactly the part that needs to be provable without
    /// a server, a breaker or a clock.
    ///
    /// UNION, never replacement. The derivation stays the authority on which
    /// turns a LIVE streak covers; the hold only stops a tap's own breaker reset
    /// from erasing what was already on screen. A held id that no longer names a
    /// live message costs nothing — the thread asks `contains(message.id)` per
    /// row, so a dangling id simply matches no row.
    static func unnamedFolderRowState(
        in messages: [MessageRecord],
        currentLaneID: String?,
        faultedSince: Date?,
        hold: UnnamedFolderHold?
    ) -> (ids: Set<UUID>, hold: UnnamedFolderHold?) {
        let derived = unnamedFolderRowIDs(
            in: messages, currentLaneID: currentLaneID, faultedSince: faultedSince)
        guard let hold,
              !unnamedFolderHoldIsSpent(hold, in: messages, currentLaneID: currentLaneID) else {
            return (derived, nil)
        }
        return (derived.union(hold.ids), hold)
    }

    /// Recompute the folder-less row set from the breaker's LIVE verdict, folding
    /// in whatever a tap is holding. Cheap and allocation-light, so it runs on
    /// every reload rather than being pushed from the dispatch path: the reply
    /// that needs the row is landed by the background delegate on iOS, in a
    /// process the VM never sees, and a row that only appeared on the surfaces
    /// the VM dispatched itself would be missing on the platform where it
    /// matters most.
    func refreshUnnamedFolderRows() {
        let state = Self.unnamedFolderRowState(
            in: messages,
            currentLaneID: currentFileLaneID,
            faultedSince: currentFileLaneWitnessKey.flatMap {
                BackgroundFileTransfer.FileLaneWitnessBreaker.shared.faultedSince(lane: $0)
            },
            hold: unnamedFolderHold
        )
        unnamedFolderHold = state.hold
        // Compared before assigning so an unchanged set repaints nothing.
        if state.ids != outputFolderUnnamedIDs {
            outputFolderUnnamedIDs = state.ids
        }
    }

    /// Re-enable pre-dispatch probing on `snapshot`'s lane, WITHOUT retracting
    /// what the thread currently says about it.
    ///
    /// The reset is the point: a deliberate tap is the user asserting their
    /// server is worth asking again, and the very next turn they send must try
    /// to name a folder rather than wait out a cooldown they cannot see.
    ///
    /// The hold taken first is what stops that reset from doubling as a verdict.
    /// `faultedSince` is the sole live input to the folder-less rows, so a bare
    /// reset would clear every one of them SYNCHRONOUSLY — the tapped row would
    /// vanish under the user's finger, before the look it started has run, and
    /// take its explanation and its "Review file setup" button with it. Held
    /// here, released only by an answer (`releaseUnnamedFolderHold`) or by the
    /// evidence rules in `unnamedFolderHoldIsSpent`.
    ///
    /// Internal rather than private for the test target: the regression this
    /// carries — the tapped row surviving its own button — is only observable
    /// across the reset, so the seam has to be callable.
    func reopenWitnessProbing(for snapshot: SettingsManager.FileTransferSnapshot) {
        // Captured BEFORE the reset, because the reset is what destroys the
        // derivation this reads from. Keyed on `currentFileLaneID` rather than
        // the snapshot's, because that is the lane the on-screen set was derived
        // against and the lane `refreshUnnamedFolderRows` will compare it to.
        if let laneID = currentFileLaneID, !outputFolderUnnamedIDs.isEmpty {
            unnamedFolderHold = UnnamedFolderHold(
                laneID: laneID,
                ids: outputFolderUnnamedIDs,
                takenAt: Date()
            )
        }
        BackgroundFileTransfer.FileLaneWitnessBreaker.shared.reset(
            lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot))
        refreshUnnamedFolderRows()
    }

    /// The look got a REAL ANSWER out of the file server, so the standing claim
    /// "your file server didn't answer" is now false and the held rows go.
    ///
    /// This is the only release a tap can perform, and it is deliberately gated
    /// on evidence rather than on completion: a look that resolved nothing
    /// (unreachable host, refused certificate, a lane edit mid-request, or a
    /// reply that named no file to probe at all) leaves the rows exactly where
    /// they were, still carrying their explanation and their way out.
    ///
    /// Internal rather than private for the same reason as the capture above.
    func releaseUnnamedFolderHold() {
        guard unnamedFolderHold != nil else { return }
        unnamedFolderHold = nil
        refreshUnnamedFolderRows()
    }

    /// Whether this turn has an output folder a user tap could re-read. False for
    /// a wrist-originated turn, a lane that cannot hold a nested collection, a
    /// dispatch whose freshness was never witnessed, and a row that synced ahead
    /// of its attribute — every one of which the manual name search still serves.
    static func canRecheckOutputs(_ message: MessageRecord) -> Bool {
        message.role == "agent"
            && message.outputScanLaneID != nil
            && message.outputBoxKey != nil
    }

    /// Whether this turn has a file lane a name search could probe. MIRRORS the
    /// DURABLE half of `searchMentionedFiles`'s own guard — role and lane; the
    /// remaining clause is the transient one-tap-at-a-time lock, which is a
    /// reason to ignore a tap, not a reason to hide the verb. It exists so the
    /// menu item cannot drift from that guard: the handler returns immediately
    /// on a turn with no lane, so
    /// an ungated item is a verb that answers a tap with nothing at all — no
    /// result, no caption, no error. That is the MAJORITY configuration, not an
    /// edge: a turn sent with no file server configured persists no lane id, and
    /// so does every row that predates the attribute.
    ///
    /// Weaker than `canRecheckOutputs` by exactly one clause, deliberately: a
    /// turn with a lane but no FOLDER — a wrist-originated turn, a lane that
    /// cannot hold a nested collection, a dispatch whose freshness was never
    /// witnessed — is precisely the population the automatic lane never serves,
    /// so the name search is the only recovery it has.
    static func canSearchMentionedFiles(_ message: MessageRecord) -> Bool {
        message.role == "agent" && message.outputScanLaneID != nil
    }

    /// Whether the bubble footer has any manual-look verb to offer at all — the
    /// gate on ATTACHING the context menu, not just on filling it.
    ///
    /// A `.contextMenu` whose body evaluates to nothing still runs the long-press
    /// lift animation and then presents an empty sheet, so "no items" has to mean
    /// "no menu". Both clauses require an agent row, which is what keeps a user's
    /// own sent message from lifting under a long press and offering nothing.
    static func showsOutputActionsMenu(_ message: MessageRecord) -> Bool {
        canRecheckOutputs(message) || canSearchMentionedFiles(message)
    }

    /// Whether this turn carries a settled census worth a STANDING row, and what
    /// it says. Pure, like its two neighbours above, so the visibility rule is
    /// provable without a store, a server or a view.
    ///
    /// NO VIEW-MODEL STATE BACKS THIS, deliberately. The census lives on the
    /// record, `messages` is already the observable the thread renders from, and
    /// a bubble already repaints when its own `MessageRecord` compares unequal —
    /// so a changed census repaints for free. It also needs no pruning: the two
    /// transient row-drivers beside it (`outputDiscoveryFaultIDs`,
    /// `outputRecheckStates`) each need a live-id sweep on every reload, while a
    /// field on a row cannot outlive the row.
    ///
    /// Nil for a turn with NO census recorded (UNKNOWN) and for one whose census
    /// is SILENT (OBSERVED NONE). Those are different facts and the store keeps
    /// them apart, but they draw the same thing: nothing.
    ///
    /// A row with no `outputBoxKey` never qualifies however its census reads — a
    /// rescue resolves `<outputBoxKey>/<name>`, so a census with no folder
    /// describes files nothing could fetch. The clone path is why that clause is
    /// not theoretical: a cloned agent turn can carry a lane with no folder.
    static func outputDeliveryRow(for message: MessageRecord) -> OutputDeliveryOutcome? {
        guard message.role == "agent",
              message.outputScanLaneID != nil,
              message.outputBoxKey != nil,
              let outcome = message.outputDeliveryOutcome,
              !outcome.isSilent,
              !typeClaimHasGoneStale(outcome) else {
            return nil
        }
        return outcome
    }

    /// Whether the ONLY thing this census still claims is a type refusal the
    /// allowlist has since overtaken.
    ///
    /// THE ALLOWLIST IS THE ONE INPUT THAT MOVES between the pass that wrote a
    /// census and the render that reads it, and `rescuableEntries` already
    /// re-asks the verdict for exactly that reason — so a row could reach the
    /// screen saying "the folder held 2 files Conduck doesn't open on its own"
    /// with no name under it and no Review button beside it, because every name
    /// it had was dropped one layer down. A bare count with nothing to act on is
    /// the worst of both surfaces: it makes a claim the app can no longer
    /// support and offers nothing to do about it, over files the thread is about
    /// to show as ordinary chips.
    ///
    /// THREE CONDITIONS, and each is load-bearing:
    ///   - The other two populations must be EMPTY. A shape count and a
    ///     remainder are bare integers about names that were never persisted, so
    ///     nothing can overtake them and the row stands on either.
    ///   - The claim must be FULLY DESCRIBED by the names it retained
    ///     (`typeRefusedCount == typeRefusedEntries.count`). A census that
    ///     counted more of the folder than it kept has an unexamined remainder,
    ///     and "the ones I kept are deliverable now" says nothing about it.
    ///   - Every retained name must be deliverable TODAY. An unreadable blob
    ///     decodes to no entries, which fails this test at the clause above
    ///     rather than here — a row that lost its names still has its count, and
    ///     "there were N" is the correct degradation.
    private static func typeClaimHasGoneStale(_ outcome: OutputDeliveryOutcome) -> Bool {
        guard outcome.shapeRefusedCount == 0,
              outcome.undeliveredCount == 0,
              outcome.typeRefusedCount > 0,
              outcome.typeRefusedCount == outcome.typeRefusedEntries.count else {
            return false
        }
        return outcome.typeRefusedEntries.allSatisfy { entry in
            if case .deliverable = FileServerClient.outboxEntryVerdict(entry.name) { return true }
            return false
        }
    }

    /// The caption a manual look leaves on the row, or nil when a clean success
    /// leaves nothing to annotate.
    ///
    /// A TAP IS ALWAYS ANSWERED. That is the rule this function exists to
    /// enforce, and it is the one an earlier shape broke: the two FINDING
    /// captions were suppressed outright whenever a standing held-back row was
    /// up, so a user who tapped "Check again" on exactly the row that offers the
    /// verb got no acknowledgement of any kind — no caption, no change, nothing
    /// to distinguish a completed re-read from a tap that missed the button. The
    /// same silence swallowed "Search mentioned files", which asks about the
    /// SERVED ROOT and therefore cannot contradict a row about the folder at all.
    ///
    /// WHAT THE SUPPRESSION WAS ACTUALLY FOR is narrower than what it did: the
    /// held-back row is PERSISTED and outlives the look, so a later clean look
    /// printing "No returned files were discovered." under a row naming a file
    /// contradicts it, and a shape count printed under a row that already states
    /// one says the same number twice. Both are fixed by REPHRASING under a row
    /// rather than by going quiet — and "Nothing new came back" is provable of
    /// both, because the only branch that can produce either state is the one
    /// that inserted nothing.
    ///
    /// THE REPHRASE IS FOR THE EMPTY HALF ONLY. Every state that reports what the
    /// LOOK did — `.couldNotCheck`, `.delivered` — is left alone, because a
    /// sentence about the look cannot contradict a row about the folder: a
    /// standing refusal and a re-read that got no answer are both true at once,
    /// and so are a standing refusal and eight files that have just landed. What
    /// separates those two is only whether they are worth saying at all — see
    /// `.delivered` below.
    ///
    /// `hasStandingRow` is therefore read for two unrelated jobs, and mixing them
    /// up is what a caller must not do: it is ONE of the two inputs to the WORDING
    /// of an empty result — the chip census the state itself carries is the other,
    /// because a look that added nothing to a reply ALREADY holding files found
    /// nothing NEW rather than nothing at all — and it decides whether a delivery
    /// is worth narrating.
    static func lookResultCaption(
        for state: OutputRecheckState?,
        hasStandingRow: Bool
    ) -> LocalizedStringResource? {
        switch state {
        case .checking, nil:
            return nil
        case .couldNotCheck:
            // Deliberately names NO cause. This one state covers a lane that no
            // longer matches the turn's, a look the app itself declined because
            // another pass held the turn, a settings edit mid-request, and a
            // genuine transport/auth/certificate failure. Only the last is a
            // server the app could not reach, so naming reachability would send
            // most users to debug a server that is working perfectly.
            return LocalizedStringResource(
                "thread.outputs.result.couldNotCheck",
                defaultValue: "Couldn't finish the check just now.")
        case .delivered(let fileCount):
            guard hasStandingRow else {
                // NOTHING LEFT TO ANNOTATE, which is the same rule a clean
                // success has always followed: with no row above them the new
                // chips are the entire visible change, and a sentence counting
                // what the user can already see is one more line between them and
                // the files.
                return nil
            }
            // THE ROW SURVIVED THE TAP, and that is what makes this one delivery
            // worth narrating. A held-back row is persisted, so it repaints
            // unchanged after a look that added files — the screen a user gets
            // back from "Check again" is the screen they tapped, with the new
            // chips folded in among the old ones and the same warning above them.
            // The count is the only proof on screen that the tap did anything.
            //
            // A COUNT, NEVER A NAME: this sentence sits beside a census that may
            // include shape refusals, and a name is exactly what the gate that
            // refused them exists to keep out of the app's own voice.
            return LocalizedStringResource(
                "thread.outputs.result.delivered",
                defaultValue: "^[\(fileCount) file](inflect: true) came back.")
        case .noneFound(let chipCount), .undeliverableEntries(_, let chipCount):
            guard !hasStandingRow else {
                // The row is the richer surface and it is already saying what
                // the folder holds. This says only what the LOOK did, which is
                // the half the row cannot cover — and it is what turns a tap
                // into an answered question.
                //
                // TRUE OF BOTH STATES BY CONSTRUCTION, not by inspection: neither
                // is reachable except from the branch of `commitTappedOutputs`
                // guarded on having inserted nothing. That is the guarantee the
                // sentence rests on, and the reason a delivering look can no
                // longer arrive here to deny its own chips.
                return LocalizedStringResource(
                    "thread.outputs.result.nothingNew",
                    defaultValue: "Nothing new came back.")
            }
            // BELOW HERE THE FOLDER HAS NO ROW SPEAKING FOR IT, which for a
            // refusal count is the narrow window before the census this same
            // commit persisted has been read back onto the reply. The row is the
            // better surface once it is up — it names the mechanism and the
            // remedy — so this arm is what the user sees in the meantime rather
            // than a second, competing description of the folder.
            if case .undeliverableEntries(let count, _) = state, count > 0 {
                // SHAPE REFUSALS ONLY, and that is the whole of what this
                // caption covers. The other population — a name refused for its
                // TYPE — has the held-back row, which names it and offers a
                // rescue; a caption that counted both would report the same file
                // twice, once as a number under a row that had just named it.
                //
                // THE COUNT, NEVER THE NAME, which is precisely why the shape
                // half stayed here. A shape-refused name is one the outbound
                // gate was unwilling to address at all, so printing it would put
                // the deceptive string the gate exists to stop in front of the
                // user, in the app's own voice.
                //
                // AND NO CAUSE. The listing proves the folder held something
                // this app will not address; it does not prove whether the agent
                // meant to write it, wrote it by accident, or was handed it by a
                // tool.
                return LocalizedStringResource(
                    "thread.outputs.result.undeliverable",
                    defaultValue: "The folder for this reply held ^[\(count) file](inflect: true) Conduck can't hand over.")
            }
            // THE SUBJECT OF THE SENTENCE IS THE LOOK, NOT THE FOLDER, and the
            // absolute wording only reads that way while the reply is empty. With
            // chips already on the row — the ordinary end of a rescue, where the
            // held-back row retired once its last name arrived and a later look
            // then found nothing to add — "no returned files were discovered"
            // sits under files that visibly did return and reads as a denial of
            // them. The census the commit stamped is the whole test: a look that
            // handed nothing over to a reply already holding server files found
            // nothing NEW, not nothing at all — which is the tap-scoped sentence
            // the standing-row arm above reaches for on the same grounds.
            if chipCount > 0 {
                return LocalizedStringResource(
                    "thread.outputs.result.nothingNew",
                    defaultValue: "Nothing new came back.")
            }
            // DISCOVERY, never a claim about the agent. The server answered and
            // there was nothing to hand over — which is equally consistent with
            // a reply that produced nothing, one that wrote somewhere else, and
            // one whose write tool failed silently. Saying "the agent produced
            // nothing" would pick one of those out of no evidence.
            return LocalizedStringResource(
                "thread.outputs.result.noneFound",
                defaultValue: "No returned files were discovered.")
        }
    }

    /// What a tap's result may write, decided BEFORE any of it happens so the two
    /// halves cannot drift apart in the body of an `async` method.
    ///
    /// TWO SEPARATE QUESTIONS, and conflating them is what this type prevents.
    /// A census is worth writing on its own — a folder holding only names this
    /// app will not address IS the zero-draft case, and it is precisely the case
    /// the standing row exists for. STAMPING the turn is a different and
    /// PERMANENT act: it removes the turn from the automatic candidate set
    /// forever. So a tap on a readable but empty folder records what it saw and
    /// closes nothing, which is what the tap did before the census existed to be
    /// written.
    ///
    /// `conclusive` still owns the age gate on top of the draft test — a pass
    /// that delivered inside the grace window may not close the turn either.
    struct TappedOutputCommit: Equatable, Sendable {
        /// Whether the store is opened at all.
        let writesToStore: Bool
        /// Whether that write also stamps `outputScanDone`.
        let stampsTurnScanned: Bool
    }

    static func tappedOutputCommit(
        draftCount: Int,
        conclusive: Bool,
        hasCensus: Bool
    ) -> TappedOutputCommit {
        TappedOutputCommit(
            writesToStore: draftCount > 0 || hasCensus,
            stampsTurnScanned: conclusive && draftCount > 0
        )
    }

    /// Whether a folder re-read got a real ANSWER about the folder — the evidence
    /// half of what the USER'S tap reports when it hands over no chips.
    ///
    /// READ FROM THE VERDICT, NEVER FROM `conclusive`. `conclusive` ANDs the
    /// server's answer with the turn's AGE gate (`outputScanGrace`), and that
    /// gate exists for one job only: stopping the AUTOMATIC pass from
    /// PERMANENTLY closing a turn on a listing that arrived a beat after the
    /// reply. It has no bearing on what a user who just asked is told. A tap ten
    /// seconds after the reply that got a clean `207` or a clean `404` learned
    /// exactly as much as one an hour later, and reporting it as "couldn't finish
    /// the check" would name a fault that did not happen — on the impatient tap,
    /// which is the common one.
    ///
    /// `.absent` counts as an answer for the same reason it closes a turn:
    /// nothing creates the folder in advance, so a `404` is the server saying
    /// there is nothing there.
    static func folderReadAnswered(
        _ reconciliation: FileTransferOutputDetector.OutboxReconciliation
    ) -> Bool {
        switch reconciliation.verdict {
        case .entries, .absent: return true
        case .unusable: return false
        }
    }

    /// Whether a ROOT NAME SEARCH actually got something out of the file server —
    /// the evidence that may retire a held folder-less row.
    ///
    /// `conclusive` ALONE IS NOT THAT EVIDENCE, and the gap is the whole reason
    /// this exists. `probeNamedCandidates` returns `conclusive == true` for an
    /// EMPTY probe window without issuing a single request, and the window is
    /// empty on the ordinary case: a reply that named no filename, or named only
    /// files this thread already uploaded. Retiring the row on that would clear
    /// it for the INTENT to look, which is precisely the defect the hold exists
    /// to prevent.
    ///
    /// So a probed window is required — and `foundAnything` is the same proof by
    /// another route: a confirmed-present file means the server spoke, and it
    /// covers the mixed run where one probe answered definitively and another
    /// timed out (`conclusive == false`).
    ///
    /// Takes the same `excludedKeys` the probe was given, so the two cannot drift
    /// on what "probed" means.
    static func rootSearchGotAnAnswer(
        candidates: [String],
        excludedKeys: Set<String>,
        conclusive: Bool,
        foundAnything: Bool
    ) -> Bool {
        if foundAnything { return true }
        guard candidates.contains(where: { !excludedKeys.contains($0) }) else { return false }
        return conclusive
    }

    /// USER-INITIATED re-read of one turn's output folder ("Check again").
    ///
    /// A closed turn is never re-listed automatically — that is the whole point
    /// of the permanent marker. A deliberate tap is different: the user is
    /// telling the app that something changed on their side, and re-asking is the
    /// only way to find out. It is allowed to ADD chips to an already-closed turn
    /// (`reconcileOutputScan` is indifferent to the marker).
    ///
    /// ORDER IS LOAD-BEARING — `reconcileOutbox` deliberately resolves no
    /// settings of its own, so this caller owns both identity guards:
    ///   1. resolve the CURRENT ready lane and require it to be the exact lane
    ///      this turn was dispatched to (a repointed server must never answer
    ///      for an old turn);
    ///   2. claim the turn, so a retro pass in this process cannot list it
    ///      concurrently;
    ///   3. list;
    ///   4. re-check the lane identity — a settings edit mid-request invalidates
    ///      the result;
    ///   5. only then reconcile.
    ///
    /// FAN-OUT: one PROPFIND for the tapped turn, followed by ONE retro pass over
    /// the turns the tap un-held — the tap says "my server changed" about the
    /// whole thread, not about one row, and that pass is what acts on it.
    /// `outputRecheckInFlightID` makes it one tap at a time for the whole thread.
    ///
    /// The result is DEVICE-LOCAL and stops here. Nothing about it is sent to
    /// the gateway: a listing reported back would build a file-existence oracle
    /// against the user's own server out of a diagnostic.
    func recheckOutputs(for message: MessageRecord) async {
        guard outputRecheckInFlightID == nil,
              let laneID = message.outputScanLaneID,
              let outboxKey = message.outputBoxKey else {
            return
        }
        outputRecheckInFlightID = message.id
        // ONE transient answer on screen at a time. A caption is the reply to a
        // question the user just asked, so a thread cannot accumulate a column of
        // stale ones as they work down it.
        outputRecheckStates = [message.id: .checking]
        defer { outputRecheckInFlightID = nil }

        guard let (ref, snapshot) = await resolveTappedLane(matching: laneID) else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        guard OutputScanClaimRegistry.shared.claim(message.id) else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        defer { OutputScanClaimRegistry.shared.release(message.id) }
        defer { handBackHeldTurnsAfterTap() }
        // A deliberate tap is the user asserting their server is worth asking
        // again, so it clears the lane breaker's backoff outright and hands back
        // every turn this VM had parked behind it. Without this the tap would
        // recover ONE turn while the automatic path stayed silenced for up to an
        // hour on a lane the user has just told us to re-examine.
        FileLaneScanBreaker.shared.reset(lane: FileLaneScanBreaker.laneKey(for: snapshot))
        // The SAME assertion applies to the pre-dispatch witness, which parks
        // the same server on its own ladder: a user who has just fixed their
        // tunnel taps here, and the very next turn they send must try to name a
        // folder again rather than wait out a cooldown they cannot see. The
        // folder-less rows this tap did NOT touch — siblings elsewhere in the
        // thread — are held across the reset rather than deleted by it.
        reopenWitnessProbing(for: snapshot)
        releaseRetroScanHolds()

        // The age ladder still applies, anchored on the turn's own `createdAt`:
        // a tap on a turn that is minutes old closes it on a definite answer,
        // and a tap seconds after the reply does not — a file the agent is about
        // to write must survive an impatient tap exactly as it survives the
        // automatic pass. `scanMayClose` refuses to close on `.unusable`
        // regardless of age, so an unreadable server never closes anything.
        let reconciliation = await FileTransferOutputDetector.reconcileOutbox(
            outboxKey: outboxKey,
            snapshot: snapshot,
            excludedKeys: Set(message.attachments.compactMap(\.storedKey)),
            turnCreatedAt: message.createdAt
        )
        // The row's own verdict, refreshed by the tap: a fault that has cleared
        // must stop showing, and one that persists must keep showing.
        applyDiscoveryVerdict(reconciliation.verdict, to: message.id)
        await commitTappedOutputs(
            reconciliation.drafts,
            conclusive: reconciliation.conclusive,
            for: message,
            laneID: laneID,
            ref: ref,
            snapshot: snapshot,
            // The CLOSE decision and the CAPTION are separate questions, and this
            // is the seam where they part: `conclusive` still governs the
            // permanent marker (age gate included), while what the user is told
            // is whatever the server actually said.
            reportedNothingWhen: Self.folderReadAnswered(reconciliation),
            // …and this is the rest of what it said. A listing that delivered
            // nothing is not the same fact as a listing that delivered nothing
            // BECAUSE the folder held only names this app cannot address, and
            // only the folder-reading verb can tell them apart. The SHAPE half
            // alone: the type half has the held-back row, which names those
            // files, and counting them here as well would report each of them
            // twice on the same bubble.
            shapeRefusedCount: reconciliation.shapeRefusedCount,
            // …and this is the half of it that outlives the process. The caption
            // above is the answer to a tap; this is the settled fact about the
            // folder, and a tap must leave the row in the same state the
            // automatic pass would — or a user who asks gets something a user who
            // waits never does, and loses it on relaunch besides.
            deliveryOutcome: Self.deliveryOutcome(from: reconciliation)
        )
        // EARNED, and only now. A `207` or a `404` is the lane answering (an
        // `.unusable` verdict is not), which makes "your file server didn't
        // answer" false for the SIBLING folder-less rows this tap held across
        // the breaker reset. Ordered after the commit so the caption is already
        // on the row when it clears — a release before the commit's awaits could
        // paint a frame with the rows gone and nothing yet said.
        if Self.folderReadAnswered(reconciliation) {
            releaseUnnamedFolderHold()
        }
    }

    /// USER-INITIATED probe of the filenames this reply MENTIONED, at the served
    /// root ("Search mentioned files").
    ///
    /// THE TAIL RECOVERY, and the only place reply prose can still schedule a
    /// request. It is for the gateway that ignored the folder it was given and
    /// wrote to its workspace root instead — a shape no listing of the box can
    /// ever find, and one the user can see in the reply text while the app
    /// cannot act on it.
    ///
    /// Available on every agent turn that HAS A FILE LANE — including one with no
    /// folder at all (a wrist-originated turn, a flat lane), which is exactly the
    /// population that gets no automatic delivery. A turn with no lane has no
    /// server to search and is gated out of the menu entirely
    /// (`canSearchMentionedFiles`), because the guard below can only return.
    /// It never closes the turn: a name found at the root says nothing about the
    /// folder this turn named.
    ///
    /// The chips it mints carry BARE storedKeys, so they cannot begin with the
    /// reply's own box prefix and the thread renders them with visibly weaker
    /// provenance — found on the file server, not produced by this reply.
    func searchMentionedFiles(for message: MessageRecord) async {
        guard outputRecheckInFlightID == nil,
              message.role == "agent",
              let laneID = message.outputScanLaneID else {
            return
        }
        outputRecheckInFlightID = message.id
        // ONE transient answer on screen at a time. A caption is the reply to a
        // question the user just asked, so a thread cannot accumulate a column of
        // stale ones as they work down it.
        outputRecheckStates = [message.id: .checking]
        defer { outputRecheckInFlightID = nil }

        guard let (ref, snapshot) = await resolveTappedLane(matching: laneID) else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        guard OutputScanClaimRegistry.shared.claim(message.id) else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        defer { OutputScanClaimRegistry.shared.release(message.id) }
        defer { handBackHeldTurnsAfterTap() }
        FileLaneScanBreaker.shared.reset(lane: FileLaneScanBreaker.laneKey(for: snapshot))
        // Holds this turn's OWN folder-less row (and its siblings') on screen
        // across the reset: this is the one action that row offers, so the row
        // has to survive its own button and report the outcome.
        reopenWitnessProbing(for: snapshot)
        releaseRetroScanHolds()

        let candidates = await FileTransferOutputDetector
            .extractCandidatesOffMainActor(from: message.text)
        // Resolved HERE rather than inline, because whether anything was probed
        // at all is load-bearing below.
        let excludedKeys = Set(message.attachments.compactMap(\.storedKey))
            .union(inboundStoredKeyTokens())
        let scan = await FileTransferOutputDetector.probeNamedCandidates(
            candidates: candidates,
            snapshot: snapshot,
            excludedKeys: excludedKeys
        )
        await commitTappedOutputs(
            scan.drafts,
            // A root search NEVER closes a turn: it asked a different question
            // from the one the marker answers, so a clean "not at the root" says
            // nothing about the folder this reply was told to write into.
            conclusive: false,
            for: message,
            laneID: laneID,
            ref: ref,
            snapshot: snapshot,
            // Probe evidence, with no age gate folded in: `probeNamedCandidates`
            // reports whether every probe came back definitive, which is already
            // "did the server answer" and nothing else.
            reportedNothingWhen: scan.conclusive,
            // NO CENSUS EXISTS HERE, and zero is the truthful report of that.
            // A root search asks about names the reply mentioned, one key at a
            // time; it never lists a folder, so it never sees an entry to refuse.
            // The type gate does its work upstream, on the candidate tokens, and
            // a name it filtered out was a word in a sentence — not a file
            // anybody's server was found to be holding.
            shapeRefusedCount: 0,
            // NIL, AND NEVER A ZEROED CENSUS. The persisted census is a claim
            // about ONE FOLDER as one listing read it, and this verb never opens
            // a folder — so it has no such claim to make. A zero here would
            // overwrite a real refusal the automatic lane earned, from a look
            // that could not have seen it. Zero above and nil here are not
            // inconsistent: the caption reports what THIS look found, and nil is
            // how the store is told nothing was looked at.
            deliveryOutcome: nil
        )
        // EARNED, and only on evidence the server spoke — see
        // `rootSearchGotAnAnswer` for why `scan.conclusive` alone is not that.
        // Ordered after the commit so the caption is already on the row when it
        // clears; a release before the commit's awaits could paint a frame with
        // the rows gone and nothing yet said.
        if Self.rootSearchGotAnAnswer(
            candidates: candidates,
            excludedKeys: excludedKeys,
            conclusive: scan.conclusive,
            foundAnything: !scan.drafts.isEmpty
        ) {
            releaseUnnamedFolderHold()
        }
    }

    /// The bound gateway's currently READY lane, required to be the exact one a
    /// turn was dispatched to. Shared by both tap paths so they cannot drift on
    /// which identity a manual look is allowed to read.
    private func resolveTappedLane(
        matching laneID: String
    ) async -> (ref: RemoteAgentRef, snapshot: SettingsManager.FileTransferSnapshot)? {
        let rawBackend = try? await ConversationStore.shared
            .fetchConversation(id: conversationID)?.backend
        guard let ref = rawBackend.flatMap({ RemoteAgentRef(rawString: $0) }),
              let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref),
              snapshot.durableLaneID == laneID else {
            return nil
        }
        return (ref, snapshot)
    }

    /// The hand-back a tap owes the rest of the thread, on EVERY path out.
    /// `releaseRetroScanHolds` cancels the armed wake (an empty hold map is what
    /// makes `armRetroScanWake` do that), and a negative outcome returns without
    /// a store write — so no `.conversationsDidChange`, no reload, and nothing at
    /// all scheduled for the turns the tap just un-held. A tap on one turn would
    /// otherwise DELETE the recovery of every other pending turn in the thread.
    ///
    /// Registered as a `defer` rather than called inline, and the timing is the
    /// point: the pass cannot then interleave with the tap's own request at an
    /// `await` and double the fan-out at the user's server.
    private func handBackHeldTurnsAfterTap() {
        Task { @MainActor [weak self] in
            await self?.runRetroOutputScan()
        }
    }

    /// The conversation's own INBOUND uploads, as the tokens a root search must
    /// not probe. The turn text hands the agent each uploaded file's stored name,
    /// so a reply that merely echoes one would otherwise chip the user's own
    /// upload back at them. Both the full key and its last path component,
    /// because the candidate regex cannot cross a `/` and only ever surfaces the
    /// leaf. Non-`user` unknown roles count as inbound — the conservative
    /// direction, since a wrongly-suppressed chip beats a wrong chip.
    ///
    /// Only the ROOT search needs this: a folder listing reads a path minted for
    /// one dispatch, which no inbound upload can be inside.
    ///
    /// The leaf is taken on UTF-8 BYTES, like every other separator read in this
    /// lane. A key whose leaf opens with a combining mark fuses that mark with
    /// the `/` before it into one Character, so a grapheme search finds an
    /// earlier separator or none at all and inserts a folder path where the leaf
    /// belongs — the suppression then misses, and the root search chips the
    /// user's own file back at them. That is the NON-conservative direction, the
    /// one this set exists to avoid.
    private func inboundStoredKeyTokens() -> Set<String> {
        var tokens = Set<String>()
        for message in messages where message.role != "agent" {
            for attachment in message.attachments {
                guard let key = attachment.storedKey else { continue }
                tokens.insert(key)
                if let leaf = key.utf8
                    .split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
                    .last, leaf.count != key.utf8.count {
                    tokens.insert(String(decoding: leaf, as: UTF8.self))
                }
            }
        }
        return tokens
    }

    /// Persist what a tap found and report the outcome on the row. Shared by both
    /// tap paths: the identity re-check, the store write and the reported state
    /// are one policy, and two copies of it would drift on the one thing that
    /// matters — never reporting "nothing there" for a server that did not
    /// answer, and never reporting it for a look that just handed files over.
    ///
    /// The `drafts.isEmpty` guard below is the SEAM the reported state is chosen
    /// on, and it is a branch rather than a comparison for a reason: every state
    /// this method can set except `.delivered` carries the claim that the look
    /// produced nothing, so a look that produced something must not be able to
    /// reach one by arithmetic.
    ///
    /// `conclusive` decides only whether the turn is PERMANENTLY stamped scanned,
    /// and only on a look that actually delivered a chip — a tap that reads a
    /// readable-but-empty folder writes its census and closes nothing, because
    /// closing a turn removes it from the automatic pass forever and that is not
    /// a decision a reporting change gets to make. `reportedNothingWhen` is the
    /// separate evidence half — did the server answer the question this look
    /// asked — and it is REQUIRED rather than defaulted to `conclusive`, because
    /// the two are different questions and the default was how the age gate
    /// leaked into the caption.
    ///
    /// `shapeRefusedCount` is the listing's census of entries whose NAME the app
    /// will not address at all, and it is REQUIRED for the same reason: the root
    /// search reads no folder and therefore has no census, so a default would
    /// let it claim zero refusals it never looked for — the exact silence this
    /// count exists to end.
    ///
    /// IT IS THE SHAPE HALF ONLY, and deliberately not the whole refusal census.
    /// The other half — a name refused for its TYPE — is carried by the standing
    /// held-back row, which NAMES the file and offers a rescue; a caption that
    /// counted both would report the same file twice, once as a bare number
    /// underneath a row that had just named it. What is left here is exactly the
    /// population whose whole presentation is a count: a name the gate exists to
    /// keep out of the app's own voice.
    ///
    /// READ ON THE EMPTY BRANCH ONLY. It answers "why did this look hand nothing
    /// over", which is a question a look that handed something over does not ask.
    ///
    /// `deliveryOutcome` is the FULL census in the classified, persistable form
    /// that row reads, and it is required on the same grounds. The count above
    /// dies with the process; this is what survives a relaunch, so a user who
    /// taps and one who waits are left looking at the same row.
    private func commitTappedOutputs(
        _ drafts: [AttachmentDraft],
        conclusive: Bool,
        for message: MessageRecord,
        laneID: String,
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot,
        reportedNothingWhen serverAnswered: Bool,
        shapeRefusedCount: Int,
        deliveryOutcome: OutputDeliveryOutcome?
    ) async {
        guard await FileTransferOutputDetector.configuredLaneStillMatches(
            ref: ref,
            snapshot: snapshot
        ) else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        // A ZERO-DRAFT LOOK IS NOT A LOOK WITH NOTHING TO PERSIST, and a look
        // worth persisting is not therefore a look that may CLOSE the turn.
        // `tappedOutputCommit` is where those two questions are separated, and
        // it is a pure function so the separation is provable without a store,
        // a server or a lane.
        let commit = Self.tappedOutputCommit(
            draftCount: drafts.count,
            conclusive: conclusive,
            hasCensus: deliveryOutcome != nil
        )
        var inserted = false
        if commit.writesToStore {
            guard let didInsert = try? await ConversationStore.shared.reconcileOutputScan([
                .init(
                    messageID: message.id,
                    drafts: drafts,
                    markScanned: commit.stampsTurnScanned,
                    expectedLaneID: laneID,
                    deliveryOutcome: deliveryOutcome
                )
            ]) else {
                outputRecheckStates[message.id] = .couldNotCheck
                return
            }
            inserted = didInsert
        }
        guard !drafts.isEmpty else {
            guard serverAnswered else {
                outputRecheckStates[message.id] = .couldNotCheck
                return
            }
            // Census stamped now, so a later pass that actually finds something
            // retires this caption instead of leaving it to contradict a visible
            // chip (see `liveRecheckStates`).
            let chipsNow = message.attachments.count(where: \.isServerFile)
            // A refusal is the more specific true thing: "nothing was discovered"
            // is also true of a folder holding ten refused names, and it is the
            // sentence that makes them invisible. A folder whose only refusals
            // were TYPE refusals falls through to `.noneFound` here, and under
            // the held-back row the view REPHRASES either state to what the look
            // did — the row is the surface that says what the folder holds, with
            // the names and a way to get the files, so the caption stops
            // competing with it and reports the tap instead.
            //
            // THE ONLY SITE FOR EITHER STATE, and it is inside a guard on having
            // no drafts. Both carry, in some wording, the claim that this look
            // produced nothing; setting one anywhere else is how that claim
            // reached a user whose files had just arrived.
            outputRecheckStates[message.id] = shapeRefusedCount > 0
                ? .undeliverableEntries(count: shapeRefusedCount, chipCount: chipsNow)
                : .noneFound(chipCount: chipsNow)
            return
        }
        // `inserted == false` means the lane moved under the write or every
        // draft was already there — a real failure ONLY on a look that had
        // drafts to insert, which the guard above has already established.
        guard inserted else {
            outputRecheckStates[message.id] = .couldNotCheck
            return
        }
        // THE LOOK DELIVERED, AND THAT IS THE WHOLE OF WHAT IT REPORTS. The
        // insert posts `.conversationsDidChange`, so the reload repaints the row
        // on its own; this states what the tap achieved, which the repaint alone
        // does not when a persisted held-back row comes back looking exactly as
        // it did before the tap.
        //
        // `shapeRefusedCount` IS DELIBERATELY NOT READ HERE. What a listing could
        // not hand over is a standing fact about the FOLDER, it is already on its
        // way to the row inside `deliveryOutcome`, and the row states it with the
        // mechanism and the remedy attached. Consulting it on this path is what
        // let a look that handed over eight files pick a state meaning "this look
        // handed over nothing" — and the row that same count guarantees is what
        // then turned that state into "Nothing new came back."
        //
        // `drafts.count`, not an insert tally, because the store skips only a
        // draft whose `storedKey` is ALREADY on the reply — a skip means another
        // device inserted that same file first, so every one of these files is on
        // the row by the time this returns. `inserted` above has already ruled out
        // the case where nothing was written at all.
        outputRecheckStates[message.id] = .delivered(fileCount: drafts.count)
    }

    /// Fold one listing verdict into the observable fault set. Compared before
    /// assigning so a repeat verdict repaints nothing.
    private func applyDiscoveryVerdict(_ verdict: FileServerListingVerdict, to messageID: UUID) {
        switch verdict {
        case .entries, .absent:
            if outputDiscoveryFaultIDs.contains(messageID) {
                outputDiscoveryFaultIDs.remove(messageID)
            }
        case .unusable:
            if !outputDiscoveryFaultIDs.contains(messageID) {
                outputDiscoveryFaultIDs.insert(messageID)
            }
        }
    }

    /// Bulk-resolve a `HeaderIdentity` for every stored conversation the memo
    /// doesn't already know, so the FIRST open of any thread this session
    /// renders the right gateway pill on frame one (the per-VM `reload()` memo
    /// only covers REvisits — without this, every first switch after launch
    /// still flickered "Personal AI"). Called by `MenuBarCoordinator` at launch
    /// and re-run on `.conversationsDidChange` (fills only missing entries —
    /// newly minted/CloudKit-imported rows; visited entries stay authoritative,
    /// owned by their VM's resolve). Mirrors `resolveBackendDisplayName()`'s
    /// three-way ladder. `hasTurns` proxies off `titleSnippet` (written on the
    /// first user turn) — a legacy pre-backfill row degrades to the chevron
    /// popping in after the fetch, never a wrong name.
    static func warmHeaderMemo() async {
        guard let records = try? await ConversationStore.shared.fetchConversations() else { return }
        let customs = await SettingsManager.shared.gatewayBadgeRoster()
        let configured = await SettingsManager.shared.configuredRemoteAgentRefs()
        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        // Availability once per unique backend raw, not per row.
        var availability: [String: Bool] = [:]
        for raw in Set(records.map(\.backend)) where RemoteAgentRef(rawString: raw) != nil {
            availability[raw] = await SettingsManager.shared
                .remoteAgentSnapshot(forConversationBackend: raw) != nil
        }
        for record in records {
            guard headerMemo[record.id] == nil else { continue }
            guard headerMemo.count < headerMemoCap else { break }
            let hasTurns = record.titleSnippet != nil
            if let ref = RemoteAgentRef(rawString: record.backend) {
                headerMemo[record.id] = HeaderIdentity(
                    displayName: RemoteAgentRefMetadata.displayName(for: ref, customs: customs),
                    boundRef: ref,
                    boundGatewayAvailable: availability[record.backend] ?? false,
                    customGateways: customs,
                    configuredRefsForClone: configured,
                    hasTurns: hasTurns
                )
            } else if !configured.isEmpty {
                headerMemo[record.id] = HeaderIdentity(
                    displayName: RemoteAgentRefMetadata.displayName(for: defaultRef, customs: customs),
                    boundRef: nil,
                    boundGatewayAvailable: true,
                    customGateways: customs,
                    configuredRefsForClone: configured,
                    hasTurns: hasTurns
                )
            }
            // else: truly unconfigured — the VM's "Personal AI" default IS the
            // correct render; no entry needed.
        }
    }

    /// Fill the memo for a conversation the app has JUST created — a first-turn
    /// mint or a Clone — from the ref it was created with, BEFORE any VM is bound
    /// to it. `warmHeaderMemo()` structurally cannot cover this case: the row did
    /// not exist the last time it ran, so a just-minted conversation is always a
    /// miss and its pill shows the generic "Personal AI" placeholder for the
    /// length of `resolveBackendDisplayName()`'s hops — while the app already knew
    /// the answer, having just written it into the row.
    ///
    /// `hasTurns` is a PARAMETER, not derived from `titleSnippet != nil` the way
    /// `warmHeaderMemo()` derives it. A clone copies the source's turns but
    /// inherits only its OPTIONAL snippet, and an attachment-only or whitespace
    /// first turn writes none — so a snippet test would report "no turns" for a
    /// clone that has them and pop the chevron in a frame late. Callers pass
    /// `false` for a fresh mint and the source VM's `hasTurns` for a clone.
    ///
    /// Every awaited value is gathered into a local before ANYTHING is published,
    /// so a partially-resolved identity can never become visible. At capacity this
    /// EVICTS rather than skipping — the opposite of `warmHeaderMemo()`, whose
    /// bulk fill deliberately stops when full; this is the one entry that must not
    /// be the one dropped.
    static func seedHeaderIdentity(
        for record: ConversationRecord,
        ref: RemoteAgentRef,
        hasTurns: Bool
    ) async {
        let customs = await SettingsManager.shared.gatewayBadgeRoster()
        let configured = await SettingsManager.shared.configuredRemoteAgentRefs()
        // Availability uses the SAME predicate as `warmHeaderMemo()` and
        // `resolveBackendDisplayName()`, both of which overwrite this entry within
        // a beat. `configuredRemoteAgentRefs().contains(ref)` is stricter (it
        // fails closed on an unreadable token), so seeding from it would render a
        // one-frame "this gateway is no longer available" banner on a thread whose
        // gateway is fine — the inverse of the flicker this seed exists to remove.
        let available = await SettingsManager.shared
            .remoteAgentSnapshot(forConversationBackend: record.backend) != nil
        let identity = HeaderIdentity(
            displayName: RemoteAgentRefMetadata.displayName(for: ref, customs: customs),
            boundRef: ref,
            boundGatewayAvailable: available,
            customGateways: customs,
            configuredRefsForClone: configured,
            hasTurns: hasTurns
        )
        if var existing = headerMemo[record.id] {
            // A `warmHeaderMemo()` that raced the awaits above resolved from the
            // same stored binding, so its name, ref and availability are equally
            // authoritative — leave them. But it DERIVES `hasTurns` from
            // `titleSnippet`, which a clone need not carry, so that one field is
            // ours to correct: otherwise the clone chevron still pops in late on
            // exactly the rows this parameter exists for.
            guard hasTurns, !existing.hasTurns else { return }
            existing.hasTurns = true
            headerMemo[record.id] = existing
            return
        }
        if headerMemo.count >= headerMemoCap, let victim = headerMemo.keys.first {
            headerMemo.removeValue(forKey: victim)
        }
        headerMemo[record.id] = identity
    }

    /// Test seam only — the memo is process-global static, so it outlives an
    /// XCTest case and a full one leaves `warmHeaderMemo()` silently filling
    /// nothing for the rest of the run.
    static func resetHeaderMemoForTesting() {
        headerMemo.removeAll()
    }

    /// Publish the just-resolved header state into the session memo so the NEXT
    /// VM minted for this conversation renders it on frame one. See `headerMemo`.
    private func rememberHeaderIdentity() {
        if Self.headerMemo.count >= Self.headerMemoCap,
           Self.headerMemo[conversationID] == nil,
           let victim = Self.headerMemo.keys.first {
            Self.headerMemo.removeValue(forKey: victim)
        }
        Self.headerMemo[conversationID] = HeaderIdentity(
            displayName: backendDisplayName,
            boundRef: boundRef,
            boundGatewayAvailable: boundGatewayAvailable,
            customGateways: customGateways,
            configuredRefsForClone: configuredRefsForClone,
            hasTurns: !messages.isEmpty
        )
    }

    /// Resolve the display name for the in-flight indicator: names the
    /// conversation's bound backend (the responder). Under per-conversation
    /// routing the turn goes to the conversation's stored `backend`, so its
    /// display name names the real responder. Falls back to the default backend
    /// (e.g. a legacy row with an unknown raw value), then "Personal AI".
    private func resolveBackendDisplayName() async {
        // Cache the roster + configured refs for the thread badge / Clone sheet.
        let customs = await SettingsManager.shared.gatewayBadgeRoster()
        customGateways = customs
        configuredRefsForClone = await SettingsManager.shared.configuredRemoteAgentRefs()

        let conversationRecord = try? await ConversationStore.shared.fetchConversation(id: conversationID)
        // Compat-mode flag for the persistent banner (one fetch, reused
        // for the backend resolution below).
        hideEarlierPhotos = conversationRecord?.hideEarlierPhotos ?? false
        let rawBackend = conversationRecord?.backend
        if let raw = rawBackend, let ref = RemoteAgentRef(rawString: raw) {
            boundRef = ref
            backendDisplayName = RemoteAgentRefMetadata.displayName(for: ref, customs: customs)
            // The bound gateway is available iff its snapshot resolves (token +
            // url present). A deleted custom → nil → recovery banner.
            boundGatewayAvailable = await SettingsManager.shared
                .remoteAgentSnapshot(forConversationBackend: raw) != nil
        } else if !(await SettingsManager.shared.configuredRemoteAgentRefs().isEmpty) {
            // Gate on per-ref CONFIGURED state, NOT the legacy single-slot
            // `getRemoteAgentBackend()` (frozen after migration → nil on a fresh
            // multi-gateway install, which would wrongly fall through to
            // "Personal AI").
            boundRef = nil
            let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
            backendDisplayName = RemoteAgentRefMetadata.displayName(for: defaultRef, customs: customs)
            boundGatewayAvailable = true
        } else {
            boundRef = nil
            backendDisplayName = String(localized: "Personal AI")  // xcstrings: chat-ui
            boundGatewayAvailable = true
        }
        await refreshCurrentFileLaneID()
    }

    /// Re-resolve `currentFileLaneID` from the bound gateway's CURRENT settings.
    /// Reads the READY snapshot (URL + credential present AND the staged test
    /// passed), the same gate every dispatch surface uses — a lane the app would
    /// not dispatch against must not authorise a notice about it either.
    /// The ONE writer of the tracked lane identity pair, and the only place that
    /// decides the pair has moved. Every caller — the header resolution inside
    /// `reload()` and the settings observer alike — goes through here, so a
    /// change can be recorded exactly once no matter which path observes it
    /// first.
    private func refreshCurrentFileLaneID() async {
        let snapshot: SettingsManager.FileTransferSnapshot?
        if let ref = boundRef {
            snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        } else {
            snapshot = nil
        }
        let laneID = snapshot?.durableLaneID
        let signature = snapshot?.identitySignature
        // The FIRST resolution is not a move. Nil is this VM's starting value,
        // so latching on it would make every thread presentation look like the
        // user had just edited their lane.
        if hasResolvedFileLaneIdentity,
           laneID != currentFileLaneID || signature != currentFileLaneSignature {
            fileLaneIdentityMoved = true
        }
        hasResolvedFileLaneIdentity = true
        currentFileLaneID = laneID
        currentFileLaneSignature = signature
    }

    /// Whether this thread ends on a user turn that never got a reply — i.e.
    /// whether cloning it produces a turn someone could choose to send on the
    /// new gateway, which is the only case where the clone sheet asks.
    ///
    /// MUST agree with `ConversationStore.cloneConversation`'s trailing-turn
    /// rule, which is the thing actually producing (or not producing) a
    /// `continuationMessageID`. Disagreement is silent in both directions: ask
    /// without a continuation and "Send now" does nothing; skip the ask and the
    /// user is never offered a send that was available. Hence the same two
    /// clauses, and hence `status != "sent"` rather than a `failed` test —
    /// `sending` and a legacy nil both mean unanswered here.
    ///
    /// Reads the VM's loaded snapshot rather than re-fetching: this is a view
    /// predicate evaluated while the sheet is up, and `messages` is the same
    /// array the thread is already rendering.
    var hasUnansweredTrailingTurn: Bool {
        guard let last = messages.last else { return false }
        return last.role == "user" && last.status != "sent"
    }

    /// Clone this conversation onto `ref` (a chosen configured gateway): create
    /// a new conversation bound to it, copying the history INCLUDING attachments,
    /// and return the new conversation id so the caller can make it active.
    /// Honors the no-silent-reroute invariant — this is an explicit user action,
    /// NOT a rebind of the existing thread (which would hand a different agent a
    /// history it never produced).
    ///
    /// Resolves the TARGET's durable file lane from the RAW snapshot, not the
    /// ready one: readiness gates NEW uploads, and a stale/failed Test
    /// Connection verdict must not detach references to blobs the lane still
    /// physically owns (same posture as `retry`'s `currentRawLane`).
    ///
    /// `continueImmediately` is the user's OWN answer, collected in the clone
    /// sheet before this runs (`hasUnansweredTrailingTurn` decides whether the
    /// question is even asked). It is deliberately not inferred from the source
    /// row's status: both answers are legitimate, and which one a person wants
    /// depends on what they were in the middle of, which the app cannot read.
    ///
    /// When true, the continuation is armed BEFORE returning — the caller
    /// navigates immediately, and arming first is what lets the destination
    /// suppress the failed-row treatment on its very first render instead of
    /// racing it. When false nothing is armed and the cloned turn simply waits
    /// as an ordinary un-replied turn: Try Again fires it on demand, and it
    /// rides along in the history of whatever the user types next.
    func cloneConversation(to ref: RemoteAgentRef, continueImmediately: Bool) async -> UUID? {
        do {
            let targetLaneID = await SettingsManager.shared
                .fileTransferSnapshot(for: ref)?.durableLaneID
            let cloned = try await ConversationStore.shared.cloneConversation(
                id: conversationID,
                toBackend: ref.rawString,
                targetFileLaneID: targetLaneID
            )
            if continueImmediately, let continuationID = cloned.continuationMessageID {
                PendingCloneContinuation.shared.arm(
                    conversationID: cloned.conversation.id,
                    messageID: continuationID
                )
            }
            // Seed BEFORE returning: the caller navigates by posting a deep-link
            // carrying a bare UUID, so the target gateway's identity would
            // otherwise not survive the hop and the clone's pill would open on
            // "Personal AI". `hasTurns` comes from this (the SOURCE) VM — the
            // clone copies its turns, but not necessarily its title snippet.
            await Self.seedHeaderIdentity(
                for: cloned.conversation,
                ref: ref,
                hasTurns: hasTurns
            )
            return cloned.conversation.id
        } catch {
            setSendNotice(String(localized: "remoteAgent.clone.failed",
                               defaultValue: "Couldn't clone this conversation. Try again."))
            return nil
        }
    }

    // MARK: - Send-error banner state

    /// Set the transient send-error banner from a typed error — stores its
    /// user-facing description AND numeric code (drives the Troubleshoot
    /// deep-link into Diagnostics). Use this instead of assigning `sendError`
    /// directly so the message and code can never diverge.
    ///
    /// Cause AND remedy (`descriptionWithRecovery`), matching the failed-turn
    /// row this banner stands in for while that row is offscreen: the two are
    /// the same verdict seen from two scroll positions, so the banner cannot
    /// carry less. It matters most for the failures whose remedy is the whole
    /// point — a certificate the device refused is fixed on the SERVER, and a
    /// pinned key that disagreed with a trusted chain carries an interception
    /// warning that lives only in the remedy half. `descriptionWithRecovery`
    /// drops the generic "Try again." rather than appending it, so a terminal
    /// refusal never gains a retry invitation here.
    func setSendError(_ error: AppError, messageID: UUID? = nil) {
        sendError = error.descriptionWithRecovery(for: boundRef)
        sendErrorCode = error.errorCode
        sendErrorMessageID = messageID
    }

    /// Set the banner to a plain notice with no error taxonomy (e.g. a dropped
    /// attachment) — no Diagnostics code, so the banner shows no Troubleshoot link.
    func setSendNotice(_ message: String) {
        sendError = message
        sendErrorCode = nil
        sendErrorMessageID = nil
    }

    /// Surface a fail-closed composer route/lane rejection without consuming the
    /// draft or staged files. There is deliberately no persisted failed bubble:
    /// local acceptance never happened, so the user can retry the intact
    /// composer after the gateway/file settings settle.
    func reportComposerDispatchRejection() {
        setSendNotice(String(localized: "Couldn't send that message. Try again."))
    }

    /// Clear the banner and its code together.
    func clearSendError() {
        sendError = nil
        sendErrorCode = nil
        sendErrorMessageID = nil
    }

    // MARK: - Mutations

    /// Append a turn to this thread and reload. Returns the persisted record
    /// (callers can use it for optimistic insertion). On store failure the
    /// `.conversationsDidChange` observer still re-syncs the visible thread.
    @discardableResult
    func append(role: String, text: String, sourceDevice: String) async -> MessageRecord? {
        do {
            let record = try await ConversationStore.shared.appendMessage(
                role: role,
                text: text,
                conversationID: conversationID,
                sourceDevice: sourceDevice
            )
            await reload()
            return record
        } catch {
            loadError = String(localized: "Couldn't send that message. Try again.")
            return nil
        }
    }

    // MARK: - Converse (in-app entry 2)

    /// Append a user turn to THIS visible conversation and fire the converse
    /// hop over the background session. The per-device active-conversation
    /// pointer is IMPLICIT-ONLY: stamped only when `stampsQuickPointer` is
    /// true (the quick-capture lane); explicit in-app/window turns never
    /// touch it — the in-app thread appends to the visible conversation
    /// regardless of the pointer/TTL
    /// ("in-app appends to what's on screen"). The optimistic user bubble
    /// appears immediately via the post-append reload; the in-flight indicator
    /// shows until the reply lands (delegate appends the agent bubble +
    /// `.conversationsDidChange` reloads), the turn is cancelled, or it fails.
    ///
    /// RemoteAgent not configured → sets `sendError`, no bubble fired.
    ///
    /// `attachments` (default empty) are processed by the VM into
    /// `AttachmentDraft`s (images via `ImageProcessor` → downsized JPEG +
    /// thumbnail; text files via `TextFileExtractor` → extracted text) before
    /// the optimistic user bubble is written with `status: "sending"`. New-turn
    /// image data-URIs + spliced text-file blocks ride the wire; PRIOR-turn
    /// image bytes are re-resolved from the store via `loadAttachmentData` and
    /// retained in context (no current-turn-only rule). On success the user
    /// bubble flips to `sent`; on failure to `failed` (drives the Retry chip).
    func sendUserTurn(
        _ text: String,
        modality: TurnModality = .voice,
        attachments: [PendingAttachment] = [],
        // Composer-only route seal. When present, the conversation's persisted
        // backend must still equal the gateway captured while staging; a stale
        // picker/default must never reroute stored keys.
        expectedRef: RemoteAgentRef? = nil,
        // Composer-only durable file-lane seal. A landed storedKey may dispatch
        // only while the current configuration still identifies the exact lane
        // that accepted the upload.
        expectedFileLaneID: String? = nil,
        // Called exactly once when supplied: true only after the user turn and
        // all attachment drafts have been durably appended; false on any
        // pre-acceptance rejection/write failure. This lets the composer retain
        // its draft/tiles until local persistence is certain.
        onLocalAcceptance: (@MainActor (Bool) -> Void)? = nil,
        // True ONLY for the implicit quick-capture lane (the Mac hotkey
        // capture): a successful turn then stamps the per-device
        // quick-capture pointer. In-app/window call sites keep the default
        // `false` — explicit surfaces never retarget the quick lane.
        stampsQuickPointer: Bool = false,
        // Per-send speak latch mirroring `stampsQuickPointer`: true ONLY when
        // the macOS quick lane sends with the device-local "speak replies"
        // toggle ON — the reply is then spoken on arrival via `ReplyVoice`.
        // The verdict rides EACH SEND, never VM state, because the
        // coordinator's registry shares ONE VM between popover and main window
        // for the same conversation — a VM-level flag would leak the popover's
        // verdict onto window turns. Window/in-app call sites keep the default
        // `false`: the main-window lane NEVER speaks (hard rule). No-op off
        // macOS.
        speaksReply: Bool = false,
        // Per-send popover-surfacing latch (macOS quick/hotkey lane only): true
        // ONLY for a menu-bar / ⌘⇧1 / ⌘⇧2 capture. The menu-bar popover then
        // shows THIS reply on arrival and retains it for reopen. Window/in-app
        // call sites keep the default `false` — a reply the user is already
        // watching in the main window (or one synced from iPhone/Watch) never
        // populates the popover, even though the registry shares ONE VM between
        // popover and window for the same conversation. Rides EACH SEND (never
        // VM state) for the same reason as `speaksReply`. No-op off macOS.
        surfacesInPopover: Bool = false
    ) async {
        clearSendError()

        #if os(macOS)
        // One in-flight turn per VM on macOS: a 2nd concurrent send would
        // clobber `inFlightTask`, orphaning the first turn's cancel handle (its
        // reply would still land). The composer/popover also disable inputs
        // while `isAwaitingReply`; this is the correctness backstop.
        //
        // Claim the lock SYNCHRONOUSLY on the MainActor before any `await`:
        // `remoteAgentSnapshot()` below is async, so two rapid hotkey captures
        // would otherwise both pass the guard before either sets `inFlightTask`.
        // Setting `isAwaitingReply` here (no await between guard and set) makes
        // the claim atomic; the early no-token return and the `defer` release it.
        guard inFlightTask == nil, !isAwaitingReply else {
            onLocalAcceptance?(false)
            return
        }
        isAwaitingReply = true   // atomic claim on MainActor — no await between guard and set
        #endif

        // Capture the established conversation route ONCE before processing any
        // attachments. Composer sends carry `expectedRef`; generic/legacy sends
        // leave it nil and retain the historical append-then-fail behavior.
        let rawBackend = try? await ConversationStore.shared
            .fetchConversation(id: conversationID)?.backend
        let establishedRef = rawBackend.flatMap(RemoteAgentRef.init(rawString:))
        if let expectedRef, establishedRef != expectedRef {
            #if os(macOS)
            isAwaitingReply = false
            #endif
            reportComposerDispatchRejection()
            onLocalAcceptance?(false)
            return
        }
        // Capture ONE ready physical lane for the entire dispatch. The same
        // immutable snapshot drives storedKey ownership, history mapping,
        // file-delivery instruction, background metadata, and output recovery.
        let dispatchFileLane: SettingsManager.FileTransferSnapshot?
        if let establishedRef {
            dispatchFileLane = await SettingsManager.shared
                .fileTransferReadySnapshot(for: establishedRef)
        } else {
            dispatchFileLane = nil
        }
        if let expectedFileLaneID {
            guard let routeRef = establishedRef,
                  routeRef == expectedRef,
                  let dispatchFileLane,
                  dispatchFileLane.durableLaneID == expectedFileLaneID else {
                #if os(macOS)
                isAwaitingReply = false
                #endif
                reportComposerDispatchRejection()
                onLocalAcceptance?(false)
                return
            }
        }

        // NOTE: full gateway configuration is resolved AFTER the optimistic
        // append below. The composer now waits for the local-acceptance callback
        // before clearing its draft/tiles; once appended, a later routing failure
        // renders the standard failed bubble + Retry chip instead of losing the
        // message.

        // Process staged attachments → drafts + the new-turn wire material
        // (image data-URIs + extracted text-file blocks). Heavy work (image
        // downsize / text decode) runs here off the actor pipelines. The
        // inline-vision long-edge cap is the fixed `ImageProcessor.defaultMaxPixel`
        // (the user-configurable "Max image dimension" setting was removed — the
        // file-transfer route now sends originals, so only the inline copy is
        // capped, at the de-facto vision sweet spot).
        let processed = await Self.processAttachments(attachments)
        let handsOffStoredKeys =
            !processed.serverFileRefs.isEmpty
            || !processed.imageFileRefs.isEmpty
            || !processed.textFileServerRefs.isEmpty
        if handsOffStoredKeys, dispatchFileLane == nil {
            #if os(macOS)
            isAwaitingReply = false
            #endif
            reportComposerDispatchRejection()
            onLocalAcceptance?(false)
            return
        }
        if processed.droppedCount > 0 {
            // Honest notice — the user saw these chips in the staging strip;
            // the turn still ships with whatever processed cleanly. Non-fatal:
            // `sendError` doubles as the thread's notice banner and clears on
            // the next send.
            setSendNotice(String(localized: LocalizedStringResource(
                "send.attachment.dropped",
                defaultValue: "An attachment couldn't be read and wasn't included."
            )))  // xcstrings: hardening
        }

        // Optimistic user bubble — append + reload so it shows the instant STT
        // completes, before/while the agent request is in flight. The modality
        // suffix (`-voice` / `-text`) lets the footer chip render a subtle
        // modality glyph; the base device value stays intact for the device map.
        // The turn is written `status: "sending"` so the footer shows a spinner
        // until the reply lands (→ `sent`) or it fails (→ `failed`).
        let userSourceDevice = "\(SourceDevice.current)-\(modality.rawValue)"
        let userRecord: MessageRecord?
        do {
            userRecord = try await ConversationStore.shared.appendMessage(
                role: "user",
                text: text,
                conversationID: conversationID,
                sourceDevice: userSourceDevice,
                status: "sending",
                fileTransferLaneID: handsOffStoredKeys
                    ? dispatchFileLane?.durableLaneID
                    : nil,
                attachments: processed.drafts
            )
            await reload()
        } catch {
            loadError = String(localized: "Couldn't send that message. Try again.")
            userRecord = nil
        }
        guard let userRecord else {
            #if os(macOS)
            isAwaitingReply = false   // release the synchronous claim; no Task spawned yet
            #endif
            onLocalAcceptance?(false)
            return
        }
        let userMessageID = userRecord.id
        onLocalAcceptance?(true)

        // Notification auth (plan D4b) — iOS only. The user has committed a
        // FOREGROUND in-app composer send; request notification permission now
        // if still `.notDetermined` so a later reply/failure notification isn't
        // silently dropped. Idempotent + non-blocking: a no-op once determined,
        // never gates the send on the outcome. Honors an explicit Setup Guide
        // "Not now" (this low-urgency, user-is-watching path doesn't re-pop the
        // dialog; the genuinely-headless backstops still ask).
        //
        // macOS is deliberately EXCLUDED *here*, not app-wide: it owns the same
        // prompt at its own committed-dispatch points
        // (`MenuBarCoordinator.requestNotificationPermissionIfNeeded`), which is
        // where a Mac send is actually committed. Asking from this window path
        // too would only re-pop the same dialog. (The Share path keeps its own
        // prompt in `SharedInboxDrainer`.)
        #if !os(macOS)
        if !NotificationPermissions.isNotificationsDeferred {
            await NotificationPermissions.ensureRequested()
        }
        #endif

        if stampsQuickPointer {
            // Record this turn's quick-lane provenance BEFORE dispatch so a
            // later `retry()` of this exact message inherits it (see
            // `quickStampMessageIDs`).
            quickStampMessageIDs.insert(userMessageID)
        }
        #if os(macOS)
        if speaksReply {
            // Record this turn's speak verdict BEFORE dispatch — same
            // lifecycle as `quickStampMessageIDs` above: a later `retry()` of
            // this exact message inherits it; ids unknown to the set fail-safe
            // to SILENT (see `speakMessageIDs`).
            speakMessageIDs.insert(userMessageID)
        }
        if surfacesInPopover {
            // Record this turn's popover-surfacing verdict BEFORE dispatch so a
            // later `retry()` of this exact message inherits it (see
            // `popoverReplyMessageIDs`).
            popoverReplyMessageIDs.insert(userMessageID)
        }
        #endif

        // Route by THIS conversation's bound backend (per-conversation routing),
        // NOT the global default. Read the persisted `Conversation.backend` and
        // resolve its per-backend snapshot. A nil snapshot means the bound
        // backend is unknown OR unconfigured → surface `remoteAgentNotConfigured`
        // (Decision B: no silent reroute to the default gateway). Keyless
        // (`.none`) sends with no token; `.bearer` requires a non-empty token —
        // a nil/empty token (e.g. a transient Keychain read failure) FAILS
        // CLOSED rather than silently sending unauthenticated. Either failure
        // flips the just-appended turn to `failed` (Retry chip) — the text is
        // never lost.
        let resolvedSnapshot = await SettingsManager.shared.remoteAgentSnapshot(forConversationBackend: rawBackend ?? "")
        let resolvedToken = resolvedSnapshot?.token ?? ""
        guard let snapshot = resolvedSnapshot,
              !(snapshot.authScheme.requiresToken && resolvedToken.isEmpty) else {
            #if os(macOS)
            isAwaitingReply = false   // release the synchronous claim on early return
            #endif
            // EXACT-message flip (the id is in hand — the conversation-wide
            // writer could alias a concurrent sibling turn) + the failure
            // classification so the inline row explains the failure after
            // relaunch. Pre-dispatch: no request was assembled, history fact
            // unknown → nil.
            await ConversationStore.shared.failTurn(
                messageID: userMessageID,
                classification: .init(
                    failureCode: AppError.remoteAgentNotConfigured.errorCode,
                    wireCode: nil,
                    hadHistoryImages: nil
                )
            )
            await reload()
            setSendError(.remoteAgentNotConfigured, messageID: userMessageID)
            return
        }
        let token = resolvedToken

        // Prior turns (excluding the just-appended user turn) with each prior
        // turn's image bytes resolved into data-URIs — images are RETAINED in
        // context (locked image-context decision — no current-turn-only rule) —
        // plus the bound ref's image-history policy, all owned by the
        // shared assembler (the single history choke point across the six
        // converse surfaces). `try?` preserves this path's non-throwing posture
        // (a store hiccup sends with empty history rather than failing the turn).
        let priorTurns = (try? await ConversationHistoryAssembler.assemble(
            conversationID: conversationID,
            excludingUserMessageID: userMessageID,
            excludingNewUserText: text,
            boundRef: RemoteAgentRef(rawString: rawBackend ?? ""),
            dispatchFileLaneID: dispatchFileLane?.durableLaneID
        )) ?? []
        // Dispatch-time fact for the failure classification: does THIS
        // request carry historical image parts? (Post-policy, post-compat —
        // exactly what actually goes on the wire.)
        let requestHadHistoryImages = ConverseRequest.containsImageParts(priorTurns)

        let newUserImageDataURIs = processed.imageDataURIs
        let newUserTextFileBlocks = processed.textFileBlocks
        let newUserServerFileRefs = processed.serverFileRefs
        let newUserImageFileRefs = processed.imageFileRefs
        let newUserTextFileServerRefs = processed.textFileServerRefs

        // Enter in-flight state — drives the answering indicator + elapsed clock
        // here, and claims the conversation in `InFlightTurnRegistry` so the list
        // row, the quit guard, and any VM minted for this thread later see the
        // same turn.
        beginInFlight()
        #if !os(macOS)
        // macOS already claimed `isAwaitingReply` synchronously at the top (race
        // guard); only the non-macOS path sets it here.
        isAwaitingReply = true
        #endif

        #if os(macOS)
        // macOS: FOREGROUND `RemoteAgentClient` (the
        // menu-bar app stays alive; no background URLSession). The in-flight
        // `Task` is held by this long-lived VM (owned by `MenuBarCoordinator`)
        // so popover teardown during the agent wait does NOT cancel it; only
        // `cancelInFlight()` cancels via `inFlightTask?.cancel()`. The VM (not
        // a delegate) appends the agent reply + stamps the quick-capture
        // pointer (quick-lane turns only) + posts `.conversationsDidChange`
        // (via `append`).
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isAwaitingReply = false
                self.endInFlight()
                self.inFlightTask = nil
            }
            do {
                // READY lane on the bound gateway → the per-turn file-delivery
                // instruction rides (mirrors `BackgroundRemoteAgent.send`,
                // which derives this internally; the foreground client can't —
                // it has no ref — so the macOS paths derive at the call site).
                if let dispatchFileLane {
                    guard await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: snapshot.ref,
                        snapshot: dispatchFileLane
                    ) else {
                        throw AppError.fileTransferNotConfigured
                    }
                }
                // Name THIS dispatch's output folder and witness that it is not
                // there yet. AFTER the lane revalidation above, so the folder is
                // named on the lane this send actually uses. No folder (no ready
                // lane, a lane that cannot answer a PROPFIND at all, or an
                // unwitnessed absence) → no location line and no automatic
                // delivery for this turn; the same value is persisted with the
                // reply below, so the wire and the row can never disagree about
                // which folder was promised.
                //
                // The OUTCOME is not read here even though it is available: what
                // the thread says about a folder-less turn is derived from the
                // lane's live witness health at paint time (see
                // `outputFolderUnnamedIDs`), NOT threaded from the dispatch. It
                // has to be — on iOS the reply is landed by a background
                // delegate in a process this view model never sees, so a row
                // that only appeared where the VM dispatched itself would be
                // missing on the platform that needs it most, and two mechanisms
                // for one row is how they drift.
                let outboxKey = await BackgroundFileTransfer.mintOutboxKey(
                    conversationID: conversationID,
                    snapshot: dispatchFileLane
                ).key
                // Pinning session for the LIVE hop. The pin is resolved from the
                // DISPATCHED ref here, at send time, from the durable store —
                // never captured earlier in the turn — so a re-pin between
                // compose and send is honoured. `URLSession.shared` must never
                // carry this send: it cannot hold a delegate, so the user's pin
                // (and the cross-host-redirect refusal) would be a no-op on
                // macOS while Settings' Test Connection still pinned.
                // Session ownership: created and invalidated INSIDE this
                // `do` block, so the `defer` runs only after the send (and the
                // landing below) has finished — a `defer` outside the awaiting
                // scope would tear down a healthy in-flight turn.
                let (pinnedSession, trustEvaluator) = RemoteAgentClient.makePinnedForegroundSession(
                    pinnedFingerprintHex: RemoteAgentTrustEvaluator.storedConversePin(for: snapshot.ref)
                )
                defer { pinnedSession.invalidateAndCancel() }
                // Captured HERE, at dispatch, alongside the ref and pin already
                // read at send time — never at landing. A turn can run for
                // minutes and the user can edit the gateway meanwhile; a
                // landing-time read would credit the NEW configuration with the
                // OLD one's success. Built from `snapshot`'s own values for the
                // same reason one step earlier: the snapshot is what the request
                // below actually carries, so a fresh settings read here could
                // describe a gateway this turn never touched.
                let dispatchChatSignature = await SettingsManager.shared.gatewayChatSuccessSignature(
                    for: snapshot.ref,
                    url: snapshot.url,
                    authScheme: snapshot.authScheme,
                    model: snapshot.model
                )
                let reply = try await RemoteAgentClient.shared.send(
                    backend: snapshot.backend,
                    url: snapshot.url,
                    token: token,
                    authScheme: snapshot.authScheme,
                    model: snapshot.model,
                    priorTurns: priorTurns,
                    newUserText: text,
                    newUserImageDataURIs: newUserImageDataURIs,
                    newUserTextFileBlocks: newUserTextFileBlocks,
                    newUserServerFileRefs: newUserServerFileRefs,
                    newUserImageFileRefs: newUserImageFileRefs,
                    newUserTextFileServerRefs: newUserTextFileServerRefs,
                    fileServerReady: dispatchFileLane != nil,
                    outboxKey: outboxKey,
                    transport: .pinned(session: pinnedSession, evaluator: trustEvaluator)
                )
                // Cooperative-cancel check: a Cancel tapped between the reply
                // landing and this point should drop the reply.
                guard !Task.isCancelled else { return }
                // Persist the reply + sent flip FIRST and release the awaiting UI
                // before output-file probes begin. The slow, optional detector
                // patches chips onto the durable bubble asynchronously.
                _ = try await self.landMacForegroundReply(
                    reply: reply,
                    userMessageID: userMessageID,
                    dispatchRef: snapshot.ref,
                    dispatchFileLane: dispatchFileLane,
                    // The SAME folder the wire named — never a second mint.
                    outputBoxKey: outboxKey,
                    dispatchChatSignature: dispatchChatSignature,
                    stampsQuickPointer: stampsQuickPointer,
                    surfacesInPopover: surfacesInPopover,
                    speaksReply: speaksReply
                )
            } catch is CancellationError {
                // User cancelled — leave the user bubble; no agent bubble. Flip
                // the turn to `failed` (Retry chip): the macOS foreground path
                // has no background delegate to do it, and `sending` would
                // strand until the launch sweep (mirrors the iOS delegate's
                // live-cancel flip). STATUS-ONLY (guarded to `sending` rows):
                // a cancel is not a gateway verdict, so any pre-existing
                // classification stays and no new one is written.
                await ConversationStore.shared.markPendingUserTurn(messageID: userMessageID, to: "failed")
            } catch {
                // Terminal failure (body-classified carrier, bare AppError, or
                // anything else) — ONE shared handler persists the
                // classification (wire code included when the gateway sent
                // one) + raises the banner. `hadHistoryImages` was computed
                // from the ACTUAL assembled request at dispatch.
                await self.recordSendFailure(error, userMessageID: userMessageID, requestHadHistoryImages: requestHadHistoryImages)
            }
        }
        inFlightTask = task
        await task.value
        #else
        defer {
            isAwaitingReply = false
            endInFlight()
        }

        do {
            _ = try await BackgroundRemoteAgent.shared.send(
                backend: snapshot.backend,
                ref: snapshot.ref,
                url: snapshot.url,
                token: token,
                authScheme: snapshot.authScheme,
                model: snapshot.model,
                priorTurns: priorTurns,
                newUserText: text,
                newUserImageDataURIs: newUserImageDataURIs,
                newUserTextFileBlocks: newUserTextFileBlocks,
                newUserServerFileRefs: newUserServerFileRefs,
                newUserImageFileRefs: newUserImageFileRefs,
                newUserTextFileServerRefs: newUserTextFileServerRefs,
                inputFileTransferSnapshot: dispatchFileLane,
                fileTransferSnapshot: dispatchFileLane,
                conversationID: conversationID,
                // EXACT per-message status flips in the background delegate (a
                // conversation-wide flip would alias a concurrent sibling
                // turn's status — e.g. a long headless think in this thread).
                userMessageID: userMessageID,
                // Implicit-only pointer: in-app call sites never pass true, so
                // an iOS in-app turn never stamps; the delegate stamps only
                // when this rides true (quick-capture lane).
                stampsActiveConversation: stampsQuickPointer
            )
            // Success resolves only AFTER the delegate's atomic
            // reply-insert + user-sent transaction persisted. The caller never
            // writes `sent` independently: that could expose a delivered user
            // bubble with no assistant reply after a store failure.
            // Terminal success — drop the provenance entry (a `failed` turn
            // would keep it for retry).
            quickStampMessageIDs.remove(userMessageID)
        } catch is CancellationError {
            // User cancelled — drop the indicator, leave the user bubble, no
            // agent bubble. The delegate's live-cancel path flips the turn to
            // `failed` (Retry chip) — nothing to do here.
        } catch {
            // Terminal failure — the shared handler. The background delegate
            // ALSO persists its classification (authoritative writer); the
            // guarded `failTurn` transition makes the two writes converge on
            // the richest classification regardless of order.
            await recordSendFailure(error, userMessageID: userMessageID, requestHadHistoryImages: requestHadHistoryImages)
        }
        #endif
    }

    /// Start the full send in a retained task, but return to the composer as
    /// soon as local persistence accepts (or rejects) the turn. The network
    /// reply continues under this long-lived VM's existing in-flight ownership.
    func submitUserTurnAwaitingLocalAcceptance(
        _ text: String,
        modality: TurnModality = .text,
        attachments: [PendingAttachment],
        expectedRef: RemoteAgentRef,
        expectedFileLaneID: String?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                await self.sendUserTurn(
                    text,
                    modality: modality,
                    attachments: attachments,
                    expectedRef: expectedRef,
                    expectedFileLaneID: expectedFileLaneID,
                    onLocalAcceptance: { accepted in
                        continuation.resume(returning: accepted)
                    }
                )
            }
        }
    }

    // MARK: - Attachment processing + retry

    /// Result of processing staged attachments: the persistable drafts (full
    /// bytes, written to the store) + the new-turn wire material (image
    /// data-URIs + fenced text-file blocks). Image processing failures are
    /// dropped silently per-item (a sibling failing must not sink the turn);
    /// the UI layer surfaces per-tile errors before send.
    /// `nonisolated` + `Sendable` explicitly, not incidentally: this is the value
    /// `processAttachments` hands back ACROSS an actor boundary, so the boundary
    /// should be stated in the type rather than inferred. Without `nonisolated`
    /// the target's MainActor default isolation would make it main-actor-bound
    /// and the `@concurrent` producer could not construct it at all.
    private nonisolated struct ProcessedAttachments: Sendable {
        var drafts: [AttachmentDraft] = []
        var imageDataURIs: [String] = []
        var textFileBlocks: [(filename: String, text: String)] = []
        /// New-turn server-file references (file-transfer route): the original
        /// name + the storedKey the eager upload minted. Spliced into the new
        /// user turn's text as the "saved as <storedKey>" wire line (NOT a
        /// content part — the bytes already live in the agent's working folder).
        var serverFileRefs: [(originalName: String, storedKey: String)] = []
        /// New-turn DUAL-IMAGE server references (this-turn-only): the storedKey
        /// + display filename of each composer image whose eager upload landed
        /// (the user's own name, or the numbered `image…` fallback — see
        /// `ComposerImageName`). Spliced into the new user turn's text as the "also saved
        /// as <filename> (<storedKey>)" image line ALONGSIDE the inline
        /// `imageDataURIs` (vision sees the downsized JPEG; the uploaded file is
        /// the original). EPHEMERAL — never persisted on the draft (the image
        /// draft stays a plain inline image); the ref is spliced on THIS turn only
        /// and not re-spliced on later turns. An image whose upload hadn't landed
        /// contributes a data-URI (inline vision) but NO entry here (inline-only).
        var imageFileRefs: [(storedKey: String, filename: String)] = []
        /// New-turn DUAL-TEXT server references (this-turn-only): the original
        /// name + the storedKey of each composer text file whose eager upload
        /// landed. Spliced into the new user turn's text as the dual-text "also
        /// saved as <storedKey>" line ALONGSIDE the inline fenced block (the agent
        /// reads the pasted text AND can operate on the real file). EPHEMERAL on
        /// the wire — spliced on THIS turn only; on later turns `priorTurns`
        /// re-derives the disk ref from the persisted `storedKey` (and drops the
        /// inline fence). A dual-text file whose upload hadn't landed contributes
        /// an inline `textFileBlocks` entry but NO entry here (inline-only).
        var textFileServerRefs: [(originalName: String, storedKey: String)] = []
        /// Items that failed send-time processing (image decode / text
        /// extraction) and were skipped. The turn still ships — but the caller
        /// surfaces an honest notice instead of silently dropping a chip the
        /// user saw in the strip.
        var droppedCount = 0
    }

    /// Run images through `ImageProcessor` (downsize + EXIF/GPS strip → JPEG +
    /// thumbnail) and text files through `TextFileExtractor`, building drafts +
    /// wire material in staged order.
    ///
    /// `@concurrent` — and it has to be. This type is `@MainActor`, and under the
    /// target's `SWIFT_APPROACHABLE_CONCURRENCY` a bare `nonisolated async`
    /// static runs on the CALLER's executor, which here is the main actor. So
    /// the annotation that used to be here moved nothing: the base64 encoding of
    /// every image, `TextFileExtractor`'s whole-file read + UTF-8 decode, and the
    /// per-file `resourceValues` stats all ran on the main actor while the user
    /// was waiting for the composer to clear. (The image downsize itself was
    /// always fine — `ImageProcessor` is an actor and the `await` genuinely
    /// hops.) `@concurrent` is the only spelling that reaches the generic
    /// executor.
    @concurrent
    private nonisolated static func processAttachments(
        _ attachments: [PendingAttachment],
        maxPixel: Int = ImageProcessor.defaultMaxPixel
    ) async -> ProcessedAttachments {
        var result = ProcessedAttachments()
        var sequence = 0

        for attachment in attachments {
            switch attachment {
            case .image(let data):
                guard let processed = try? await ImageProcessor.shared.process(data, maxPixel: maxPixel) else {
                    result.droppedCount += 1
                    continue   // per-item failure — skip, don't sink the turn
                }
                result.drafts.append(
                    AttachmentDraft(
                        mimeType: "image/jpeg",
                        data: processed.jpegData,
                        thumbnailData: processed.thumbnailData,
                        width: processed.width,
                        height: processed.height,
                        byteSize: processed.byteSize,
                        sequence: sequence
                    )
                )
                result.imageDataURIs.append(DataURIBuilder.jpegDataURI(from: processed.jpegData))
                sequence += 1

            case .dualImage(let processedJPEG, let thumbnail, let width, let height, let byteSize, let storedKey, let filename):
                // Dual-route image: the host ALREADY processed this image once at
                // staging (downsized + EXIF/GPS-stripped JPEG, the INLINE copy)
                // and eagerly uploaded the ORIGINAL RAW bytes (true format) — NOT
                // these processed bytes. We must NOT re-process — build the inline
                // data-URI directly from `processedJPEG` (the vision copy). Persist
                // an INLINE image draft that ALSO carries the upload `storedKey`
                // (Phase A): `isServerReference` STAYS false (the bytes are present
                // inline; this is NOT a download-chip server reference) but the
                // `storedKey` is persisted so a LATER turn — once this image ages
                // past the bound gateway's `ImageHistoryPolicy` inline window —
                // can splice an imperative file reference instead of re-shipping
                // the full base64 every turn (Phase C). The semantic discriminator
                // everywhere is `isServerReference` / `isServerFile`, NEVER
                // `storedKey != nil`, so a dual image with a `storedKey` still
                // renders as an inline image, never a download chip, and is never
                // retry-probed as a server file. If the eager upload landed
                // (`storedKey != nil`), ALSO record the ephemeral image file-ref so
                // THIS turn carries the "also saved as <filename>" line alongside
                // the inline bytes; if not (nil), the image rides inline-only (Send
                // was never gated on the upload, and no key is persisted).
                var dualDraft = AttachmentDraft(
                    mimeType: "image/jpeg",
                    filename: filename,
                    data: processedJPEG,
                    thumbnailData: thumbnail,
                    width: width,
                    height: height,
                    byteSize: byteSize,
                    sequence: sequence
                )
                // Persist the upload key on the INLINE image (isServerReference
                // stays false). nil when the eager upload hadn't landed by send
                // time → inline-only, no later reference possible (correct).
                dualDraft.storedKey = storedKey
                result.drafts.append(dualDraft)
                result.imageDataURIs.append(DataURIBuilder.jpegDataURI(from: processedJPEG))
                if let storedKey {
                    result.imageFileRefs.append((storedKey: storedKey, filename: filename))
                }
                sequence += 1

            case .textFile(let url):
                guard let extracted = try? TextFileExtractor.extract(from: url),
                      let textData = extracted.text.data(using: .utf8) else {
                    result.droppedCount += 1
                    continue
                }
                result.drafts.append(
                    AttachmentDraft(
                        mimeType: extracted.mimeType,
                        filename: extracted.filename,
                        data: textData,
                        thumbnailData: nil,
                        width: 0,
                        height: 0,
                        byteSize: textData.count,
                        sequence: sequence
                    )
                )
                result.textFileBlocks.append((filename: extracted.filename, text: extracted.text))
                sequence += 1

            case .dualText(_, let extractedText, let filename, let mimeType, let storedKey):
                // Dual-route text file: the host ALREADY extracted the text once at
                // staging (the bound gateway has a file-server) and eagerly uploaded
                // the ORIGINAL raw file bytes — NOT these extracted bytes. We must
                // NOT re-extract — build the inline fenced block directly from
                // `extractedText`. Persist an INLINE text draft that ALSO carries
                // the upload `storedKey`: `isServerReference` STAYS false (the bytes
                // are present inline as `data`; this is NOT a download-chip server
                // reference), but the `storedKey` is persisted so a LATER turn can
                // splice an imperative disk reference instead of re-shipping the
                // fenced text every turn (`priorTurns` branches on
                // `isText && storedKey != nil`). The semantic discriminator
                // everywhere is `isServerReference`/`isServerFile`, NEVER
                // `storedKey != nil`, so a dual-text draft stays `isText == true`,
                // still inlines its `extractedText`, and is never retry-probed as a
                // server file. If the eager upload landed (`storedKey != nil`), ALSO
                // record the ephemeral text file-ref so THIS turn carries the "also
                // saved as <storedKey>" line alongside the fenced block; if not
                // (nil), the file rides inline-only (Send was never gated on the
                // upload, and no key is persisted).
                guard let textData = extractedText.data(using: .utf8) else {
                    result.droppedCount += 1
                    continue
                }
                var dualDraft = AttachmentDraft(
                    mimeType: mimeType,
                    filename: filename,
                    data: textData,
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: textData.count,
                    sequence: sequence
                )
                // Persist the upload key on the INLINE text draft (isServerReference
                // stays false). nil when the eager upload hadn't landed by send time
                // → inline-only, no later reference possible (correct).
                dualDraft.storedKey = storedKey
                result.drafts.append(dualDraft)
                result.textFileBlocks.append((filename: filename, text: extractedText))
                if let storedKey {
                    result.textFileServerRefs.append((originalName: filename, storedKey: storedKey))
                }
                sequence += 1

            case .serverFile(let url, let originalName, let mimeType, let storedKey):
                // File-transfer route: the bytes are ALREADY on the user's
                // gateway file-server (the host uploaded eagerly on attach), so
                // we never run ImageProcessor / TextFileExtractor here. Persist a
                // server-reference draft (empty `data`; `byteSize` from the
                // source file for display) + record the wire ref. `data: Data()`
                // is deliberate — the draft carries NO local bytes; the store
                // skips decoding it for a server reference.
                var draft = AttachmentDraft(
                    mimeType: mimeType,
                    filename: originalName,
                    data: Data(),
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    sequence: sequence
                )
                draft.isServerReference = true
                draft.storedKey = storedKey
                result.drafts.append(draft)
                result.serverFileRefs.append((originalName: originalName, storedKey: storedKey))
                sequence += 1
            }
        }

        return result
    }

    // MARK: - File transfer (server-file upload helpers)

    /// Upload `localURL`'s bytes to the bound gateway's file-server as
    /// `storedKey`, forwarding determinate progress via `onProgress` (0...1).
    /// Called by the composer host the instant a file is staged (eager-on-attach)
    /// so the turn can dispatch the moment every upload has landed.
    ///
    /// Resolves the file-server snapshot for `ref`; a missing/unconfigured
    /// file-server throws `fileTransferNotConfigured` (the composer should only
    /// offer "Add file" when a snapshot exists, but this is the correctness
    /// backstop). Throws the `.fileTransfer*` family on a transport / HTTP
    /// failure — the staged tile flips to `.failed` (visible Retry; NO silent
    /// retry).
    ///
    /// GOTCHA (load-bearing): `BackgroundFileTransfer.uploadFile` DELETES the URL
    /// it is handed (its `defer { removeItem }` reclaims the upload body after
    /// enqueue). So we copy `localURL` to a THROWAWAY temp file and hand the
    /// background driver the COPY — the staged source `url` survives intact for
    /// `processAttachments` (which reads its file size) and for a later Retry
    /// (which re-uploads from the same source).
    /// STATIC (no instance state): the upload needs only the ref's snapshot, so a
    /// VM-less composer (brand-new conversation before its first turn) can stage +
    /// eager-upload a server file too — its key is minted under the composer's
    /// `pendingConversationID`, the identifier the row it creates then adopts, so
    /// that first turn's files are already in the folder that conversation owns.
    static func uploadServerFile(
        localURL: URL,
        storedKey: String,
        snapshot: SettingsManager.FileTransferSnapshot,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        // Copy to a throwaway temp file because the background driver deletes the
        // URL it's given; the staged source URL must survive for draft-build +
        // retry.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-ftupload-\(UUID().uuidString)")
        // The copy is INSIDE the cleanup scope, not before it. A `copyItem` that
        // throws part-way can still leave a partial destination behind, and a
        // cleanup that only begins after the copy returned would strand it in
        // the temp directory. The cancellation re-check sits here too: the copy
        // now suspends (it hops off the main actor), so a Stop can land during
        // it, and without this the upload would proceed anyway.
        do {
            try await copyForUpload(from: localURL, to: tmp)
            try Task.checkCancellation()
            try await BackgroundFileTransfer.shared.uploadFile(
                localURL: tmp,
                snapshot: snapshot,
                storedKey: storedKey,
                onProgress: onProgress
            )
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// The staging copy for an upload, OFF the main actor.
    ///
    /// `@concurrent` is load-bearing, not tidiness. This type is `@MainActor`, so
    /// a plain `static func` — even an `async` one — inherits that isolation, and
    /// under the target's `SWIFT_APPROACHABLE_CONCURRENCY` a bare `nonisolated
    /// async` would too (it runs on the CALLER's executor). `copyItem` is a
    /// synchronous whole-file byte copy: the source here is the user's ORIGINAL
    /// picked file — a camera HEIC/ProRAW or an arbitrarily large binary, bounded
    /// only by `Constants.fileTransferSoftConfirmBytes` — so on the main actor it
    /// blocks the composer for as long as the copy takes. `@concurrent` is the
    /// only annotation that actually moves it to the generic executor.
    @concurrent
    private nonisolated static func copyForUpload(from source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Best-effort delete of an orphaned uploaded file (e.g. the user removed /
    /// X-cancelled a staged tile AFTER its upload had already landed). Resolves
    /// the file-server snapshot for `ref` and issues a best-effort DELETE; a
    /// missing snapshot or a server-side failure is silently ignored — an orphan
    /// blob on the user's own server is harmless and never blocks anything.
    /// STATIC (no instance state) so the VM-less composer can clean up too.
    static func deleteOrphanServerFile(
        storedKey: String,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async {
        await BackgroundFileTransfer.shared.deleteFile(snapshot: snapshot, storedKey: storedKey)
    }

    /// Re-fire a failed user turn using its STORED content (text + persisted
    /// attachments) — no re-processing of source files (the bytes are already
    /// in the store). Flips the turn back to `sending`, re-resolves prior-turn
    /// + this-turn image data-URIs from the store, and re-sends.
    ///
    /// Only `user` turns with `status == "failed"` are retryable; anything else
    /// is a no-op.
    func retry(_ message: MessageRecord, omittingPhotos: Bool = false) async {
        guard message.role == "user", message.status == "failed" else { return }
        // A plain re-fire of a TERMINAL failure sends the identical request into
        // the identical refusal — a certificate this device won't accept, a
        // rejected token, a URL that isn't an AI endpoint. The affordance is
        // gated where it's offered, so reaching here on a terminal code means a
        // caller that gates only on role/status; re-assert the stored verdict
        // rather than burn a request or no-op silently under the user's tap.
        //
        // `omittingPhotos` is EXEMPT: dropping the photo makes it a materially
        // different request, which is the whole point of "Resend without photo"
        // on a photo decline — a verdict about the photo cannot govern a send
        // that no longer carries one.
        if !omittingPhotos, let failureCode = message.failureCode {
            let storedFailure = AppError.from(errorCode: failureCode, message: nil)
            guard storedFailure.isRetryable else {
                setSendError(storedFailure, messageID: message.id)
                return
            }
        }
        clearSendError()

        #if os(macOS)
        guard inFlightTask == nil, !isAwaitingReply else { return }
        isAwaitingReply = true
        #endif

        // ATOMIC retry claim, FIRST — before any await below. The CAS
        // (`failed` → `sending`) makes two rapid taps — or "Try again" racing
        // "Resend without photo" — dispatch exactly once: the loser sees the
        // status already claimed and aborts (fail-fast, no silent retry). The
        // stored failure classification is KEPT by the claim (frozen rule:
        // cleared only on success); the early-return paths below flip back
        // with the status-only writer so it survives a failed pre-flight.
        guard await ConversationStore.shared.beginRetry(messageID: message.id) else {
            #if os(macOS)
            isAwaitingReply = false
            #endif
            return
        }
        // CLAIM THE TURN AT THE CAS, not at the dispatch far below. A retry
        // re-uses the ORIGINAL message row and `beginRetry` writes only the
        // status column — `createdAt` still says 09:00 for a turn re-fired at
        // 11:00. So from the instant that row reads `sending` again, every
        // surface resolving delivery state from the aggregate sees an unresolved
        // turn two hours old, and without a local claim the resolver returns
        // `.working(.stale)`: this device would render the static "No reply yet"
        // mark over its own live request, for the whole pre-flight (which
        // includes network `probeExists` round-trips). Claiming here also closes
        // the window in which the composer still offered Send for a turn already
        // dispatching. EVERY early return below releases it.
        //
        // SPEND THE FAILURE ACKNOWLEDGEMENT HERE TOO, for the same `createdAt`
        // reason. The stamp the list compares an acknowledgement against is that
        // same frozen `createdAt`, so it does not advance across a retry: if
        // this turn fails again, an acknowledgement taken before the retry would
        // still cover it and the row would never go red — silently, for every
        // re-failure that turn ever has, and `markFailureSeen` is monotone so
        // nothing would undo it. Asking again is also the clearest statement a
        // user can make that they have NOT finished with this failure.
        ReadStateStore.shared.clearFailureSeen(conversationID)
        beginInFlight()
        await reload()

        // Route the retry by THIS conversation's bound backend (per-conversation
        // routing — NOT the global default; same resolution as `sendUserTurn`).
        // A nil snapshot → `remoteAgentNotConfigured` (no silent reroute).
        let rawBackend = try? await ConversationStore.shared.fetchConversation(id: conversationID)?.backend
        guard let snapshot = await SettingsManager.shared.remoteAgentSnapshot(forConversationBackend: rawBackend ?? "") else {
            #if os(macOS)
            isAwaitingReply = false
            #endif
            // Drop the registry claim taken at the CAS — this turn never
            // dispatched, so no surface may keep showing it as live.
            endInFlight()
            // Release the retry claim STATUS-ONLY (keeps the stored
            // classification — the original failure reason still explains
            // the row; this pre-flight never reached the gateway).
            await ConversationStore.shared.markPendingUserTurn(messageID: message.id, to: "failed")
            await reload()
            setSendError(.remoteAgentNotConfigured, messageID: message.id)
            return
        }
        // Keyless (`.none`) sends with no token; `.bearer` requires a non-empty
        // token — a nil/empty token (e.g. a transient Keychain read failure)
        // FAILS CLOSED rather than silently sending unauthenticated.
        let token = snapshot.token ?? ""
        if snapshot.authScheme.requiresToken, token.isEmpty {
            #if os(macOS)
            isAwaitingReply = false
            #endif
            endInFlight()
            await ConversationStore.shared.markPendingUserTurn(messageID: message.id, to: "failed")
            await reload()
            setSendError(.remoteAgentNotConfigured, messageID: message.id)
            return
        }

        // Existing blobs and NEW output promises have deliberately different
        // gates. A failed/stale readiness verdict must not brick a key already
        // owned by this turn, so existing inputs resolve from the RAW saved
        // snapshot and require the exact persisted durable lane. New output
        // delivery remains READY-only.
        let currentRawLane = await SettingsManager.shared
            .fileTransferSnapshot(for: snapshot.ref)
        let readyOutputLane = currentRawLane?.available == true
            ? currentRawLane
            : nil
        let hasPersistedStoredKeys =
            RetryFileReferenceResolver.hasRequiredStoredKeys(
                message,
                omittingPhotos: omittingPhotos
            )
        let existingInputLane: SettingsManager.FileTransferSnapshot?
        if hasPersistedStoredKeys {
            guard FileTransferLaneOwnership.canAccessExistingBlob(
                expectedLaneID: message.fileTransferLaneID,
                snapshot: currentRawLane
            ), let currentRawLane else {
                #if os(macOS)
                isAwaitingReply = false
                #endif
                endInFlight()
                await ConversationStore.shared.markPendingUserTurn(
                    messageID: message.id,
                    to: "failed"
                )
                await reload()
                setSendError(.fileTransferNotConfigured, messageID: message.id)
                return
            }
            existingInputLane = currentRawLane
        } else {
            existingInputLane = nil
        }
        let historyFileLane = existingInputLane ?? readyOutputLane

        let userMessageID = message.id
        let text = message.text
        // Inherit the ORIGINAL turn's quick-lane provenance (recorded at first
        // dispatch — see `quickStampMessageIDs`): a retried quick turn keeps
        // continuity; a retried window/in-app turn never stamps.
        let stampsQuickPointer = quickStampMessageIDs.contains(userMessageID)
        #if os(macOS)
        // Inherit the ORIGINAL turn's speak verdict the same way (recorded at
        // first dispatch — see `speakMessageIDs`): a retried quick turn whose
        // original send latched speak still speaks; an id NOT in the set (a
        // window/in-app turn, or any stale id) fail-safes to SILENT.
        let speaksReply = speakMessageIDs.contains(userMessageID)
        // Inherit the ORIGINAL turn's popover-surfacing verdict the same way: a
        // retried quick/hotkey turn's reply still populates the popover; an id
        // NOT in the set (a window/in-app turn, or any stale id) never does.
        let surfacesInPopover = popoverReplyMessageIDs.contains(userMessageID)
        #endif

        // Rebuild all three server-backed input shapes only after exact-lane
        // ownership succeeds: server-only files, dual images (original file
        // ref + inline vision bytes), and dual text (disk ref + inline fence).
        // Probe EVERY owned key before dispatch. A definitive miss means the
        // stored retry can no longer truthfully refer to its original bytes.
        let retryReferences = RetryFileReferenceResolver.resolve(
            for: message,
            capturedLaneID: existingInputLane?.durableLaneID,
            omittingPhotos: omittingPhotos
        )
        // This turn's server-backed files that the dispatch canNOT reach —
        // either a clone tombstone (key cleared because it was minted on
        // another lane) or a key the resolver refused for lane mismatch. The
        // newest turn is assembled OUTSIDE `ConverseRequest.priorTurns`, which
        // is where the honest "not available in the current file-transfer lane"
        // note is normally emitted, so without this count the first dispatch
        // after a cross-lane clone would drop the file in silence and let the
        // model answer as though nothing had ever been attached.
        let resolvedServerKeys = Set(retryReferences.serverFiles.map(\.storedKey))
        let unavailableFileCount = message.attachments
            .filter(\.isServerFile)
            .filter { attachment in
                guard let key = attachment.storedKey, !key.isEmpty else { return true }
                return !resolvedServerKeys.contains(key)
            }
            .count
        if let fileSnapshot = existingInputLane {
            for storedKey in retryReferences.storedKeys {
                let outcome = await BackgroundFileTransfer.shared.probeExists(
                    snapshot: fileSnapshot,
                    storedKey: storedKey
                )
                if outcome == .missing {
                    #if os(macOS)
                    isAwaitingReply = false
                    #endif
                    endInFlight()
                    // Release the retry claim status-only (classification
                    // kept) — the Retry affordance stays visible.
                    await ConversationStore.shared.markPendingUserTurn(messageID: message.id, to: "failed")
                    await reload()
                    setSendError(.fileTransferFileUnavailable, messageID: message.id)
                    return
                }
            }
        }
        let serverRefs = retryReferences.serverFiles.map {
            (originalName: $0.originalName, storedKey: $0.storedKey)
        }
        let newUserImageFileRefs = retryReferences.imageFiles.map {
            (storedKey: $0.storedKey, filename: $0.filename)
        }
        let newUserTextFileServerRefs = retryReferences.textFiles.map {
            (originalName: $0.originalName, storedKey: $0.storedKey)
        }

        // (Already flipped to `sending` by the atomic `beginRetry` claim above.)

        // Re-resolve this turn's stored image bytes + text-file blocks.
        // "Resend without photo" (`omittingPhotos`) drops THIS turn's inline
        // photo content for the send — an EXPLICIT user action, never silent;
        // the stored attachments are untouched (non-destructive) and the UI
        // keeps showing them.
        let thisTurnImageBytes = omittingPhotos
            ? []
            : ((try? await ConversationStore.shared.loadAttachmentData(for: userMessageID)) ?? [])
        let newUserImageDataURIs = thisTurnImageBytes.map { DataURIBuilder.jpegDataURI(from: $0) }
        let newUserTextFileBlocks: [(filename: String, text: String)] = message.attachments
            .filter { $0.isText }
            .compactMap { att in
                guard let text = att.extractedText else { return nil }
                // Prefer the stored original filename; fall back to a
                // mimeType-derived name for legacy rows (pre-`filename` column).
                let filename: String
                if let name = att.filename, !name.isEmpty {
                    filename = name
                } else {
                    switch att.mimeType {
                    case "text/markdown": filename = "file.md"
                    case "text/csv": filename = "file.csv"
                    case "application/json": filename = "file.json"
                    default: filename = "file.txt"
                    }
                }
                return (filename: filename, text: text)
            }

        // Prior turns + their retained image data-URIs + the escape hatch
        // (exclude this turn) — the SAME shared assembler as the live send path,
        // so retry produces the same wire shape. `try?` preserves the
        // non-throwing posture.
        let priorTurns = (try? await ConversationHistoryAssembler.assemble(
            conversationID: conversationID,
            excludingUserMessageID: userMessageID,
            excludingNewUserText: text,
            boundRef: RemoteAgentRef(rawString: rawBackend ?? ""),
            dispatchFileLaneID: historyFileLane?.durableLaneID
        )) ?? []
        // Dispatch-time fact for the failure classification: does THIS
        // request carry historical image parts? (Post-policy, post-compat —
        // exactly what actually goes on the wire.)
        let requestHadHistoryImages = ConverseRequest.containsImageParts(priorTurns)

        // The registry claim is ALREADY held (taken at the `beginRetry` CAS, so
        // the pre-flight above is covered too) — re-taking it here would mint a
        // second token and orphan the first, which would then pin a spinner for
        // its whole TTL. A retry is a turn like any other from here on, and the
        // surfaces reading the registry cannot tell them apart.
        #if !os(macOS)
        isAwaitingReply = true
        #endif

        #if os(macOS)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isAwaitingReply = false
                self.endInFlight()
                self.inFlightTask = nil
            }
            do {
                // Mirrors `sendUserTurn`'s macOS branch — retry must produce
                // the same wire shape as the original send.
                if let existingInputLane {
                    guard await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: snapshot.ref,
                        snapshot: existingInputLane
                    ) else {
                        throw AppError.fileTransferNotConfigured
                    }
                }
                if let readyOutputLane,
                   readyOutputLane.durableLaneID != existingInputLane?.durableLaneID {
                    guard await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: snapshot.ref,
                        snapshot: readyOutputLane
                    ) else {
                        throw AppError.fileTransferNotConfigured
                    }
                }
                // A FRESH folder, never the abandoned attempt's. Reusing the
                // failed dispatch's path lets a file written late by that attempt
                // appear as this turn's output, which destroys the only property
                // the design has — that everything in the folder was put there
                // after this turn named it. Outcome discarded for the reason
                // `sendUserTurn`'s macOS branch gives.
                let outboxKey = await BackgroundFileTransfer.mintOutboxKey(
                    conversationID: conversationID,
                    snapshot: readyOutputLane
                ).key
                // Same pinning session as `sendUserTurn`'s macOS branch — a
                // retry must reproduce the original send's TRUST posture, not
                // just its wire shape. Pin resolved from the dispatched ref at
                // send time; session owned by (and invalidated inside) this
                // awaiting `do` block.
                let (pinnedSession, trustEvaluator) = RemoteAgentClient.makePinnedForegroundSession(
                    pinnedFingerprintHex: RemoteAgentTrustEvaluator.storedConversePin(for: snapshot.ref)
                )
                defer { pinnedSession.invalidateAndCancel() }
                // Captured HERE, at dispatch, alongside the ref and pin already
                // read at send time — never at landing. A turn can run for
                // minutes and the user can edit the gateway meanwhile; a
                // landing-time read would credit the NEW configuration with the
                // OLD one's success. Built from `snapshot`'s own values for the
                // same reason one step earlier: the snapshot is what the request
                // below actually carries, so a fresh settings read here could
                // describe a gateway this turn never touched.
                let dispatchChatSignature = await SettingsManager.shared.gatewayChatSuccessSignature(
                    for: snapshot.ref,
                    url: snapshot.url,
                    authScheme: snapshot.authScheme,
                    model: snapshot.model
                )
                let reply = try await RemoteAgentClient.shared.send(
                    backend: snapshot.backend,
                    url: snapshot.url,
                    token: token,
                    authScheme: snapshot.authScheme,
                    model: snapshot.model,
                    priorTurns: priorTurns,
                    newUserText: text,
                    newUserImageDataURIs: newUserImageDataURIs,
                    newUserTextFileBlocks: newUserTextFileBlocks,
                    newUserServerFileRefs: serverRefs,
                    newUserImageFileRefs: newUserImageFileRefs,
                    newUserTextFileServerRefs: newUserTextFileServerRefs,
                    newUserUnavailableFileCount: unavailableFileCount,
                    fileServerReady: readyOutputLane != nil,
                    outboxKey: outboxKey,
                    transport: .pinned(session: pinnedSession, evaluator: trustEvaluator)
                )
                guard !Task.isCancelled else { return }
                // Same persistence-first ordering as the original-send path.
                // Output chips patch asynchronously after the durable reply and
                // sent flip release the awaiting UI.
                _ = try await self.landMacForegroundReply(
                    reply: reply,
                    userMessageID: userMessageID,
                    dispatchRef: snapshot.ref,
                    dispatchFileLane: readyOutputLane,
                    // The SAME folder the wire named — never a second mint.
                    outputBoxKey: outboxKey,
                    dispatchChatSignature: dispatchChatSignature,
                    stampsQuickPointer: stampsQuickPointer,
                    surfacesInPopover: surfacesInPopover,
                    speaksReply: speaksReply
                )
            } catch is CancellationError {
                // Mirror sendUserTurn's macOS cancel flip — no delegate exists
                // on this foreground path to terminalize the turn. Status-only:
                // the pre-retry classification stays (cancel is not a gateway
                // verdict).
                await ConversationStore.shared.markPendingUserTurn(messageID: userMessageID, to: "failed")
            } catch {
                // Terminal failure — the shared handler (classification +
                // banner in one place; see recordSendFailure).
                await self.recordSendFailure(error, userMessageID: userMessageID, requestHadHistoryImages: requestHadHistoryImages)
            }
        }
        inFlightTask = task
        await task.value
        #else
        defer {
            isAwaitingReply = false
            endInFlight()
        }
        do {
            _ = try await BackgroundRemoteAgent.shared.send(
                backend: snapshot.backend,
                ref: snapshot.ref,
                url: snapshot.url,
                token: token,
                authScheme: snapshot.authScheme,
                model: snapshot.model,
                priorTurns: priorTurns,
                newUserText: text,
                newUserImageDataURIs: newUserImageDataURIs,
                newUserTextFileBlocks: newUserTextFileBlocks,
                newUserServerFileRefs: serverRefs,
                newUserImageFileRefs: newUserImageFileRefs,
                newUserTextFileServerRefs: newUserTextFileServerRefs,
                newUserUnavailableFileCount: unavailableFileCount,
                inputFileTransferSnapshot: existingInputLane,
                fileTransferSnapshot: readyOutputLane,
                conversationID: conversationID,
                // Exact per-message flips — same rationale as sendUserTurn.
                userMessageID: userMessageID,
                // Inherited quick-lane provenance — see sendUserTurn's twin.
                stampsActiveConversation: stampsQuickPointer
            )
            // Terminal success — drop the provenance entry.
            quickStampMessageIDs.remove(userMessageID)
        } catch is CancellationError {
        } catch {
            // Terminal failure — the shared handler (classification + banner
            // in one place; see recordSendFailure).
            await recordSendFailure(error, userMessageID: userMessageID, requestHadHistoryImages: requestHadHistoryImages)
        }
        #endif
    }

    /// THE terminal failure handler every send/retry catch arm routes through —
    /// it persists the classification via the guarded `failTurn` and
    /// raises the banner state, deriving (AppError, wireCode) from the thrown
    /// error through the shared `TurnFailureClassification.init(from:)` — so
    /// the four dispatch sites cannot drift apart in how a failure is
    /// recorded. Cancellation is NOT routed here (a cancel is not a gateway
    /// verdict; those arms flip status-only).
    private func recordSendFailure(
        _ error: Error,
        userMessageID: UUID,
        requestHadHistoryImages: Bool?
    ) async {
        await ConversationStore.shared.failTurn(
            messageID: userMessageID,
            classification: .init(from: error, hadHistoryImages: requestHadHistoryImages)
        )
        setSendError(error.unwrappedAppError ?? .remoteAgentUnreachable, messageID: userMessageID)
    }

    // MARK: - Compat mode ("Keep chatting without photos")

    /// Enable compat mode for THIS conversation and re-fire the failed turn
    /// WITHOUT its photos — the "Resend without photo" row action. The flag is
    /// persisted BEFORE dispatch (frozen rule: the banner is visible before
    /// any substituted send); historical images substitute via the assembler,
    /// this turn's own photos are dropped by the explicit `omittingPhotos`
    /// retry. Non-destructive: stored attachments and the UI keep the images.
    func resendWithoutPhoto(_ message: MessageRecord) async {
        // Persist BEFORE dispatch (banner-before-send rule); `retry`'s own
        // reload repaints — an explicit reload here would double the full
        // store/settings fan-out for one tap.
        await ConversationStore.shared.setHideEarlierPhotos(conversationID: conversationID, true)
        await retry(message, omittingPhotos: true)
    }

    /// Enable compat mode WITHOUT resending anything — the poisoned-chat row
    /// action ("Keep chatting without photos"): the user keeps typing; from
    /// the next send on, historical images ride as the canonical disclosure.
    func enableHideEarlierPhotos() async {
        await ConversationStore.shared.setHideEarlierPhotos(conversationID: conversationID, true)
        await reload()
    }

    /// Reverse compat mode — the banner's "Try photos again" action.
    func disableHideEarlierPhotos() async {
        await ConversationStore.shared.setHideEarlierPhotos(conversationID: conversationID, false)
        await reload()
    }

    /// Cancel the in-flight turn — no stale reply lands later. Leaves the user
    /// bubble; no agent bubble.
    /// Cancel the in-flight turn. `expecting` names the turn the caller intends
    /// to stop (an `inFlightTurnToken` read earlier); a non-nil token that no
    /// longer matches means the intended turn already resolved and a DIFFERENT
    /// one is now in flight, so the cancel is dropped rather than applied to a
    /// bystander.
    ///
    /// This is what makes the composer's captured Stop intent safe. That control
    /// morphs between Send and Stop, so a click can be aimed at one and land
    /// after the button has become the other; capturing the intent alone fixes
    /// the Send half (a stale `.send` hits `send()`'s own live guards and
    /// no-ops), but a stale `.stop` had nothing equivalent — and an unqualified
    /// cancel is destructive in a way a no-op is not. A live `isInFlight`
    /// re-check would NOT close it: in the case that matters something else
    /// (Watch relay, Shortcut, the quick-capture lane on this same VM) has
    /// already started the next turn, so the flag reads true and the wrong turn
    /// dies. Only the identity distinguishes them.
    ///
    /// Callers that genuinely mean "stop whatever is running" (session teardown)
    /// pass nil.
    ///
    /// Qualified against `liveTurnStartedAt`, not the stored stamp: a Stop
    /// rendered for a turn this VM did not dispatch (the same conversation, a
    /// discarded sibling instance or the background session) carries that turn's
    /// registry stamp, and comparing it to a nil stored stamp would silently drop
    /// every such cancel. `canStopLiveTurn` has already established that this
    /// device holds a usable handle before any of this is reachable from the UI.
    ///
    /// KNOWN LIMITATION, not fixed here: the non-macOS arm routes to
    /// `BackgroundRemoteAgent.cancel(conversationID:)`, which picks
    /// `inFlight.values.first(where:)` — so when TWO background turns overlap in
    /// one conversation it may cancel the wrong one. The single-turn case, which
    /// is what the composer's Stop offers, is exact. Fixing the overlap needs a
    /// task-identity handle threaded through `BackgroundRemoteAgent`.
    func cancelInFlight(expecting token: Date? = nil) {
        guard Self.cancelApplies(expecting: token, current: liveTurnStartedAt) else { return }
        #if os(macOS)
        // Cancel the foreground `Task`; its `defer` clears the in-flight flags.
        // `RemoteAgentClient` surfaces a URLError(.cancelled) → CancellationError
        // when the session data task is torn down.
        inFlightTask?.cancel()
        #else
        BackgroundRemoteAgent.shared.cancel(conversationID: conversationID)
        // The delegate's `.cancelled` path resolves the awaiting continuation
        // with `CancellationError`; `sendUserTurn`'s `defer` clears the flags.
        #endif
    }

    #if os(macOS)
    /// macOS reply-arrived effect: post `.conversationReplyArrived` so the
    /// menu-bar coordinator can raise the unread dot for `conversationID`. Wraps
    /// the two real call sites (`sendUserTurn` + `retry` success branches).
    /// THIS VIEW MODEL POSTS NO BANNER — it posts only the notification the
    /// coordinator observes. The coordinator is what decides, from that one
    /// observer, whether to raise the dot and whether to post a banner (it does
    /// both only when the thread is unattended). Fires on every macOS reply
    /// success regardless of originating surface; it skips the thread the
    /// popover is currently showing. Exercised by
    /// `ConversationDetailViewModelMacReplyArrivedTests`.
    func dispatchReplyArrivedEffects() {
        NotificationCenter.default.post(
            name: .conversationReplyArrived,
            object: nil,
            userInfo: [NotificationDeepLink.conversationIDKey: conversationID.uuidString]
        )
    }

    /// The always-alive SHARED-ENGINE leg of quick-lane speak-on-arrival — the
    /// popover-CLOSED case (no view-owned speaker exists to route through).
    /// Cross-instance arbitration runs through the `SpeechExclusivity` bus:
    /// `claimForAutoSpeak` REFUSES while the mic is recording (auto-audio
    /// never plays over a live capture — the reply stays tappable in the
    /// thread) and otherwise silences every other macOS speaker (view-owned
    /// ThreadSpeakers included) before this one starts. The follow-up
    /// `cancel()` is still LOAD-BEARING: `claim` excludes the claimant, and
    /// `speak` alone only cancels the in-flight FETCH (`inFlight?.cancel()`),
    /// NOT audio already playing on the shared instance itself. Raw reply in:
    /// `sanitize: true` runs `ReplySanitizer` inside `ReplyVoice` (never
    /// pre-sanitize here). Empty completion — fire-and-forget; nothing awaits
    /// playback end. Called by the default `replySpeaker` wiring AND by the
    /// coordinator's rewired closure's popover-closed branch.
    static func speakArrivalOnSharedEngine(_ reply: String) {
        guard SpeechExclusivity.shared.claimForAutoSpeak(ReplyVoice.shared) else { return }
        ReplyVoice.shared.cancel()
        ReplyVoice.shared.speak(reply, sanitize: true, completion: {})
    }

    /// Internal seam exercised by `ConversationDetailViewModelMacReplySpeakTests`
    /// (the banner twin's exact shape). Runs the per-send speak gate + the
    /// closure-speaker hop. Wraps the two real call sites (`sendUserTurn` +
    /// `retry` success branches) so the test can drive the decision without
    /// standing up a full converse round-trip. `speaks` is the PER-SEND latched
    /// verdict (the `speaksReply` parameter / the `speakMessageIDs` provenance
    /// read) — never a VM property, because the coordinator's registry shares
    /// one VM between popover and main window.
    func dispatchReplySpeakIfNeeded(reply: String, speaks: Bool) async {
        guard speaks else { return }
        await replySpeaker(reply)
    }

    /// Internal seam (twin of `dispatchReplySpeakIfNeeded`) exercised by
    /// `ConversationDetailViewModelPopoverReplyTests`: retain the agent reply as
    /// THIS conversation's quick-lane popover reply IFF the send came from the
    /// menu-bar/hotkey lane (`surfaces`). Both macOS success branches
    /// (`sendUserTurn` + `retry`) call it; a window/in-app/synced reply passes
    /// `surfaces: false` (or a nil id on a store failure) and leaves the marker
    /// untouched — so the popover keeps showing the last genuine quick reply.
    func recordPopoverReplyIfNeeded(agentReply: MessageRecord?, surfaces: Bool) {
        guard surfaces, let agentReply else { return }
        lastPopoverReply = agentReply
    }

    #endif

    // MARK: - Copy

    /// Copy a message's text to the system clipboard.
    func copy(_ message: MessageRecord) {
        Pasteboard.copy(message.text)
    }

    /// Copy the whole conversation as one plain-text block: role-labeled
    /// turns, agent Markdown verbatim, attachments as placeholders — never
    /// bytes (see `ConversationCopyFormatter`). Backs the thread toolbar's
    /// "Copy conversation" button.
    func copyEntireConversation() {
        Pasteboard.copy(ConversationCopyFormatter.build(
            messages: messages, agentName: backendDisplayName))
    }
}
