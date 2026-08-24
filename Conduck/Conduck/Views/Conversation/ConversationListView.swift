// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationListView.swift
//
// The conversation list, shared verbatim by three hosts: the iPhone browsing
// sheet (`ContentView`), the iPad split sidebar (`ConversationLibraryView`) and
// the macOS window sidebar (`MainWindowView`).
// Time-grouped (Today / This Week / Earlier) by `lastActivityAt`,
// `.searchable`, per-row delete (swipe on iOS, right-click context menu on
// macOS) plus a Delete-All trash (iOS toolbar item; macOS-fenced sidebar-region
// toolbar item). Each row = title (fallback to the first line of
// the last message) + a reserved trailing activity mark + a role-aware preview
// subtitle + a metadata line that is a date when nothing is happening and the
// status words while a turn is in flight.
// Tapping a row selects that conversation ("Continue" = set it active +
// show it). Backed by `ConversationListViewModel`.
//
// Every difference between the three hosts is an ADDITIVE flag declared below,
// defaulting to the iPhone sheet's rendering, so a host that says nothing gets
// the sheet. macOS differences are spelled inside `#if os(macOS)` fences
// instead, which is a stronger guarantee than a default: that platform's view
// tree never gains the modifier at compile time.

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
    /// macOS window has no sidebar-column toolbar of its own (one toolbar spans
    /// the whole split view, and `LeadingToolbarChrome` owns New there), so it
    /// passes `false`; iOS keeps the default `true`. This flag governs only the
    /// iOS-designed items — macOS's Delete-All is the separate `#if os(macOS)`
    /// toolbar item below, unaffected by this flag.
    var showsToolbarActions: Bool = true
    /// Optional host-owned search binding. The split-view hosts pass their
    /// pinned search field's text through this so filtering is driven by the
    /// custom field (NOT the native `.searchable`, which iOS forces into the
    /// nav-bar area rather than inline in the column). iPhone leaves this nil
    /// and uses `internalSearch` via `.searchable`.
    var externalSearchText: Binding<String>? = nil
    /// Custom-gateway roster snapshot, used to resolve a row's gateway badge
    /// (name / color / monogram) for a `.custom` ref. Host-owned.
    var customGateways: [CustomGateway] = []
    /// The gateways configured on this device. Feeds the per-row badge
    /// visibility rule together with the loaded conversations — the view owns
    /// that decision (`RemoteAgentRefMetadata.shouldShowBadges`) rather than
    /// taking a pre-computed Bool, so all three hosts of this list answer it
    /// identically. Empty (the default) still shows badges on a history that
    /// spans two gateways: the rows outlive the config that made them.
    var configuredRefs: [RemoteAgentRef] = []
    /// Optional host callback to open Settings from a bottom footer row. When
    /// non-nil, a "Settings" row renders pinned to the list's bottom (iOS
    /// sheet/sidebar); when nil the inset is empty (layout-neutral) so macOS —
    /// which owns its own external `identityFooter` — gets no duplicate row.
    var onOpenSettings: (() -> Void)? = nil
    /// iPhone opts in: render the Settings affordance as a leading toolbar item
    /// (top-left) instead of the bottom footer row, freeing the bottom edge for the
    /// native iOS 26 search capsule. iPad/macOS sidebars keep the footer (default false).
    var settingsInToolbar: Bool = false
    /// Additive: render the New `square.and.pencil` toolbar item. iPhone keeps
    /// the default `true`; the iPad sidebar passes `false` because
    /// `LeadingToolbarChrome` owns New on whichever COLUMN's bar is on screen —
    /// the sidebar's own bar while the sidebar is up, which is exactly when this
    /// list renders, so a second item here would sit beside the first.
    var newConversationInToolbar: Bool = true
    /// Additive: collapse Delete-All into an `ellipsis.circle` overflow menu
    /// instead of a bare destructive trash button. Every current host keeps the
    /// default `false` (bare trash button verbatim).
    var deleteAllInMenu: Bool = false
    /// Additive: dock Delete-All at the bar's LEADING edge instead of the
    /// trailing slot `.primaryAction` resolves to on iOS. Where exactly the
    /// system puts it there, and why no lever offsets it by a chosen amount, is
    /// measured on `deleteAllPlacement`.
    ///
    /// The iPad split sidebar (`ConversationLibraryView`) is the only host that
    /// passes `true`: its trailing slot belongs to compose, which sits
    /// immediately left of the system toggle to match the macOS window, so the
    /// destructive action goes to the opposite end of the bar. Every other host
    /// keeps the default `false` — the iPhone conversation sheet has no sidebar
    /// toggle and gives its leading slot to Settings (`settingsInToolbar: true`),
    /// and macOS never renders this item at all (`showsToolbarActions: false`).
    /// Those two facts are independent of this flag, which is why the sheet is
    /// safe at the default rather than by exclusion.
    var deleteAllLeading: Bool = false
    /// Additive: adopt the inset list style instead of the style a
    /// `NavigationSplitView` sidebar column resolves to on its own. The iPad
    /// split sidebar (`ConversationLibraryView`) is the only host that passes
    /// `true`, so its column takes the same style the macOS window's sidebar
    /// takes unconditionally, and with it the row separators the sidebar column
    /// draws none of. The iPhone conversation sheet keeps the default `false` —
    /// it is a browsing sheet, not a sidebar, and the platform already gives it
    /// separators there. macOS never reads this flag: its style is set inside
    /// the `#if os(macOS)` fence below and is not conditional, so the guarantee
    /// that this changes nothing on that platform is the fence, not the default.
    ///
    /// MEASURED on an iPad Pro 13-inch (M5), iPadOS 26.5 simulator, portrait,
    /// sidebar column x 10–330, from screenshot pixel columns at 2x:
    ///
    ///   default   no separator drawn      row content x 42.0
    ///   `.inset`  separator 38.5–305.5    row content x 34.0
    ///
    /// with the selected row's `.listRowBackground` band spanning 26.0–313.5
    /// (16pt inside the column, both ends) under `.inset`. Row PITCH measures
    /// 117.0 under both — `conversationRow` owns the vertical metrics and this
    /// style leaves them alone — so the flag changes what separates the rows and
    /// where their content sits, never how tall they are.
    var usesInsetListStyle: Bool = false
    /// Optional active-conversation highlight. The persistent-sidebar hosts (iPad
    /// split + macOS window) pass the currently-selected id so its row reads as
    /// "selected" (subtle amber row fill + the `.isSelected` VoiceOver trait); the
    /// iPhone sheet leaves it nil (a tap dismisses the sheet, so there's no
    /// persistent selection to indicate).
    var selectedConversationID: UUID? = nil
    /// Additive: called AFTER one conversation was actually deleted through
    /// this list (right-click Delete on macOS, swipe on iOS), with its id. The
    /// macOS window uses it to drop its detail pane when the open thread dies;
    /// the iOS hosts pass nothing (default nil) and render exactly as before.
    /// Never fires on a store throw — the row is still alive then.
    var onDeleted: ((UUID) -> Void)? = nil
    /// Additive: called AFTER Delete-All actually cleared the store. Same
    /// consumer and same success contract as `onDeleted`.
    var onDeletedAll: (() -> Void)? = nil

    @State private var viewModel = ConversationListViewModel()
    /// Drives the quiet "iCloud unavailable" banner (the only sync chrome). Reads
    /// the shared `@Observable` monitor; the banner shows only when iCloud is in a
    /// user-actionable bad state AND not dismissed this episode.
    @State private var syncMonitor = CloudSyncMonitor.shared
    @State private var internalSearch: String = ""
    @State private var showDeleteAllConfirmation = false
    /// Cache of conversation TAILS keyed by conversation ID (filled on row
    /// appear; avoids holding the whole message store in memory). Feeds the row
    /// SUBTITLE and the title fallback only (display) — it does not drive search,
    /// and it does not drive delivery state (that comes from the whole-store
    /// unresolved-turn aggregate, because a conversation is not a turn).
    @State private var previews: [UUID: TailPreview] = [:]
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

    /// Where Delete-All docks. `.topBarLeading` is iOS-only and this file
    /// compiles for macOS too, so the leading case is spelled inside the fence.
    /// macOS never renders this item at all — its host passes
    /// `showsToolbarActions: false` — so its branch is the inert one. (The
    /// macOS trash is the separate `#if os(macOS)` item in the toolbar block,
    /// not this one; the two are never live together.)
    ///
    /// WHERE THE LEADING TRASH LANDS, and why nothing here sets it. MEASURED
    /// (iPadOS 26.5, iPad Pro 12.9-inch (6th gen) simulator, 1024x1366pt
    /// portrait, sidebar column x 10–330): the bar pins a `.topBarLeading` item
    /// at x=14 — 4pt inside the column — and holds it there. Five levers, each
    /// built, installed and re-probed on that device; artifacts under
    /// `final-probe/` (one `ax-*.json` sweep + one screenshot per experiment,
    /// distinct md5s):
    ///
    ///   `.padding(.leading, 8)` on the Button              14.0  INERT   (E1)
    ///   `ToolbarSpacer(.fixed, placement: .topBarLeading)`
    ///     declared ahead of the item                       14.0  INERT   (E4)
    ///   `.padding(.leading, 8)` inside the Button's Label  14.0  INERT   (E5)
    ///   `ToolbarItemGroup` + a leading flexible `Spacer()`  56.0  MOVES  (E2)
    ///   `ToolbarItemGroup` + `Spacer().frame(width: 8)`     56.0  MOVES  (E3)
    ///
    /// So a lever DOES exist, and it is unusable: the group gives the spacer a
    /// whole toolbar slot, +42pt, identical whether the spacer is flexible or
    /// pinned to 8pt. There is no lever that offsets the item by a chosen amount,
    /// which is why this file declares a bare `ToolbarItem` and takes the 14.
    ///
    /// The 14 is SYMMETRIC with the system's own sidebar toggle at the other end
    /// of the same bar (326.0, 4pt inside the column's trailing edge at 330), so
    /// the toolbar band is square in itself. It is the band's own edge and not
    /// the column's: the content below — the pinned `SidebarSearchField` and the
    /// list it filters — squares against the list's row box instead, which sits
    /// further in. `ConversationLibraryView`'s `.safeAreaInset` carries those
    /// frames.
    private var deleteAllPlacement: ToolbarItemPlacement {
        #if os(iOS)
        deleteAllLeading ? .topBarLeading : .primaryAction
        #else
        .primaryAction
        #endif
    }

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
        // suppresses BOTH: an empty inline title (so no wasted large-title band
        // above the pinned header) and the native search (which iOS forces into
        // the nav-bar area, ABOVE any pinned header).
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
                    ToolbarItem(placement: deleteAllPlacement) {
                        if deleteAllInMenu {
                            // Opt-in: fold Delete-All into an overflow menu when
                            // a host's bar is too crowded for a bare button.
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
            #if os(macOS)
            // macOS window: Delete-All is a trash item in the window toolbar's
            // SIDEBAR region — the region `LeadingToolbarChrome`'s New button
            // occupies (declared at the column level in MainWindowView) —
            // mirroring the iOS toolbar trash. Declared HERE, not in the host,
            // because this view owns the list view model: the same
            // `!viewModel.conversations.isEmpty` gate the iOS trash uses, and
            // the same `showDeleteAllConfirmation` alert below, both come for
            // free. Fenced, not flagged — independent of `showsToolbarActions`,
            // which governs only the iOS-designed items above. Lives and dies
            // with the sidebar column's CONTENT: a collapsed sidebar removes
            // it, exactly as the iPad sidebar bar does.
            if !viewModel.conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label(String(localized: "Delete All"), systemImage: "trash")
                    }
                    .help(String(localized: LocalizedStringResource(
                        "conversations.deleteAll.help",
                        defaultValue: "Delete all conversations"
                    )))
                    .accessibilityIdentifier("toolbar.deleteAll")  // stable QA target (non-localized)
                }
            }
            #endif
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
                Task {
                    if await viewModel.deleteAll() {
                        onDeletedAll?()
                    }
                }
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
        // Resolved ONCE per list build, not once per row: the rule scans the
        // whole conversation array, and a single-gateway list is exactly the
        // case where it can't bail early — evaluating it per row would make
        // that scan quadratic in the number of conversations.
        let showsBadge = showsGatewayBadge
        return List {
            ForEach(filteredTimeGroups) { group in
                Section {
                    ForEach(group.conversations) { convo in
                        Button {
                            onSelect(convo.id)
                        } label: {
                            conversationRow(convo, showsBadge: showsBadge)
                        }
                        // Full-bleed live row on macOS: the wash and the click
                        // target reach exactly the band `.listRowBackground`
                        // paints below, so a hovered row and a selected one
                        // share one shape. No-op on iOS.
                        .settingsListRowButton()
                        #if os(macOS)
                        // Right-click Delete on the row — the macOS counterpart
                        // of the iOS swipe (`.onDelete` renders nothing on this
                        // platform). Fenced, not flagged: the iOS hosts never
                        // gain this modifier at compile time. Attached after
                        // `.settingsListRowButton()` so the menu's hit region is
                        // the same full-bleed band that style reclaims. Direct
                        // `convo` capture, never index math, so a list mutation
                        // between click and menu action cannot retarget the
                        // delete. NO confirmation, by spec ("Deleting a single
                        // conversation is deliberately not made to argue back").
                        // DECIDED EXCEPTION to the context-menu-mirrors-a-
                        // visible-control rule (see the attachment chip in
                        // ConversationThreadView): on this platform the row menu
                        // IS the per-row affordance, the platform-standard one
                        // for sidebar lists — founder-decided, don't "fix" it by
                        // removing the menu or adding a keyboard path.
                        .contextMenu {
                            Button(role: .destructive) {
                                Task {
                                    if await viewModel.delete(convo) {
                                        onDeleted?(convo.id)
                                    }
                                }
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                            .accessibilityIdentifier("context.deleteConversation")  // stable QA target (non-localized)
                        }
                        #endif
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
                                let convo = group.conversations[index]
                                if await viewModel.delete(convo) {
                                    onDeleted?(convo.id)
                                }
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
        #elseif os(iOS)
        .modifier(InsetListStyleModifier(isEnabled: usesInsetListStyle))
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await viewModel.reload() }
    }

    /// Whether rows carry the leading gateway badge. Computed from the WHOLE
    /// loaded list (`viewModel.conversations`), never the search-filtered
    /// subset — `fetchConversations()` takes no limit, so this is every stored
    /// conversation, and keying off the filtered set would make badges blink in
    /// and out as the user types.
    private var showsGatewayBadge: Bool {
        RemoteAgentRefMetadata.shouldShowBadges(
            configured: configuredRefs,
            conversationBackends: viewModel.conversations.lazy.map(\.backend),
            customs: customGateways
        )
    }

    private func conversationRow(_ convo: ConversationRecord, showsBadge: Bool) -> some View {
        let tail = previews[convo.id]
        let ref = RemoteAgentRef(rawString: convo.backend)
        // "" for an unresolvable ref — the shared copy then says a bare
        // "Answering…" rather than " is answering…".
        let gatewayName = ref.map { RemoteAgentRefMetadata.displayName(for: $0, customs: customGateways) } ?? ""
        let state = viewModel.rowState(for: convo, tailRole: tail?.role)
        let inputs = ConversationActivityInputs(record: convo, tailRole: tail?.role)
        // The title fallback receives the RAW tail text. Baking the "You: "
        // prefix into the cache would put it in headlines, because
        // `conversationTitle` uses the same string as its fallback.
        let title = MessageRowFormatters.conversationTitle(
            title: convo.title,
            titleSnippet: convo.titleSnippet,
            lastMessagePreview: tail?.text
        )
        let subtitle = MessageRowFormatters.conversationSubtitle(text: tail?.text, role: tail?.role)

        return HStack(spacing: 12) {
            // Leading gateway badge — only when the list spans two gateway
            // identities, and only for a resolvable ref (a deleted / un-synced
            // custom renders nothing via `GatewayBadge`'s empty-monogram
            // guard, and is excluded from the count for that same reason).
            // NEVER tinted, dimmed or overlaid by row state: it answers "which
            // gateway", not "what is happening".
            if showsBadge, let ref {
                GatewayBadge(ref: ref, customs: customGateways)
            }

            // ONE clock for the whole row. It exists only while the row is
            // working, and it re-resolves the state every minute so the title
            // weight, the mark and the status words cross the grace boundary
            // together instead of on three schedules.
            ConversationActivityClock(
                state: state,
                inputs: inputs,
                conversationID: convo.id
            ) { resolved, tick in
                VStack(alignment: .leading, spacing: 6) {
                    // `.center`, not `.firstTextBaseline`: the mark has no text
                    // baseline and would float low against the headline.
                    HStack(alignment: .center, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            // Bold is the unseen treatment, and it is INDEPENDENT
                            // of delivery state — a failed-and-unseen row is red
                            // AND bold, with neither fact suppressed. `nil`
                            // inherits `.headline`'s own weight rather than
                            // flattening it.
                            .fontWeight(resolved.hasUnseenReply ? .bold : nil)
                            .lineLimit(1)
                            .foregroundStyle(AppColors.textEmphasis)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ConversationActivityMark(
                            state: resolved,
                            conversationID: convo.id,
                            now: tick
                        )
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(resolved.hasUnseenReply ? AppColors.textPrimary : AppColors.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ConversationActivityLine(
                        state: resolved,
                        now: tick,
                        gatewayName: gatewayName,
                        lastActivityAt: convo.lastActivityAt,
                        conversationID: convo.id
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        // Make the WHOLE row rectangle the click target (the `maxWidth` is
        // required first — a left-aligned VStack otherwise collapses to text
        // width, leaving the right side a dead zone even with `contentShape`).
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // REQUIRED for "state leads": without it the gateway badge's own
        // accessibility element reads first and the mark reads last.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(MessageRowFormatters.rowAccessibilityLabel(
            state: state,
            title: title,
            subtitle: subtitle,
            gatewayName: gatewayName,
            lastActivityAt: convo.lastActivityAt,
            showsGateway: showsBadge && ref != nil,
            // The spoken row matches the seen one, including the two phases that
            // must not name the gateway. Resolved OUTSIDE the row's clock, like
            // the rest of this label — a label that rewrites on a timer produces
            // repeated announcements.
            phase: ConversationRowActivity.livePhase(convo.id)?.phase ?? .answering
        )))
        // Keyed on the PAIR, not the id: the tail changes only when a message is
        // appended, and that bumps `lastActivityAt`. Keying on the id alone froze
        // a row's preview for the life of the view, so a reply landing while the
        // list was on screen never reached the subtitle.
        .task(id: Self.previewKey(convo)) {
            await loadPreviewIfNeeded(convo)
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

    /// One conversation's cached tail: the collapsed-and-cut preview string plus
    /// the role that decides whether it gets a "You: " prefix, stamped with the
    /// `lastActivityAt` it was read at so the entry is self-invalidating. ONE
    /// entry per conversation — the stamp lives in the value, not the key, so the
    /// cache cannot grow past the conversation count.
    private struct TailPreview: Equatable {
        let lastActivityAt: Date
        let text: String
        let role: MessageRole?
    }

    /// Combined identity + freshness key for a row's tail fetch.
    private struct PreviewKey: Hashable {
        let id: UUID
        let lastActivityAt: Date
    }

    private static func previewKey(_ convo: ConversationRecord) -> PreviewKey {
        PreviewKey(id: convo.id, lastActivityAt: convo.lastActivityAt)
    }

    /// Lazily fetch one row's tail, once per `(id, lastActivityAt)`.
    ///
    /// ONE row, no attachment faults — `fetchConversationTail` replaces a
    /// `fetchMessages(for:)` fan-out that faulted every message of the
    /// conversation plus each one's `attachments` set and kept only the last. The
    /// cost still scales with VISIBLE rows, not with the list, so a CloudKit
    /// change storm cannot turn this into a per-reload fan-out.
    private func loadPreviewIfNeeded(_ convo: ConversationRecord) async {
        guard previews[convo.id]?.lastActivityAt != convo.lastActivityAt else { return }
        let tail = try? await ConversationStore.shared.fetchConversationTail(id: convo.id)
        previews[convo.id] = TailPreview(
            lastActivityAt: convo.lastActivityAt,
            // (The thread view renders the full Markdown; this is preview-only.)
            text: tail.map { Self.previewText(forReply: $0.text) } ?? "",
            role: MessageRole(stored: tail?.role)
        )
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
            Text(LocalizedStringResource(
                "conversations.empty.micHint",
                defaultValue: "Tap the mic on the home screen to start a conversation with your AI."
            ))
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
/// Applies the inset list style only where a host asks for it. Follows the same
/// shape as `NativeSearchableModifier` below rather than an inline conditional:
/// the `else` branch returns the content with no list style applied, so a host at
/// the default renders exactly as it did before this flag existed. It is not a
/// zero-cost wrapper — the content still gains a `ModifiedContent`/
/// `_ConditionalContent` pair — but `isEnabled` is a constant per host, so the
/// branch never flips and SwiftUI never rebuilds the subtree across it.
private struct InsetListStyleModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.listStyle(.inset)
        } else {
            content
        }
    }
}

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
/// inline at the TOP of the sidebar column, which the native `.searchable`
/// cannot do (iOS forces it into the nav-bar area instead). Drives the list's
/// filter via the host's `externalSearchText` binding.
struct SidebarSearchField: View {
    @Binding var text: String

    /// Drives the macOS click-anywhere-on-the-capsule focus assist below.
    @FocusState private var fieldFocused: Bool

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
                // 22, not the 28 default: the clear button shares an HStack with
                // the search field, so the frame is also the capsule's height.
                // Circular wash: the glyph is a filled circle nearly as wide as
                // that square, so a rounded one would halo its corners.
                .pointerIconButton(size: 22, shape: .circle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Self.fill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Self.stroke, lineWidth: 0.5))
        #if os(macOS)
        // The drawn capsule is the padded frame, but padding and a `.background`
        // shape add no live area — only the field's own text line placed a caret,
        // leaving the magnifier, the 12pt side bands and the 8pt top/bottom bands
        // dead. Route a click anywhere on the capsule to the field so it behaves
        // like the system search field it imitates.
        //
        // A BEHIND-CONTENT `.background` layer, never `.contentShape` on the
        // wrapper and never `.overlay`: this is the same fix as
        // `MessageComposerBar.macOS` (see its comment), which records that making
        // the WRAPPER itself hittable surfaces an unlabeled phantom tappable
        // element in the accessibility tree — and this wrapper carries
        // `.accessibilityIdentifier("sidebar.search")`, so that phantom would
        // absorb the identifier and hand AX clients a button where the text field
        // should be. The layer is hidden from AX; VoiceOver focuses the field
        // directly. Being behind the content, it also cannot steal clicks from
        // the field or the clear button.
        .background(
            Color.clear
                .contentShape(Capsule(style: .continuous))
                .onTapGesture { fieldFocused = true }
                .accessibilityHidden(true)
        )
        #endif
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
        // Bound only off iOS — it exists for the capsule-wide click-to-focus
        // assist in `body`, which is macOS-only.
        base
            .focused($fieldFocused)
        #endif
    }
}
