// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModel.swift
//
// Observable view model backing a single conversation THREAD (the chat-bubble
// scroll — iOS home / Watch detail). Split 1→2 with
// `ConversationListViewModel`.
//
// Handles load + append + the deinit-safe `.conversationsDidChange`
// observer, plus the EPHEMERAL in-flight state machine (NOT a persisted
// `Message.status` — that send-state field is V1.1): optimistic user bubble,
// a "thinking" elapsed timer driving the staged copy, and a Cancel affordance
// that cancels the underlying `URLSessionTask`. The in-flight state lives
// here on the VM (local, never persisted) so the bubble row stays a plain
// snapshot of the store.

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
    /// failed), Send never gated on it. `filename` is the display name with the
    /// original's TRUE extension (e.g. `image.heic`) so the wire splice names the
    /// uploaded file by its real format. NOTE (intentional asymmetry): vision
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

/// Process-wide ownership of output scans. A macOS reply claims its
/// caller-generated message ID BEFORE persistence posts the reload notification;
/// retro recovery must claim the same ID before probing. This closes the
/// direct-versus-retro race inside one process without pretending Core Data /
/// CloudKit provides a distributed compare-and-set across devices.
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
        let reconcileOutputs: (@MainActor (_ agentMessageID: UUID) async -> Void)?
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
                await reconcileOutputs(agentRecord.id)
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

    // MARK: - Ephemeral in-flight state (NOT persisted — V1.0 has no Message.status)

    /// True while an agent turn is in flight for this conversation.
    var isAwaitingReply = false

    /// When the in-flight turn started — drives the elapsed clock. Nil when no
    /// turn is in flight.
    var inFlightStartedAt: Date?

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
    /// `@ObservationIgnored` — pure bookkeeping, never drives a view.
    @ObservationIgnored private var retroScanAttempted: Set<UUID> = []

    /// Guards a single in-flight retro-scan pass per VM (a reload storm must not
    /// stack concurrent passes). `@ObservationIgnored` — bookkeeping only.
    @ObservationIgnored private var retroScanInFlight = false

    /// Max candidate turns probed per retro-scan pass — bounds fan-out on a
    /// thread carrying many un-scanned Watch/CarPlay turns; the rest catch up on
    /// later opens (each pass marks the conclusive ones durably).
    private static let retroScanCap = 20

    enum RetroOutputScanRoute: Equatable {
        case conclusiveWithoutProbe
        case probeCurrentLane
        case deferUntilMatchingLane
    }

    /// Result of the production per-candidate retro-scan executor. The executor
    /// owns the final route/preflight/claim boundary immediately before the
    /// injected probe closure, which lets tests prove that a removed or
    /// repointed durable lane performs zero network work.
    enum RetroOutputCandidateExecution {
        case deferred
        case claimUnavailable
        case local(ConversationStore.OutputScanReconciliation)
        case probed(ConversationStore.OutputScanReconciliation)
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
            // Retroactive output scan (non-awaited): any modern dispatch that
            // persisted an explicit pending marker + exact durable lane may
            // recover if its asynchronous landing probe did not finish.
            // Legacy ownerless rows deliberately remain untouched: guessing the
            // currently configured lane could attach an unrelated file after a
            // gateway was repointed. Guarded to a single in-flight pass; the
            // per-instance attempted-set + durable `outputScanDone` marker stop
            // re-probing on reload echoes.
            Task { [weak self] in await self?.runRetroOutputScan() }
        } catch {
            loadError = String(localized: "Couldn't load this conversation. Try again.")
        }
        hasLoadedInitialMessages = true
        rememberHeaderIdentity()
        isLoading = false
    }

    /// Pure, unit-testable candidate filter for the retro output scan. Every
    /// surface qualifies only with explicit false AND a durable lane identity,
    /// atomically persisted when its dispatch latched a READY file lane. This
    /// recovers a crash between reply persistence and an asynchronous scan
    /// without probing legacy/v6 Watch, CarPlay, or Mac rows whose lane cannot
    /// be proven.
    /// Already-scanned and per-instance-attempted turns are excluded. Newest-first
    /// (messages are createdAt-ascending), capped. Existing server refs do not
    /// exclude a partial-success turn; store reconciliation dedupes them.
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
                }
                .prefix(cap)
        )
    }

    /// Decide whether a candidate can finish locally, may probe the currently
    /// configured lane, or must wait until its dispatch lane is restored.
    /// Filename-free replies are locally conclusive even after lane removal or
    /// repointing because they require no network evidence.
    /// `async` ONLY because the candidate extraction is hopped off the main
    /// actor: its regex is superlinear in reply length and reply text is
    /// untrusted, so running it inline froze this pass (up to `retroScanCap`
    /// replies) on every thread open. The routing decision itself is pure.
    static func retroOutputScanRoute(
        for message: MessageRecord,
        currentLaneID: String?
    ) async -> RetroOutputScanRoute {
        let hasFilenameCandidates =
            !(await FileTransferOutputDetector.extractCandidatesOffMainActor(from: message.text)).isEmpty
        if !hasFilenameCandidates {
            return .conclusiveWithoutProbe
        }

        guard let storedLaneID = message.outputScanLaneID,
              storedLaneID == currentLaneID else {
            return .deferUntilMatchingLane
        }
        return .probeCurrentLane
    }

    /// Execute the production decision boundary for one retro-scan candidate.
    /// A network-capable route must pass the current-lane identity check before
    /// it can claim the message or invoke `probe`; mismatched/removed lanes stay
    /// pending and unattempted. Closure injection keeps the no-I/O guarantee
    /// deterministic in XCTest while `runRetroOutputScan` uses the live detector.
    static func executeRetroOutputScanCandidate(
        _ candidate: MessageRecord,
        currentLaneID: String?,
        snapshotAvailable: Bool,
        laneStillMatches: () async -> Bool,
        claim: () -> Bool,
        didClaim: () -> Void,
        probe: (_ excludedKeys: Set<String>) async -> (
            drafts: [AttachmentDraft],
            conclusive: Bool
        )
    ) async -> RetroOutputCandidateExecution {
        guard let expectedLaneID = candidate.outputScanLaneID else {
            // Compiler-level backstop for callers that bypass candidate
            // selection: ownerless rows can neither probe nor even receive a
            // marker-only mutation.
            return .deferred
        }
        let route = await retroOutputScanRoute(
            for: candidate,
            currentLaneID: currentLaneID
        )
        switch route {
        case .deferUntilMatchingLane:
            return .deferred
        case .probeCurrentLane:
            guard snapshotAvailable, await laneStillMatches() else {
                return .deferred
            }
        case .conclusiveWithoutProbe:
            break
        }

        guard claim() else { return .claimUnavailable }
        didClaim()

        switch route {
        case .conclusiveWithoutProbe:
            return .local(.init(
                messageID: candidate.id,
                drafts: [],
                markScanned: true,
                expectedLaneID: expectedLaneID
            ))
        case .probeCurrentLane:
            let excluded = Set(candidate.attachments.compactMap(\.storedKey))
            let scan = await probe(excluded)
            return .probed(.init(
                messageID: candidate.id,
                drafts: scan.drafts,
                markScanned: scan.conclusive,
                expectedLaneID: expectedLaneID
            ))
        case .deferUntilMatchingLane:
            return .deferred
        }
    }

    /// One retro output-scan pass. Resolves the bound file-server snapshot ONCE,
    /// probes each candidate turn's reply, and reconciles confirmed chips +
    /// conclusive markers in a single store save. Aborts (no marking, no
    /// attempted-set inserts) when the lane has no file transfer configured, and
    /// aborts (no persist) if the lane is repointed mid-pass. Never logs reply
    /// text / filenames / storedKeys.
    /// Global per-pass SOURCE-download budget for retro-scan preview enrichment:
    /// total bytes fetched across EVERY reply enriched in one retro pass. Larger
    /// than the per-reply landing budget because a pass can span several
    /// preview-less replies at once.
    private static let retroPassPreviewSourceBudget: Int64 = 16 * 1024 * 1024   // 16 MiB
    /// Global per-pass STORED-preview budget: total preview/thumbnail bytes
    /// produced across a whole retro pass.
    private static let retroPassPreviewStoredBudget = 1 * 1024 * 1024           // 1 MiB

    /// Spawn the WS-2 preview-enrichment tail for a just-landed reply's output
    /// chips (macOS FOREGROUND landing paths — the iOS background delegate spawns
    /// its own inside `recordReply`). Detached + best-effort: never blocks the
    /// reply UX, never surfaces errors; no-op when there are no output chips.
    private func spawnPreviewEnrichment(
        messageID: UUID?,
        drafts: [AttachmentDraft],
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) {
        guard let messageID, !drafts.isEmpty else { return }
        Task.detached {
            await FileTransferOutputDetector.enrichPreviews(
                drafts: drafts,
                messageID: messageID,
                ref: ref,
                snapshot: snapshot
            )
        }
    }

    #if os(macOS)
    /// Persist a foreground Mac reply + sent flip before probing any output
    /// filenames. Output chips are an asynchronous patch on the durable agent
    /// bubble; a probe timeout can no longer hold the bubble, spinner, unread
    /// cue, or a subsequent send hostage.
    private func landMacForegroundReply(
        reply: String,
        userMessageID: UUID,
        dispatchRef: RemoteAgentRef,
        dispatchFileLane: SettingsManager.FileTransferSnapshot?,
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
        // Claim before persistence: `completeAgentTurn` posts its reload before
        // returning, so claiming afterward leaves a direct/retro race window.
        let ownsOutputClaim = dispatchFileLane == nil
            ? false
            : OutputScanClaimRegistry.shared.claim(agentMessageID)
        let persist: @MainActor () async throws -> MessageRecord = {
            try await ConversationStore.shared.completeAgentTurn(
                userMessageID: userMessageID,
                userStatus: "sent",
                agentText: reply,
                conversationID: conversationID,
                sourceDevice: SourceDevice.current,
                agentMessageID: agentMessageID,
                outputScanLaneID: laneID
            )
        }
        let afterPersistBeforeRelease: @MainActor (MessageRecord) async -> Void = {
            [weak self] agentRecord in
            guard let self else { return }
            // The immediate scan owns this turn for this VM instance.
            // Insert before any suspension so the reload post emitted by
            // `completeAgentTurn` cannot launch a parallel recovery pass.
            if dispatchFileLane != nil {
                self.retroScanAttempted.insert(agentRecord.id)
            }
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
        let reconcileOutputs: (@MainActor (UUID) async -> Void)?
        if let dispatchFileLane, ownsOutputClaim {
            reconcileOutputs = { [weak self] agentMessageID in
                defer { OutputScanClaimRegistry.shared.release(agentMessageID) }

                // A filename-free reply is conclusive without network access,
                // even if the user removed/repointed the lane after dispatch.
                let hasCandidates =
                    !(await FileTransferOutputDetector.extractCandidatesOffMainActor(from: reply)).isEmpty
                if hasCandidates {
                    guard await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: dispatchRef,
                        snapshot: dispatchFileLane
                    ) else {
                        self?.retroScanAttempted.remove(agentMessageID)
                        return
                    }
                }
                let scan = await FileTransferOutputDetector.reconciliationScan(
                    reply: reply,
                    conversationID: conversationID,
                    snapshot: dispatchFileLane,
                    excludedKeys: []
                )
                if hasCandidates {
                    guard await FileTransferOutputDetector.configuredLaneStillMatches(
                        ref: dispatchRef,
                        snapshot: dispatchFileLane
                    ) else {
                        self?.retroScanAttempted.remove(agentMessageID)
                        return
                    }
                }
                let inserted: Bool
                do {
                    inserted = try await ConversationStore.shared.reconcileOutputScan([
                        .init(
                            messageID: agentMessageID,
                            drafts: scan.drafts,
                            markScanned: scan.conclusive,
                            expectedLaneID: dispatchFileLane.durableLaneID
                        )
                    ])
                } catch {
                    // Store failure likewise preserves the pending marker.
                    self?.retroScanAttempted.remove(agentMessageID)
                    return
                }
                if !scan.conclusive {
                    self?.retroScanAttempted.remove(agentMessageID)
                }
                guard inserted else { return }
                self?.spawnPreviewEnrichment(
                    messageID: agentMessageID,
                    drafts: scan.drafts,
                    ref: dispatchRef,
                    snapshot: dispatchFileLane
                )
            }
        } else {
            reconcileOutputs = nil
        }
        let releaseAwaitingUI: @MainActor () -> Void = { [weak self] in
            self?.isAwaitingReply = false
            self?.inFlightStartedAt = nil
        }
        do {
            return try await MacForegroundReplyLanding.persistThenScheduleOutputs(
                dependencies: .init(
                    persist: persist,
                    afterPersistBeforeRelease: afterPersistBeforeRelease,
                    reconcileOutputs: reconcileOutputs
                ),
                releaseAwaitingUI: releaseAwaitingUI
            )
        } catch {
            if ownsOutputClaim {
                OutputScanClaimRegistry.shared.release(agentMessageID)
            }
            throw error
        }
    }
    #endif

    private func runRetroOutputScan() async {
        guard !retroScanInFlight else { return }

        let candidates = Self.retroScanCandidates(
            in: messages,
            attempted: retroScanAttempted,
            cap: Self.retroScanCap
        )
        guard !candidates.isEmpty else { return }

        retroScanInFlight = true
        defer { retroScanInFlight = false }

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

        // Inbound-exclusion token set once for the whole pass.
        let inbound = FileTransferOutputDetector.inboundStoredKeyTokens(in: messages)

        var localResults: [ConversationStore.OutputScanReconciliation] = []
        var probedResults: [ConversationStore.OutputScanReconciliation] = []
        var probedMessageIDs: [UUID] = []
        var claimedMessageIDs: [UUID] = []
        defer {
            for messageID in claimedMessageIDs {
                OutputScanClaimRegistry.shared.release(messageID)
            }
        }

        for candidate in candidates {
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
                probe: { excluded in
                    guard let snapshot else { return ([], false) }
                    return await FileTransferOutputDetector.detect(
                        reply: candidate.text,
                        snapshot: snapshot,
                        inboundTokens: inbound,
                        excludedKeys: excluded
                    )
                }
            )

            switch execution {
            case .local(let result):
                localResults.append(result)
            case .probed(let result):
                probedResults.append(result)
                probedMessageIDs.append(candidate.id)
            case .deferred, .claimUnavailable:
                continue
            }
        }

        // A lane drift after probes drops ONLY network-derived results. Locally
        // conclusive filename-free replies remain safe to stamp. Remove dropped
        // probe attempts so restoring the exact lane can retry in this VM.
        var committedProbedResults: [ConversationStore.OutputScanReconciliation] = []
        if !probedResults.isEmpty,
           let ref,
           let snapshot,
           await FileTransferOutputDetector.configuredLaneStillMatches(
                ref: ref,
                snapshot: snapshot
           ) {
            committedProbedResults = probedResults
        } else if !probedResults.isEmpty {
            for messageID in probedMessageIDs {
                retroScanAttempted.remove(messageID)
            }
        }

        let results = localResults + committedProbedResults
        guard !results.isEmpty else { return }
        guard let inserted = try? await ConversationStore.shared.reconcileOutputScan(results) else {
            for result in results {
                retroScanAttempted.remove(result.messageID)
            }
            return
        }
        // An inconclusive network pass intentionally keeps the durable marker
        // pending. Release its per-VM attempt ownership after reconciliation so
        // restoring the lane / a later settings echo can retry without remount.
        for result in committedProbedResults where !result.markScanned {
            retroScanAttempted.remove(result.messageID)
        }

        // WS-2 preview enrichment for THIS pass's freshly-reconciled drafts ONLY
        // (no backfill of older preview-less chips). ONE global budget threads
        // across every reply in the pass, enforced SEQUENTIALLY. Reuses the same
        // pre-resolved `snapshot` + identity guard: after the bounded downloads,
        // the lane identity is re-checked so a mid-enrichment repoint can't apply
        // old-server previews.
        var sourceBudget = Self.retroPassPreviewSourceBudget
        var storedBudget = Self.retroPassPreviewStoredBudget
        var patches: [FileTransferOutputDetector.PreviewPatch] = []
        guard inserted, let ref, let snapshot,
              await FileTransferOutputDetector.configuredLaneStillMatches(
                ref: ref,
                snapshot: snapshot
              ) else {
            return
        }
        for result in committedProbedResults where !result.drafts.isEmpty {
            if sourceBudget <= 0 || storedBudget <= 0 { break }
            let built = await FileTransferOutputDetector.buildPreviewPatches(
                for: result.drafts,
                messageID: result.messageID,
                snapshot: snapshot,
                sourceBudget: &sourceBudget,
                storedBudget: &storedBudget)
            patches.append(contentsOf: built)
        }
        guard !patches.isEmpty else { return }
        guard await FileTransferOutputDetector.configuredLaneStillMatches(
            ref: ref,
            snapshot: snapshot
        ) else {
            return
        }
        _ = try? await ConversationStore.shared.applyPreviews(patches)
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
        let customs = await SettingsManager.shared.customGateways()
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
        let customs = await SettingsManager.shared.customGateways()
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
    }

    /// Clone this conversation onto `ref` (a chosen configured gateway): create
    /// a new conversation bound to it, copying the text-turn history, and return
    /// the new conversation id so the caller can make it active. Honors the
    /// no-silent-reroute invariant — this is an explicit user action, NOT a
    /// rebind of the existing thread (which would hand a different agent a
    /// history it never produced). Attachments are V1-skipped (text-only clone).
    func cloneConversation(to ref: RemoteAgentRef) async -> UUID? {
        do {
            let cloned = try await ConversationStore.shared.cloneConversation(
                id: conversationID,
                toBackend: ref.rawString
            )
            return cloned.id
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
        sendError = error.descriptionWithRecovery
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
        // macOS is deliberately EXCLUDED: replies surface via the menu-bar
        // unread dot (`dispatchReplyArrivedEffects` → `MenuBarCoordinator`), so
        // macOS never prompts for reply notifications. (The Share path keeps its
        // own prompt in `SharedInboxDrainer`.)
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

        // Enter in-flight state — drives the answering indicator + elapsed clock.
        inFlightStartedAt = Date()
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
                self.inFlightStartedAt = nil
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
                // OLD one's success.
                let dispatchChatSignature = await SettingsManager.shared.gatewayChatSuccessSignature(for: snapshot.ref)
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
            inFlightStartedAt = nil
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
    private struct ProcessedAttachments {
        var drafts: [AttachmentDraft] = []
        var imageDataURIs: [String] = []
        var textFileBlocks: [(filename: String, text: String)] = []
        /// New-turn server-file references (file-transfer route): the original
        /// name + the storedKey the eager upload minted. Spliced into the new
        /// user turn's text as the "saved as <storedKey>" wire line (NOT a
        /// content part — the bytes already live in the agent's working folder).
        var serverFileRefs: [(originalName: String, storedKey: String)] = []
        /// New-turn DUAL-IMAGE server references (this-turn-only): the storedKey
        /// + true-format display filename of each composer image whose eager
        /// upload landed. Spliced into the new user turn's text as the "also saved
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
    /// wire material in staged order. `nonisolated` + `static` so the heavy
    /// work runs off the MainActor.
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
    /// eager-upload a server file too — it just mints a FLAT storedKey (no
    /// conversation folder exists yet).
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
        try FileManager.default.copyItem(at: localURL, to: tmp)
        do {
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
        await reload()

        // Route the retry by THIS conversation's bound backend (per-conversation
        // routing — NOT the global default; same resolution as `sendUserTurn`).
        // A nil snapshot → `remoteAgentNotConfigured` (no silent reroute).
        let rawBackend = try? await ConversationStore.shared.fetchConversation(id: conversationID)?.backend
        guard let snapshot = await SettingsManager.shared.remoteAgentSnapshot(forConversationBackend: rawBackend ?? "") else {
            #if os(macOS)
            isAwaitingReply = false
            #endif
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

        inFlightStartedAt = Date()
        #if !os(macOS)
        isAwaitingReply = true
        #endif

        #if os(macOS)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isAwaitingReply = false
                self.inFlightStartedAt = nil
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
                // OLD one's success.
                let dispatchChatSignature = await SettingsManager.shared.gatewayChatSuccessSignature(for: snapshot.ref)
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
                    fileServerReady: readyOutputLane != nil,
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
            inFlightStartedAt = nil
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
    func cancelInFlight() {
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
    /// macOS surfaces replies via the menu-bar cue, NOT a notification — no
    /// banner is posted here. Fires on every macOS reply success regardless of
    /// originating surface; the coordinator decides whether to mark unread
    /// (it skips the thread the popover is currently showing). Exercised by
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
