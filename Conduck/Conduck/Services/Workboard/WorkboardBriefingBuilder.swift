// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardBriefingBuilder.swift
//
// Deterministic, private Workboard briefing facts. The spoken sentence is
// derived from one counted value, so voice can never invent a count or a
// completion. The visible briefing renders the board's own item lists
// (`WorkboardBriefingSnapshot`) and borrows this sentence verbatim.

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

nonisolated enum WorkboardBriefingBuilder {
    /// Spoken order. A kind whose count is zero drops out of the sentence
    /// entirely rather than being read as "0".
    private enum Kind: CaseIterable {
        case replies
        case failures
        case waiting
        case drafts
    }

    static func build(from facts: WorkboardBriefingFacts) -> String {
        if facts.isEmpty {
            return String(
                localized: "workboard.briefing.clear",
                defaultValue: "Your Workboard is clear. There is nothing open right now."
            )
        }

        let phrases = Kind.allCases.compactMap { kind in
            phrase(kind, count: count(of: kind, in: facts))
        }

        return String.localizedStringWithFormat(
            String(
                localized: "workboard.briefing.update.format",
                defaultValue: "Workboard update: %@."
            ),
            joinedForSpeech(phrases)
        )
    }

    private static func count(of kind: Kind, in facts: WorkboardBriefingFacts) -> Int {
        switch kind {
        case .replies: return facts.repliesToReview
        case .failures: return facts.failuresToReview
        case .waiting: return facts.waiting
        case .drafts: return facts.drafts
        }
    }

    /// One key per phrase. The singular/plural choice belongs to the catalog's
    /// plural variation, never to a count check here: languages with more than
    /// two plural categories cannot be expressed by a two-way branch, so a
    /// second locale would otherwise need code changes rather than translation.
    private static func phrase(_ kind: Kind, count: Int) -> String? {
        guard count > 0 else { return nil }
        switch kind {
        case .replies:
            return String(
                localized: "workboard.briefing.spoken.reply",
                defaultValue: "\(count) replies to review"
            )
        case .failures:
            return String(
                localized: "workboard.briefing.spoken.failure",
                defaultValue: "\(count) sends needing attention"
            )
        case .waiting:
            return String(
                localized: "workboard.briefing.spoken.waiting",
                defaultValue: "\(count) requests waiting for replies"
            )
        case .drafts:
            return String(
                localized: "workboard.briefing.spoken.draft",
                defaultValue: "\(count) prepared drafts"
            )
        }
    }

    private static func joinedForSpeech(_ phrases: [String]) -> String {
        guard !phrases.isEmpty else {
            return String(localized: "workboard.briefing.nothingOpen", defaultValue: "nothing open")
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }
}
#endif
