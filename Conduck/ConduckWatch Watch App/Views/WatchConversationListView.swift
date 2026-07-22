// Conduck
// WatchConversationListView.swift
//
// Watch conversation browse: grouped list, swipe-to-delete, empty state. Search
// entry is a top-bar magnifier (`TextFieldLink` → system text-entry screen);
// an active query shows as a slim in-list chip with one-tap clear.
// Rows rebind to title + `lastActivityAt` + last-message preview.
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
                    ForEach(filtered) { conversation in
                        NavigationLink(value: conversation.id) {
                            row(for: conversation)
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
            Text("Ask your personal AI to start one.")  // xcstrings
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

    // ACCEPTED V1 DECISION (reviewer-confirmed): rows show title + relative date
    // but NO last-message preview. Deriving a preview means an N-message fetch
    // per visible row on the wrist — not worth the perf cost. The thread view
    // shows the bodies. Keep this.
    private func row(for conversation: ConversationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(Self.displayTitle(for: conversation))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                WatchGatewayBadge(backendRawValue: conversation.backend)
            }
            Text(Self.relativeFormatter.localizedString(
                for: conversation.lastActivityAt,
                relativeTo: Date()
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
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
