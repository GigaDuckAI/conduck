// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareView.swift  (ConduckShareExtensionMac appex)
//
// SwiftUI body of the macOS Share Extension, hosted by `ShareViewController` via
// `NSHostingController` (Apple gives appexes no SwiftUI principal). Telegram-style
// PINNED layout in the fixed 480×600 dark panel:
//
//   ┌───────────────────────────────────────┐
//   │ [✕]  ▢ icon  filename / type-desc     │  ← headerBar (PINNED, §B)
//   │      ▢ doc  Page text · 48 KB [ ON]   │  ← captureToggleRow (Safari only, §B.5)
//   │      🔍 Search                        │  ← searchField (PINNED, conditional §C)
//   ├───────────────────────────────────────┤
//   │ NEW CONVERSATION                      │  ⎫
//   │  ● OpenClaw                  ◯/◉      │  ⎪ ScrollView — the ONLY scrolling
//   │ RECENT CHATS                          │  ⎬   region. Section headers pin,
//   │  ● Trip planning · 2h        ◯/◉      │  ⎪   and WORK is ALWAYS its last
//   │ WORK                                  │  ⎪   section, however the sections
//   │  ● Add to Work · Nothing…    ◯/◉      │  ⎭   above it are filtered.
//   ├───────────────────────────────────────┤
//   │ ▢ Add a message…                      │  ← bottomBar (PINNED floor, §D)
//   │ [ Choose a destination ]              │  ← disabled until a row is picked;
//   └───────────────────────────────────────┘     then [ Add to Work ] / [ Send now ]
//
// The macOS share host renders NO `.toolbar` (the old layout's Send button lived
// there → "no Send button" bug). The one primary action therefore lives in the
// pinned in-panel bottom bar. The header/search/dividers/bottomBar are siblings
// of the `ScrollView`, so the action always sits on the panel floor, and the
// list — which now ends in the Work row — fills the fixed panel by itself.
//
// ── Safari page-text capture (§B.5) ────────────────────────────────────────────
// When shared from Safari, `resolveCapture` yields a `WebPageCapture.Payload` and
// the `captureToggleRow` mounts between the header and the search field: it names
// the scope ("Page text" / "Selected text"), shows the captured size (+ truncation),
// and carries an amber switch (default ON) whose state feeds `onSend`. Every
// non-Safari share resolves nil → the row never mounts and the layout is unchanged.
//
// Dark-mode only (the host sets `.darkAqua` + this view forces
// `.preferredColorScheme(.dark)`). Colors are LOCAL literals matching the app
// palette — the appex does NOT share the main-app `AppColors` source membership, so
// we can't reference it. Same reason the strings use inline `defaultValue:` (the
// appex carries its OWN `Localizable.xcstrings`; keys are spliced into it later).
//
// ── Capture / send boundary ────────────────────────────────────────────────────
// Work is the LAST row of the ONE destination list — after every gateway and
// every recent chat, in its own section, present whatever the roster holds and
// whatever is typed in the search field. Nothing is pre-selected: the rows are
// the question, and the button answers only once a row is clicked, so no share is
// routed for the person in either direction. A Work pick reaches
// `onAddToWorkboard` and only the inert Work capture inbox, always targetlessly
// (Work is ONE desk, which the drainer resolves); a gateway pick reaches `onSend`
// and the send manifest. The two cannot be confused, because a pick is a
// `ShareDestination` while the manifest writer takes only a `ShareTarget`, which
// carries no desk case. Plain Return always inserts a line break; only the
// visible primary button or ⌘-Return commits. Neither action fires on appear, the
// rows lock while a commit runs, and the failure alert's Try Again calls the
// Work-only helper rather than the pick.

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// The gateway target the person picked in the destination list. Maps 1:1 to
/// the `SharedInboxManifest` routing fields the host writes (see
/// `ShareViewController.commit(caption:target:)`):
///   - `.newConversation(nil)`           → legacy/default route (all refs nil)
///   - `.newConversation(.some(ref))`    → mint a new conversation bound to `ref`
///   - `.existing(id, backendRef)`       → append to an existing conversation
enum ShareTarget: Equatable {
    /// Start a NEW conversation. `gatewayRef == nil` is the legacy/default target
    /// (the drainer routes to the default gateway); a non-nil ref pins the gateway.
    case newConversation(gatewayRef: String?)
    /// Append to an EXISTING conversation, carrying its bound gateway ref as a
    /// fallback hint should the conversation be deleted before the drain runs.
    case existing(conversationID: UUID, backendRef: String)
}

/// What the person picked in the destination list. `.work` is the desk — one
/// desk, so it names no card — and `.send` is a gateway target. Kept apart from
/// `ShareTarget` so the send manifest writer, which takes only a `ShareTarget`,
/// cannot be handed the desk by any edit to this view.
enum ShareDestination: Equatable {
    case work
    case send(ShareTarget)
}

/// The rich, async-resolved descriptor for the shared item's HEADER row — name +
/// type + an OS-supplied icon/thumbnail. Resolved off the LEAD provider by the
/// host's `resolveLeadHeader` closure WITHOUT reading the full bytes (type→icon
/// for documents, an ImageIO-bounded thumbnail for images). `nil` until resolved
/// (the header shows the immediate glyph state until then); `icon == nil` falls
/// back to the typed glyph forever (web URLs / plain text never get an icon).
struct ResolvedHeader {
    /// Filename / page-title / text-snippet — the header's PRIMARY line.
    let filename: String
    /// Localized type description ("PDF Document", host, …) — the SECONDARY line.
    let typeDescription: String?
    /// OS file-type icon or a memory-bounded image thumbnail; `nil` → keep the glyph.
    let icon: NSImage?
}

enum WorkboardCommitFailure: Hashable, Identifiable, Sendable {
    case unavailable
    case tooLarge
    case empty
    /// Something in the share is not a regular file — a folder, a package
    /// document such as `.rtfd` or `.pages`, or a symlink.
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

    func cancelCommit() {
        phase = nil
    }
}

struct ShareView: View {

    /// Total attachment count (drives the header "+N more" summary).
    let attachmentCount: Int
    /// macOS activation caps each category independently. A mixed share can
    /// therefore exceed Conduck's total envelope cap and must be rejected whole.
    let attachmentLimitExceeded: Bool
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
    /// Resolve the Safari page-text capture payload (memoized single load, shared
    /// with the host's commit path). `nil` for every non-Safari share → the toggle
    /// row never mounts and the envelope is unchanged. Owned by the host VC.
    let resolveCapture: @MainActor () async -> WebPageCapture.Payload?
    /// Commit the share with the typed caption, the picked target, and whether to
    /// include the captured page text. Owned by the host VC, which resolves
    /// `target` into the manifest's routing fields.
    let onSend: (String, ShareTarget, Bool) -> Void
    /// Save shared material as an inert Work capture. Work is ONE desk, so the
    /// capture carries no destination — the host always writes a targetless
    /// envelope and the drainer resolves the desk. This closure has no
    /// gateway/send parameter and therefore cannot dispatch.
    let onAddToWorkboard: (String, Bool) -> Void
    /// Dismiss without queuing anything. Owned by the host VC.
    let onCancel: () -> Void

    @ObservedObject var submissionState: ShareSubmissionState

    @State private var caption: String = ""
    /// The picked destination — `nil` until the person picks one. NOTHING is
    /// pre-selected, and nothing survives from a previous share (each invocation
    /// is a fresh process that reads only the snapshot): the rows are the
    /// question, and the primary button stays disabled until one is clicked.
    @State private var destination: ShareDestination?
    @State private var query: String = ""
    /// Rich header (async); `nil` until `resolveLeadHeader` returns — until then the
    /// header renders the immediate glyph + `previewItems.first` label.
    @State private var resolvedLead: ResolvedHeader?
    /// Safari page-text capture payload (async); `nil` until `resolveCapture`
    /// returns AND for every non-Safari share (the toggle row mounts only when
    /// non-nil).
    @State private var capturePayload: WebPageCapture.Payload?
    /// Whether the captured page text rides the send. Opt-OUT: defaults ON, and the
    /// host writes the synthetic markdown only while true.
    @State private var includePageText = true

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
    /// (`ShareTargetFilter`, unit-tested). The Work row below is then the only
    /// destination — which is why it is rendered outside every branch.
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
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {                       // fills the fixed 480×600 host
                headerBar                              // PINNED (§B)
                if capturePayload != nil {             // PINNED, conditional (§B.5)
                    captureToggleRow
                }
                if showSearch { searchField }
                Divider().overlay(Palette.border)
                scrollRegion                           // the ONE destination list
                    .frame(maxHeight: .infinity)
                Divider().overlay(Palette.border)
                if attachmentLimitExceeded { attachmentLimitBanner }
                bottomBar                              // PINNED floor (§D)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.amber)
        .task {
            // Resolve the rich header (name/type/icon) off the lead provider. The
            // header shows the immediate glyph state until this lands; a nil result
            // simply keeps that glyph.
            resolvedLead = await resolveLeadHeader()
        }
        .task {
            // Resolve the Safari page-text capture (nil for every non-Safari
            // share). Only a non-nil payload mounts the toggle row.
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

    // MARK: - Header (§B)

    /// PINNED top bar: close button + the shared-item header (icon + name + type).
    /// Never blank — at minimum a typed glyph + a label.
    private var headerBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.card))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.cancel))
            .disabled(submissionState.isCommitting)

            sharedItemHeader
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var attachmentLimitBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.amber)
            Text(Strings.tooManyItems)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    /// The shared-item header content: a 36×36 icon/thumbnail (resolved) or a
    /// typed SF-Symbol glyph (immediate/loading), a primary filename line, and a
    /// secondary type-description line (with a "+N more" suffix for multi-item
    /// shares). Falls back gracefully when the rich header hasn't resolved yet.
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
        }
    }

    /// 36×36 leading glyph/icon. Prefers the resolved `NSImage` (file-type icon or
    /// bounded image thumbnail); otherwise the typed SF-Symbol of the lead item.
    @ViewBuilder
    private var headerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.card)
            if let icon = resolvedLead?.icon {
                Image(nsImage: icon)
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
    /// permanent state for web URLs / plain text that never get an icon).
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
    /// the share carries multiple attachments (reusing the count summary).
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

    // MARK: - Capture toggle (§B.5)

    /// Capture toggle row — mounted only when a Safari page-text capture arrived
    /// (`capturePayload != nil`); every non-Safari share never sees it. Sits
    /// directly under the shared-item header: a `doc.text` glyph, a scope-aware
    /// title, a size (+ truncation) subtitle, and an amber switch defaulting ON.
    private var captureToggleRow: some View {
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
                Text(captureTitle)
                    .font(.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = captureSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $includePageText)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(Strings.captureToggleA11y))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Toggle title — the captured scope ("Page text" vs "Selected text").
    private var captureTitle: String {
        capturePayload?.isSelection == true ? Strings.captureSelection : Strings.capturePage
    }

    /// Toggle subtitle — the returned byte size (localized), suffixed "· truncated"
    /// when any capture stage cut the text.
    private var captureSubtitle: String? {
        guard let payload = capturePayload else { return nil }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(payload.returnedByteCount), countStyle: .binary)
        return payload.truncated ? "\(size) · \(Strings.captureTruncated)" : size
    }

    // MARK: - Search field (§C)

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

    // MARK: - Scroll region (the picker rows)

    /// The ONLY scrolling region — pinned section headers, compact rows. The
    /// header/search/dividers/bottomBar all sit OUTSIDE this so the bottom bar
    /// stays on the panel floor.
    private var scrollRegion: some View {
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
                // ALWAYS, last, outside every branch above: a destination that
                // never disappears — not behind a search, not behind an empty
                // roster, not behind a missing snapshot.
                workSection
            }
            .padding(.vertical, 4)
        }
    }

    /// The Work destination: one row, in its own section, last. Its own section
    /// because the list pins section headers — a header-less trailing row would
    /// scroll under the pinned RECENT CHATS header and read as a chat.
    private var workSection: some View {
        Section {
            targetRow(
                badge: badge(symbol: "tray.and.arrow.down.fill", fill: Palette.amber),
                title: Strings.addToWorkboard,
                subtitle: Strings.nothingSent,
                selectable: true,
                isSelected: destination == .work,
                action: { destination = .work }
            )
        } header: {
            sectionHeader(Strings.sectionWork)
        }
    }

    /// Shown in place of the two send sections when a DECODED snapshot lists no
    /// configured gateway and no recent chat: the send route is a route the app
    /// itself says cannot succeed, so it is told rather than offered.
    private var noAILine: some View {
        Text(Strings.noAI)
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
                isSelected: destination == .send(target),
                action: { destination = .send(target) }
            )
        } else {
            ForEach(filteredGateways, id: \.ref) { gateway in
                let target = ShareTarget.newConversation(gatewayRef: gateway.ref)
                targetRow(
                    badge: badge(monogram: gateway.monogram, fill: color(hex: gateway.colorHex)),
                    title: gateway.displayName,
                    subtitle: Strings.newConversation,
                    selectable: true,
                    isSelected: destination == .send(target),
                    action: { destination = .send(target) }
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
                isSelected: destination == .send(target),
                action: { destination = .send(target) }
            )
        }
    }

    /// Shown only when NO snapshot decoded: the roster is UNKNOWN, not empty —
    /// the app may well hold a gateway this appex cannot see — so the legacy
    /// route stays on offer (both manifest refs nil → the drainer routes to the
    /// default gateway). It has to be clickable, because nothing is pre-selected.
    private var legacyNewConversationRow: some View {
        targetRow(
            badge: badge(monogram: "+", fill: Palette.teal),
            title: Strings.newConversation,
            subtitle: nil,
            selectable: true,
            isSelected: destination == .send(.newConversation(gatewayRef: nil)),
            action: { destination = .send(.newConversation(gatewayRef: nil)) }
        )
    }

    /// Centered empty-search state (query non-empty, both filtered lists empty).
    /// The Work row still sits below it, so a search that matches nothing never
    /// leaves the share with nowhere to go.
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
            .padding(.vertical, 9)
            .background(isSelected ? Palette.amber.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        // Locked while a commit runs: a click during the asynchronous copy must
        // not move the pick under it (the retry is bound to Work by construction
        // too).
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

    /// Round monogram badge (~30pt) — filled with the gateway's resolved color.
    private func badge(monogram: String, fill: Color) -> AnyView {
        AnyView(
            ZStack {
                Circle().fill(fill)
                Text(monogram)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
        )
    }

    /// The same round badge carrying an SF Symbol instead of a monogram — the
    /// Work row's desk glyph, the one every other Work door already uses.
    private func badge(symbol: String, fill: Color) -> AnyView {
        AnyView(
            ZStack {
                Circle().fill(fill)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.background)
            }
            .frame(width: 30, height: 30)
        )
    }

    // MARK: - Bottom bar (§D)

    /// The ONE predicate behind both the primary button's `.disabled(…)` and the
    /// opacity that draws it as disabled. `.buttonStyle(.plain)` over an explicit
    /// amber fill and an explicit foreground dims NEITHER on its own, so without
    /// the opacity a button that refuses every click looks exactly like one that
    /// commits — and with nothing pre-selected that is the state every share
    /// opens in. Both modifiers read this property, so they cannot drift apart.
    private var isPrimaryDisabled: Bool {
        destination == nil || submissionState.isCommitting || attachmentLimitExceeded
    }

    /// PINNED floor: multiline message field and the ONE primary action, which
    /// names the picked destination — "Choose a destination" (disabled) until a
    /// row is clicked, then "Add to Work" or "Send now". Return always inserts a
    /// line break; only ⌘-Return or the visible button commits, so ⌘-Return can
    /// only commit what a disabled button would refuse.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(Strings.captionPlaceholder, text: $caption, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.textPrimary)
                    // Hardware Return falls through as a no-op on a vertical
                    // TextField, so insert line breaks explicitly. Leave ⌘-Return
                    // to the primary button's shortcut so it commits exactly once.
                    .onKeyPress(keys: [.return]) { keyPress in
                        if keyPress.modifiers.contains(.command) {
                            return .ignored
                        }
                        caption += "\n"
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Palette.border, lineWidth: 1)
            )

            Button(action: commit) {
                Group {
                    if submissionState.phase == .addingToWorkboard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Palette.background)
                            Text(Strings.addingToWorkboard)
                        }
                    } else if submissionState.phase == .sending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Palette.background)
                            Text(Strings.sending)
                        }
                    } else if destination == .work {
                        Label(Strings.addToWorkboard, systemImage: "tray.and.arrow.down.fill")
                    } else if destination != nil {
                        Label(Strings.sendNow, systemImage: "paperplane.fill")
                    } else {
                        Text(Strings.chooseDestination)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.amber)
                )
                .opacity(isPrimaryDisabled ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isPrimaryDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Commit

    /// The primary button and ⌘-Return. Reads the pick ONCE and dispatches; each
    /// helper below is bound to ONE inbox by construction and reads no pick. The
    /// attachment-limit refusal is checked here and again in each helper, as at
    /// the tip: an over-limit share must be refused however it is reached.
    private func commit() {
        guard !attachmentLimitExceeded else { return }
        guard let destination else { return }
        switch destination {
        case .work:              addToWorkboard()
        case .send(let target):  send(target)
        }
    }

    /// Work only — and the alert's Try Again, so a retry can never follow a row
    /// clicked after the failed attempt began. It has no target parameter, so it
    /// cannot dispatch.
    private func addToWorkboard() {
        guard !attachmentLimitExceeded else { return }
        guard submissionState.begin(.addingToWorkboard) else { return }
        onAddToWorkboard(caption, includePageText)
    }

    /// A gateway pick only — the target arrives as an argument, so the desk
    /// cannot reach the send manifest however this view is edited.
    private func send(_ target: ShareTarget) {
        guard !attachmentLimitExceeded else { return }
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

    // MARK: - Localized strings (inline defaults → spliced into the appex's xcstrings)

    private enum Strings {
        static let sectionWork = String(localized: "share.section.work",
            defaultValue: "Work",
            comment: "Picker section header above the Add to Work row")
        static let chooseDestination = String(localized: "share.destination.choose",
            defaultValue: "Choose a destination",
            comment: "Disabled primary button label until a destination row is picked")
        static let noAI = String(localized: "share.destination.noAI",
            defaultValue: "No personal AI available.",
            comment: "Shown in place of the gateway rows when the snapshot lists no configured gateway and no recent chat")
        static let nothingSent = String(localized: "share.work.inert",
            defaultValue: "Nothing is sent to AI",
            comment: "Subtitle of the Add to Work row — privacy reassurance for an inert Work capture")
        static let cancel = String(localized: "share.cancel",
            defaultValue: "Cancel",
            comment: "Cancel / close control in the Share Extension")
        static let sendNow = String(localized: "share.sendNow",
            defaultValue: "Send now",
            comment: "Immediate dispatch button in the Share Extension")
        static let addToWorkboard = String(localized: "share.addToWork",
            defaultValue: "Add to Work",
            comment: "Primary button that saves shared material as inert Work")
        static let addingToWorkboard = String(localized: "share.addToWork.progress",
            defaultValue: "Adding to Work…",
            comment: "Progress label while the Share Extension saves inert Work")
        static let sending = String(localized: "share.send.progress",
            defaultValue: "Sending…",
            comment: "Progress label while the Share Extension queues a conversation send")
        static let tooManyItems = String(localized: "share.error.tooManyItems",
            defaultValue: "Share up to 10 items at a time. Nothing has been sent — select fewer items and try again.",
            comment: "Visible refusal when a mixed macOS share exceeds the total attachment limit")
        static let workboardErrorTitle = String(localized: "share.work.error.title",
            defaultValue: "Couldn’t Add to Work",
            comment: "Title shown when the Share Extension cannot persist a Work capture")
        static let workboardErrorUnavailable = String(localized: "share.work.error.unavailable",
            defaultValue: "Nothing was saved. Check that your Mac has free storage, then try again.",
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
            comment: "Capture toggle title when the Safari share captured the whole page's text")
        static let captureSelection = String(localized: "share.capture.selection",
            defaultValue: "Selected text",
            comment: "Capture toggle title when the Safari share captured the user's text selection")
        static let captureTruncated = String(localized: "share.capture.truncated",
            defaultValue: "truncated",
            comment: "Suffix on the capture toggle subtitle when the captured text hit the size cap")
        static let captureToggleA11y = String(localized: "share.capture.toggleA11y",
            defaultValue: "Include page text",
            comment: "Accessibility label for the switch that includes or excludes the captured page text")
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
