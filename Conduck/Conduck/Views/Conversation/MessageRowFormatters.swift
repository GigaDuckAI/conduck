// SPDX-License-Identifier: Apache-2.0

// Conduck
// MessageRowFormatters.swift
//
// Formatters for the conversation surfaces: relative-date + device icon/label
// helpers, a conversation title-fallback, and the list row's role-aware subtitle
// + composed VoiceOver label, with a `carplay` case in the device icon/label
// maps.
//
// The thinking-stage selector lives here too (pure function of elapsed
// seconds + prior-turn count) so it is unit-testable independent of SwiftUI.

import Foundation

/// Formatters reused across the conversation surfaces (list rows, thread
/// bubble footers). Pure functions — unit-testable without SwiftUI.
enum MessageRowFormatters {
    /// Locale-aware relative date ("2 min ago", "yesterday").
    static func relativeDate(from date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    /// Sidebar-row timestamp with a calendar-anchored shape: **Today** → the
    /// time of day ("10:14"), **Yesterday** → "Yesterday", **older** → an
    /// absolute short date ("Apr 12", or "Apr 12, 2025" once the year differs).
    /// Absolute dates beat "3 weeks ago" for cross-referencing real-world
    /// events. `now` is injectable so the day-bucketing is deterministic in
    /// tests; `isDateInYesterday` is avoided for the same reason (it reads the
    /// system clock instead of `now`).
    static func conversationListDate(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return listTimeFormatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")  // xcstrings: chat-ui
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? listDayMonthFormatter.string(from: date)
            : listDayMonthYearFormatter.string(from: date)
    }

    /// Cached formatters for `conversationListDate` (DateFormatter creation is
    /// expensive; these are reused across every row). Templates are
    /// locale-resolved (12h/24h, month-name order) by `setLocalizedDateFormatFromTemplate`.
    private static let listTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let listDayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private static let listDayMonthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()

    /// Scannable headline for a conversation. Uses the stored `title` when
    /// present; otherwise falls back to the first non-empty line of the
    /// last-message preview so nil-title conversations still render a
    /// meaningful row (the title-fallback helper, kept here for the
    /// list).
    static func conversationTitle(title: String?, titleSnippet: String?, lastMessagePreview: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        // Denormalized first-user-line snippet — the primary title source now
        // (no gateway gives us a real `title`). Written on the first user turn.
        if let snippet = titleSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty {
            return snippet
        }
        if let preview = lastMessagePreview, !preview.isEmpty {
            return firstLineFallback(from: preview)
        }
        return String(localized: "New conversation")
    }

    /// First non-empty line of the text, collapsed and capped so it fits one
    /// title row without wrapping badly.
    static func firstLineFallback(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        let head = String(trimmed.prefix(80)).trimmingCharacters(in: .whitespaces)
        return head + String(localized: "…")
    }

    // MARK: - Conversation-list row

    /// The row SUBTITLE. `text` is the RAW tail preview, never a pre-prefixed
    /// string: `conversationTitle` above uses that same raw text as its TITLE
    /// fallback, so a "You: " baked into the cache would land in headlines.
    ///
    /// Returns nil when there is nothing to show, so the caller omits the line
    /// entirely and the row's height depends on whether the conversation HAS a
    /// tail — never on what state it is in. An attachment-only turn stores empty
    /// `text` and takes that path: a bare "You:" with nothing after it is worse
    /// than no line, and naming the attachment would be inventing content this
    /// projection does not carry (the tail fetch reads one row and deliberately
    /// faults no attachments).
    ///
    /// The prefix is ONE format string, never two concatenated `Text`s — a
    /// translator must be able to reorder it. An AGENT turn gets no prefix at
    /// all; its absence is the signal.
    static func conversationSubtitle(text: String?, role: MessageRole?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard role == .user else { return trimmed }
        return String(localized: "conversation.row.youSaid",
                      defaultValue: "You: \(trimmed)")  // xcstrings: chat-ui
    }

    /// One composed VoiceOver label for a whole conversation row.
    ///
    /// STATE LEADS. The row sets `.accessibilityElement(children: .ignore)`
    /// precisely so this ordering holds — left to itself the gateway badge's own
    /// element reads first and the trailing mark reads last, the inverse of what
    /// a triage surface needs.
    ///
    /// The LIVE CLOCK IS EXCLUDED, replaced by an absolute "Sent at 10:14": a
    /// label that rewrites itself on a timer produces a stream of repeated
    /// announcements over the whole wait, and an absolute reference is better
    /// information anyway (the same reasoning the thread view's elapsed clock
    /// already follows). A FAILED row gets no such stamp — its metadata line
    /// carries the words "Not sent" where the date would be, and the label
    /// tracks what the row actually says.
    ///
    /// - Parameter showsGateway: mirrors the row's badge visibility. The gateway
    ///   is named as its own component only when the badge is on screen AND the
    ///   status sentence did not already name it.
    static func rowAccessibilityLabel(
        state: ConversationRowState,
        title: String,
        subtitle: String?,
        gatewayName: String,
        lastActivityAt: Date,
        showsGateway: Bool,
        now: Date = Date()
    ) -> String {
        var parts: [String] = []
        if let lead = stateLead(state) { parts.append(lead) }
        parts.append(title)

        let gateway = gatewayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var statusNamedTheGateway = false
        if case .working(let confidence, _) = state.activity {
            // The status sentence mirrors what the metadata line actually says,
            // so the spoken row and the seen row agree.
            let sentence = ConversationActivityCopy.working(confidence, gatewayName: gateway)
            statusNamedTheGateway = confidence == .live && !gateway.isEmpty
            parts.append(sentence.trimmingCharacters(in: sentenceTail))
        }
        if showsGateway, !gateway.isEmpty, !statusNamedTheGateway {
            parts.append(gateway)
        }
        if let subtitle { parts.append(subtitle) }
        // NEVER after "Not sent": a failed row's own metadata line replaces the
        // date with the words "Not sent", and appending "Sent at 10:14" would
        // tell a VoiceOver user the turn both was and was not sent — the one
        // reading a sighted user cannot get. Every other state's line does show
        // a time, and this static stamp is what stands in for the live clock the
        // label deliberately excludes.
        switch state.activity {
        case .failed:
            break
        case .idle, .working, .answeredUnseen:
            parts.append(sentPhrase(lastActivityAt, now: now))
        }
        return parts.joined(separator: ". ")
    }

    /// Trailing ellipsis + full stop, trimmed off a status sentence before it is
    /// joined into the composed label: "OpenClaw is answering…. Kitchen…" is a
    /// stutter VoiceOver reads aloud.
    private static let sentenceTail = CharacterSet(charactersIn: "… .")

    /// The state word (or pair of words) the label opens with. Nil for a row with
    /// nothing to report, which then simply starts with its title.
    ///
    /// A delivery state and an unseen reply can BOTH be true, and the label says
    /// both — the same orthogonality the mark and the bold title render.
    private static func stateLead(_ state: ConversationRowState) -> String? {
        switch state.activity {
        case .idle:
            // The resolver folds idle + unseen into `.answeredUnseen`, so this
            // arm is belt-and-braces rather than a live path.
            return state.hasUnseenReply ? newReplyWord : nil
        case .answeredUnseen:
            return newReplyWord
        case .working:
            return state.hasUnseenReply
                ? String(localized: "activity.a11y.workingUnseen",
                         defaultValue: "Working, new reply")  // xcstrings: chat-ui
                : String(localized: "activity.a11y.working",
                         defaultValue: "Working")  // xcstrings: chat-ui
        case .failed:
            return state.hasUnseenReply
                ? String(localized: "activity.a11y.notSentUnseen",
                         defaultValue: "Not sent, new reply")  // xcstrings: chat-ui
                : ConversationActivityCopy.notSent
        }
    }

    private static var newReplyWord: String {
        String(localized: "activity.a11y.newReply", defaultValue: "New reply")  // xcstrings: chat-ui
    }

    /// "Sent at 10:14" for today, "Sent Yesterday" / "Sent Apr 12" otherwise —
    /// two WHOLE format strings, because "Sent at Yesterday" is what one string
    /// plus `conversationListDate` would have produced.
    private static func sentPhrase(_ date: Date, now: Date) -> String {
        let stamp = conversationListDate(from: date, now: now)
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return String(localized: "activity.a11y.sentAtTime",
                          defaultValue: "Sent at \(stamp)")  // xcstrings: chat-ui
        }
        return String(localized: "activity.a11y.sentOnDay",
                      defaultValue: "Sent \(stamp)")  // xcstrings: chat-ui
    }

    static func icon(forDevice device: String) -> String {
        switch device {
        case "iphone": return "iphone"
        case "ipad": return "ipad"
        case "mac": return "laptopcomputer"
        case "watch": return "applewatch"
        case "carplay": return "car"
        default: return "app"
        }
    }

    static func label(forDevice device: String) -> String {
        switch device {
        case "iphone": return String(localized: "iPhone")
        case "ipad": return String(localized: "iPad")
        case "mac": return String(localized: "Mac")
        case "watch": return String(localized: "Watch")
        case "carplay": return String(localized: "CarPlay")
        default: return device
        }
    }

    // MARK: - sourceDevice modality suffix

    /// The base device component of a `sourceDevice` tag. Tags may carry a
    /// modality suffix (`iphone-text`, `mac-voice`); legacy tags have none
    /// (`iphone`). Splits on the FIRST "-" and returns the leading segment so
    /// the device icon/label maps still resolve. Backward-compatible: a tag
    /// without a suffix returns itself.
    static func baseDevice(from sourceDevice: String) -> String {
        if let dash = sourceDevice.firstIndex(of: "-") {
            return String(sourceDevice[..<dash])
        }
        return sourceDevice
    }

    // MARK: - Server-file render dedupe

    /// Dedupe server-file attachments by `storedKey`, keeping ONE row per key,
    /// ordered by sequence. Belt-and-braces: CloudKit has no distributed
    /// compare-and-set, so two devices' near-simultaneous retro output scans can
    /// merge duplicate rows for one storedKey — the UI must never show duplicate
    /// download chips. Selection policy per key: a row WITH a usable preview
    /// (`thumbnailData != nil || previewKind != nil`) beats a preview-less row so
    /// the surviving chip is the one the wrist/phone can actually render; ties
    /// (same preview status) break to the LOWEST sequence. nil-storedKey rows are
    /// NEVER collapsed (no key to dedupe on). Pure + unit-testable; the caller
    /// pre-filters to `isServerFile`.
    static func dedupedServerFiles(_ attachments: [AttachmentRecord]) -> [AttachmentRecord] {
        func hasPreview(_ a: AttachmentRecord) -> Bool {
            a.thumbnailData != nil || a.previewKind != nil
        }
        // Pick the winning row per key: preview-bearing first, then lowest sequence.
        var winners: [String: AttachmentRecord] = [:]
        for attachment in attachments {
            guard let key = attachment.storedKey else { continue }
            guard let current = winners[key] else { winners[key] = attachment; continue }
            if hasPreview(attachment), !hasPreview(current) {
                winners[key] = attachment
            } else if hasPreview(attachment) == hasPreview(current),
                      attachment.sequence < current.sequence {
                winners[key] = attachment
            }
        }
        let ordered = attachments.sorted { $0.sequence < $1.sequence }
        var emittedKeys = Set<String>()
        return ordered.filter { attachment in
            guard let key = attachment.storedKey else { return true }
            // Emit ONLY the winning row for this key, exactly once.
            guard winners[key]?.id == attachment.id else { return false }
            return emittedKeys.insert(key).inserted
        }
    }

    /// The SF Symbol for a turn's modality, if the `sourceDevice` tag carries a
    /// recognised modality suffix. `waveform` = spoken, `keyboard` = typed.
    /// Returns nil for legacy/unsuffixed tags (no modality glyph rendered).
    static func modalityIcon(from sourceDevice: String) -> String? {
        guard let dash = sourceDevice.firstIndex(of: "-") else { return nil }
        let suffix = String(sourceDevice[sourceDevice.index(after: dash)...])
        switch suffix {
        case "voice": return "waveform"
        case "text": return "keyboard"
        default: return nil
        }
    }
}

// MARK: - In-flight elapsed clock (pure, unit-testable)

/// Elapsed-time formatting for the in-flight "answering" indicator. The earlier
/// staged copy (`.connecting` / `.sendingContext`) was retired with the
/// borderless indicator redesign; only the `m:ss` clock remains.
enum ThinkingStage {
    /// `m:ss` formatter for the in-flight elapsed timer.
    static func clock(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - In-flight "thinking" indicator label (pure, unit-testable)

/// The in-flight phases a chat indicator can show, on any surface. Kept free of
/// any per-platform type so the label logic is unit-testable from the
/// cross-target test bundle (mirrors `WatchAutoSpeakVerdict`).
///
/// Not every surface shows every phase: the Watch maps its recording state
/// machine onto `.transcribing`/`.answering`, the phone/Mac thread shows only
/// `.answering` (its pre-dispatch window is carried by the user bubble's own
/// sending dot), and the menu-bar popover is the one surface that shows all
/// three.
enum ThinkingPhase: Equatable {
    /// Speech-to-text in flight — the dictated text doesn't exist yet, so no
    /// user bubble and no elapsed clock (the phase is brief).
    case transcribing
    /// The turn exists locally but has not reached its gateway dispatch phase —
    /// attachments, the durable write, history assembly, credential resolution.
    /// Deliberately distinct from `.answering`: nothing has been sent yet, so
    /// claiming the gateway is working would be a lie.
    case sending
    /// The agent request is in flight — the user bubble is on screen; surfaces
    /// pair this with an elapsed `m:ss` clock from the turn's start.
    case answering
}

/// Pure label resolver for the agent-side "thinking" row. Foundation-only +
/// watch-safe (the file is a member of both targets), so
/// `ThinkingIndicatorTests` covers the empty-name fallback without
/// referencing any UI.
enum ThinkingIndicator {
    /// The indicator label for a phase. During `.answering` the bound gateway's
    /// name leads ("OpenClaw is answering…"); an EMPTY or whitespace name (the
    /// brief window before the bound ref resolves — draft adoption, list-cache
    /// refresh, a freshly minted VM still on its default name) falls back to a
    /// bare "Answering…" — NEVER " is answering…".
    static func label(phase: ThinkingPhase, backendName: String) -> String {
        switch phase {
        case .transcribing:
            return String(localized: "Transcribing…")  // xcstrings: chat-ui
        case .sending:
            return String(localized: "Sending…")  // xcstrings: chat-ui
        case .answering:
            let name = backendName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                return String(localized: "Answering…")  // xcstrings: chat-ui
            }
            return String(localized: "\(name) is answering…")  // xcstrings: chat-ui
        }
    }
}
