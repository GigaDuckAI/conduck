// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareView.swift  (ConduckShareExtension appex)
//
// SwiftUI body of the iOS Share Extension, hosted by `ShareViewController` via
// `UIHostingController` (Signal-iOS pattern; Apple gives appexes no SwiftUI
// principal through iOS 26). The iOS realization of the macOS "Telegram-style"
// redesign — same polish, but in iOS-native chrome:
//
//   ┌───────────────────────────────────────┐
//   │ Cancel            Where to?           │  ← NavigationStack nav bar (Cancel
//   │                                       │     only; both actions live below)
//   │ ▢ icon  filename / type-desc          │  ← sharedItemHeader (PINNED)
//   │ 🔍 Search                             │  ← searchField (PINNED, conditional)
//   ├───────────────────────────────────────┤
//   │ NEW CONVERSATION                      │  ⎫
//   │  ● OpenClaw                  ◉        │  ⎪ ScrollView — the ONLY scrolling
//   │ RECENT CHATS                          │  ⎬   region, holding gateways and
//   │  ● Trip planning · 2h        ◯        │  ⎭   recent chats. Headers pin.
//   ├───────────────────────────────────────┤
//   │ ▢ Add a message…                      │  ← bottomComposer (.safeAreaInset)
//   │ [ Add to Work ]  [ Send to OpenClaw ] │  ← the two actions, side by side
//   │   Nothing is sent to AI               │  ← Work's own caption
//   └───────────────────────────────────────┘
//
// Unlike macOS (whose share host renders NO `.toolbar`, forcing a manual pinned
// VStack floor for the actions), iOS keeps its native nav bar (`Cancel` + the
// "Where to?" title) and moves the actions into a bottom composer via
// `.safeAreaInset(edge: .bottom)`. That gives native software-keyboard avoidance
// while keeping the destination list and the actions visually distinct.
//
// Dark-mode only (the host sets `overrideUserInterfaceStyle = .dark`). Colors are
// LOCAL literals matching the app palette — the appex does NOT share the main-app
// `AppColors` source membership, so we can't reference it. Same reason the strings
// use inline `defaultValue:` (the appex carries its OWN strings; no shared catalog).
//
// ── Capture / send boundary ────────────────────────────────────────────────────
// The list answers ONE question — which conversation a send goes to — so it holds
// only gateways and recent chats. Work is an action on the floor beside Send,
// never a row: the two inboxes are two buttons that name themselves, rather than
// two rows that look alike.
//
// The sheet opens with a row highlighted: the app's published default gateway
// when it is configured, else the first configured gateway, else nothing. A
// highlight is not a decision — nothing leaves the sheet until a button that
// NAMES where it goes is pressed, and Send carries that name ("Send to OpenClaw",
// "Send to Trip planning"). The legacy no-snapshot route is never highlighted for
// the person: its nil ref lets the drainer continue the app's live quick-capture
// conversation, a place this sheet never named.
//
// Add to Work reaches `onAddToWorkboard` and only the inert Work capture inbox;
// Send reaches `onSend` and the send manifest. The two cannot be confused: the
// pick is a `ShareTarget`, which carries no desk case, and the Work helper takes
// no target at all. ⌘↩ sends and ⌘⇧↩ adds to Work, each firing only its own
// button. Neither action fires on appear, the rows lock while a commit runs, and
// the failure alert's Try Again calls the Work-only helper rather than the pick.
//
// `ShareTarget`, the pick this view seeds, and the two rules that read it — which
// row opens highlighted, and what the Send button names — all live in
// `ShareTargetFilter.swift`, where `ShareTargetFilterTests` covers them without a
// SwiftUI body. This file keeps only the localized strings those rules cannot
// reach.

import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

/// The rich, async-resolved descriptor for the shared item's HEADER row — name +
/// type + (image-only) a memory-bounded thumbnail. Resolved off the LEAD provider
/// by the host's `resolveLeadHeader` closure WITHOUT reading the full bytes (an
/// ImageIO-bounded thumbnail for images; a localized type description for other
/// files). `nil` until resolved (the header shows the immediate glyph state until
/// then); `icon == nil` falls back to the typed glyph forever (documents / web
/// URLs / plain text never get an icon on iOS).
struct ResolvedHeader {
    /// Filename / page-title / text-snippet — the header's PRIMARY line.
    let filename: String
    /// Localized type description ("PDF Document", host, …) — the SECONDARY line.
    let typeDescription: String?
    /// A memory-bounded image thumbnail; `nil` → keep the typed glyph (documents).
    let icon: UIImage?
}

enum WorkboardCommitFailure: Hashable, Identifiable, Sendable {
    case unavailable
    case tooLarge
    case empty
    /// Something in the share is not a regular file — a folder or a package
    /// document such as `.rtfd` or `.pages`.
    case unsupportedItem
    /// The assembled capture violates the durable envelope contract, so the
    /// same share can never publish however often it is replayed.
    case invalidContent

    var id: Self { self }

    /// Only a transient filesystem failure can improve when replayed unchanged.
    /// Size, empty-input, unsupported-item, and contract failures all require
    /// the person to change the share.
    var allowsRetry: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

@MainActor
final class ShareSubmissionState: ObservableObject {
    enum Phase: Equatable {
        case addingToWorkboard
        case sending
    }

    @Published private(set) var phase: Phase?
    @Published var workboardFailure: WorkboardCommitFailure?

    var isCommitting: Bool { phase != nil }

    func begin(_ phase: Phase) -> Bool {
        guard self.phase == nil else { return false }
        workboardFailure = nil
        self.phase = phase
        return true
    }

    func failWorkboardCommit(_ failure: WorkboardCommitFailure) {
        phase = nil
        workboardFailure = failure
    }
}

struct ShareView: View {

    /// Total attachment count (drives the header "+N more" summary).
    let attachmentCount: Int
    /// Lightweight preview descriptors (no bytes loaded — see
    /// `ShareViewController.buildPreviewItems()`). `previewItems.first` gives the
    /// IMMEDIATE type + name for the header before `resolveLeadHeader` lands.
    let previewItems: [PreviewItem]
    /// The gateway and recent-chat targets the main app published for the
    /// destination list; `nil` when no snapshot exists / it failed to decode
    /// (→ legacy single-row fallback).
    let snapshot: ShareTargetsSnapshot?
    /// Resolve the rich header off the LEAD provider (name/type/icon) WITHOUT a
    /// full-byte read. `@MainActor`, returns `nil` on any failure (→ keep the
    /// immediate glyph state). Owned by the host VC.
    let resolveLeadHeader: @MainActor () async -> ResolvedHeader?
    /// Resolve the Safari page-text capture payload, if this share carries one.
    /// `@MainActor`, awaits the host's memoized capture load; `nil` for every
    /// non-Safari share (→ no toggle row). Owned by the host VC.
    let resolveCapture: @MainActor () async -> WebPageCapture.Payload?
    /// Commit the share with the typed caption, the picked target, and whether the
    /// captured page text should be included (the toggle). Owned by the host VC,
    /// which resolves `target` into the manifest's routing fields.
    let onSend: (String, ShareTarget, Bool) -> Void
    /// Save the shared material as an inert Work capture on the one desk. This
    /// closure names no destination and has no gateway/send parameter, so it
    /// cannot dispatch.
    let onAddToWorkboard: (String, Bool) -> Void
    /// Dismiss without queuing anything. Owned by the host VC.
    let onCancel: () -> Void

    @ObservedObject var submissionState: ShareSubmissionState

    @State private var caption: String = ""
    /// Which conversation a send goes to. Seeded from the snapshot at init — the
    /// app's default gateway, else the first configured one, else nothing — and
    /// moved only by tapping a row. It is a HIGHLIGHT, not a decision: the Send
    /// button names whatever this holds, and nothing leaves the sheet until that
    /// button (or ⌘↩) is pressed. Nothing survives from a previous share; each
    /// invocation is a fresh process that reads only the snapshot.
    @State private var destination: ShareTarget?
    @State private var query: String = ""
    /// Rich header (async); `nil` until `resolveLeadHeader` returns — until then the
    /// header renders the immediate glyph + `previewItems.first` label.
    @State private var resolvedLead: ResolvedHeader?
    /// Safari page-text capture payload (async); `nil` until `resolveCapture`
    /// returns AND only ever non-nil for a Safari share — drives the toggle row's
    /// presence + copy. When set, `includePageText` gates whether it rides.
    @State private var capturePayload: WebPageCapture.Payload?
    /// The capture toggle — default ON (the feature is visible, not hidden). Only
    /// consulted when `capturePayload != nil`; OFF still delivers the page URL
    /// (the envelope appends it toggle-independently).
    @State private var includePageText = true
    @FocusState private var captionFocused: Bool
    /// At an accessibility text size the two floor actions stack instead of
    /// sharing a row — two half-width buttons cannot hold a scaled-up label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Explicit because the pick is seeded from the snapshot: the memberwise init
    /// cannot reach `@State`, and a `.onAppear` seed would be a decision taken
    /// after the sheet was already on screen.
    init(
        attachmentCount: Int,
        previewItems: [PreviewItem],
        snapshot: ShareTargetsSnapshot?,
        resolveLeadHeader: @escaping @MainActor () async -> ResolvedHeader?,
        resolveCapture: @escaping @MainActor () async -> WebPageCapture.Payload?,
        onSend: @escaping (String, ShareTarget, Bool) -> Void,
        onAddToWorkboard: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void,
        submissionState: ShareSubmissionState
    ) {
        self.attachmentCount = attachmentCount
        self.previewItems = previewItems
        self.snapshot = snapshot
        self.resolveLeadHeader = resolveLeadHeader
        self.resolveCapture = resolveCapture
        self.onSend = onSend
        self.onAddToWorkboard = onAddToWorkboard
        self.onCancel = onCancel
        self.submissionState = submissionState
        _destination = State(initialValue: ShareTargetFilter.preselectedTarget(snapshot: snapshot))
    }

    // MARK: - Local palette (mirrors AppColors; appex can't import it)

    private enum Palette {
        static let background = Color(red: 0.071, green: 0.063, blue: 0.063)   // dark-900
        static let card = Color(red: 0.118, green: 0.102, blue: 0.094)        // dark-800
        static let elevated = Color(red: 0.145, green: 0.125, blue: 0.118)    // #25201E (composer box)
        static let border = Color(red: 0.239, green: 0.208, blue: 0.192)      // dark-600
        static let amber = Color(red: 1.0, green: 0.757, blue: 0.027)
        static let teal = Color(red: 0.149, green: 0.651, blue: 0.604)
        static let textPrimary = Color(red: 0.929, green: 0.910, blue: 0.890)
        static let textSecondary = Color(red: 0.851, green: 0.816, blue: 0.784)
        static let textTertiary = Color(red: 0.627, green: 0.580, blue: 0.541)
        static let neutralBadge = Color(red: 0.392, green: 0.357, blue: 0.333) // recents w/o gateway match
    }

    // MARK: - Derived target lists

    /// Gateways the user can start a NEW conversation with (configured only).
    private var configuredGateways: [ShareTargetsSnapshot.Gateway] {
        (snapshot?.gateways ?? []).filter { $0.configured }
    }

    /// Existing conversations to append to, most-recent-first (the writer already
    /// orders them, but we don't depend on that).
    private var recents: [ShareTargetsSnapshot.RecentConversation] {
        (snapshot?.recentConversations ?? [])
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The legacy "New conversation" row shows only when NO snapshot decoded —
    /// the roster is unknown, not empty (`ShareTargetFilter`, unit-tested).
    private var showsLegacyRow: Bool {
        ShareTargetFilter.showsLegacyNewConversationRow(snapshotDecoded: snapshot != nil)
    }

    /// A decoded snapshot with no configured gateway and no recent chat is TOLD
    /// in one line rather than offered a send the drainer would refuse
    /// (`ShareTargetFilter`, unit-tested). The line points at Add to Work, which
    /// sits on the floor and is unaffected by an empty roster.
    private var showsNoAILine: Bool {
        ShareTargetFilter.showsNoAILine(snapshotDecoded: snapshot != nil,
                                        gatewayCount: configuredGateways.count,
                                        recentCount: recents.count)
    }

    // MARK: - Search

    /// Search renders only once the combined target count exceeds 8 (pure helper
    /// `ShareTargetFilter` owns the rule + the filtering so both stay unit-tested).
    private var showSearch: Bool {
        ShareTargetFilter.shouldShowSearch(gatewayCount: configuredGateways.count,
                                           recentCount: recents.count)
    }

    /// Gateways after the search filter (empty/whitespace query → passthrough).
    private var filteredGateways: [ShareTargetsSnapshot.Gateway] {
        ShareTargetFilter.filterGateways(configuredGateways, query: query)
    }

    /// Recents after the search filter (empty/whitespace query → passthrough).
    private var filteredRecents: [ShareTargetsSnapshot.RecentConversation] {
        ShareTargetFilter.filterRecents(recents, query: query)
    }

    /// True when the user is actively searching but nothing matched — drives the
    /// centered "No matches" empty state inside the scroll region.
    private var isEmptySearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && filteredGateways.isEmpty && filteredRecents.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    sharedItemHeader               // PINNED
                    if let payload = capturePayload {
                        capturePageTextRow(payload)  // PINNED, Safari-capture only
                    }
                    if showSearch { searchField }
                    Divider().overlay(Palette.border)
                    pickerScroll                   // the ONE destination list
                        .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle(Text(Strings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { onCancel() } label: {
                        Text(Strings.cancel)
                    }
                    .tint(Palette.textSecondary)
                    .disabled(submissionState.isCommitting)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomComposer }
        }
        .tint(Palette.amber)
        .preferredColorScheme(.dark)
        .task {
            // Resolve the rich header (name/type/icon) off the lead provider. The
            // header shows the immediate glyph state until this lands; a nil result
            // simply keeps that glyph.
            resolvedLead = await resolveLeadHeader()
        }
        .task {
            // Resolve the Safari page-text capture (if any) — mounts the toggle
            // row when a payload arrives. Separate `.task` so a slow header
            // thumbnail never delays the toggle (both run concurrently).
            capturePayload = await resolveCapture()
        }
        .alert(item: $submissionState.workboardFailure) { failure in
            if failure.allowsRetry {
                Alert(
                    title: Text(Strings.workboardErrorTitle),
                    message: Text(workboardFailureMessage(failure)),
                    primaryButton: .default(Text(Strings.retry)) {
                        addToWorkboard()
                    },
                    secondaryButton: .cancel(Text(Strings.cancel)) {
                        onCancel()
                    }
                )
            } else {
                Alert(
                    title: Text(Strings.workboardErrorTitle),
                    message: Text(workboardFailureMessage(failure)),
                    dismissButton: .default(Text(Strings.cancel)) { onCancel() }
                )
            }
        }
    }

    // MARK: - Header (shared-item, PINNED)

    /// The shared-item header content: a 36×36 thumbnail (image, resolved) or a
    /// typed SF-symbol glyph (immediate/loading + the permanent state for
    /// documents / URLs / text), a primary filename line, and a secondary
    /// type-description line (with a "+N more" suffix for multi-item shares).
    private var sharedItemHeader: some View {
        HStack(spacing: 12) {
            headerIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(headerPrimary)
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = headerSecondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 36×36 leading glyph/icon. Prefers the resolved `UIImage` (bounded image
    /// thumbnail); otherwise the typed SF-symbol of the lead item.
    @ViewBuilder
    private var headerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.card)
            if let icon = resolvedLead?.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: leadGlyph)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(leadGlyphTint)
            }
        }
        .frame(width: 36, height: 36)
    }

    /// Immediate type glyph for the lead item (the "still loading" state, and the
    /// permanent state for documents / web URLs / plain text that never get an icon).
    private var leadGlyph: String { previewItems.first?.symbol ?? "doc" }

    private var leadGlyphTint: Color {
        previewItems.first?.tint(amber: Palette.amber, teal: Palette.teal,
                                 secondary: Palette.textSecondary)
            ?? Palette.textSecondary
    }

    /// Primary header line — resolved filename if available, else the immediate
    /// lead-item label, else a generic fallback. Never empty.
    private var headerPrimary: String {
        if let name = resolvedLead?.filename, !name.isEmpty { return name }
        if let label = previewItems.first?.label, !label.isEmpty { return label }
        return Strings.itemFallback
    }

    /// Secondary header line — the type description, with a "+N more" suffix when
    /// the share carries multiple attachments.
    private var headerSecondary: String? {
        let typeDesc = resolvedLead?.typeDescription?.trimmingCharacters(in: .whitespaces)
        let base = (typeDesc?.isEmpty == false) ? typeDesc : nil
        if attachmentCount > 1 {
            let more = moreSummary(extra: attachmentCount - 1)
            if let base { return "\(base) · \(more)" }
            return more
        }
        return base
    }

    // MARK: - Capture toggle row (PINNED, Safari-capture only)

    /// The Safari page-text capture row — mounted only when `capturePayload != nil`
    /// (a Safari share whose JS payload parsed to usable text). A `doc.text` glyph
    /// matching the header icon, a "Page text" / "Selected text" title, a byte-size
    /// subtitle (+ " · truncated" when the capture was cut at the cap), and an amber
    /// toggle defaulting ON. Toggling OFF still delivers the page URL — the envelope
    /// appends it toggle-independently; the toggle only gates the text attachment.
    private func capturePageTextRow(_ payload: WebPageCapture.Payload) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.card)
                Image(systemName: "doc.text")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.amber)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.isSelection ? Strings.captureSelection : Strings.capturePage)
                    .font(.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(captureSubtitle(payload))
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $includePageText)
                .labelsHidden()
                .tint(Palette.amber)
                .accessibilityLabel(Text(Strings.captureToggleA11y))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Byte-size subtitle for the capture row — human-readable size of the text
    /// that actually rides (`returnedByteCount`), plus a " · truncated" suffix when
    /// any capture stage cut it at the cap.
    private func captureSubtitle(_ payload: WebPageCapture.Payload) -> String {
        // `.binary` (1024-based) so the sheet's size matches the wire notes'
        // `WebPageCapture.formatKB` (also 1024-based) — `.file` (1000-based) would
        // disagree with the truncation note the agent receives.
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(payload.returnedByteCount), countStyle: .binary)
        return payload.truncated ? "\(size) · \(Strings.captureTruncated)" : size
    }

    // MARK: - Search field (PINNED, conditional)

    /// PINNED search field — only mounted when `showSearch` is true (more than 8
    /// total targets). Not auto-focused (see file header).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textTertiary)
            TextField(Strings.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.clearSearch))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Picker (the ONLY scrolling region)

    /// Pinned section headers, compact rows. The header/search/divider/composer all
    /// sit OUTSIDE this so the bottom composer stays on the panel floor.
    private var pickerScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if showsLegacyRow {
                    legacyNewConversationRow
                } else if showsNoAILine {
                    noAILine
                } else if isEmptySearch {
                    emptySearchState
                } else {
                    newConversationSection
                    recentChatsSection
                }
            }
            .padding(.vertical, 4)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Shown in place of the two send sections when a DECODED snapshot lists no
    /// configured gateway and no recent chat: the send route is a route the app
    /// itself says cannot succeed, so it is told rather than offered — and the
    /// line says so while pointing at the Add to Work button on the floor, which
    /// an empty roster never takes away.
    private var noAILine: some View {
        Text(Strings.noAIWork)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
    }

    /// "New conversation" section (gateway rows). Header pins; only mounted when
    /// the filtered gateway list is non-empty.
    @ViewBuilder
    private var newConversationSection: some View {
        if !filteredGateways.isEmpty {
            Section {
                newConversationRows
            } header: {
                sectionHeader(Strings.sectionNew)
            }
        }
    }

    /// "Recent chats" section (existing-conversation rows). Header pins; only
    /// mounted when the filtered recents list is non-empty.
    @ViewBuilder
    private var recentChatsSection: some View {
        if !filteredRecents.isEmpty {
            Section {
                recentRows
            } header: {
                sectionHeader(Strings.sectionRecent)
            }
        }
    }

    @ViewBuilder
    private var newConversationRows: some View {
        // Single configured gateway → one clean collapsed "New conversation" row
        // (no per-gateway clutter), but ONLY when not searching: while searching we
        // render the gateway by its displayName so the query can match it.
        if query.isEmpty, configuredGateways.count == 1, let only = configuredGateways.first {
            let target = ShareTarget.newConversation(gatewayRef: only.ref)
            targetRow(
                badge: badge(monogram: "+", fill: Palette.teal),
                title: Strings.newConversation,
                subtitle: nil,
                selectable: true,
                isSelected: destination == target,
                action: { destination = target }
            )
        } else {
            ForEach(filteredGateways, id: \.ref) { gateway in
                let target = ShareTarget.newConversation(gatewayRef: gateway.ref)
                targetRow(
                    badge: badge(monogram: gateway.monogram, fill: color(hex: gateway.colorHex)),
                    title: gateway.displayName,
                    subtitle: Strings.newConversation,
                    selectable: true,
                    isSelected: destination == target,
                    action: { destination = target }
                )
            }
        }
    }

    @ViewBuilder
    private var recentRows: some View {
        ForEach(filteredRecents, id: \.id) { convo in
            let target = ShareTarget.existing(conversationID: convo.id, backendRef: convo.backendRef)
            let gateway = configuredGateways.first(where: { $0.ref == convo.backendRef })
                ?? snapshot?.gateways.first(where: { $0.ref == convo.backendRef })
            let fill = gateway.map { color(hex: $0.colorHex) } ?? Palette.neutralBadge
            let mono = gateway?.monogram.isEmpty == false ? gateway!.monogram : monogram(for: convo.label)
            targetRow(
                badge: badge(monogram: mono, fill: fill),
                title: convo.label.isEmpty ? Strings.untitledChat : convo.label,
                subtitle: Self.relativeFormatter.localizedString(for: convo.lastActivityAt, relativeTo: Date()),
                selectable: true,
                isSelected: destination == target,
                action: { destination = target }
            )
        }
    }

    /// Shown only when NO snapshot decoded: the roster is UNKNOWN, not empty —
    /// the app may well hold a gateway this appex cannot see — so the legacy
    /// route stays on offer (both manifest refs nil → the drainer resolves the
    /// route). It opens UNHIGHLIGHTED and has to be tapped: a nil-ref send may
    /// continue the app's live quick-capture conversation, which is a place this
    /// sheet never named, so it is never picked for the person.
    private var legacyNewConversationRow: some View {
        targetRow(
            badge: badge(monogram: "+", fill: Palette.teal),
            title: Strings.newConversation,
            subtitle: nil,
            selectable: true,
            isSelected: destination == .newConversation(gatewayRef: nil),
            action: { destination = .newConversation(gatewayRef: nil) }
        )
    }

    /// Centered empty-search state (query non-empty, both filtered lists empty).
    /// Add to Work still sits on the floor below it, so a search that matches
    /// nothing never leaves the share with nowhere to go.
    private var emptySearchState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text(Strings.searchEmpty)
                .font(.callout)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Picker building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.textTertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Palette.background)   // opaque so pinned headers don't bleed
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func targetRow(
        badge: AnyView,
        title: String,
        subtitle: String?,
        selectable: Bool,
        isSelected: Bool,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                badge.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selectable {
                    selectionRing(isSelected: isSelected)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Palette.amber.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        // Locked while a commit runs: a tap during the asynchronous copy must not
        // move the pick under it (the retry is bound to Work by construction too).
        .disabled(!selectable || submissionState.isCommitting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            subtitle.map { "\(title), \($0)" } ?? title
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Trailing selection ring (~22pt): amber filled circle + white checkmark when
    /// selected, hollow tertiary-stroked circle when not.
    @ViewBuilder
    private func selectionRing(isSelected: Bool) -> some View {
        if isSelected {
            ZStack {
                Circle().fill(Palette.amber)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
        } else {
            Circle()
                .strokeBorder(Palette.textTertiary, lineWidth: 1.5)
                .frame(width: 22, height: 22)
        }
    }

    /// Round monogram badge (~34pt) — filled with the gateway's resolved color.
    private func badge(monogram: String, fill: Color) -> AnyView {
        AnyView(
            ZStack {
                Circle().fill(fill)
                Text(monogram)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
        )
    }

    // MARK: - Bottom composer (.safeAreaInset floor)

    /// The ONE predicate behind both the Send button's `.disabled(…)` and the
    /// opacity that draws it as disabled. `.buttonStyle(.plain)` over an explicit
    /// amber fill and an explicit foreground dims NEITHER on its own, so without
    /// the opacity a button that refuses every tap looks exactly like one that
    /// commits. Both modifiers read this property, so they cannot drift apart.
    private var isPrimaryDisabled: Bool {
        destination == nil || submissionState.isCommitting
    }

    /// The same, for Add to Work — which needs no pick, because the desk is one
    /// desk and the button names it. It locks only while a commit already runs.
    private var isWorkDisabled: Bool {
        submissionState.isCommitting
    }

    /// The Send button's label — it NAMES where the share goes, so pressing it is
    /// the moment the person decides. A gateway pick names the gateway, a recent
    /// pick names the chat, and the legacy nil-ref route, which the drainer
    /// resolves rather than this sheet, says only "Send now".
    private var sendLabel: String {
        switch ShareTargetFilter.sendLabel(for: destination, snapshot: snapshot) {
        case .sendNow: return Strings.sendNow
        case .sendTo(let name): return Strings.sendTo(name)
        case .sendToUntitledChat: return Strings.sendTo(Strings.untitledChat)
        }
    }

    /// PINNED floor: the message field, then the TWO actions side by side — Add to
    /// Work leading (secondary), Send trailing (primary), equal widths — with
    /// Work's "Nothing is sent to AI" caption directly under its own button. Each
    /// button names its own inbox, so the floor is where the share is decided, not
    /// the list. ⌘↩ sends, ⌘⇧↩ adds to Work; a shortcut can only commit what its
    /// button would.
    private var bottomComposer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Palette.border)
            VStack(spacing: 10) {
                TextField(Strings.captionPlaceholder, text: $caption, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($captionFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Palette.border, lineWidth: 1)
                    )

                floorActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Palette.background)
    }

    /// The two actions. Side by side at normal text sizes; stacked (Send first) at
    /// an accessibility size, where a half-width button cannot hold its label.
    @ViewBuilder
    private var floorActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                sendButton
                workColumn
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                workColumn
                sendButton
            }
        }
    }

    /// Add to Work plus the caption that belongs to it. The caption is
    /// accessibility-hidden because the button already carries it as its hint —
    /// VoiceOver would otherwise read the reassurance twice.
    private var workColumn: some View {
        VStack(spacing: 4) {
            workButton
            Text(Strings.nothingSent)
                .font(.caption2)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    /// Secondary look — elevated fill, bordered, amber glyph and text — so the
    /// inert desk never competes with the send it sits beside.
    private var workButton: some View {
        Button(action: addToWorkboard) {
            Group {
                if submissionState.phase == .addingToWorkboard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Palette.amber)
                        Text(Strings.addingToWorkboard)
                    }
                } else {
                    Label(Strings.addToWorkboard, systemImage: "tray.and.arrow.down.fill")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.amber)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            )
            .opacity(isWorkDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .accessibilityHint(Text(Strings.nothingSent))
        .disabled(isWorkDisabled)
    }

    /// Primary look — the amber pill — and the only control that names a
    /// conversation.
    private var sendButton: some View {
        Button(action: commit) {
            Group {
                if submissionState.phase == .sending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Palette.background)
                        Text(Strings.sending)
                    }
                } else {
                    Label(sendLabel, systemImage: "paperplane.fill")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.background)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.amber)
            )
            .opacity(isPrimaryDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(isPrimaryDisabled)
    }

    // MARK: - Commit

    /// The Send button and ⌘-Return. Reads the pick ONCE and hands it to the send
    /// helper, which is bound to the send manifest by construction.
    private func commit() {
        guard let destination else { return }
        send(destination)
    }

    /// The Add to Work button, ⌘⇧-Return, and the alert's Try Again — so a retry
    /// can never follow a row tapped after the failed attempt began. It reads no
    /// pick and takes no target, so it cannot dispatch.
    private func addToWorkboard() {
        guard submissionState.begin(.addingToWorkboard) else { return }
        onAddToWorkboard(caption, includePageText)
    }

    /// A conversation pick only — the target arrives as an argument, so the desk
    /// cannot reach the send manifest however this view is edited.
    private func send(_ target: ShareTarget) {
        guard submissionState.begin(.sending) else { return }
        onSend(caption, target, includePageText)
    }

    private func workboardFailureMessage(_ failure: WorkboardCommitFailure) -> String {
        switch failure {
        case .unavailable:
            return Strings.workboardErrorUnavailable
        case .tooLarge:
            return Strings.workboardErrorTooLarge
        case .empty:
            return Strings.workboardErrorEmpty
        case .unsupportedItem:
            return Strings.workboardErrorUnsupportedItem
        case .invalidContent:
            return Strings.workboardErrorInvalidContent
        }
    }

    // MARK: - Color + monogram helpers

    /// Parse a `"#RRGGBB"` hex (the snapshot's pre-resolved badge color) into a
    /// `Color`; any malformed value falls back to the neutral badge tint so a bad
    /// snapshot can never crash or render an invisible badge.
    private func color(hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return Palette.neutralBadge }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// Fallback monogram for a recent chat with no resolvable gateway badge.
    private func monogram(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        return String(first).uppercased()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// "+N more" suffix for a multi-attachment share's secondary header line.
    private func moreSummary(extra: Int) -> String {
        String(
            localized: "share.summary.more",
            defaultValue: "+\(extra) more",
            comment: "Suffix on the share header when more than one item is shared (+n more)"
        )
    }

    // MARK: - Localized strings (inline defaults → the appex carries no catalog)

    private enum Strings {
        static let title = String(localized: "share.destination.title",
            defaultValue: "Where to?",
            comment: "Share Extension navigation title over the destination list (gateways and recent chats)")
        static let noAIWork = String(localized: "share.destination.noAI.work",
            defaultValue: "No personal AI available. You can still add this to Work.",
            comment: "Shown in place of the gateway rows when the snapshot lists no configured gateway and no recent chat; Add to Work stays available on the floor")
        static let nothingSent = String(localized: "share.work.inert",
            defaultValue: "Nothing is sent to AI",
            comment: "Caption under the Add to Work button on the share sheet's floor, and that button's accessibility hint — privacy reassurance for an inert Work capture")
        static let cancel = String(localized: "share.cancel",
            defaultValue: "Cancel",
            comment: "Cancel button in the Share Extension")
        static let sendNow = String(localized: "share.sendNow",
            defaultValue: "Send now",
            comment: "Immediate dispatch button in the Share Extension")
        static func sendTo(_ name: String) -> String {
            String(localized: "share.send.to",
                defaultValue: "Send to \(name)",
                comment: "Primary share button naming the picked destination (a gateway's name for a new conversation, or a chat's title)")
        }
        static let addToWorkboard = String(localized: "share.addToWork",
            defaultValue: "Add to Work",
            comment: "Primary button that saves shared material as inert Work")
        static let addingToWorkboard = String(localized: "share.addToWork.progress",
            defaultValue: "Adding to Work…",
            comment: "Progress label while the Share Extension saves inert Work")
        static let sending = String(localized: "share.send.progress",
            defaultValue: "Sending…",
            comment: "Progress label while the Share Extension queues a conversation send")
        static let workboardErrorTitle = String(localized: "share.work.error.title",
            defaultValue: "Couldn’t Add to Work",
            comment: "Title shown when the Share Extension cannot persist a Work capture")
        static let workboardErrorUnavailable = String(localized: "share.work.error.unavailable",
            defaultValue: "Nothing was saved. Check that your device has free storage, then try again.",
            comment: "Actionable generic Workboard persistence failure message in the Share Extension")
        static let workboardErrorTooLarge = String(localized: "share.work.error.tooLarge",
            defaultValue: "This share is too large for Work. Share fewer files or smaller files, then try again.",
            comment: "Actionable size-limit failure message for a Workboard capture")
        static let workboardErrorEmpty = String(localized: "share.work.error.empty",
            defaultValue: "There’s nothing to add yet. Add a message or include at least one shared item, then try again.",
            comment: "Actionable empty Workboard capture failure message")
        static let workboardErrorUnsupportedItem = String(localized: "share.work.error.unsupportedItem",
            defaultValue: "Folders and package documents can’t be added to Work. Share the files inside them instead.",
            comment: "Non-retryable failure message when a shared item is not a regular file")
        static let workboardErrorInvalidContent = String(localized: "share.work.error.invalidContent",
            defaultValue: "Something in this share can’t be saved to Work. Share it a different way, or share fewer items.",
            comment: "Non-retryable failure message when a share breaks the Work capture contract")
        static let retry = String(localized: "share.retry",
            defaultValue: "Try Again",
            comment: "Retry button after a Share Extension persistence failure")
        static let captionPlaceholder = String(localized: "share.caption.placeholder",
            defaultValue: "Add a message…",
            comment: "Placeholder for the caption field in the Share Extension")
        static let searchPlaceholder = String(localized: "share.search.placeholder",
            defaultValue: "Search",
            comment: "Placeholder for the target-search field in the Share Extension")
        static let searchEmpty = String(localized: "share.search.empty",
            defaultValue: "No matches",
            comment: "Empty state shown when a Share Extension target search matches nothing")
        static let clearSearch = String(localized: "share.search.clear",
            defaultValue: "Clear search",
            comment: "Accessibility label for the clear-search button in the Share Extension")
        static let newConversation = String(localized: "share.target.newConversation",
            defaultValue: "New conversation",
            comment: "Picker row that starts a brand-new conversation")
        static let sectionNew = String(localized: "share.section.new",
            defaultValue: "New conversation",
            comment: "Picker section header above the new-conversation gateway rows")
        static let sectionRecent = String(localized: "share.section.recent",
            defaultValue: "Recent chats",
            comment: "Picker section header above the recent-conversation rows")
        static let untitledChat = String(localized: "share.target.untitled",
            defaultValue: "Conversation",
            comment: "Fallback label for a recent chat with no title")
        static let itemFallback = String(localized: "share.item.fallback",
            defaultValue: "Shared item",
            comment: "Generic fallback label when a shared item has no resolvable name")
        static let capturePage = String(localized: "share.capture.page",
            defaultValue: "Page text",
            comment: "Title of the Share Extension row that toggles including the captured full-page text")
        static let captureSelection = String(localized: "share.capture.selection",
            defaultValue: "Selected text",
            comment: "Title of the Share Extension capture row when the user had text selected (the selection is captured instead of the whole page)")
        static let captureTruncated = String(localized: "share.capture.truncated",
            defaultValue: "truncated",
            comment: "Suffix on the captured-text size when the capture was cut at the size cap")
        static let captureToggleA11y = String(localized: "share.capture.toggleA11y",
            defaultValue: "Include page text",
            comment: "Accessibility label for the toggle that includes or excludes the captured page text")
    }

    // MARK: - Preview model

    /// Type-tagged preview descriptor — carries NO bytes (loading a 48 MP HEIC
    /// in the appex would blow the 120 MB cap). The host derives these from the
    /// providers' registered type identifiers + suggested names. The rich
    /// `ResolvedHeader` (async) carries name/type/icon; this gives the IMMEDIATE
    /// glyph + label for the header before that resolves.
    enum PreviewItem {
        case image(name: String?)
        case file(name: String?)
        case url
        case text

        var symbol: String {
            switch self {
            case .image: return "photo"
            case .file: return "doc"
            case .url: return "link"
            case .text: return "text.alignleft"
            }
        }

        func tint(amber: Color, teal: Color, secondary: Color) -> Color {
            switch self {
            case .image: return amber
            case .url: return teal
            case .file, .text: return secondary
            }
        }

        var label: String {
            switch self {
            case .image(let name):
                return name ?? String(localized: "share.item.image",
                    defaultValue: "Image", comment: "Label for a shared image with no name")
            case .file(let name):
                return name ?? String(localized: "share.item.file",
                    defaultValue: "File", comment: "Label for a shared file with no name")
            case .url:
                return String(localized: "share.item.link",
                    defaultValue: "Link", comment: "Label for a shared web link")
            case .text:
                return String(localized: "share.item.text",
                    defaultValue: "Text", comment: "Label for shared plain text")
            }
        }
    }
}
