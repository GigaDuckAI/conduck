// SPDX-License-Identifier: Apache-2.0

// Conduck
// BriefWorkboardIntent.swift
//
// Private, deterministic Workboard briefing for Siri and Shortcuts. It reads
// only local/private-CloudKit metadata and counts proven states; no brief text,
// material, gateway request or analytics event leaves the device.

#if !os(watchOS)
import AppIntents
import Foundation

struct BriefWorkboardIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "intent.workboardBrief.title",
        defaultValue: "Brief My Workboard"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "intent.workboardBrief.description",
            defaultValue: "Hear what needs your review, what is waiting for an AI reply, and what is still being prepared."
        )
    )

    static var supportedModes: IntentModes = [.background]

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let items = try await ConversationStore.shared.fetchWorkItems()
        let review = items.filter { $0.state == .review }
        let failures = review.filter { $0.latestDispatch?.activity.isFailure == true }.count
        let briefing = WorkboardBriefingBuilder.build(
            from: WorkboardBriefingFacts(
                repliesToReview: max(0, review.count - failures),
                failuresToReview: failures,
                waiting: items.filter { $0.state == .waiting }.count,
                drafts: items.filter { $0.state == .draft }.count
            )
        )
        return .result(
            value: briefing.spokenText,
            dialog: IntentDialog(stringLiteral: briefing.spokenText)
        )
    }
}
#endif
