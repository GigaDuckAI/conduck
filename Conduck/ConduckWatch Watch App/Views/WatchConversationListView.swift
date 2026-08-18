// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchConversationListView.swift
//
// Watch conversation browse: grouped list, swipe-to-delete, empty state. Search
// entry is a top-bar magnifier (`TextFieldLink` → system text-entry screen);
// an active query shows as a slim in-list chip with one-tap clear.
// Rows rebind to title + `lastActivityAt` + the row's delivery state, which
// swaps into the date slot rather than taking a line of its own, and the row's
// two ATTENTION facts — an unread reply and an unacknowledged failure — which
// ride the title's weight and a fixed-width trailing mark
// (`WatchConversationActivityMark`). Both attention facts are account-wide,
// read off the conversation's own mirrored columns, so the wrist agrees with
// the phone without keeping a marker of its own.
//
// Backed by `WatchConversationViewModel` over the CloudKit-ready
// `ConversationStore` — conversations from any device appear here once sync
// lands (local-only today). Tap → `WatchConversationThreadView`.

import SwiftUI

struct WatchConversationListView: View {
    @Bindable var viewModel: WatchConversationViewModel
    @State private var searchText = ""

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                ProgressView()
                    .tint(.orange)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if let error = viewModel.loadError, viewModel.conversations.isEmpty {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {  // xcstrings
                        Task { await viewModel.reload() }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } else {
                // Active-query chip: visible ONLY while a query is live, so the
                // idle list spends zero rows on search chrome (an
                // always-visible field blocked ~1/3 of the screen). Search
                // ENTRY lives in the top bar (magnifier → system text entry).
                if hasActiveQuery {
                    activeQueryChip
                }
                if filtered.isEmpty {
                    // A query is active but nothing matched (and we're not
                    // mid-fetch) → "No matches"; otherwise the empty STORE →
                    // "No conversations yet". While a content fetch is in flight,
                    // show neither so "No matches" never flashes before content
                    // results land.
                    if hasActiveQuery && !viewModel.isSearchingContent {
                        noMatchesState
                    } else if !hasActiveQuery {
                        emptyState
                    }
                } else {
                    // Resolved ONCE per list build, not once per row — the rule
                    // scans the whole conversation array, and the single-gateway
                    // case (where it can't bail early) is the common one.
                    let showsBadge = showsGatewayBadge
                    ForEach(filtered) { conversation in
                        NavigationLink(value: conversation.id) {
                            row(for: conversation, showsBadge: showsBadge)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.delete(filtered[index])
                        }
                    }
                }
            }
        }
        .refreshable {
            await viewModel.reload()
        }
        // Empty title (launchpad precedent): with back (leading) + magnifier
        // (trailing) flanking the inline bar, "Conversations" hard-clips to
        // "Conversatio" on 46mm — no label beats a broken one; the list is
        // self-describing.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Search entry: magnifier in the top bar opens the system
            // text-entry screen (dictation / scribble / QWERTY) via
            // `TextFieldLink`. watchOS can't present `.searchable`
            // programmatically (`isPresented:` overload unavailable) and its
            // reveal-by-pull is unreliable on a pushed destination, so the
            // toolbar link is the reliable affordance. Top-LEADING is owned
            // by the back button on watchOS → trailing slot. Hidden when
            // there's nothing to search and no query left to clear.
            if !viewModel.conversations.isEmpty || hasActiveQuery {
                ToolbarItem(placement: .topBarTrailing) {
                    TextFieldLink(prompt: Text("Search conversations")) {  // xcstrings
                        Image(systemName: "magnifyingglass")
                    } onSubmit: { query in
                        searchText = query
                    }
                    .accessibilityLabel(Text("Search conversations"))  // xcstrings
                }
            }
        }
        .navigationDestination(for: UUID.self) { conversationID in
            WatchConversationThreadView(conversationID: conversationID, viewModel: viewModel)
        }
        .onAppear {
            Task { await viewModel.reload() }
        }
        .task(id: searchKey) { await runContentSearch() }
    }

    // MARK: - Content search (Tier 2)

    /// Combined debounce + cancellation + staleness key. `query` is the
    /// normalized search text (nil clears results); `gen` folds in
    /// `viewModel.changeGeneration` so an in-flight search re-runs when the data
    /// changes mid-search. Identical construction to the iOS list view.
    private struct SearchKey: Hashable {
        let query: String?
        let gen: Int
    }

    private var searchKey: SearchKey {
        SearchKey(query: ConversationSearchFilter.normalizedQuery(searchText), gen: viewModel.changeGeneration)
    }

    /// Debounced whole-history content search. SwiftUI cancels + restarts this
    /// whenever `searchKey` changes (query or change-generation), giving
    /// debounce + staleness + cancellation in one construct.
    private func runContentSearch() async {
        guard let q = ConversationSearchFilter.normalizedQuery(searchText) else {
            viewModel.clearContentMatches()
            return
        }
        // Suppress "No matches" across the whole pending window (debounce +
        // fetch), not just the fetch. Mirror of the iOS surface.
        viewModel.markSearchPending()
        try? await Task.sleep(for: .seconds(Constants.contentSearchDebounce))
        guard !Task.isCancelled else { return }
        await viewModel.runContentSearch(q)
    }

    // MARK: - Filtering

    /// True when there's a non-empty search query (after trimming).
    private var hasActiveQuery: Bool {
        ConversationSearchFilter.normalizedQuery(searchText) != nil
    }

    private var filtered: [ConversationRecord] {
        guard let trimmed = ConversationSearchFilter.normalizedQuery(searchText) else {
            return viewModel.conversations
        }
        // Unified two-tier filter (identical to iPhone/iPad/Mac): instant
        // Tier-1 title + first-user-snippet match, UNIONED with the Tier-2
        // whole-history message-content match (`contentMatchIDs`).
        return viewModel.conversations.filter {
            ConversationSearchFilter.titleMatches(
                query: trimmed, title: $0.title, titleSnippet: $0.titleSnippet
            ) || viewModel.contentMatchIDs.contains($0.id)
        }
    }

    // MARK: - Active-query chip

    /// Slim first-row chip shown only while a query is active: echoes what the
    /// list is filtered by and clears in one tap. A new query (top-bar
    /// magnifier) replaces it; the bound `searchText` drives the same two-tier
    /// filter as every other surface.
    private var activeQueryChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(searchText)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear search"))  // xcstrings
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No conversations yet")  // xcstrings
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LocalizedStringResource(
                "watch.conversations.empty.hint",
                defaultValue: "Ask your AI to start one."
            ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    /// Shown when a query is active but nothing (title, snippet, or
    /// whole-history content) matches — distinct from the empty-store state so
    /// the wrist never says "No conversations yet" while the user is searching.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No matches")  // xcstrings
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Nothing matches that search.")  // xcstrings
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: - Row

    /// Whether rows carry the gateway badge — the same rule the phone, iPad,
    /// Mac and CarPlay lists apply (`RemoteAgentRefMetadata.shouldShowBadges`),
    /// so a single-gateway user sees a badge-free list on the wrist too, and a
    /// mixed history keeps its badges even once only one gateway is still
    /// configured.
    ///
    /// The configured half comes from `remoteAgentURLs.keys`, NOT
    /// `configuredBackendRefs()`. That function is the ROUTING question ("can
    /// this Watch send to this ref"), and answering it costs a synchronous
    /// `SecItemCopyMatching` per ref — `remoteAgentConfig(for:)` reads the Watch
    /// Keychain to prove the token landed. This is the IDENTITY question ("did
    /// the user ever have this gateway"), which the URL map already answers: it
    /// is rebuilt from the multi-envelope's sub-envelopes, one per ref the phone
    /// has configured. A plain dictionary read, so `body` stays free of Keychain
    /// I/O on the slowest device in the fleet — and the wrist counts a gateway
    /// as soon as its envelope lands rather than waiting on the token write.
    ///
    /// It still trails the phone by one envelope: a gateway configured on the
    /// phone seconds ago is not yet an identity here. That window is inherent to
    /// a mirrored surface, not a difference in the rule.
    ///
    /// Computed from `viewModel.conversations` (the whole list), never
    /// `filtered` — otherwise badges would appear and vanish as a search
    /// narrows. Reads `WatchSettingsReader.shared` directly, as
    /// `WatchGatewayBadge` does; both values are plain `@Observable` properties.
    private var showsGatewayBadge: Bool {
        let reader = WatchSettingsReader.shared
        return RemoteAgentRefMetadata.shouldShowBadges(
            configured: reader.remoteAgentURLs.keys.compactMap(RemoteAgentRef.init(rawString:)),
            conversationBackends: viewModel.conversations.lazy.map(\.backend),
            // The BADGE roster — the same one `WatchGatewayBadge` renders from,
            // so "should this list badge" and "can this row draw one" stay the
            // same question once forgotten gateways are in play.
            customs: reader.gatewayBadgeRoster
        )
    }

    // ACCEPTED V1 DECISION (reviewer-confirmed): rows show title + relative date
    // but NO last-message preview. Deriving a preview means an N-message fetch
    // per visible row on the wrist — not worth the perf cost. The thread view
    // shows the bodies. Keep this.
    //
    // Delivery state rides the SAME single list query (`fetchConversations(
    // activity: .turnStates)`) and renders as a SWAP inside the existing date
    // slot — one `Text` whose string and tint change. No extra line, no extra
    // fetch, and the row's height is identical in every state.
    //
    // ATTENTION state rides the same query too, on the conversation's own
    // CloudKit-mirrored marker columns, and renders in the two places that cost
    // no layout: the title's WEIGHT and a fixed-width trailing MARK. Neither
    // adds a line, neither adds a fetch, and the mark's slot is reserved in
    // every state so the title's truncation point does not move when a reply
    // lands. One `rowState` call feeds all three renderings, so the glyph, the
    // weight and the words are always resolved from one value.
    private func row(for conversation: ConversationRecord, showsBadge: Bool) -> some View {
        let state = viewModel.rowState(for: conversation)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(Self.displayTitle(for: conversation))
                    // BOLD ON AN UNSEEN REPLY — the same cue the iPhone, iPad
                    // and Mac lists use, and the wrist's only whole-row one. It
                    // is a WEIGHT change rather than a colour change on purpose:
                    // weight survives Always-On Display's dim and greyscale,
                    // where a tint difference on a black background does not.
                    .font(.caption.weight(state.hasUnseenReply ? .bold : .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // The gateway badge is never tinted, dimmed or overlaid by
                // activity — it answers "which agent", not "what happened".
                if showsBadge {
                    WatchGatewayBadge(backendRawValue: conversation.backend)
                }
                // TRAILING-MOST, after the badge, so the mark occupies one fixed
                // column at the row's edge whether or not this list badges. The
                // badge is a whole-list decision, so putting the mark outside it
                // keeps the attention glyph in the same place on every row.
                WatchConversationActivityMark(state: state)
            }
            Text(Self.metadataText(for: state.activity, lastActivityAt: conversation.lastActivityAt))
                .font(.caption2)
                .foregroundStyle(Self.metadataTint(for: state))
                // ALWAYS one line: "Waiting for a reply…" is far longer than a
                // relative date and would wrap on a 40 mm watch, changing the
                // row's height the moment its state changed.
                .lineLimit(1)
        }
    }

    /// The date slot's string. Distinct WORDS carry the state on the wrist —
    /// there is no room for a mark, and colour alone would fail the
    /// shape-not-colour rule.
    ///
    /// No elapsed clock and no `TimelineView`: a per-minute tick is continuous
    /// work a browse list should not spend on the smallest battery in the
    /// fleet, and the thread view already shows a clock for the turn you are
    /// actually waiting on.
    ///
    /// `.answeredUnseen` IS REACHABLE HERE, and it deliberately falls through to
    /// the date. The wrist reads the account's `lastViewedAt` off the record and
    /// the tail's role off the stored tail envelope, so a row with an unread
    /// reply resolves to that state like every other surface — but the fact is
    /// already carried by the bold title and the amber mark, and this slot's job
    /// is to answer WHEN. Spending it on a second copy of "new reply" would cost
    /// the only place the row says how old it is.
    private static func metadataText(
        for activity: ConversationActivity,
        lastActivityAt: Date
    ) -> String {
        switch activity {
        case .idle, .answeredUnseen:
            return relativeFormatter.localizedString(for: lastActivityAt, relativeTo: Date())
        case .working(let confidence, _):
            // Empty gateway name on purpose: the badge already names the gateway
            // one line above and the row has no width to repeat it, so `.live`
            // renders the shared bare "Answering…" fallback rather than
            // "OpenClaw is answering…".
            return ConversationActivityCopy.working(confidence, gatewayName: "")
        case .failed:
            return ConversationActivityCopy.notSent
        }
    }

    /// Red = a problem the user has not been told about yet; everything else
    /// stays neutral. A working row is information, not a call to action, so it
    /// must not compete with the one colour that means something went wrong.
    ///
    /// AN ACKNOWLEDGED FAILURE KEEPS THE WORDS AND DROPS THE RED, mirroring what
    /// the trailing mark does with its glyph and what the iPhone, iPad and Mac
    /// lists already do with theirs. "Not sent" stays true after the user has
    /// been shown the failure — the message still did not go — so the row goes
    /// on saying it; what is spent is the URGENCY, and a row that keeps shouting
    /// after it has been read trains the user to ignore the colour that matters.
    /// Because the acknowledgement is a column on the conversation, the wrist
    /// drops the red for a failure acknowledged on ANY device, and opening the
    /// thread here drops it on all of them.
    private static func metadataTint(for state: ConversationRowState) -> Color {
        switch state.activity {
        case .failed:
            return state.failureAcknowledged ? .secondary : AppColors.error
        case .idle, .working, .answeredUnseen:
            return .secondary
        }
    }

    // MARK: - Helpers

    /// Delegates to `ConversationRecord.displayTitle` (server/human title →
    /// first-user-line snippet → generic label) — single source for the row title
    /// AND the thread top bar. Aligns the fallback string to the iOS
    /// `MessageRowFormatters.conversationTitle`.
    private static func displayTitle(for conversation: ConversationRecord) -> String {
        conversation.displayTitle
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
