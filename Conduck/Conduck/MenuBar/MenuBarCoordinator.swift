// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MenuBarCoordinator.swift
//
// The macOS analog of iOS `ContentView`'s two-state-source split. The
// long-lived (`AppDelegate`-owned) `@MainActor` owner of:
//   - the `DictationService` (audio → STT engine), and
//   - EVERY live `ConversationDetailViewModel` (the thread + agent in-flight
//     state machines), held in a registry behind TWO display lanes:
//       · `quickViewModel`  — the POPOVER's quick-capture lane. Bound by the
//         hotkey capture flow (`handleTranscript`) and the launch resolve;
//         what the popover renders.
//       · `windowViewModel` — the main WINDOW's explicit lane. Bound by
//         sidebar selection / deep-links (`openConversation`) and typed sends
//         (`handleTypedText`); what the window's detail column renders.
//     The lanes are independent: browsing or typing in the window NEVER
//     retargets where the next hotkey capture lands, and a quick capture
//     never yanks the window off the thread the user is reading.
//
// On STT success `DictationService.onTranscript` fires → the coordinator
// consumes the capture-time `QuickDestinationSnapshot` (NOT a fresh resolve —
// see `handleTranscript`), (re)binds the quick lane, and calls
// `vm.sendUserTurn(...)` (the foreground agent round-trip).
//
// Long-lived ownership is LOAD-BEARING: when the popover goes
// `.transient` during the multi-minute agent wait and its hosted SwiftUI view
// tears down, the in-flight `Task` — held by the VM, held by the registry,
// held by `AppDelegate` — survives. Reopening the popover (or window)
// re-binds the SAME VM, so the thread + live thinking indicator are intact;
// popover/window teardown never cancels an in-flight turn.

import AppKit
import Observation

// MARK: - Quick-capture destination (capture-time snapshot)

/// Where the NEXT quick capture lands. `.automatic` is the pointer-driven
/// default (TTL/session policy; `existing` is the resolved thread, nil → a
/// fresh mint on the default gateway) — and also what the popover's
/// direct-response continuation freezes onto the visible reply's thread.
/// The two `explicit*` cases are one-shot overrides: `.explicitNew` (carrying
/// the gateway the fresh chat mints on, nil = the persisted default) is armed
/// by the header "New chat" button (`startNewQuickChat`, always nil);
/// `.explicitConversation` pins a specific thread (exercised by the coordinator
/// tests). `handleQuickSend` mints/continues on whichever case is frozen.
enum QuickDestination: Equatable {
    case automatic(existing: UUID?)
    case explicitNew(RemoteAgentRef?)
    case explicitConversation(UUID)
}

/// The destination RESOLVED AND FROZEN for one quick capture: `armQuickCapture`
/// freezes it at the press instant and `handleQuickSend` consumes exactly it, so
/// the words land where the capture aimed — never a send-time TTL re-resolve
/// (the display-one-send-another divergence this kills). The trailing display
/// metadata is best-effort provenance (the popover no longer surfaces a
/// destination caption); `gatewayName` is still asserted by the coordinator
/// tests.
struct QuickDestinationSnapshot: Equatable {
    var destination: QuickDestination
    /// Display title of the target thread; nil for a new-chat destination.
    var titleSnippet: String?
    /// Gateway display name resolved AT SNAPSHOT TIME (cached customs — no
    /// actor hop to label it).
    var gatewayName: String
    /// Target thread's last activity; nil for new-chat.
    var lastActivityAt: Date?

    /// Provenance for `ConversationDetailViewModel.sendUserTurn`: implicit
    /// destinations (automatic continue/mint, and the header "New chat" —
    /// which just fast-forwards what automatic would do next) re-stamp the
    /// per-device quick pointer so continuity follows the capture; an explicit
    /// EXISTING-thread pick is a one-shot detour and must NOT retarget the
    /// quick lane for future captures.
    var stampsQuickPointer: Bool {
        switch destination {
        case .automatic, .explicitNew: return true
        case .explicitConversation: return false
        }
    }
}

// MARK: - Menu-bar attention (derived, never accumulated)

/// What the status item's two dots are showing, as ONE value derived from the
/// stored conversation rows.
///
/// WHY DERIVED RATHER THAN ACCUMULATED, because the obvious implementation is
/// the other one: two in-memory `Set<UUID>`s that local turn-completion events
/// write into. That version is wrong in a way only a second device exposes. A
/// reply arriving purely by CloudKit from another Mac raises no event in this
/// process, so it bolds a list row while the status item stays dark — the menu
/// bar and the list on the same screen answering the same question from
/// different evidence.
///
/// Because a read on any device is a fact about the ACCOUNT, the mirror image of
/// that gap is worse than the gap. An imported read empties the list row while a
/// set this process filled keeps its dot lit beside it, pointing at a
/// conversation with nothing left in it — and nothing local ever arrives to
/// retire it, because the event that would have was somebody else's tap on
/// another device. A derived value cannot contradict the list, because it IS the
/// same value.
///
/// SAME RESOLVER, SAME INPUTS, SAME DEVICE-LOCAL HALVES. `rowState` goes through
/// `ConversationRowActivity.state`, which is also what the list row, its mark and
/// its status line resolve through — so this device's optimistic view overlay and
/// its in-flight claims are folded in here exactly as they are there. One
/// definition, three surfaces.
///
/// NO STORE FETCH — it reads only the rows it is handed (plus the two in-memory
/// singletons every list row already consults), so the whole derivation can be
/// exercised on hand-built rows with no container, no Keychain and no popover.
struct MenuBarAttention: Equatable {
    /// Conversations whose newest message is an agent reply nobody has looked at
    /// yet, on any of the user's devices.
    var unreadConversationIDs: Set<UUID> = []
    /// Conversations reporting a send failure the account has not acknowledged.
    var failedConversationIDs: Set<UUID> = []
    /// The freshest member of each set — what a dot-click opens.
    var mostRecentUnread: UUID?
    var mostRecentFailure: UUID?

    /// Resolve ONE picker row exactly as the conversation list resolves it.
    ///
    /// `tailRole` comes from the stored tail envelope rather than a per-row
    /// message fetch: the picker reads a bounded number of conversations in one
    /// aggregate and must not turn that into one query per row. An envelope that
    /// is absent, malformed, stale or written by a newer build yields `nil`, which
    /// the resolver reads as NOT PROJECTED and which suppresses the unseen branch
    /// rather than guessing at it — a missing dot, never a wrong one.
    static func rowState(
        _ row: ConversationStore.RecentConversation,
        now: Date = Date()
    ) -> ConversationRowState {
        ConversationRowActivity.state(
            inputs: ConversationActivityInputs(
                recent: row,
                tailRole: TailProjection.read(
                    row.tailProjection,
                    lastActivityAt: row.lastActivityAt
                ).role
            ),
            conversationID: row.id,
            now: now
        )
    }

    /// Fold a set of rows into the two dots.
    ///
    /// Freshness is decided by each row's own `lastActivityAt` rather than by the
    /// order the caller happened to hand them over, so "what a dot-click opens" is
    /// a property of the account's data and not of a fetch's sort descriptor —
    /// and stays right if a caller ever passes an unsorted or merged list.
    static func derive(
        from rows: [ConversationStore.RecentConversation],
        now: Date = Date()
    ) -> MenuBarAttention {
        var attention = MenuBarAttention()
        var newestUnreadAt: Date?
        var newestFailureAt: Date?
        for row in rows {
            let state = rowState(row, now: now)
            if state.hasUnseenReply {
                attention.unreadConversationIDs.insert(row.id)
                if newestUnreadAt.map({ row.lastActivityAt > $0 }) ?? true {
                    newestUnreadAt = row.lastActivityAt
                    attention.mostRecentUnread = row.id
                }
            }
            // An ACKNOWLEDGED failure keeps its red mark in the list — the
            // message still did not go — but loses the alert, which is what this
            // dot is. So the dot tracks the unacknowledged ones only.
            if state.activity == .failed, !state.failureAcknowledged {
                attention.failedConversationIDs.insert(row.id)
                if newestFailureAt.map({ row.lastActivityAt > $0 }) ?? true {
                    newestFailureAt = row.lastActivityAt
                    attention.mostRecentFailure = row.id
                }
            }
        }
        return attention
    }
}

/// `@MainActor` long-lived owner of the macOS capture → agent round-trip.
/// Created once in `AppDelegate.applicationDidFinishLaunching`.
@MainActor
@Observable
final class MenuBarCoordinator {
    /// Audio → STT engine. Its `onTranscript` hook is wired to `handleTranscript`.
    let dictationService: DictationService

    /// Conversation store seam — production keeps `.shared`; tests inject an
    /// isolated `ConversationStore(inMemory: true)` (the unsigned test host
    /// CRASHES on the shared CloudKit-backed container's first touch — no
    /// iCloud entitlement; same seam `SharedInboxRouting` already exposes).
    @ObservationIgnored private let conversationStore: ConversationStore

    // MARK: - VM registry + lanes

    /// Every live thread VM, keyed by conversation id. A REGISTRY (not a single
    /// shared VM) because the window navigating away from a mid-turn thread and
    /// back must reattach the SAME instance — a re-mint would double-observe
    /// `.conversationsDidChange`, show a dead spinner (the new instance never
    /// claimed `isAwaitingReply`), and open a double-send window while the old
    /// in-flight `Task` (which strongly captures its VM) still runs. It also
    /// makes same-conversation dual display (popover + window on one thread)
    /// share ONE instance → one spinner, one in-flight guard.
    /// `@ObservationIgnored` — views observe the lanes, not the map.
    @ObservationIgnored private var vmRegistry: [UUID: ConversationDetailViewModel] = [:]

    /// The popover's quick-capture lane. Nil until the first capture (or a
    /// launch resolve) binds a conversation; the popover renders an empty/start
    /// state while nil.
    private(set) var quickViewModel: ConversationDetailViewModel?

    /// The main window's explicit lane (sidebar selection / deep-link / typed
    /// sends). Nil → the window shows its new-chat empty state.
    private(set) var windowViewModel: ConversationDetailViewModel?

    /// Reuse-or-mint a thread VM. The VM posts `.conversationReplyArrived` on
    /// every macOS reply success and decides nothing about presentation; this
    /// coordinator observes it and owns the reply banner
    /// (`postReplyBannerIfUnattended`). It does NOT own the status-item dots
    /// through that event — those are derived from the stored rows
    /// (`MenuBarAttention`), and the event's only remaining attention job is to
    /// settle a thread the user is watching the reply land in.
    func viewModel(for id: UUID) -> ConversationDetailViewModel {
        if let existing = vmRegistry[id] { return existing }
        let vm = ConversationDetailViewModel(conversationID: id)
        // Popover-visibility-aware speak-on-arrival router (replaces the VM's
        // default always-shared-engine wiring). Popover OPEN on the reply's
        // thread → stage through `AutoSpeakMailbox`; `DictationPopoverView.
        // attemptAutoSpeak` consumes and speaks via its OWN ThreadSpeaker, so
        // the Speak control shows loading→playing, pause works, and the close
        // teardown stops it (the iOS/Watch mailbox pattern). Popover CLOSED →
        // the always-alive shared engine (hands-free arrival; no view exists).
        // Weak captures: the closure lives on the VM — a strong `self` would
        // cycle coordinator ↔ VM through the registry.
        vm.replySpeaker = { [weak self, weak vm] reply in
            guard let vm else { return }
            if let self, self.popoverVisibleConversationID == vm.conversationID {
                AutoSpeakMailbox.shared.request(vm.conversationID)
            } else {
                ConversationDetailViewModel.speakArrivalOnSharedEngine(reply)
            }
        }
        vmRegistry[id] = vm
        return vm
    }

    /// Bind the popover quick lane to `id` (reuse-or-mint; same id → same instance).
    func bindQuickViewModel(to id: UUID) {
        quickViewModel = viewModel(for: id)
        sweepRegistry()
    }

    /// Bind the window explicit lane to `id` (reuse-or-mint; same id → same instance).
    func bindWindowViewModel(to id: UUID) {
        windowViewModel = viewModel(for: id)
        sweepRegistry()
    }

    /// Drop registry entries no lane references — EXCEPT mid-turn VMs
    /// (`isAwaitingReply`): their in-flight `Task` must stay reachable so a
    /// later re-bind reattaches the live state machine instead of re-minting a
    /// dead-spinner duplicate. Called on every bind + at the end of each
    /// hand-off so the map can't grow unbounded across a long session.
    private func sweepRegistry() {
        vmRegistry = vmRegistry.filter { _, vm in
            vm === quickViewModel || vm === windowViewModel
                || vm === popoverOverrideViewModel || vm.isAwaitingReply
        }
    }

    /// True from the instant an STT transcript is handed off (`onTranscript`)
    /// until the agent turn fully completes. Bridges the async GAP between
    /// `DictationService` returning to `.idle` and the send `Task` claiming
    /// `ConversationDetailViewModel.isAwaitingReply` — without it the popover
    /// renders the PREVIOUS reply (or the empty hint) for a frame in that gap,
    /// the transcribing→answering flicker. Set synchronously in the
    /// `onTranscript` closure (before its `Task`) so it commits in the SAME
    /// render as `state=.idle`; cleared by `handleTranscript`'s `defer`.
    private(set) var turnStarting = false

    /// True when ANY gateway on this device can send — what the WINDOW gates on,
    /// and the twin of iOS `ContentView.isRemoteAgentConfigured`. The window
    /// mounts a gateway picker that seeds itself to a configured gateway, so it
    /// never depends on the stored default being one of them.
    ///
    /// Refreshed on launch + on `.settingsDidChangeRemotely`, alongside
    /// `isQuickCaptureReady`, from one snapshot — see `refreshConfiguredFlag`.
    private(set) var hasAnyConfiguredGateway: Bool = false

    /// True when the quick lane has somewhere to land — the DEFAULT gateway can
    /// send, OR a live quick-lane conversation would be continued instead. That
    /// is the whole question the menu-bar POPOVER gates on, because the lane has
    /// no picker: a capture either appends to the pointer's thread on its own
    /// sealed ref, or mints on the persisted default (Decision F).
    ///
    /// Strictly stronger than `hasAnyConfiguredGateway`, and the gap between them
    /// is a legitimate state rather than a glitch (`GatewayGate` carries the three
    /// ways to reach it). While that gap is open the popover says which one is
    /// missing instead of claiming no AI is set up — the beginner empty state
    /// belongs to `!hasAnyConfiguredGateway` alone.
    private(set) var isQuickCaptureReady: Bool = false

    /// The full verdict behind the two flags above, kept so the popover can say
    /// WHICH state it is in rather than re-deriving one from a pair of booleans.
    ///
    /// Nil until the first refresh lands — the same "unknown, not false"
    /// distinction `hasLoadedGatewayState` draws for the flags.
    private(set) var defaultGatewayResolution: DefaultGatewayResolution?

    /// Whether the flags above describe a real read rather than their initial
    /// values. Both start false, which is indistinguishable from "nothing is set
    /// up" until the first refresh lands.
    private(set) var hasLoadedGatewayState = false

    /// Whether a quick capture is KNOWN to have nowhere to land — the press-time
    /// question, and deliberately not `!isQuickCaptureReady`.
    ///
    /// A hotkey pressed in the window between process start and the first refresh
    /// would otherwise be refused on a device that is perfectly well configured,
    /// turning a launch-race into a lost thought. Unknown resolves to "let it
    /// through": the send path validates before it delivers, so the cost of being
    /// wrong here is a visible error, while the cost of refusing is silence.
    var isQuickCaptureKnownUnavailable: Bool {
        hasLoadedGatewayState && !isQuickCaptureReady
    }

    /// Raised when a capture press was REFUSED for want of a destination, and
    /// consumed by the popover's content router ABOVE the retained reply and the
    /// send error.
    ///
    /// Without it the refusal is invisible: `lastPopoverReply` survives popover
    /// close for the whole session, so after any successful capture the refused
    /// press would open the popover onto the PREVIOUS answer — no recording, no
    /// error, nothing naming the problem. Press it again and again: identical.
    /// The passive arm cannot cover this, because ranking the panel above a
    /// retained reply would throw away an answer the user asked for every time
    /// they merely glance at the popover.
    ///
    /// Cleared when the popover closes (the notice belongs to the press that
    /// raised it) and the moment readiness returns.
    private(set) var showsQuickCaptureUnavailableNotice = false

    /// Called by the press handlers when a capture is refused.
    func noteQuickCaptureRefused() {
        showsQuickCaptureUnavailableNotice = true
    }

    /// Called when the popover closes — the next summon starts clean.
    func clearQuickCaptureRefusalNotice() {
        showsQuickCaptureUnavailableNotice = false
    }

    /// The gateway a NEW window chat should open on, resolved from the same
    /// snapshot as the two flags above.
    ///
    /// Published so the window has a usable answer AT MOUNT. `MainWindowView`
    /// owns the live selection and re-resolves it itself, but its `@State` starts
    /// at the compiled-in built-in default and only corrects one actor hop later,
    /// while `hasAnyConfiguredGateway` — refreshed here at launch, before any
    /// window exists — can mount the composer immediately. On a device whose
    /// stored default cannot send, a turn committed inside that hop would seal to
    /// exactly the gateway this whole gate exists to keep users off, and a sealed
    /// ref never re-routes. Narrow, but the failure is permanent, so the window
    /// starts from an answer that is already correct.
    private(set) var newChatSeedRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)

    // MARK: - Menu-bar attention (both status-item dots)

    /// The thread the popover is CURRENTLY showing (nil when closed). The
    /// explicit "is the user looking at this right now" signal — `ActiveViewTracker`
    /// is too blunt here (it also counts background main-window mounts) and
    /// `showPopover` can run before the quick lane is bound. Set on popover show /
    /// quick-lane rebind-while-shown; cleared on close. NOT set during the
    /// window-composer-mic auto-open (the popover shows a HUD for a window capture
    /// whose quick thread may be stale).
    private(set) var popoverVisibleConversationID: UUID?

    /// The thread the MAIN WINDOW's detail column is showing while that window
    /// APPEARS ACTIVE — nil when the window is closed, behind another app,
    /// miniaturized, in Settings mode, or on the new-chat empty state. The
    /// window analog of `popoverVisibleConversationID` (same "user is looking
    /// at this right now" contract), fed by `MainWindowView`'s
    /// `WindowThreadVisibilityReporter` (`\.appearsActive`-gated — the reason
    /// `ActiveViewTracker` alone can't drive this: it counts background
    /// mounts, and a reply landing in a window the user isn't looking at must
    /// still raise the dot).
    private(set) var windowVisibleConversationID: UUID?

    /// Weak handle to the popover view's `ThreadSpeaker`, registered by
    /// `DictationPopoverView.onAppear`. Exists so `MenuBarController.
    /// popoverDidClose` — the AUTHORITATIVE close signal (Esc, outside click,
    /// programmatic) — can stop an in-progress popover speak deterministically:
    /// the popover's hosting controller is retained for the app's lifetime, so
    /// the view's own `.onDisappear` is not a guaranteed close callback. Weak +
    /// `@ObservationIgnored`: pure plumbing, never drives a view, must not
    /// retain the view's state object.
    @ObservationIgnored weak var popoverSpeaker: ThreadSpeaker?

    /// Conversations whose newest message is an agent reply nobody has looked at
    /// yet, on ANY of the user's devices. Drives the status-item unread dot — ONE
    /// dot when non-empty, because a count is unreadable at 18pt and ambiguous
    /// when one thread is read but another isn't.
    ///
    /// STORED rather than computed over `quickRecents`: the icon refresh in
    /// `MenuBarController.observeStateChanges` reads this inside a
    /// `withObservationTracking`, and a background/share landing changes ONLY
    /// this — there is no capture-state / `isAwaitingReply` flip to piggyback the
    /// re-fire on (as the in-app path has). Written only by `refreshAttention`,
    /// and only when the value actually differs.
    private(set) var unreadReplyConversationIDs: Set<UUID> = []

    /// Conversations reporting a send failure the ACCOUNT has not acknowledged.
    /// Drives the status-item RED dot — the failure analog of the yellow unread
    /// dot, mirroring its shape EXACTLY (one dot when non-empty; red takes
    /// precedence over yellow, because a failure is more urgent). Same
    /// stored-not-computed reason as the set above.
    private(set) var failedConversationIDs: Set<UUID> = []

    /// The freshest member of each set — the thread a dot-click opens. Freshest
    /// by `lastActivityAt`, which is an ACCOUNT fact, rather than by the order
    /// this process happened to hear about things.
    private(set) var mostRecentUnreadConversationID: UUID?
    private(set) var mostRecentFailureConversationID: UUID?

    /// Whether the status-item icon should show the unread dot.
    var hasUnreadReply: Bool { !unreadReplyConversationIDs.isEmpty }

    /// Whether the status-item icon should show the failure (red) dot.
    var hasFailure: Bool { !failedConversationIDs.isEmpty }

    /// Re-derive both dots from the rows currently in `quickRecents`.
    ///
    /// Synchronous and store-free: `refreshQuickCaches` owns the fetch, this owns
    /// the derivation, and every seam that moves this device's optimistic view
    /// overlay calls it directly — the overlay leads the store by a save plus an
    /// import, and a dot must go out on the same runloop turn the user opens the
    /// thread rather than a round-trip later.
    ///
    /// EACH WRITE IS EQUALITY-GUARDED, and that is a correctness requirement, not
    /// tidiness. `@Observable` publishes every assignment, equal or not, and
    /// `MenuBarController.handleStateChange` responds to a change on these two
    /// sets by re-reporting the popover's visible thread — which stamps the read
    /// marker, which saves, which posts `.conversationsDidChange`, which lands
    /// back here. Unconditional assignment would close that circle into an
    /// unbounded save loop for as long as the popover stays open.
    private func refreshAttention(now: Date = Date()) {
        let attention = MenuBarAttention.derive(from: quickRecents, now: now)
        if unreadReplyConversationIDs != attention.unreadConversationIDs {
            unreadReplyConversationIDs = attention.unreadConversationIDs
        }
        if failedConversationIDs != attention.failedConversationIDs {
            failedConversationIDs = attention.failedConversationIDs
        }
        if mostRecentUnreadConversationID != attention.mostRecentUnread {
            mostRecentUnreadConversationID = attention.mostRecentUnread
        }
        if mostRecentFailureConversationID != attention.mostRecentFailure {
            mostRecentFailureConversationID = attention.mostRecentFailure
        }
    }

    /// The user is demonstrably looking at this thread — settle BOTH of its
    /// attention markers, in ONE store transaction.
    ///
    /// ONE WRITE, NOT TWO. Opening a thread is a single act that is
    /// simultaneously "I have looked at this" and "I have seen its failure".
    /// Stamping the read marker and then acknowledging separately would mean two
    /// saves, two change notifications and two CKRecord exports for one click,
    /// plus a window in which a reload lands between them and renders the row
    /// half-updated.
    ///
    /// THE MARKERS ARE ACCOUNT FACTS, not device ones — they land on
    /// `Conversation.lastViewedAt` / `.failureSeenAttemptID` and reach the phone,
    /// the iPad and the wrist. That is exactly why the caller has to be a surface
    /// that has PROVEN it is on screen: retiring a mark from an intent to display
    /// retires it everywhere, for a failure nobody saw.
    ///
    /// THE ATTEMPT ID COMES OFF THE PICKER PROJECTION, which is why `quickRecents`
    /// is fetched WITH turn states. An acknowledgement names one
    /// `Message.deliveryAttemptID` and is accepted only on exact equality, so
    /// there is nothing this seam could substitute: a timestamp, or the
    /// conversation's `lastActivityAt` wearing the right parameter's name, cannot
    /// identify an attempt at all. The stamp and the identity travel together in
    /// `FailedTurnProjection` precisely so this caller cannot pair one turn's time
    /// with another turn's id.
    ///
    /// IT ACKNOWLEDGES ONLY A ROW THAT IS ACTUALLY PAINTING THE FAILURE, and that
    /// test is now the resolver's own — the same `ConversationRowState` the list
    /// row beside it renders — rather than membership of a set this process filled
    /// from local events. Acknowledging unconditionally would retire the mark for
    /// a failure that a later turn already superseded and the user therefore never
    /// saw; asking the resolver keeps the question in one place and keeps the two
    /// surfaces incapable of disagreeing about it.
    ///
    /// NIL IS THE SAFE RESIDUE, not a failure case: a conversation outside the
    /// picker's row budget, or a failed turn from before the attribute existed,
    /// acknowledges nothing here and keeps its red mark until the user reaches the
    /// thread itself — `ConversationThreadView`, which reads the id straight off
    /// the tail, settles it there. A mark that clears one screen later is the
    /// direction this design always takes.
    func noteConversationSeen(_ id: UUID) {
        let recent = quickRecents.first(where: { $0.id == id })
        let paintsFailure = recent.map { row in
            let state = MenuBarAttention.rowState(row)
            return state.activity == .failed && !state.failureAcknowledged
        } ?? false
        ReadStateStore.shared.markViewedAndAcknowledgeFailure(
            id,
            lastActivityAt: recent?.lastActivityAt,
            attemptID: paintsFailure ? recent?.newestFailed?.deliveryAttemptID : nil
        )
        // The overlay moved; the dot has to follow it in this runloop turn, not
        // after the save and the import that will eventually confirm it.
        refreshAttention()
    }

    /// A reply landed for `id`.
    ///
    /// THIS DOES NOT RAISE THE DOT. The dot is derived from the stored rows, and
    /// the append that produced this reply already posted
    /// `.conversationsDidChange`, which refreshes them. What is left is the one
    /// half no stored value can answer: whether the user is watching this land.
    ///
    /// POPOVER ONLY, deliberately. The popover hosts `DictationPopoverView`, not
    /// `ConversationThreadView`, so the thread view's own re-stamp-on-every-new-tail
    /// never fires for a popover glance and this is the only seam that can. The
    /// main window needs no arm here precisely because it DOES host that view,
    /// which re-stamps against the exact tail id; a second, coarser write from
    /// here would be one more save and one more export for the same reply.
    ///
    /// The rows are refreshed BEFORE settling so the stamp and any attempt id are
    /// taken against the turn that just landed rather than the projection from
    /// before it.
    ///
    /// NEVER POST A NOTIFICATION FROM HERE. BOTH reply observers funnel into this
    /// method, and one of them (`.remoteAgentTurnDidComplete` — the share drain /
    /// background landing) has already posted its own banner. A post here would
    /// emit two banners for one reply and consume the burst-chime window twice.
    /// The banner lives in the `.conversationReplyArrived` observer alone.
    func noteReplyArrived(_ id: UUID) {
        settleIfWatchedInPopover(id)
    }

    /// A send/turn failed for `id`. Same contract as `noteReplyArrived`: the red
    /// dot comes from the stored rows, and this settles the thread only when the
    /// popover is the surface showing it — a failure under the user's eyes has
    /// been seen, and its inline failed bubble is right there.
    func noteFailure(_ id: UUID) {
        settleIfWatchedInPopover(id)
    }

    /// Shared body of the two arrival hooks: refresh the projection, then settle
    /// `id` if the popover is showing exactly it. A no-op otherwise — including
    /// the refresh, because the change bus already drives one and a second fetch
    /// per landing would buy nothing.
    private func settleIfWatchedInPopover(_ id: UUID) {
        guard id == popoverVisibleConversationID else { return }
        Task { [weak self] in
            await self?.refreshQuickCaches()
            self?.noteConversationSeen(id)
        }
    }

    // MARK: - macOS reply banner

    /// Post the reply notification for a FOREGROUND macOS reply — the path that
    /// has no background delegate to post one for it.
    ///
    /// Same visibility guard as `noteReplyArrived`: a reply for the thread the
    /// user is already looking at needs no banner (and the foreground
    /// presentation delegate would suppress it anyway). Kept as a separate
    /// method rather than folded into `noteReplyArrived` because the two
    /// observers share that method and only ONE of them may post — see the
    /// `.conversationReplyArrived` observer's header.
    ///
    /// The body + gateway are read from the STORE rather than carried on the
    /// notification: `.conversationReplyArrived` deliberately carries only the
    /// conversation id, and it is posted after the agent row is persisted, so
    /// the tail read is exact. A tail that is not an agent turn (a race with a
    /// newer user turn) posts nothing rather than quoting the wrong bubble.
    private func postReplyBannerIfUnattended(_ id: UUID) {
        guard id != popoverVisibleConversationID,
              id != windowVisibleConversationID else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let tail = ((try? await self.conversationStore.fetchConversationTail(id: id)) ?? nil),
                  tail.role == MessageRole.agent.rawValue,
                  !tail.text.isEmpty else { return }
            let backendRaw = ((try? await self.conversationStore.fetchConversation(id: id)) ?? nil)?.backend
            await BackgroundRemoteAgent.postReplyNotification(
                tail.text,
                conversationID: id,
                backendRawValue: backendRaw
            )
        }
    }

    /// THE ONE FOUNDER-VISIBLE BEHAVIOUR CHANGE: macOS now asks for
    /// notification permission, because macOS now posts a reply banner (before,
    /// the menu-bar dot was the only cue and no macOS path ever prompted).
    /// Called from the committed dispatch paths — past every rejection guard, so
    /// a blocked or abandoned send never pops a system dialog.
    ///
    /// TO REVERT THE PROMPT: make this method return unconditionally. It is the
    /// single gate; both dispatch paths route through it and nothing else on
    /// macOS calls `NotificationPermissions`.
    ///
    /// Honors an explicit Setup-Guide "Not now" for the same reason the iOS
    /// composer backstop does: the user is watching, this is low-urgency, and
    /// re-popping the OS dialog on the very next send would undo their choice.
    private func requestNotificationPermissionIfNeeded() {
        guard !NotificationPermissions.isNotificationsDeferred else { return }
        Task { await NotificationPermissions.ensureRequested() }
    }

    // MARK: - Quit-guard copy inputs

    /// Title of the ONE conversation with a live turn, when exactly one is live.
    /// Nil otherwise, and nil when it cannot be resolved — `applicationShouldTerminate`
    /// cannot await, so this reads only synchronous caches (the picker recents)
    /// and a miss simply falls back to the generic alert copy.
    var soleLiveThreadTitle: String? {
        guard let id = InFlightTurnRegistry.shared.soleLiveConversationID else { return nil }
        return quickRecents.first(where: { $0.id == id })?.label
    }

    /// Gateway display name for that same sole live thread. Prefers the live
    /// VM's already-resolved name (the thread is mid-turn, so its VM is in the
    /// registry by construction), falling back to labelling the picker row's raw
    /// backend against the cached custom roster. Both are synchronous.
    var soleLiveThreadGatewayName: String? {
        guard let id = InFlightTurnRegistry.shared.soleLiveConversationID else { return nil }
        if let vm = vmRegistry[id] { return vm.backendDisplayName }
        if let recent = quickRecents.first(where: { $0.id == id }) {
            return quickGatewayDisplayName(forBackendRaw: recent.backend)
        }
        return nil
    }

    /// Record that the popover is now showing `id`, which settles both of that
    /// thread's attention markers. Pass nil on close. Skip the call entirely
    /// during the window-composer auto-open path.
    ///
    /// This is one of the two callbacks that report SETTLED visibility, and
    /// therefore one of the two places allowed to retire an account-wide mark —
    /// the popover is on screen and showing this thread, which is as close to
    /// proof of attention as this surface can get.
    func setPopoverVisibleConversation(_ id: UUID?) {
        popoverVisibleConversationID = id
        if let id {
            noteConversationSeen(id)
            // Retire this thread's banners. The popover hosts
            // `DictationPopoverView`, NOT `ConversationThreadView`, so that
            // view's own `.onAppear` clear never fires for a popover glance.
            NotificationDeepLink.clearDelivered(for: id)
        }
    }

    /// Record that the ACTIVE main window is now showing `id` — settling both of
    /// that thread's attention markers, in parity with the popover pin. Pass nil
    /// when the window deactivates with the thread still mounted.
    ///
    /// The second of the two settled-visibility callbacks, and the one that
    /// covers re-activation: cmd-tabbing back to a window already parked on a
    /// thread mounts nothing, so the thread view's own `.onAppear` stamp fired
    /// long ago and this report is the only signal that the user is looking at it
    /// again. `\.appearsActive`-gated at the reporter, so a thread merely mounted
    /// in a backgrounded window never reaches here — which matters more than it
    /// used to, because what it would retire is now the mark on the phone and the
    /// wrist as well.
    func setWindowVisibleConversation(_ id: UUID?) {
        windowVisibleConversationID = id
        if let id {
            noteConversationSeen(id)
            // Covers cmd-tabbing back onto an ALREADY-MOUNTED thread: the view's
            // `.onAppear` fired long ago, so this re-activation report is the
            // only signal that the user is looking at it again.
            NotificationDeepLink.clearDelivered(for: id)
        }
    }

    /// Unmount-path clear (the reporter's `.onDisappear`): drop the pin ONLY if
    /// it still points at `id` — a sidebar thread switch can mount the NEW
    /// thread's reporter before the OLD one's `.onDisappear` runs, and an
    /// unconditional nil would wipe the fresh report.
    func clearWindowVisibleConversation(ifCurrent id: UUID) {
        if windowVisibleConversationID == id { windowVisibleConversationID = nil }
    }

    // MARK: - Popover display override (read-only shared-reply glance)

    /// A TEMPORARY read-only display lane: when the user clicks the dot and the
    /// freshest unread thread is NOT the quick-capture thread (e.g. a share
    /// reply), the popover shows THIS thread instead — reply + Copy/Speak +
    /// "Read full reply in window", no compose box. Kept distinct from
    /// `quickViewModel` so showing a shared reply never mutates quick-capture
    /// state (`quickDestination` / `quickAutomaticSnapshot` / the per-device
    /// pointer). Cleared on popover close + on any new capture (`armQuickCapture`).
    private(set) var popoverOverrideViewModel: ConversationDetailViewModel?

    /// What the popover actually displays: the override when set, else the quick
    /// lane. All reply-display reads + the visible-thread bookkeeping use this.
    var displayedPopoverViewModel: ConversationDetailViewModel? {
        popoverOverrideViewModel ?? quickViewModel
    }

    /// The conversation id the popover is displaying right now (override-aware).
    var displayedPopoverConversationID: UUID? { displayedPopoverViewModel?.conversationID }

    /// Show `id` in the popover as a read-only override (reuse-or-mint the VM).
    func setPopoverOverride(to id: UUID) {
        popoverOverrideViewModel = viewModel(for: id)
        sweepRegistry()
    }

    /// Drop the read-only override (back to the quick lane).
    func clearPopoverOverride() {
        popoverOverrideViewModel = nil
        sweepRegistry()
    }

    /// Observable mirror of the device-local menu-bar input mode (voice = the
    /// popover auto-records on summon; text = it shows a focused text field).
    /// Seeded SYNCHRONOUSLY in `init` (an async seed would let a fast first
    /// summon render the wrong input surface) and refreshed by the existing
    /// `.settingsDidChangeRemotely` observer — single source for BOTH the
    /// controller's press-time branches and the popover's `body`, so neither
    /// pays a per-press actor hop and the two can't disagree.
    private(set) var menuBarInputMode: MenuBarInputMode =
        SettingsManager.menuBarInputModeAtLaunch()

    /// The text-mode popover's draft. COORDINATOR-owned (not view `@State`) so
    /// it survives popover teardown by construction — an outside-click (the
    /// IMPLICIT dismiss) keeps the user's words, while Esc / the explicit Cancel
    /// controls discard them (`cancelActiveCapture`). `sendQuickTypedDraft()`
    /// clears it atomically with `turnStarting` in one MainActor turn (the
    /// no-stale-frame contract). The popover binds it via `@Bindable`.
    var quickDraft = ""

    /// TEXT-mode compose state that must survive a dismissal: a staged ⌘⇧2
    /// screenshot, or (text mode only) a non-empty draft. Gates the explicit-
    /// pick one-shot in `popoverDidCloseHook` and the Esc-over-error reset —
    /// a pick made for a composition-in-progress lives exactly as long as the
    /// composition; image and draft are two halves of one compose surface and
    /// must share survival semantics. The draft half is mode-gated: in voice
    /// mode a draft is unreachable (the compose surface is its only sender),
    /// so it must not pin destination picks there.
    var hasComposeState: Bool {
        if pendingCaptureImage != nil { return true }
        return menuBarInputMode == .text
            && !quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The gateway the Conversations *window*'s title picker chose for the NEXT
    /// new conversation. Set by the window when the user picks a gateway
    /// or starts a new conversation; consumed (and cleared) by `handleTypedText`'s
    /// fresh-mint. Nil → the mint falls back to the persisted default. WINDOW-
    /// LANE state only: the quick lane (`handleTranscript`) never reads it — a
    /// hotkey capture always mints on the persisted default (Decision F), so a
    /// stale window pick can't hijack a quick capture.
    /// A `RemoteAgentRef` (built-in or custom) so the window can bind a new
    /// conversation to any configured gateway.
    var pendingNewConversationRef: RemoteAgentRef?

    /// Set by `MenuBarController.openSettings()` when the menu-bar "Settings…"
    /// item is chosen. Settings is now a `.sheet` on the unified main window,
    /// so when the window is currently closed the controller opens `"main"` and
    /// raises this flag; `MainWindowView.onAppear` reads + clears it and
    /// presents the sheet. The window-already-open case is covered by the live
    /// `.onReceive(.openSettingsWindow)` subscriber (no fragile sleep).
    var pendingShowSettings = false

    /// Optional Settings category to deep-link to alongside `pendingShowSettings`
    /// (e.g. the menu-bar unconfigured empty state routes to Personal AI). Read +
    /// cleared by `MainWindowView` at the SAME points it consumes
    /// `pendingShowSettings`; every root-Settings entry point nils it so a stale
    /// `.personalAI` can't leak into an unrelated Settings open. `nil` = root list.
    var pendingSettingsCategory: MacSettingsView.Category?

    /// Optional focused failure to hand the Diagnostics screen when the menu-bar
    /// popover's Troubleshoot routes into Settings → Diagnostics (the popover is
    /// outside the SwiftUI scene graph and can't present its own sheet). Consumed
    /// + cleared by `MainWindowView` at the SAME points as `pendingSettingsCategory`,
    /// then applied to the persistent runner via `DiagnosticsRunner.setFocus`.
    /// `nil` = open Diagnostics unfocused.
    var pendingDiagnosticsFocus: DiagnosticsFocus?

    /// The PNG screenshot staged by a "Screenshot & Ask" (⌘⇧2) capture, pending
    /// the voice turn it will ride on. Owned HERE (not on `DictationService`,
    /// which stays audio-only) because the recording HUD shows its thumbnail
    /// while it's non-nil and `handleTranscript`
    /// threads it onto the voice turn as a `PendingAttachment.image`. Set by
    /// `MenuBarController` right after a successful region capture; cleared after
    /// the send (delivered path only) OR by an explicit Cancel/Discard. An
    /// empty/failed STT RETAINS it so the popover's recovery UI can offer
    /// Retry-Voice / Type-Instead / Discard.
    private(set) var pendingCaptureImage: Data?

    /// One-shot "Type Instead" bridge: when the user bails out of a pending
    /// capture's voice turn into the typed composer, the captured screenshot is
    /// parked here and the main window drains it into the composer's staging
    /// (mirrors the `pendingShowSettings` deferred-present seam — read + cleared
    /// by `MainWindowView` on appear and on `.openConversationsWindow`). Nothing
    /// is sent; it just stages the image for review.
    var pendingComposerImage: Data?

    /// A turn stranded by a hand-off failure: a conversation-mint failure (rare
    /// Core Data create failure), a deleted explicit destination, or a busy
    /// target VM. Stashed so the popover's error-footer Retry can replay it
    /// (`retryPendingFailedTurn`) instead of silently losing the user's
    /// just-transcribed/typed words.
    /// INVARIANT: set only when its error actually presented on the dictation
    /// surface (`presentHandoffError` returned true) — an invisible stash would
    /// hijack a later, unrelated error's Retry. Cleared on a successful
    /// hand-off, on the popover's Dismiss, on Esc over the error state, and
    /// when a fresh capture starts (`discardPendingFailedTurn`).
    private enum PendingFailedTurn {
        case voice(transcript: String)
        case typed(text: String)
        /// A text-mode QUICK-lane turn (popover compose field). Distinct from
        /// `.typed` — that case replays through `handleTypedText` into the
        /// WINDOW lane; this one replays through `handleQuickSend(.text)` so
        /// the retry re-consumes the kept-latched quick snapshot exactly like
        /// a `.voice` replay does.
        case quickTyped(text: String)
    }
    private var pendingFailedTurn: PendingFailedTurn?

    /// Popover gate for the hand-off-failure Retry affordance (the stash itself
    /// stays private — the popover only needs "is there something to replay").
    var hasPendingFailedTurn: Bool { pendingFailedTurn != nil }

    // MARK: - Quick destination state

    /// Where the NEXT quick capture lands + its display metadata. Frozen by
    /// `armQuickCapture` and consumed by `handleQuickSend`. Nil until the first
    /// refresh resolves (a turn fired before then rebuilds the automatic case
    /// from the shared resolver — see `handleQuickSend`'s snapshot-nil fallback).
    private(set) var quickDestination: QuickDestinationSnapshot?

    /// True from `armQuickCapture()` (the hotkey press) until the turn settles
    /// (`resetQuickDestinationAfterTurn`). While latched, background refreshes
    /// (`refreshQuickDestination`) must NOT replace the snapshot — the press
    /// instant froze the destination, and a TTL boundary crossing mid-capture
    /// would otherwise retarget the send away from what the popover displayed.
    private(set) var quickDestinationLatched = false

    /// The arm-time re-resolution of an automatic destination (the popover may
    /// have sat open across a TTL boundary — the press instant wins).
    /// `handleTranscript` awaits it before consuming the snapshot.
    @ObservationIgnored private var quickArmTask: Task<Void, Never>?

    /// Monotonic counter bumped on EVERY `armQuickCapture()`.
    /// `resolveAutomaticDestinationNow` captures it at entry and commits its
    /// resolved snapshot to `quickDestination` ONLY if it's still current — so a
    /// lingering resolver from a PRIOR arm (an in-flight background refresh, or a
    /// stale `quickArmTask`) can't clobber the destination a NEWER arm froze.
    /// The direct-response continuation freeze (`armQuickCapture`) is the case
    /// that needs it: it writes an overwriteable `.automatic(existing:)` snapshot
    /// and returns without awaiting the old task, so a value-guard alone (explicit
    /// beats automatic) wouldn't protect it — automatic-vs-automatic is a tie the
    /// generation breaks in favor of the latest arm.
    @ObservationIgnored private var armGeneration = 0

    /// Recent threads, most-recently-active first (refreshed by
    /// `refreshQuickCaches`; ≤6). Two jobs: the synchronous metadata source for
    /// `selectQuickDestination(.explicitConversation:)` — a pick must not hop
    /// actors to label its own thread — and the STORED FACTS both status-item dots
    /// are derived from.
    ///
    /// THE ROW BUDGET BOUNDS THE DOTS, and the bound is benign in the direction it
    /// bites. Both attention states imply recent activity: an unseen reply is a
    /// message that just bumped `lastActivityAt`, and a reported failure is only
    /// reported while it is still the conversation's last activity. So a thread
    /// wanting attention leaves this window only once six OTHER threads have been
    /// active more recently — and if all six are settled, the seventh is a genuinely
    /// old unread rather than the thing the user just missed. The residue is a dot
    /// that goes dark early, never one that lights wrongly, and the thread's own
    /// list row keeps saying so.
    private(set) var quickRecents: [ConversationStore.RecentConversation] = []

    /// Cached custom-gateway roster, so `selectQuickDestination` resolves gateway
    /// display names without an actor hop (same reason the thread VM caches
    /// `customGateways`).
    @ObservationIgnored private var quickCustomGateways: [CustomGateway] = []

    /// Cached display name of the persisted DEFAULT gateway (the mint target
    /// for automatic/new-chat destinations). Refreshed with the snapshot.
    private(set) var quickDefaultGatewayName: String = String(localized: "Personal AI")  // xcstrings: chat-ui

    /// The most recent AUTOMATIC resolution, kept even while an explicit
    /// override occupies `quickDestination` — `selectQuickDestination(.automatic)`
    /// restores it verbatim without an async re-resolve (synchronous revert).
    private(set) var quickAutomaticSnapshot: QuickDestinationSnapshot?

    /// Holder so `deinit` (nonisolated on a `@MainActor` class) can detach the
    /// NotificationCenter observers without touching main-actor state — same
    /// pattern as `ConversationListViewModel.ObserverBox`.
    private final class ObserverBox {
        var observers: [NSObjectProtocol] = []
        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }
    private let observerBox = ObserverBox()

    /// `dictationService` defaults to a fresh instance when nil. Constructed in
    /// the body (NOT a default-arg `= DictationService()`) because the
    /// `@MainActor`-isolated `DictationService.init` can't be evaluated in the
    /// nonisolated default-argument context.
    init(dictationService: DictationService? = nil,
         conversationStore: ConversationStore = .shared) {
        self.dictationService = dictationService ?? DictationService()
        self.conversationStore = conversationStore
        // Wire the STT terminal step to the agent round-trip.
        self.dictationService.onTranscript = { [weak self] transcript in
            // `onTranscript` already fires on the main actor (DictationService
            // is @MainActor). Claim `turnStarting` SYNCHRONOUSLY here — before the
            // Task — so it commits in the same render as DictationService's
            // `state=.idle`, bridging the gap until the send Task claims
            // `isAwaitingReply` (no stale-reply flash). `handleTranscript`'s
            // `defer` clears it. Then hop through a Task for the async send path.
            self?.turnStarting = true
            Task { [weak self] in
                await self?.handleTranscript(transcript)
            }
        }

        // Refresh the configured flags + resolve the launch conversation.
        //
        // The flags go FIRST, matching iOS `ContentView.initialLoad()`: both start
        // false, and the window renders the unconfigured empty state while they
        // are, so warming ahead of them holds a configured user on a beginner
        // setup screen for the length of a full store load + conversation fetch on
        // every cold launch.
        //
        // The header memo still warms BEFORE `resolveActiveConversationOnLaunch()`
        // binds the first VM, which is the property it actually needs — the
        // launch-resolved thread draws its gateway pill on frame one rather than
        // flickering the "Personal AI" placeholder. Keep that order; the flags may
        // move ahead of the warm, never the warm behind the bind.
        Task { [weak self] in
            await self?.refreshConfiguredFlag()
            await ConversationDetailViewModel.warmHeaderMemo()
            await self?.resolveActiveConversationOnLaunch()
        }

        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .settingsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Synchronous device-local read — keeps the observable mirror
                // current so the NEXT popover summon uses the new input mode
                // (no relaunch, no actor hop in the press path).
                let previous = self.menuBarInputMode
                self.menuBarInputMode = SettingsManager.menuBarInputModeAtLaunch()
                // Text → voice flip: drop a text-staged screenshot — outside
                // text mode nothing renders or discards it, and a lingering
                // image silently rides the NEXT ⌘⇧1 voice turn (the exact
                // state `handleEscape`'s recording arm exists to prevent).
                // The DRAFT deliberately survives the flip: it is inert in
                // voice mode (the compose surface is its only sender) and
                // reappears intact when the user flips back.
                if previous == .text, self.menuBarInputMode == .voice {
                    self.clearPendingCaptureImage()
                }
                self.scheduleRemoteSettingsRefresh()
            }
        })

        // Conversation churn (new turns, deletes, renames) goes stale in the
        // destination label + recents otherwise. `refreshQuickDestination`
        // internally no-ops the DESTINATION while latched (a capture froze the
        // snapshot) or while an explicit pick is sticky; the row refresh behind it
        // always runs.
        //
        // THIS IS WHAT DRIVES BOTH STATUS-ITEM DOTS. The store fans
        // `.NSPersistentStoreRemoteChange` into this same notification, so a reply
        // that arrives purely by CloudKit from another Mac — and a read that
        // arrives from the iPad — reach the menu bar exactly as a local turn does.
        // That equivalence is the entire reason the dots are derived rather than
        // accumulated from local events.
        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .conversationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees main-thread delivery, but the closure is
            // nonisolated — a bare `Task { }` would read and mutate the latch off
            // the main actor and could admit two runners, un-bounding the very
            // fan-out this exists to stop.
            MainActor.assumeIsolated {
                self?.scheduleConversationChurnRefresh()
            }
        })

        // Reply-notification tap (posted by `NotificationDelegate`) → bind the
        // WINDOW lane to the target thread (the deep-link opens the main
        // window, never the popover) so it opens onto the reply.
        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .openConversationDeepLink,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
                  let id = UUID(uuidString: idString) else { return }
            MainActor.assumeIsolated {
                self?.openConversation(id)
            }
        })

        // Reply-arrived (posted by `ConversationDetailViewModel` on every macOS
        // FOREGROUND reply success) → post the reply banner, and settle the
        // thread if the popover is watching this land. NOT the dot: the append
        // that produced this reply also posted `.conversationsDidChange`, and the
        // observer above is what refreshes the rows both dots are derived from.
        //
        // THE BANNER LIVES HERE AND NOWHERE ELSE. Both reply observers funnel
        // into `noteReplyArrived`, and the OTHER one
        // (`.remoteAgentTurnDidComplete`, i.e. the share drain / background
        // landing) has ALREADY posted a banner of its own through
        // `recordReply → finishRecordedReply → postReplyNotification`. Posting
        // from the shared method would emit TWO banners for one share reply and
        // consume the burst-chime window twice. The foreground-VM path is the
        // one that has no banner otherwise, and it is exactly this notification.
        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .conversationReplyArrived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
                  let id = UUID(uuidString: idString) else { return }
            MainActor.assumeIsolated {
                self?.noteReplyArrived(id)
                self?.postReplyBannerIfUnattended(id)
            }
        })

        // Background/SHARE reply landed (posted by `BackgroundRemoteAgent` AFTER
        // the agent bubble is persisted — `postTurnCompleted`, main queue). The
        // in-app macOS path appends in the foreground and posts
        // `.conversationReplyArrived` instead (no background delegate), so the two
        // events are mutually exclusive per turn — observing both means a share
        // reply landing in the open popover settles it too. We deliberately do NOT
        // fire from the share drainer's success branch: the dispatch awaiter
        // resumes BEFORE the reply is persisted, and a drainer post would also
        // miss the relaunch-reconcile completion.
        //
        // POSTS NO BANNER, deliberately: this path already posted one inside
        // `recordReply → finishRecordedReply → postReplyNotification`. Adding one
        // here — or moving the post into the shared `noteReplyArrived` — is the
        // double-banner bug.
        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .remoteAgentTurnDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
                  let id = UUID(uuidString: idString) else { return }
            MainActor.assumeIsolated {
                self?.noteReplyArrived(id)
            }
        })

        // A turn FAILED (posted by `BackgroundRemoteAgent` — background/headless
        // post-dispatch, share dispatch-failure, and `ConverseIntent`
        // pre-dispatch all route through it). Settles the thread when the popover
        // is showing exactly it — the user is looking at the inline failed bubble,
        // so the account has been shown this attempt. The RED dot itself comes
        // from the stored rows, not from here. A no-turn failure carries no thread
        // (empty/absent conversationID) → the guard no-ops, and such failures
        // surface via notification only, never the dot.
        observerBox.observers.append(NotificationCenter.default.addObserver(
            forName: .remoteAgentTurnDidFail,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idString = note.userInfo?[NotificationDeepLink.conversationIDKey] as? String,
                  let id = UUID(uuidString: idString) else { return }
            MainActor.assumeIsolated {
                self?.noteFailure(id)
            }
        })
    }

    // MARK: - Configured flag

    /// Re-decide what the window and the popover may show.
    ///
    /// Both answers come from ONE `newChatPickerSnapshot()` turn and from
    /// `GatewayGate`. One turn because read separately the roster and the default
    /// can describe different moments (a Settings re-point landing between the two
    /// awaits), and the popover would then invite a capture the window had already
    /// ruled out. `GatewayGate` because this file is `#if os(macOS)` and never
    /// compiles into the iOS-Simulator suite, so a predicate written inline here
    /// is untestable — which is how the window came to gate on the wrong one.
    ///
    /// The strict `configuredRemoteAgentRefs()` predicate is what both answers
    /// rest on: `remoteAgentSnapshot()` returns non-nil on a URL-ONLY gateway (no
    /// token for `.bearer`, no model for OpenRouter), a false positive that would
    /// let the user dictate into a half-configured gateway.
    ///
    /// Quick-capture readiness is `resolution.canSend`, which agrees with plain
    /// set membership of the default in the configured roster for every shape but
    /// two. Under `.selectionRequired` the compatibility projection is the
    /// built-in fallback, which may itself be configured — membership would
    /// answer "ready" for a device with no default chosen at all. And a custom
    /// the user retired from the roster can still be send-able, where membership
    /// and send-ability disagree in the other direction. `canSend` is true only
    /// where the pointer is a member of the configured set BY CONSTRUCTION.
    ///
    /// …OR the quick lane would CONTINUE a live conversation, which never touches
    /// the default at all. `resolveAutomaticDestinationNow` routes a TTL-fresh
    /// pointer straight to its own thread on that thread's sealed ref, so a
    /// verdict about the default has no authority over it — the same question
    /// `CheckNetworkIntent` and `ConverseIntent` ask before they look at the
    /// default, through the same helper, and the same one the wrist's
    /// `resolveHeadlessCaptureTarget` asks first. Without it a Mac whose user has
    /// picked no default is refused on EVERY press while their quick-lane thread
    /// is sitting right there, live.
    ///
    /// The pointer can lapse between this read and a press, which makes the flag
    /// permissive rather than restrictive for one TTL boundary — and that is the
    /// direction this gate already fails in by design (`isQuickCaptureKnownUnavailable`
    /// lets presses through while readiness is unknown, because the send path
    /// validates before it delivers and keeps the words in the retry stash).
    private func refreshConfiguredFlag() async {
        let snapshot = await SettingsManager.shared.newChatPickerSnapshot()
        hasAnyConfiguredGateway = GatewayGate.canSendAnywhere(configured: snapshot.configuredRefs)
        // Spelled out rather than `||` — the operator's right-hand side is a
        // non-async autoclosure and cannot carry the `await`. Short-circuited the
        // same way, so the healthy device never pays for the store fetch.
        var quickReady = GatewayGate.isQuickCaptureReady(resolution: snapshot.resolution)
        if !quickReady {
            quickReady = await SharedInboxRouting.liveQuickCaptureCanContinue(
                defaultRef: snapshot.defaultRef, store: conversationStore)
        }
        isQuickCaptureReady = quickReady
        defaultGatewayResolution = snapshot.resolution
        // The same value `armQuickCapture` resolves, from an earlier and cheaper
        // read — this snapshot is already in hand, so the popover has a name to
        // show before the arm path runs. Both sites stay: the arm path also
        // refreshes the custom roster the name is resolved against.
        quickDefaultGatewayName = RemoteAgentRefMetadata.displayName(
            for: snapshot.resolution.ref, customs: snapshot.badgeRoster)
        newChatSeedRef = NewChatGatewaySeed.resolve(
            configured: snapshot.configuredRefs,
            lastUsed: snapshot.lastUsedRef,
            persistedDefault: snapshot.defaultRef
        )
        hasLoadedGatewayState = true
        // The notice describes a state that no longer holds.
        if isQuickCaptureReady { showsQuickCaptureUnavailableNotice = false }
    }

    /// Re-read gateway readiness on demand.
    ///
    /// The flags are otherwise refreshed only at launch and on
    /// `.settingsDidChangeRemotely`, and neither fires when the thing that
    /// changed is the KEYCHAIN becoming readable. A refresh that ran before first
    /// unlock reads every `.bearer` gateway as unconfigured and caches that, and
    /// because the press guards then refuse every capture, nothing else would ever
    /// trigger the read that corrects it. Called when the popover is summoned and
    /// when the app is activated — both are moments the user is present and the
    /// device is necessarily unlocked.
    func refreshGatewayReadiness() async {
        await refreshConfiguredFlag()
    }

    // MARK: - Active conversation resolution

    /// On launch, gated by the user's `OnLaunchMode`: the default
    /// `.startNewConversation` leaves the QUICK lane unbound (empty state — a
    /// fresh conversation is minted on the first turn); `.resumeLastConversation`
    /// binds it to the TTL-active conversation if fresh, else the most-
    /// recently-active one (DISPLAY-ONLY — binding never stamps the pointer, so
    /// the fallback shows the last thread without retargeting captures).
    /// Mirrors iOS `ContentView.resolveInitialConversationID`. One-shot per
    /// process — the `quickViewModel == nil` guard prevents re-fire so window-
    /// close-then-reopen-while-process-alive keeps showing whatever the
    /// coordinator is bound to. Always ends by seeding the quick-destination
    /// snapshot so the first capture consumes a resolved destination.
    private func resolveActiveConversationOnLaunch() async {
        if quickViewModel == nil {
            let mode = await SettingsManager.shared.getOnLaunchMode()
            if mode == .resumeLastConversation {
                if let id = await SettingsManager.shared.resolveActiveConversationID() {
                    bindQuickViewModel(to: id)
                } else if let first = ((try? await conversationStore.fetchConversations()) ?? []).first {
                    bindQuickViewModel(to: first.id)
                }
            }
        }
        await refreshQuickDestination()
    }

    /// Open a conversation indicated by a reply-notification deep-link, the
    /// window sidebar, or the popover's "Open window…" hand-off. Binds the
    /// WINDOW lane — an explicit surface: a notification tap / sidebar pick
    /// deliberately does NOT touch the quick lane or the per-device
    /// quick-capture pointer (implicit-only: quick captures write it; browsing
    /// must not retarget where the next hotkey capture lands).
    ///
    /// SETTLES NOTHING, deliberately, and this is the one thing about the method
    /// worth remembering. Binding a lane is an INTENT to show a thread, not proof
    /// that anything is on screen: a deep-link can arrive while the window is
    /// closed, behind another app or miniaturized, and a sidebar pick can land in
    /// a window the user then leaves without reading. Acknowledging here would
    /// retire an ACCOUNT-wide mark — on the phone and the wrist too — for a reply
    /// or a failure nobody looked at, and nothing ever re-arms one.
    ///
    /// The two visibility callbacks answer that question properly and both settle
    /// on arrival: `setWindowVisibleConversation`, fed by `MainWindowView`'s
    /// `\.appearsActive`-gated `WindowThreadVisibilityReporter`, and
    /// `setPopoverVisibleConversation`. Whichever surface actually ends up showing
    /// this thread reports it, and the marker is written then.
    func openConversation(_ id: UUID) {
        bindWindowViewModel(to: id)
    }

    /// Clear the WINDOW lane so the window returns to its new-chat empty state;
    /// the next typed turn mints a fresh conversation. Backs the sidebar
    /// "New Conversation" button + ⌘N. Deliberately does NOT clear the
    /// quick-capture pointer or the quick lane — an explicit window action must
    /// not retarget the hotkey lane (the Settings-side "Start new conversation"
    /// clears in `SettingsViewModel` are a different, deliberate surface).
    func startNewWindowConversation() {
        windowViewModel = nil
        sweepRegistry()
    }

    /// Clear the QUICK lane so the popover returns to its fresh compose/start
    /// state; the next capture mints a brand-new chat on the persisted default
    /// gateway. Backs the popover header's "New chat" button — the ONE explicit
    /// "start over" affordance now that a popover response always continues the
    /// visible reply (`armQuickCapture`'s direct-response freeze). SETTLED-ONLY:
    /// a no-op mid-capture / mid-turn (mirrors the button's visibility) so it
    /// can't yank a thread out from under an in-flight turn.
    func startNewQuickChat() {
        guard dictationService.state == .idle,
              !turnStarting,
              quickViewModel?.isAwaitingReply != true,
              quickViewModel?.sendError == nil else { return }
        // The popover renders `popoverOverrideViewModel ?? quickViewModel`, so a
        // lingering read-only override would keep winning after we clear the
        // quick lane — drop it first.
        clearPopoverOverride()
        // Arm a fresh chat on the persisted default gateway. `.explicitNew(nil)`
        // survives to the next capture (it doesn't set `quickDestinationLatched`,
        // so `armQuickCapture`'s self-heal won't wipe it) and mints in
        // `handleQuickSend`.
        selectQuickDestination(.explicitNew(nil))
        // Drop the retained reply + its VM so the popover falls to the empty
        // state (mirrors `startNewWindowConversation`). Settled-only above means
        // the retired VM leaves no in-flight turn stranded.
        quickViewModel = nil
        setPopoverVisibleConversation(nil)
        sweepRegistry()
    }

    // MARK: - Quick destination (capture-time snapshot)

    /// Re-resolve the automatic destination + refresh the snapshot caches.
    /// The DESTINATION half is a no-op while LATCHED (a capture armed — the press
    /// froze the snapshot) or while the current destination is EXPLICIT (a pick is
    /// sticky until consumed by a capture or reset/discarded). Called on launch,
    /// on settings/conversation change, and after every turn settles.
    ///
    /// THE CACHE HALF RUNS ON EVERY CALL, ahead of both guards, and that ordering
    /// is load-bearing. Those guards protect the frozen destination; neither has
    /// anything to say about the menu bar's dots, which are derived from the rows
    /// this refresh fetches. Gating the fetch on them would freeze both dots for
    /// the length of a capture — and the latch is held until the turn SETTLES, so
    /// that is the whole multi-minute agent wait: a reply landing in another
    /// thread, or a read arriving from the iPad, would not reach the status item
    /// until the current turn finished.
    /// Coalescing guards for the two NOTIFICATION-driven refreshes below. Both
    /// paths reach `refreshQuickCaches()` → `ConversationStore.fetchRecentForPicker`,
    /// and both suspend on `SettingsManager` before they get there — so a burst
    /// of posts used to overlap without bound, one live fetch per post. Each
    /// fetch opens a fresh background context and parks a dispatch worker on a
    /// synchronous Core Data coordinator hop; at libdispatch's 512-thread
    /// ceiling nothing can be scheduled again and the process wedges. Same
    /// shape, same reason, as `ConversationDetailViewModel.scheduleReload()`.
    ///
    /// ONE runner for BOTH notifications, with a pending bit per reason. Two
    /// independent latches would each be locally correct and still race: both
    /// reach `refreshQuickCaches()`, which writes `quickCustomGateways`,
    /// `quickDefaultGatewayName` and `quickRecents` with no generation guard of
    /// its own (`resolveAutomaticDestinationNow` guards only against a newer
    /// ARM, not a sibling refresh). Interleaved at their `await`s, the older
    /// pass can commit after the newer one and settle the dots on stale rows.
    /// Single-flighting the shared state — not each caller — is the fix.
    /// `@ObservationIgnored` — pure bookkeeping, never drives a view.
    @ObservationIgnored private var quickRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var quickRefreshSettingsPending = false
    @ObservationIgnored private var quickRefreshChurnPending = false

    /// `.conversationsDidChange` → destination re-resolve + header-memo warm.
    private func scheduleConversationChurnRefresh() {
        quickRefreshChurnPending = true
        startQuickRefreshIfIdle()
    }

    /// `.settingsDidChangeRemotely` → configured flag + destination re-aim.
    private func scheduleRemoteSettingsRefresh() {
        quickRefreshSettingsPending = true
        startQuickRefreshIfIdle()
    }

    /// Drain both pending bits on one serialized runner: at most one pass in
    /// flight, plus one trailing pass for whatever arrived during it. A CloudKit
    /// import storm or a KVS sync burst therefore costs a BOUNDED number of
    /// `fetchRecentForPicker` calls instead of one per post — each of which
    /// takes a fresh background context and parks a dispatch worker on a
    /// synchronous Core Data coordinator hop, and at libdispatch's 512-thread
    /// ceiling nothing can be scheduled again and the process wedges.
    ///
    /// Order is load-bearing and matches what the two handlers did separately:
    /// `refreshConfiguredFlag` (roster truth) → `refreshQuickDestination`
    /// (re-aim from it) → `warmHeaderMemo` (label rows the churn introduced).
    /// Each half still runs only for the reason that asked for it, so a settings
    /// post never pays for the memo warm and churn never re-reads the flag.
    ///
    /// Nothing suspends between the final pending read and clearing the task —
    /// that gap is exactly where reentrancy would slip a second runner in.
    private func startQuickRefreshIfIdle() {
        guard quickRefreshTask == nil else { return }
        quickRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.quickRefreshSettingsPending || self.quickRefreshChurnPending {
                let settings = self.quickRefreshSettingsPending
                let churn = self.quickRefreshChurnPending
                self.quickRefreshSettingsPending = false
                self.quickRefreshChurnPending = false
                if settings {
                    await self.refreshConfiguredFlag()
                }
                // A default-gateway change (or custom-roster edit) re-aims the
                // automatic destination; conversation churn shifts the rows
                // behind it. Both reasons need this, so it is unconditional.
                // No-op on the DESTINATION while latched/explicit.
                await self.refreshQuickDestination()
                if churn {
                    // Fill header-memo entries for rows this churn introduced
                    // (fresh mint / CloudKit import) — misses only; visited
                    // entries stay owned by their VM's resolve.
                    await ConversationDetailViewModel.warmHeaderMemo()
                }
            }
            self.quickRefreshTask = nil
        }
    }

    func refreshQuickDestination() async {
        var destinationIsExplicit = false
        switch quickDestination?.destination {
        case .explicitNew, .explicitConversation: destinationIsExplicit = true
        case .automatic, nil: break
        }
        guard !quickDestinationLatched, !destinationIsExplicit else {
            await refreshQuickCaches()
            return
        }
        await resolveAutomaticDestinationNow()
    }

    /// Re-read everything this coordinator caches about the store and the gateway
    /// roster, then re-derive the menu-bar dots from it.
    ///
    /// The ONE place `quickRecents` is written, which is why it also owns the
    /// derivation: the rows and the dots must never be one fetch apart.
    ///
    /// The name caches come first so the automatic snapshot and every
    /// `selectQuickDestination` pick resolve display names synchronously
    /// afterwards — a menu tap must not hop actors to label its own pick.
    private func refreshQuickCaches() async {
        let defaultRef = await SettingsManager.shared.defaultRemoteAgentRef()
        let customs = await SettingsManager.shared.gatewayBadgeRoster()
        quickCustomGateways = customs
        quickDefaultGatewayName = RemoteAgentRefMetadata.displayName(for: defaultRef, customs: customs)
        // WITH turn states: these rows answer both dots and carry the
        // acknowledgement's attempt IDENTITY, which only this projection has.
        // Without it the menu bar could resolve nothing but "unacknowledged" and
        // would contradict the conversation list on the same screen — the exact
        // inconsistency the account-wide markers exist to remove. The cost is ONE
        // extra whole-store aggregate query per refresh (never one per row), on a
        // path that already re-reads the picker rows.
        quickRecents = (try? await conversationStore.fetchRecentForPicker(
            limit: 6,
            includeTurnStates: true
        )) ?? []
        refreshAttention()
    }

    /// The actual resolve — split from `refreshQuickDestination` so
    /// `armQuickCapture` can force it WHILE latched (the press instant wins any
    /// TTL race; the latch only blocks *background* refreshes).
    private func resolveAutomaticDestinationNow() async {
        // The arm this resolve belongs to. If a NEWER arm lands before we reach
        // the write below, this resolve is stale and must NOT commit (a later
        // arm — notably the direct-response freeze — has already decided).
        // Captured BEFORE the cache refresh, because that refresh awaits and a
        // newer arm can land inside it.
        let generation = armGeneration
        await refreshQuickCaches()

        // Pointer resolution rides the shared quick-capture helper (TTL +
        // default-gateway re-check): a pointer whose row is bound to a
        // no-longer-default gateway resolves nil → fresh mint on the default.
        let snapshot: QuickDestinationSnapshot
        if let record = await SharedInboxRouting.resolveQuickCaptureConversation(store: conversationStore) {
            snapshot = QuickDestinationSnapshot(
                destination: .automatic(existing: record.id),
                titleSnippet: record.displayTitle,
                gatewayName: quickGatewayDisplayName(forBackendRaw: record.backend),
                lastActivityAt: record.lastActivityAt
            )
        } else {
            snapshot = QuickDestinationSnapshot(
                destination: .automatic(existing: nil),
                titleSnippet: nil,
                gatewayName: quickDefaultGatewayName,
                lastActivityAt: nil
            )
        }
        quickAutomaticSnapshot = snapshot
        // A NEWER arm superseded this resolve while it was awaiting — its frozen
        // destination wins (the direct-response freeze bumps the generation and
        // writes `.automatic(existing:)`, which this stale resolve would
        // otherwise clobber automatic-over-automatic).
        guard generation == armGeneration else { return }
        // An explicit pick stays sticky even if this resolve raced in behind it
        // (e.g. an arm-task landing after a quick menu tap): explicit beats
        // automatic, never the other way around.
        switch quickDestination?.destination {
        case .explicitNew, .explicitConversation: break
        case .automatic, nil: quickDestination = snapshot
        }
    }

    /// Gateway display name for a stored `Conversation.backend` raw string,
    /// resolved against the cached roster (no actor hop — `resolveAutomaticDestinationNow`
    /// labels the automatic snapshot's gateway with it); unparseable raw → the
    /// default gateway's name (defensive, mirrors the VM's fallback ladder).
    func quickGatewayDisplayName(forBackendRaw raw: String) -> String {
        guard let ref = RemoteAgentRef(rawString: raw) else { return quickDefaultGatewayName }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: quickCustomGateways)
    }

    /// Picker tap → replace the snapshot IN PLACE, synchronously (metadata from
    /// the cached `quickRecents` / cached names — a menu tap must not hop
    /// actors to label its own pick). Allowed while idle AND while recording
    /// (the user may retarget mid-capture; the send consumes whatever is
    /// displayed, so display==send still holds). Stays latched if latched.
    /// Blocked once the turn is consuming the snapshot (processing / hand-off
    /// gap / agent wait) — the popover disables the control there too; this
    /// guard is the correctness backstop.
    func selectQuickDestination(_ destination: QuickDestination) {
        guard dictationService.state != .processing,
              !turnStarting,
              quickViewModel?.isAwaitingReply != true else { return }
        switch destination {
        case .explicitNew(let ref):
            // The picked gateway's display name (default name when nil) drives
            // the "New chat · {gateway}" caption synchronously — the cached
            // custom roster avoids an actor hop inside the menu tap.
            let name = ref.map { RemoteAgentRefMetadata.displayName(for: $0, customs: quickCustomGateways) }
                ?? quickDefaultGatewayName
            quickDestination = QuickDestinationSnapshot(
                destination: destination,
                titleSnippet: nil,
                gatewayName: name,
                lastActivityAt: nil
            )
        case .explicitConversation(let id):
            let recent = quickRecents.first(where: { $0.id == id })
            quickDestination = QuickDestinationSnapshot(
                destination: destination,
                titleSnippet: recent?.label,
                gatewayName: recent.map { quickGatewayDisplayName(forBackendRaw: $0.backend) }
                    ?? quickDefaultGatewayName,
                lastActivityAt: recent?.lastActivityAt
            )
        case .automatic:
            // "Back to automatic" — restore the cached automatic resolution
            // verbatim (synchronous; see `quickAutomaticSnapshot`). A missing
            // cache (shouldn't happen — the row only renders from it) falls
            // back to a bare automatic that `handleTranscript` re-resolves.
            quickDestination = quickAutomaticSnapshot ?? QuickDestinationSnapshot(
                destination: destination,
                titleSnippet: nil,
                gatewayName: quickDefaultGatewayName,
                lastActivityAt: nil
            )
        }
    }

    /// The hotkey press: FREEZE the destination for this capture. An automatic
    /// (or not-yet-resolved) destination is re-resolved NOW — the popover may
    /// have sat open across a TTL boundary, and the press instant wins; an
    /// explicit override is kept verbatim (the pick IS the destination).
    /// `handleTranscript` awaits `quickArmTask` so STT finishing first can't
    /// consume a half-resolved snapshot.
    func armQuickCapture() {
        // Every arm advances the generation so a stale resolver from a PRIOR arm
        // can't win the write in `resolveAutomaticDestinationNow` (see
        // `armGeneration`). Must precede the direct-response early return below,
        // which relies on it to protect its `.automatic(existing:)` freeze.
        armGeneration &+= 1

        // Direct-response continuation: when the popover is OPEN and IDLE showing
        // THIS quick thread's own settled reply, a response made in it ALWAYS
        // continues that thread (on its bound gateway) — the TTL/session policy
        // governs COLD captures only. Freeze the destination to the visible
        // thread and skip the re-resolve. Evaluated BEFORE `clearPopoverOverride`
        // because the override-nil check is part of the guard (a read-only
        // shared-reply glance is a DIFFERENT thread — it must fall through to the
        // policy, not force-continue). `.automatic(existing:)` — not
        // `.explicitConversation` — so the send re-stamps the quick pointer
        // (`stampsQuickPointer`), keeping a later COLD ⌘⇧1 pointed at this
        // just-answered thread within the window.
        if dictationService.state == .idle,
           popoverOverrideViewModel == nil,
           quickViewModel?.isAwaitingReply != true,
           quickViewModel?.sendError == nil,
           let visibleID = popoverVisibleConversationID,
           visibleID == quickViewModel?.conversationID,
           quickViewModel?.lastPopoverReply != nil {
            quickDestinationLatched = true
            quickArmTask = nil   // any prior resolver is now generation-stale
            quickDestination = QuickDestinationSnapshot(
                destination: .automatic(existing: visibleID),
                titleSnippet: nil,
                gatewayName: quickViewModel?.backendDisplayName ?? quickDefaultGatewayName,
                lastActivityAt: nil
            )
            return
        }

        // A new capture always shows the QUICK lane — drop any read-only
        // shared-reply override the popover may have been displaying.
        clearPopoverOverride()
        // Self-heal a latch left over from an ABANDONED error turn (popover
        // clicked away while `.error` — no reset ran): a NEW capture must not
        // consume the dead turn's one-shot explicit pick hours later. Recovery
        // re-arms are exempt — a retained screenshot or stashed transcript
        // means this arm CONTINUES that turn, and its snapshot must ride
        // (the Retry-Voice contract: same shot, same destination).
        if quickDestinationLatched, pendingCaptureImage == nil, !hasPendingFailedTurn {
            switch quickDestination?.destination {
            case .explicitNew, .explicitConversation:
                quickDestination = nil   // re-resolved as automatic below
            case .automatic, nil:
                break
            }
        }
        quickDestinationLatched = true
        switch quickDestination?.destination {
        case .explicitNew, .explicitConversation:
            return
        case .automatic, nil:
            quickArmTask = Task { [weak self] in
                await self?.resolveAutomaticDestinationNow()
            }
        }
    }

    /// A turn settled (delivered, failed-without-stash, or abandoned): unlatch,
    /// drop the arm task, revert any consumed explicit override back to
    /// automatic (one-shot semantics), and re-resolve in the background so the
    /// popover label reflects the new reality (a just-stamped pointer now
    /// resolves as the automatic destination).
    ///
    /// KNOWN BENIGN RACE (documented, not coordinated): if a SECOND capture is
    /// armed while the first turn's agent wait is still running, the first
    /// turn's settle lands here mid-capture and unlatches the second's frozen
    /// snapshot. Harmless in practice: during the wait the direct-response freeze
    /// is blocked (its `isAwaitingReply != true` guard is false) and no picker
    /// exists, so the second capture can only be AUTOMATIC — and the background
    /// re-resolve produces the same automatic answer (label and send read the
    /// same snapshot, so display==send still holds). An explicit pick can never
    /// ride this race. (`armGeneration` guards a DIFFERENT race — a stale
    /// resolver clobbering the direct-response freeze — not this settle-unlatch
    /// one, which needs no coordination.)
    func resetQuickDestinationAfterTurn() {
        quickDestinationLatched = false
        quickArmTask = nil
        switch quickDestination?.destination {
        case .explicitNew, .explicitConversation:
            quickDestination = nil   // refresh below repopulates with automatic
        case .automatic, nil:
            break
        }
        Task { [weak self] in
            await self?.refreshQuickDestination()
        }
    }

    /// Popover closed (any path — X, Esc, transient outside-click). When the
    /// close is a true IDLE dismissal, an unconsumed explicit pick dies with
    /// the popover (one-shot semantics: a pick with no capture must not
    /// silently retarget a capture made hours later). Every mid-turn guard
    /// below exists because a TRANSIENT dismiss during the agent wait (or
    /// mid-capture, or with compose state staged — a screenshot or a
    /// text-mode draft) must NOT reset the destination the turn is about to
    /// consume / is consuming.
    func popoverDidCloseHook() {
        guard !turnStarting, quickViewModel?.isAwaitingReply != true else { return }

        // Abandoned ERROR dismissal: the popover closed in `.error` with
        // nothing recoverable (no compose state, no stashed transcript) —
        // the turn is dead, so settle it fully. Without this, the latch
        // survives the click-away forever: background refreshes stay frozen
        // and a capture made much later would consume the dead turn's
        // explicit pick. (An error WITH recovery context keeps its latch —
        // Retry must replay into the frozen destination.)
        if case .error = dictationService.state,
           !hasComposeState, !hasPendingFailedTurn {
            resetQuickDestinationAfterTurn()
            return
        }

        guard dictationService.state == .idle,
              !quickDestinationLatched,
              !hasComposeState else { return }
        switch quickDestination?.destination {
        case .explicitNew, .explicitConversation:
            quickDestination = nil
            Task { [weak self] in
                await self?.refreshQuickDestination()
            }
        case .automatic, nil:
            break
        }
    }

    // MARK: - Pending capture image (Screenshot & Ask)

    /// Stage the region screenshot for the imminent voice turn. Called by
    /// `MenuBarController` right after a successful `RegionCaptureController`
    /// capture, before it starts the recording.
    func setPendingCaptureImage(_ data: Data) {
        pendingCaptureImage = data
    }

    /// Drop the staged screenshot (after a delivered send, or on Cancel/Discard).
    func clearPendingCaptureImage() {
        pendingCaptureImage = nil
    }

    /// Universal explicit-bail teardown — Esc, the popover's recording Cancel-X,
    /// its working-view X, the capture-recovery Discard, and the error-footer
    /// Dismiss ALL route here. Mode- AND state-independent: cancels an in-flight
    /// reply (guarded), cancels the active recording (discards audio, no STT;
    /// also clears `.error → .idle`), drops a staged ⌘⇧2 screenshot AND the typed
    /// draft, discards any stranded-turn stash, and releases the armed
    /// destination. After this nothing survives to spill into the next ⌘⇧1/⌘⇧2
    /// summon. Every clear is a guard-free no-op when N/A. Only the IMPLICIT
    /// click-away dismiss preserves compose state (see `popoverDidCloseHook`).
    func cancelActiveCapture() {
        if quickViewModel?.isAwaitingReply == true { quickViewModel?.cancelInFlight() }
        dictationService.cancelRecording()
        clearPendingCaptureImage()
        quickDraft = ""
        discardPendingFailedTurn()
        resetQuickDestinationAfterTurn()
    }

    /// "Type Instead" — bail out of the voice turn into the typed composer while
    /// keeping the captured screenshot. Parks the image on the composer bridge,
    /// cancels the recording, and opens the conversations window (which drains
    /// the bridge into the composer's staging). Clears the popover-side pending
    /// image last so the popover collapses out of capture mode. The quick
    /// destination resets too — the turn continues as a WINDOW-lane typed turn,
    /// so the armed quick snapshot is dead.
    func typeInsteadFromCapture() {
        pendingComposerImage = pendingCaptureImage
        dictationService.cancelRecording()
        NotificationCenter.default.post(name: .openConversationsWindow, object: nil)
        clearPendingCaptureImage()
        resetQuickDestinationAfterTurn()
    }

    // MARK: - STT terminal step → agent round-trip

    /// Forward an STT transcript to the converse path by CONSUMING the
    /// capture-time `QuickDestinationSnapshot` — NEVER re-resolving the
    /// destination here. The popover displayed the snapshot at capture time;
    /// re-resolving at send time (the old behavior) could land the words
    /// somewhere else whenever the TTL flipped between the press and STT
    /// completing — the display-one-send-another bug this method's shape kills.
    ///
    /// A "Screenshot & Ask" (⌘⇧2) capture stages a screenshot on
    /// `pendingCaptureImage`; it rides this same voice turn as a
    /// `PendingAttachment.image`. The image is cleared in the `defer` (every
    /// exit here is terminal for the screenshot — empty/failed STT flips
    /// `DictationService` to `.error` UPSTREAM and never calls through here).
    func handleTranscript(_ transcript: String) async {
        await handleQuickSend(transcript, modality: .voice)
    }

    /// Send a TEXT-mode quick turn: the popover compose field's Return press.
    /// The quick-lane analog of the `onTranscript` closure — everything before
    /// the `Task` is synchronous and in ONE MainActor turn, so the draft clear
    /// + `turnStarting` (→ the popover's working view) commit in the same
    /// render (no stale frame), and `armQuickCapture()` freezes the displayed
    /// destination at the press instant (display==send, exactly like voice —
    /// text mode just has a zero-length "recording" between arm and send).
    func sendQuickTypedDraft() {
        let trimmed = quickDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty no-op MUST precede any state change: entering `handleQuickSend`
        // empty would burn a staged ⌘⇧2 screenshot via its defer. Attachment-only
        // turns (image staged, no words) are allowed — parity with `handleTypedText`.
        guard !trimmed.isEmpty || pendingCaptureImage != nil else { return }
        // Backstops against a racing Return while a turn is consuming the
        // pipeline (the compose surface is hidden during the working phase, so
        // these shouldn't fire from the UI). Both return BEFORE the draft
        // clears — a blocked send must not eat the words.
        guard !turnStarting, quickViewModel?.isAwaitingReply != true else { return }
        switch dictationService.state {
        case .recording, .processing:
            // A shared-service capture is live (window-composer mic) — the
            // popover renders its HUD, not the compose surface.
            return
        case .error:
            // Typing anew over a presented error mirrors the voice fresh-press
            // (`MenuBarController.handleShortcutPress` .error arm): drop the
            // stash — the user chose new words over Retry — and clear the
            // error surface. `armQuickCapture()`'s self-heal then releases the
            // stale latch a stash-error left behind.
            discardPendingFailedTurn()
            dictationService.cancelRecording()
        case .idle:
            break
        }
        turnStarting = true
        quickDraft = ""
        armQuickCapture()
        Task { [weak self] in
            await self?.handleQuickSend(trimmed, modality: .text)
        }
    }

    /// The shared quick-lane send (voice transcripts + text-mode typed turns).
    /// One body so the snapshot-consume / mint / busy / stash ladder cannot
    /// drift between modalities — only the stash case, the empty-text rule,
    /// and `sendUserTurn`'s modality differ.
    private func handleQuickSend(_ text: String, modality: TurnModality) async {
        // The stash-error returns below (deleted/busy/mint-failed destination)
        // keep the snapshot LATCHED so the error footer's Retry replays into
        // EXACTLY the destination this capture froze; every other exit resets
        // it (turn consumed or abandoned).
        var keepSnapshot = false
        // Clear the gap-bridge flag + staged screenshot on EVERY exit; reset
        // the destination unless a stash-error kept it; sweep so a turn that
        // re-bound the quick lane releases the previous thread's VM.
        defer {
            turnStarting = false
            clearPendingCaptureImage()
            if !keepSnapshot { resetQuickDestinationAfterTurn() }
            sweepRegistry()
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Voice: a transcript is the whole turn — empty means nothing to send.
        // Text: an empty caption is allowed iff a ⌘⇧2 screenshot is staged
        // (attachment-only turn — `sendQuickTypedDraft` pre-guards the
        // no-image case, this is the replay-path backstop).
        switch modality {
        case .voice:
            guard !trimmed.isEmpty else { return }
        case .text:
            guard !trimmed.isEmpty || pendingCaptureImage != nil else { return }
        }

        // The arm-time re-resolution must settle before the snapshot is read —
        // a fast STT on a short utterance can finish before the resolve does.
        await quickArmTask?.value
        quickArmTask = nil

        // Device-local "speak quick-lane replies" toggle, read PER SEND here
        // with the other capture-time reads (never cached on the VM — the
        // registry shares one VM with the window lane, which must NEVER speak;
        // per-send also means a Settings flip applies to the very next
        // capture). Read BEFORE the busy-check → send hand-off below so it
        // adds no suspension point inside that window. Every quick surface
        // rides this single send: the popover mic, ⌘⇧1, AND ⌘⇧2
        // Screenshot & Ask (the screenshot is just an attachment on this same
        // turn).
        let speaksReply = await SettingsManager.shared.getSpeakQuickLaneReplies()

        // Snapshot-nil fallback (a replayed stash from before any resolve, or
        // a turn fired before launch seeding finished): build the automatic
        // case from the shared resolver — identical routing, just resolved
        // late because there was nothing displayed to diverge from.
        let snapshot: QuickDestinationSnapshot
        if let current = quickDestination {
            snapshot = current
        } else {
            let record = await SharedInboxRouting.resolveQuickCaptureConversation(store: conversationStore)
            snapshot = QuickDestinationSnapshot(
                destination: .automatic(existing: record?.id),
                titleSnippet: record?.displayTitle,
                gatewayName: quickDefaultGatewayName,
                lastActivityAt: record?.lastActivityAt
            )
        }

        // Resolve the snapshot's destination to a target conversation id
        // (nil → mint fresh below, on `mintRef` if the pick named a gateway,
        // else the persisted default).
        var targetID: UUID?
        var mintRef: RemoteAgentRef?
        switch snapshot.destination {
        case .automatic(let existingID):
            if let existingID,
               ((try? await conversationStore.fetchConversation(id: existingID)) ?? nil) != nil {
                targetID = existingID
            } else {
                // Pointer thread deleted between snapshot and send → fall
                // through to a fresh mint. The IMPLICIT lane never errors on a
                // vanished pointer — the user never chose that thread, so
                // "continue → new chat" is invisible-correct, not a surprise.
                targetID = nil
            }
        case .explicitNew(let ref):
            targetID = nil
            mintRef = ref
        case .explicitConversation(let id):
            if ((try? await conversationStore.fetchConversation(id: id)) ?? nil) != nil {
                targetID = id
            } else {
                // The user EXPLICITLY picked this thread and it's gone — unlike
                // the automatic case a silent reroute would betray the pick, so
                // surface it. Stash the words for the error footer's Retry and
                // repoint the snapshot to `.explicitNew` KEPT LATCHED, so the
                // error copy's promise ("Retry → new chat") is exactly what the
                // replay does. Stash ONLY when the error actually presented
                // (see `pendingFailedTurn` invariant) AND there are words to
                // replay — a typed attachment-only turn has none (its image is
                // cleared by the defer), so it degrades to a Dismiss-only error.
                if dictationService.presentHandoffError(message: destinationDeletedMessage),
                   !trimmed.isEmpty {
                    pendingFailedTurn = quickStash(trimmed, modality: modality)
                    quickDestination = QuickDestinationSnapshot(
                        destination: .explicitNew(nil),
                        titleSnippet: nil,
                        gatewayName: quickDefaultGatewayName,
                        lastActivityAt: nil
                    )
                    keepSnapshot = true
                }
                return
            }
        }

        // Mint when no existing target: on the snapshot's explicit gateway
        // (`mintRef`, from a "New chat · {gateway}" pick), else the persisted
        // default. The window picker's `pendingNewConversationRef` is
        // deliberately NOT consumed here (window-lane state — `handleTypedText`
        // owns it): a gateway picked for the next WINDOW chat must not hijack
        // a hotkey capture (Decision F). The quick lane's own one-shot pick
        // rides the latched snapshot instead.
        let resolvedID: UUID
        if let targetID {
            resolvedID = targetID
        } else {
            let snapshot = await SettingsManager.shared.newChatPickerSnapshot()
            let ref: RemoteAgentRef = mintRef ?? snapshot.defaultRef
            // VALIDATE BEFORE MINTING, the rule `SharedInboxRouting.mintOnRef`
            // already applies to every headless lane and this one did not. A
            // conversation seals its gateway at creation and never re-routes, so
            // minting on a ref that cannot send leaves a permanently dead thread
            // in the sidebar — one per attempt — and the user's words then fail
            // one layer deeper, where the stash machinery below cannot keep them.
            //
            // The press-time guards in `MenuBarController` stop the common case
            // before a recording even starts; this is what covers the rest: a
            // configuration change landing between the press and the send, a door
            // that forgets to check, and the launch window where readiness is
            // still unknown. Refusing here costs a visible error with the words
            // kept; not refusing costs a thread that can never answer.
            guard snapshot.configuredRefs.contains(ref) else {
                if dictationService.presentHandoffError(message: destinationUnavailableMessage),
                   !trimmed.isEmpty {
                    pendingFailedTurn = quickStash(trimmed, modality: modality)
                    keepSnapshot = true
                }
                return
            }
            guard let fresh = try? await conversationStore.createConversation(backend: ref.rawString) else {
                // Mint failed (rare Core Data create failure) — never swallow
                // the just-captured words. Same stash machinery as above;
                // the snapshot stays latched so Retry replays the SAME
                // destination decision (e.g. an explicit "New chat" pick stays
                // a new chat, not whatever automatic resolves to later).
                if dictationService.presentHandoffError(message: mintFailedMessage),
                   !trimmed.isEmpty {
                    pendingFailedTurn = quickStash(trimmed, modality: modality)
                    keepSnapshot = true
                }
                return
            }
            // Same reason as the window mint: `viewModel(for:)` below binds a VM
            // whose header would otherwise open on the "Personal AI" placeholder.
            await ConversationDetailViewModel.seedHeaderIdentity(
                for: fresh,
                ref: ref,
                hasTurns: false
            )
            resolvedID = fresh.id
        }

        // Busy target: the VM's atomic in-flight claim would silently swallow
        // this turn (its guard returns before the optimistic bubble is ever
        // written — the words would just vanish). Upgrade to a VISIBLE error +
        // stash; the snapshot stays latched, so Retry replays into the SAME
        // target once it frees up.
        let vm = viewModel(for: resolvedID)
        if vm.isAwaitingReply {
            if dictationService.presentHandoffError(message: destinationBusyMessage),
               !trimmed.isEmpty {
                pendingFailedTurn = quickStash(trimmed, modality: modality)
                keepSnapshot = true
            }
            return
        }

        // Successful hand-off — a stale stash (user re-recorded instead of
        // Retrying) must not ride a later, unrelated error's Retry.
        pendingFailedTurn = nil
        // Committed dispatch: this turn WILL produce a reply banner, so ask for
        // permission now if it is still undecided. Idempotent, non-blocking, and
        // never gates the send.
        requestNotificationPermissionIfNeeded()
        bindQuickViewModel(to: resolvedID)
        // Thread a pending "Screenshot & Ask" screenshot onto the turn as an
        // inline image attachment (empty when this is a plain ⌘⇧1 capture).
        // The `defer` above clears it on the way out.
        let attachments: [PendingAttachment] = pendingCaptureImage.map { [.image($0)] } ?? []
        await vm.sendUserTurn(
            trimmed,
            modality: modality,
            attachments: attachments,
            stampsQuickPointer: snapshot.stampsQuickPointer,
            speaksReply: speaksReply,
            // The quick/hotkey lane owns the popover: its reply is retained and
            // shown there. ALL three destinations qualify (incl. a picked
            // recent, which sends `stampsQuickPointer: false`) — surfacing is a
            // separate axis from pointer-stamping.
            surfacesInPopover: true
        )
    }

    /// The quick-lane stash case for a modality — voice replays keep their
    /// transcript framing; text-mode replays go back through
    /// `handleQuickSend(.text)` so the modality chip and snapshot consumption
    /// match the original press.
    private func quickStash(_ text: String, modality: TurnModality) -> PendingFailedTurn {
        switch modality {
        case .voice: return .voice(transcript: text)
        case .text: return .quickTyped(text: text)
        }
    }

    /// Forward a TYPED turn from the unified window to the WINDOW lane.
    /// Unlike `handleTranscript` (voice quick-capture, snapshot-driven), the
    /// window user is looking at the thread, so a typed turn appends to the
    /// VISIBLE conversation regardless of TTL — and stays on the default
    /// `stampsQuickPointer: false` (explicit surfaces never retarget the quick
    /// lane). Mints a fresh conversation (bound to the window picker's pending
    /// backend, else the persisted default) only when the lane is empty.
    func handleTypedText(_ dispatch: ComposerTurnDispatch) async -> Bool {
        defer { sweepRegistry() }
        let trimmed = dispatch.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !dispatch.attachments.isEmpty else { return false }
        guard ComposerDispatchOwnership.matches(
            sealedConversationID: dispatch.conversationID,
            activeConversationID: windowViewModel?.conversationID
        ) else {
            windowViewModel?.reportComposerDispatchRejection()
            return false
        }
        // Set only when THIS call mints a fresh row, so the last-used pointer is
        // recorded once the turn is accepted below — appending to an existing
        // thread says nothing about which gateway new chats should start on.
        var mintedRef: RemoteAgentRef?
        if windowViewModel == nil {
            // The composer minted this turn's file-server keys under
            // `pendingConversationID` before any row existed, so the row adopts
            // that identifier and the files are already in its folder. Passing
            // it here — and NOT through `dispatch.conversationID`, the
            // nil-means-new-chat ownership sentinel the guards above branch on —
            // is what keeps a new-chat send from reading as a conversation switch.
            guard let fresh = try? await conversationStore.createConversation(
                id: dispatch.pendingConversationID,
                backend: dispatch.ref.rawString
            ) else {
                // Mint failed. The local-acceptance handshake leaves the window
                // composer's draft and attachments intact; also surface the
                // failure on the coordinator's existing error footer.
                _ = dictationService.presentHandoffError(message: mintFailedMessage)
                return false
            }
            // Hand the row's identity to the memo BEFORE binding: the bind mints
            // a VM whose `backendDisplayName` is the generic "Personal AI" until
            // its resolve lands, and the title bar switches to reading it the
            // moment `windowViewModel` goes non-nil.
            //
            // Deliberately ABOVE the ownership guard, not between it and the
            // clear-and-bind pair it protects — that pair must follow the guard
            // with no suspension in between. The cost is that an abandoned mint
            // leaves one stale memo entry keyed by a deleted UUID: bounded, never
            // looked up again, and cheaper than reopening the race the guard
            // exists to close.
            await ConversationDetailViewModel.seedHeaderIdentity(
                for: fresh,
                ref: dispatch.ref,
                hasTurns: false
            )
            guard ComposerMintOwnership.resolve(
                sealedConversationID: dispatch.conversationID,
                activeConversationIDAfterMint: windowViewModel?.conversationID
            ) == .adoptFreshConversation else {
                // The create hop suspended and the user selected an existing
                // conversation meanwhile. Discard only our unused empty mint;
                // never bind it over the user's newer selection.
                try? await conversationStore.deleteConversation(id: fresh.id)
                // Real deletion is the ONLY thing that drops the device-local
                // read-state residue (absence from a fetch is not one), so
                // every delete path calls this — even a mint that never carried
                // an echo. The durable markers need nothing: they are columns
                // on the conversation and die with it by cascade.
                ReadStateStore.shared.forget(fresh.id)
                windowViewModel?.reportComposerDispatchRejection()
                return false
            }
            // Consume the mutable picker slot only after the sealed ref was
            // durably minted. A failed mint leaves both composer and picker
            // ownership intact for retry.
            pendingNewConversationRef = nil
            bindWindowViewModel(to: fresh.id)
            mintedRef = dispatch.ref
        }
        guard let vm = windowViewModel,
              dispatch.conversationID == nil
                || vm.conversationID == dispatch.conversationID,
              let raw = try? await conversationStore
                .fetchConversation(id: vm.conversationID)?.backend,
              RemoteAgentRef(rawString: raw) == dispatch.ref else {
            windowViewModel?.reportComposerDispatchRejection()
            return false
        }
        // Successful hand-off — drop any stale mint-failure stash (see
        // `handleTranscript`).
        pendingFailedTurn = nil
        // Committed dispatch (window lane) — same reply-banner permission
        // backstop as the quick lane.
        requestNotificationPermissionIfNeeded()
        let accepted = await vm.submitUserTurnAwaitingLocalAcceptance(
            trimmed,
            modality: .text,
            attachments: dispatch.attachments,
            expectedRef: dispatch.ref,
            expectedFileLaneID: dispatch.fileLaneID
        )
        // Window lane only, and only on a fresh mint that was actually accepted.
        // The quick lane deliberately does NOT record: Decision F keeps a gateway
        // picked for the next WINDOW chat out of a hotkey capture, and the converse
        // holds too — a hotkey capture must not re-aim the window's picker.
        //
        // Inline rather than a detached `Task`, so this can never land after a
        // clear triggered by the user choosing a new default or forgetting a
        // gateway, and two quick sends can never record out of order.
        if accepted, let mintedRef {
            await SettingsManager.shared.setLastUsedRemoteAgentRef(mintedRef)
        }
        return accepted
    }

    // MARK: - Hand-off failure recovery (stranded turn)

    /// The user-facing message for a conversation-mint failure, shown on the
    /// dictation error surface (popover error footer) with Retry/Dismiss.
    private var mintFailedMessage: String {
        String(localized: LocalizedStringResource(
            "popover.error.conversationCreateFailed",
            defaultValue: "Couldn't start a conversation for that. Your words are kept — press Retry to send them."
        ))  // xcstrings: hardening
    }

    /// Explicitly-picked destination thread was deleted before the send landed.
    /// The snapshot is repointed to `.explicitNew` before this presents, so the
    /// "new chat" promise is literally what Retry does.
    private var destinationDeletedMessage: String {
        String(localized: LocalizedStringResource(
            "popover.error.destinationDeleted",
            defaultValue: "That conversation was deleted. Your words are kept — press Retry to send them to a new chat."
        ))  // xcstrings: session-continuation
    }

    /// Target thread already has a turn in flight (one in-flight turn per VM).
    /// The snapshot stays latched, so Retry replays into the SAME thread.
    private var destinationBusyMessage: String {
        String(localized: LocalizedStringResource(
            "popover.error.destinationBusy.v2",
            defaultValue: "Your AI is still answering. Your words are kept — press Retry when it finishes."
        ))  // xcstrings: session-continuation
    }

    /// The gateway this capture would have started on cannot send. Names the
    /// remedy (choose a default) rather than the symptom, because on a device with
    /// other working gateways "not configured" reads as false.
    private var destinationUnavailableMessage: String {
        String(localized: LocalizedStringResource(
            "popover.error.destinationUnavailable",
            defaultValue: "This Mac can't reach its default AI. Your words are kept — choose a default in Settings, then press Retry."
        ))  // xcstrings: gateway-gate
    }

    /// Replay a turn stranded by a hand-off failure (popover error-footer Retry).
    /// Dismisses the error surface, then re-runs the matching hand-off path —
    /// a voice replay claims `turnStarting` exactly like the `onTranscript`
    /// closure does (same gap-bridge, cleared by `handleTranscript`'s `defer`)
    /// and RE-CONSUMES the kept-latched snapshot, so the replay lands exactly
    /// where the error copy promised; a typed replay goes back through
    /// `handleTypedText` so its modality chip stays `text`.
    func retryPendingFailedTurn() {
        guard let turn = pendingFailedTurn else { return }
        pendingFailedTurn = nil
        dictationService.cancelRecording()   // .error → .idle (dismisses the error surface)
        switch turn {
        case .voice(let transcript):
            turnStarting = true
            Task { [weak self] in
                await self?.handleTranscript(transcript)
            }
        case .quickTyped(let text):
            // Same gap-bridge + quick-lane replay as `.voice`, with the typed
            // modality preserved (re-consumes the kept-latched snapshot).
            turnStarting = true
            Task { [weak self] in
                await self?.handleQuickSend(text, modality: .text)
            }
        case .typed(let text):
            Task { [weak self] in
                guard let self else { return }
                let ref: RemoteAgentRef
                if let pending = self.pendingNewConversationRef {
                    ref = pending
                } else {
                    ref = await SettingsManager.shared.defaultRemoteAgentRef()
                }
                _ = await self.handleTypedText(ComposerTurnDispatch(
                    text: text,
                    attachments: [],
                    ref: ref,
                    fileLaneID: nil,
                    handedOffServerAttachmentIDs: [],
                    conversationID: self.windowViewModel?.conversationID,
                    // A FRESH identity, not one carried from anywhere: this retry
                    // stages no attachments (`attachments` / `stagedAttachmentIDs` /
                    // `handedOffServerAttachmentIDs` are all empty), so there are no
                    // pre-minted file-server keys for it to align with — the only
                    // thing `pendingConversationID` exists to keep in step. It is
                    // read at all only when this dispatch MINTS a conversation
                    // (`conversationID == nil`, the menu bar's new-chat case); an
                    // append ignores it.
                    pendingConversationID: UUID(),
                    stagingGeneration: UUID(),
                    stagedAttachmentIDs: []
                ))
            }
        }
    }

    /// Drop a stashed hand-off-failure turn (popover Dismiss / Esc over the
    /// error state) so a stale stash can't ride a later, unrelated error's
    /// Retry.
    func discardPendingFailedTurn() {
        pendingFailedTurn = nil
    }
}
#endif
