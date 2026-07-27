// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationListView.swift
//
// iPhone conversation list.
// Time-grouped (Today / This Week / Earlier) by `lastActivityAt`,
// `.searchable`, swipe-delete. Each row = title (fallback to the first line
// of the last message) + relative `lastActivityAt` + last-message preview.
// Tapping a row selects that conversation ("Continue" = set it active +
// show it). Backed by `ConversationListViewModel`.

import SwiftUI

struct ConversationListView: View {
    /// Called with the chosen conversation's ID. The host (ContentView)
    /// sets it active + dismisses the list.
    let onSelect: (UUID) -> Void
    /// Called when the user taps the compose affordance. The host dismisses
    /// this list AND clears the active conversation (start a fresh one). The
    /// iPad library binding selects nil directly, so it provides a no-op-style
    /// closure that just clears its selection.
    var onNewConversation: () -> Void = {}
    /// Additive: suppress the built-in toolbar New / Delete-All actions. The
    /// macOS `MainWindowView` sidebar header owns its own "New conversation"
    /// button, so it passes `false`; iOS keeps the default `true`.
    var showsToolbarActions: Bool = true
    /// Optional host-owned search binding. macOS passes its sidebar search
    /// field's text through this so filtering is driven by the custom field
    /// (NOT the native `.searchable`, which renders above the New Conversation
    /// button). iOS leaves this nil and uses `internalSearch` via `.searchable`.
    var externalSearchText: Binding<String>? = nil
    /// Custom-gateway roster snapshot, used to resolve a row's gateway badge
    /// (name / color / monogram) for a `.custom` ref. Host-owned.
    var customGateways: [CustomGateway] = []
    /// Show the per-row gateway identity badge. Hosts pass
    /// `configuredRefs.count >= 2` so the badge appears only in a multi-gateway
    /// setup (single-gateway users see no new chrome) — mirrors the nav-title
    /// gateway-picker gate.
    var showsGatewayBadge: Bool = false
    /// Optional host callback to open Settings from a bottom footer row. When
    /// non-nil, a "Settings" row renders pinned to the list's bottom (iOS
    /// sheet/sidebar); when nil the inset is empty (layout-neutral) so macOS —
    /// which owns its own external `identityFooter` — gets no duplicate row.
    var onOpenSettings: (() -> Void)? = nil
    /// iPhone opts in: render the Settings affordance as a leading toolbar item
    /// (top-left) instead of the bottom footer row, freeing the bottom edge for the
    /// native iOS 26 search capsule. iPad/macOS sidebars keep the footer (default false).
    var settingsInToolbar: Bool = false
    /// Additive: render the New `square.and.pencil` toolbar item. iPhone + macOS
    /// keep the default `true`; the iPad sidebar passes `false` because its own
    /// prominent pinned "New Conversation" header owns New there.
    var newConversationInToolbar: Bool = true
    /// Additive: collapse Delete-All into an `ellipsis.circle` overflow menu
    /// instead of a bare destructive trash button. The iPad sidebar passes `true`
    /// (the prominent New header already occupies the toolbar's primary slot);
    /// iPhone + macOS keep the default `false` (bare trash button verbatim).
    var deleteAllInMenu: Bool = false
    /// Optional active-conversation highlight. The persistent-sidebar hosts (iPad
    /// split + macOS window) pass the currently-selected id so its row reads as
    /// "selected" (subtle amber row fill + the `.isSelected` VoiceOver trait); the
    /// iPhone sheet leaves it nil (a tap dismisses the sheet, so there's no
    /// persistent selection to indicate).
    var selectedConversationID: UUID? = nil

    @State private var viewModel = ConversationListViewModel()
    /// Drives the quiet "iCloud unavailable" banner (the only sync chrome). Reads
    /// the shared `@Observable` monitor; the banner shows only when iCloud is in a
    /// user-actionable bad state AND not dismissed this episode.
    @State private var syncMonitor = CloudSyncMonitor.shared
    @State private var internalSearch: String = ""
    @State private var showDeleteAllConfirmation = false
    /// Cache of last-message previews keyed by conversation ID (filled on
    /// row appear; avoids holding the whole message store in memory). Feeds the
    /// row SUBTITLE only (display) — it no longer drives search.
    @State private var previews: [UUID: String] = [:]
    /// Tier-2 whole-history content-search result: ids of conversations whose
    /// MESSAGE TEXT matches the active query (filled by the debounced
    /// `.task(id:)` below; empty when there's no query). Unioned with the
    /// instant Tier-1 title/snippet match in `filteredConversations`.
    @State private var contentMatchIDs: Set<UUID> = []
    /// True from the moment a content search is pending (debounce start) until
    /// its results land. Gates the no-results empty state so "No results" never
    /// flashes while a content-only match is still being resolved — identical to
    /// the Watch surface.
    @State private var isSearchingContent = false

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.conversations.isEmpty {
                errorView(error)
            } else if !trimmedSearchQuery.isEmpty && filteredTimeGroups.isEmpty && !isSearchingContent {
                noSearchResultsView
            } else if viewModel.conversations.isEmpty {
                emptyStateView
            } else if filteredTimeGroups.isEmpty && !isSearchingContent {
                noSearchResultsView
            } else {
                conversationsList
            }
        }
        #if os(iOS)
        // iPhone (no external field) keeps the native large "Conversations" title
        // + `.searchable` bar. The iPad sidebar passes `externalSearchText` and
        // renders its own pinned search field above the list (Mac-mirroring), so it
        // suppresses BOTH: an empty inline title (the slim bar then hosts only the
        // Delete-All button + the system sidebar toggle — no wasted large-title band)
        // and the native search (which iOS forces into the nav-bar area, ABOVE any
        // pinned header — the very thing that put search above New here).
        .navigationTitle(externalSearchText == nil ? Text("Conversations") : Text(""))
        .navigationBarTitleDisplayMode(externalSearchText == nil ? .large : .inline)
        .modifier(NativeSearchableModifier(text: $internalSearch, isEnabled: externalSearchText == nil))
        #else
        .navigationTitle(Text("Conversations"))
        #endif
        .toolbar {
            #if os(iOS)
            if let onOpenSettings, settingsInToolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onOpenSettings() } label: {
                        HStack(spacing: 8) {
                            Image("conduck-app-mark")
                                .resizable().interpolation(.high)
                                .frame(width: 28, height: 28)
                            Text(LocalizedStringResource("menu.settings.short", defaultValue: "Settings"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                    }
                    .accessibilityIdentifier("toolbar.settings")
                    .accessibilityLabel(Text(LocalizedStringResource("menu.settings.short", defaultValue: "Settings")))
                }
            }
            #endif
            if showsToolbarActions {
                if newConversationInToolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onNewConversation()
                        } label: {
                            Label(String(localized: "New conversation"), systemImage: "square.and.pencil")  // xcstrings: chat-ui
                        }
                        .accessibilityIdentifier("toolbar.newConversation")  // stable QA target (non-localized)
                    }
                }
                if !viewModel.conversations.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        if deleteAllInMenu {
                            // iPad sidebar: fold Delete-All into an overflow menu
                            // so it doesn't crowd the prominent New header.
                            Menu {
                                Button(role: .destructive) {
                                    showDeleteAllConfirmation = true
                                } label: {
                                    Label(String(localized: "Delete All"), systemImage: "trash")
                                }
                                .accessibilityIdentifier("toolbar.deleteAll")  // stable QA target (non-localized)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        } else {
                            Button(role: .destructive) {
                                showDeleteAllConfirmation = true
                            } label: {
                                Label(String(localized: "Delete All"), systemImage: "trash")
                            }
                            .accessibilityIdentifier("toolbar.deleteAll")  // stable QA target (non-localized)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if syncMonitor.showsBanner, let reason = syncMonitor.unavailableReason {
                ICloudUnavailableBanner(reason: reason) {
                    syncMonitor.dismissBanner()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { settingsFooterRow }
        .alert(Text("Delete all conversations?"), isPresented: $showDeleteAllConfirmation) {
            Button(role: .destructive) {
                Task { await viewModel.deleteAll() }
            } label: {
                Text("Delete All")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel")
            }
        } message: {
            Text("This removes every conversation from this device and all your other devices. This cannot be undone.")
        }
        .task { await viewModel.reload() }
        .task(id: searchKey) { await runContentSearch() }
    }

    // MARK: - Content search (Tier 2)

    /// Debounced whole-history content search. Driven by `.task(id: searchKey)`
    /// — SwiftUI cancels + restarts this whenever the query or
    /// `changeGeneration` changes, giving debounce + staleness + cancellation in
    /// one construct. The `Task.sleep` is the debounce (cancelled if the key
    /// changes again before it elapses), so a fast typist spawns at most one
    /// store fetch per settle. Mirror of `WatchConversationListView.runContentSearch`
    /// — keep the two in lockstep (the shared match rule lives in `ConversationSearchFilter`).
    private func runContentSearch() async {
        guard let q = ConversationSearchFilter.normalizedQuery(activeQuery) else {
            contentMatchIDs = []
            isSearchingContent = false
            return
        }
        // Raise the pending flag BEFORE the debounce so the no-results empty
        // state is suppressed across the whole pending window (debounce + fetch),
        // not just the fetch — otherwise "No results" flashes while a
        // content-only match is still being resolved. Identical to the Watch.
        isSearchingContent = true
        try? await Task.sleep(for: .seconds(Constants.contentSearchDebounce))
        guard !Task.isCancelled else { return }
        let ids = (try? await ConversationStore.shared.searchConversationIDs(containing: q)) ?? []
        guard !Task.isCancelled else { return }   // query changed during the fetch → drop the stale result
        contentMatchIDs = ids
        isSearchingContent = false
    }

    // MARK: - Settings footer

    /// Bottom-pinned "Settings" row, mirroring the macOS `identityFooter`
    /// design. Renders ONLY when the host wired `onOpenSettings` (iOS sheet /
    /// iPad sidebar); macOS passes nil so its own external footer stays the
    /// single source of the Settings affordance.
    @ViewBuilder
    private var settingsFooterRow: some View {
        if let onOpenSettings, !settingsInToolbar {
            VStack(spacing: 0) {
                Divider().overlay(AppColors.border)
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image("conduck-app-mark")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 32, height: 32)
                        Text(LocalizedStringResource("menu.settings.short", defaultValue: "Settings"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityIdentifier("toolbar.settings")
            }
            .background(AppColors.cardBackground)
        }
    }

    // MARK: - Filtering + grouping

    /// The query actually driving the filter: the host-owned external binding
    /// when present (macOS sidebar field), else the internal `.searchable` text
    /// (iOS).
    private var activeQuery: String {
        externalSearchText?.wrappedValue ?? internalSearch
    }

    private var trimmedSearchQuery: String {
        activeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredConversations: [ConversationRecord] {
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return viewModel.conversations }
        // Unified two-tier filter (identical on iPhone/iPad/Mac/Watch): instant
        // Tier-1 title + first-user-snippet match, UNIONED with the Tier-2
        // whole-history message-content match (`contentMatchIDs`, populated by
        // the debounced `.task(id:)`). The row preview subtitle is now display
        // only — no longer a search source (so search is complete: mid-thread +
        // un-scrolled conversations match too).
        return viewModel.conversations.filter { convo in
            ConversationSearchFilter.titleMatches(
                query: query, title: convo.title, titleSnippet: convo.titleSnippet
            ) || contentMatchIDs.contains(convo.id)
        }
    }

    /// Combined debounce + cancellation + staleness key for the content search.
    /// `query` is the normalized active query (nil clears results); `gen` folds
    /// in `viewModel.changeGeneration` so an in-flight search re-runs when the
    /// underlying conversations change mid-search.
    private struct SearchKey: Hashable {
        let query: String?
        let gen: Int
    }

    private var searchKey: SearchKey {
        SearchKey(query: ConversationSearchFilter.normalizedQuery(activeQuery), gen: viewModel.changeGeneration)
    }

    private struct TimeGroup: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let conversations: [ConversationRecord]
    }

    private var filteredTimeGroups: [TimeGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var today: [ConversationRecord] = []
        var thisWeek: [ConversationRecord] = []
        var earlier: [ConversationRecord] = []

        for convo in filteredConversations {
            if convo.lastActivityAt >= startOfToday {
                today.append(convo)
            } else if convo.lastActivityAt >= startOfWeek {
                thisWeek.append(convo)
            } else {
                earlier.append(convo)
            }
        }

        var groups: [TimeGroup] = []
        if !today.isEmpty { groups.append(TimeGroup(id: "today", title: "Today", conversations: today)) }
        if !thisWeek.isEmpty { groups.append(TimeGroup(id: "week", title: "This week", conversations: thisWeek)) }
        if !earlier.isEmpty { groups.append(TimeGroup(id: "earlier", title: "Earlier", conversations: earlier)) }
        return groups
    }

    // MARK: - List

    private var conversationsList: some View {
        List {
            ForEach(filteredTimeGroups) { group in
                Section {
                    ForEach(group.conversations) { convo in
                        Button {
                            onSelect(convo.id)
                        } label: {
                            conversationRow(convo)
                        }
                        .buttonStyle(.plain)
                        // Active-conversation highlight (persistent-sidebar hosts
                        // only; nil on the iPhone sheet → Color.clear). A subtle
                        // amber row fill — the app's accent reads as "selected" on
                        // the dark theme — plus the VoiceOver `.isSelected` trait.
                        .listRowBackground(
                            convo.id == selectedConversationID
                                ? AppColors.brandAmber.opacity(0.15)
                                : Color.clear
                        )
                        .accessibilityAddTraits(
                            convo.id == selectedConversationID ? .isSelected : []
                        )
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                await viewModel.delete(group.conversations[index])
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(nil)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await viewModel.reload() }
    }

    private func conversationRow(_ convo: ConversationRecord) -> some View {
        HStack(spacing: 12) {
            // Leading gateway badge — only in a multi-gateway setup, and only
            // for a resolvable ref (a deleted / un-synced custom renders
            // nothing via `GatewayBadge`'s empty-monogram guard).
            if showsGatewayBadge, let ref = RemoteAgentRef(rawString: convo.backend) {
                GatewayBadge(ref: ref, customs: customGateways)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(MessageRowFormatters.conversationTitle(
                    title: convo.title,
                    titleSnippet: convo.titleSnippet,
                    lastMessagePreview: previews[convo.id]
                ))
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(AppColors.textEmphasis)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let preview = previews[convo.id], !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(MessageRowFormatters.conversationListDate(from: convo.lastActivityAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        // Make the WHOLE row rectangle the click target (the `maxWidth` is
        // required first — a left-aligned VStack otherwise collapses to text
        // width, leaving the right side a dead zone even with `contentShape`).
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: convo.id) {
            await loadPreviewIfNeeded(convo.id)
        }
    }

    /// Characters KEPT in the cached preview string. The row renders
    /// `.lineLimit(2)` at `.subheadline`, so even the widest surface (the macOS
    /// split-view sidebar) shows well under 200 characters — 500 is generous
    /// headroom and nothing the user could see is lost. Load-bearing because
    /// this row's `.task` runs on the main actor during scene setup on
    /// iPad/macOS (the conversation list is the always-visible sidebar there):
    /// it bounds what `Text` ever has to lay out, however long the reply is.
    static let previewCharacterCount = 500

    /// The sidebar subtitle for a reply: collapse Markdown links to their
    /// label, THEN cut to `previewCharacterCount`.
    ///
    /// THE ORDER IS THE POINT. Cutting first can slice a `[label](target)` in
    /// half, and a half-link is not collapsible — the scanner needs the closing
    /// `)` — so the raw target survives into the sidebar. That target is
    /// attacker-influenced and is exactly the string this collapse exists to
    /// keep off a glance surface: an agent's file link carries its host-side
    /// filesystem path (`[poem.md](/Users/…/poem.md)`), and a web link carries a
    /// host the user never chose to see. Collapsing first, the 500-character cut
    /// only ever lands in text the user would have read anyway.
    ///
    /// Cost: `ReplySanitizer.linkCollapsed` sees the whole reply, not a
    /// 500-character head. It carries NO input cap by design — capping a display
    /// scan would strand the raw target this collapse exists to remove, at a
    /// length the author of the reply picks. What bounds it instead: the scan
    /// walks `String.UnicodeScalarView` indices without materializing them, bails
    /// with no allocation when the text holds no `[`, and allocates an output
    /// only when a link actually collapsed. Reply size itself is bounded at the
    /// transport layer (`Constants.maxBackgroundResponseBytes`). This preview is
    /// computed ONCE per conversation and cached by `loadPreviewIfNeeded`, so it
    /// is the cheaper of the two callers — the Watch bubble runs the same scan
    /// per render pass.
    static func previewText(forReply reply: String) -> String {
        String(ReplySanitizer.linkCollapsed(reply).prefix(previewCharacterCount))
    }

    private func loadPreviewIfNeeded(_ id: UUID) async {
        guard previews[id] == nil else { return }
        let messages = (try? await ConversationStore.shared.fetchMessages(for: id)) ?? []
        if let last = messages.last {
            // (The thread view renders the full Markdown; this is preview-only.)
            previews[id] = Self.previewText(forReply: last.text)
        } else {
            previews[id] = ""
        }
    }

    // MARK: - Empty / error

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.brandAmber.opacity(0.7))
            Text("No conversations yet")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textPrimary)
            Text("Tap the mic on the home screen to start a conversation with your personal AI.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(AppColors.textTertiary)
            Text("No matches")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textPrimary)
            Text("Nothing in your conversations matches that search.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.reload() }
            } label: {
                Text("Try Again")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#if os(iOS)
/// Applies the native `.searchable` field ONLY when the host hasn't supplied its
/// own search field. The iPhone sheet (no `externalSearchText`) opts in; the iPad
/// sidebar passes an `externalSearchText` binding and renders a custom
/// `SidebarSearchField` above the list, so the native bar — which iOS forces into
/// the nav-bar area above any pinned header — must be suppressed there.
private struct NativeSearchableModifier: ViewModifier {
    @Binding var text: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, prompt: Text("Search conversations"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            content
        }
    }
}
#endif

/// Shared sidebar search field (magnifier + plain field + clear button) used by
/// BOTH the iPad split sidebar (`ConversationLibraryView`) and the macOS unified
/// window (`MainWindowView`). Reproduces the iPhone's native dark-mode search
/// chrome — cool translucent system-gray fill, capsule shape, body-size glyph —
/// while sitting BELOW the prominent New Conversation button (the founder-locked
/// sidebar order; native `.searchable` can only render above it). Drives the
/// list's filter via the host's `externalSearchText` binding.
struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Self.fill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Self.stroke, lineWidth: 0.5))
        .accessibilityIdentifier("sidebar.search")
    }

    /// Reproduces the iPhone's native dark-mode search bar: a very subtle
    /// translucent fill plus a hairline border (not the heavier `.tertiarySystemFill`,
    /// which reads too light). The app is locked to `.preferredColorScheme(.dark)`,
    /// so a white-blend value renders the same on both iPad and macOS.
    private static let fill = Color.white.opacity(0.08)
    private static let stroke = Color.white.opacity(0.14)

    @ViewBuilder
    private var field: some View {
        let base = TextField(String(localized: "Search conversations"), text: $text)
            .textFieldStyle(.plain)
            .font(.body)
            .accessibilityLabel(Text("Search conversations"))
        #if os(iOS)
        base
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        base
        #endif
    }
}
