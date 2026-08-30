// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardBriefingBuilder.swift
//
// Deterministic, private Workboard briefing facts. Visible rows and spoken text
// are rendered from one value so voice can never invent a count or completion.

#if !os(watchOS)
import Foundation

nonisolated struct WorkboardBriefingFacts: Equatable, Sendable {
    let repliesToReview: Int
    let failuresToReview: Int
    let waiting: Int
    let drafts: Int

    init(repliesToReview: Int, failuresToReview: Int, waiting: Int, drafts: Int) {
        self.repliesToReview = max(0, repliesToReview)
        self.failuresToReview = max(0, failuresToReview)
        self.waiting = max(0, waiting)
        self.drafts = max(0, drafts)
    }

    var needsAttention: Int { repliesToReview + failuresToReview }
    var isEmpty: Bool { needsAttention == 0 && waiting == 0 && drafts == 0 }
}

nonisolated struct WorkboardBriefing: Equatable, Sendable {
    nonisolated struct Row: Equatable, Sendable, Identifiable {
        nonisolated enum Kind: String, Sendable {
            case replies
            case failures
            case waiting
            case drafts
        }

        let kind: Kind
        let count: Int
        let title: String
        let detail: String

        var id: String { kind.rawValue }
    }

    let rows: [Row]
    let spokenText: String
}

nonisolated enum WorkboardBriefingBuilder {
    static func build(from facts: WorkboardBriefingFacts) -> WorkboardBriefing {
        if facts.isEmpty {
            return WorkboardBriefing(
                rows: [],
                spokenText: String(
                    localized: "workboard.briefing.clear",
                    defaultValue: "Your Workboard is clear. There is nothing open right now."
                )
            )
        }

        let rows = [
            row(.replies, count: facts.repliesToReview),
            row(.failures, count: facts.failuresToReview),
            row(.waiting, count: facts.waiting),
            row(.drafts, count: facts.drafts)
        ].compactMap { $0 }

        let phrases = rows.map { row in
            switch row.kind {
            case .replies:
                return counted(
                    row.count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.spoken.reply.one",
                        defaultValue: "%lld reply to review"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.spoken.reply.many",
                        defaultValue: "%lld replies to review"
                    )
                )
            case .failures:
                return counted(
                    row.count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.spoken.failure.one",
                        defaultValue: "%lld send needing attention"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.spoken.failure.many",
                        defaultValue: "%lld sends needing attention"
                    )
                )
            case .waiting:
                return counted(
                    row.count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.spoken.waiting.one",
                        defaultValue: "%lld request waiting for a reply"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.spoken.waiting.many",
                        defaultValue: "%lld requests waiting for replies"
                    )
                )
            case .drafts:
                return counted(
                    row.count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.spoken.draft.one",
                        defaultValue: "%lld prepared draft"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.spoken.draft.many",
                        defaultValue: "%lld prepared drafts"
                    )
                )
            }
        }

        return WorkboardBriefing(
            rows: rows,
            spokenText: String.localizedStringWithFormat(
                String(
                    localized: "workboard.briefing.update.format",
                    defaultValue: "Workboard update: %@."
                ),
                joinedForSpeech(phrases)
            )
        )
    }

    private static func row(_ kind: WorkboardBriefing.Row.Kind, count: Int) -> WorkboardBriefing.Row? {
        guard count > 0 else { return nil }
        switch kind {
        case .replies:
            return .init(
                kind: kind,
                count: count,
                title: String(localized: "workboard.briefing.row.replies", defaultValue: "Replies to review"),
                detail: counted(
                    count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.row.replies.detail.one",
                        defaultValue: "%lld reply arrived"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.row.replies.detail.many",
                        defaultValue: "%lld replies arrived"
                    )
                )
            )
        case .failures:
            return .init(
                kind: kind,
                count: count,
                title: String(localized: "workboard.briefing.row.failures", defaultValue: "Needs attention"),
                detail: counted(
                    count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.row.failures.detail.one",
                        defaultValue: "%lld send needs attention"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.row.failures.detail.many",
                        defaultValue: "%lld sends need attention"
                    )
                )
            )
        case .waiting:
            return .init(
                kind: kind,
                count: count,
                title: String(localized: "workboard.briefing.row.waiting", defaultValue: "Waiting on AI"),
                detail: counted(
                    count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.row.waiting.detail.one",
                        defaultValue: "%lld request is waiting"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.row.waiting.detail.many",
                        defaultValue: "%lld requests are waiting"
                    )
                )
            )
        case .drafts:
            return .init(
                kind: kind,
                count: count,
                title: String(localized: "workboard.briefing.row.drafts", defaultValue: "Prepared drafts"),
                detail: counted(
                    count,
                    singular: LocalizedStringResource(
                        "workboard.briefing.row.drafts.detail.one",
                        defaultValue: "%lld draft is ready to shape"
                    ),
                    plural: LocalizedStringResource(
                        "workboard.briefing.row.drafts.detail.many",
                        defaultValue: "%lld drafts are ready to shape"
                    )
                )
            )
        }
    }

    private static func counted(
        _ count: Int,
        singular: LocalizedStringResource,
        plural: LocalizedStringResource
    ) -> String {
        String.localizedStringWithFormat(
            String(localized: count == 1 ? singular : plural),
            Int64(count)
        )
    }

    private static func joinedForSpeech(_ phrases: [String]) -> String {
        guard !phrases.isEmpty else {
            return String(localized: "workboard.briefing.nothingOpen", defaultValue: "nothing open")
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }
}
#endif
