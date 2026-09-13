// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationProjectRowTests.swift
//
// The pure string rules a project conversation's row adds outside Work: the
// name in the settled date slot and nowhere else, the membership VoiceOver
// hears in EVERY state the row draws a folder in, the project name a search
// can find because the row shows it, and the one projection every use of
// the person's project name goes through.

import XCTest
@testable import Conduck

@MainActor
final class ConversationProjectRowTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_760_000_000)

    private func state(_ activity: ConversationActivity, unseen: Bool = false) -> ConversationRowState {
        ConversationRowState(activity: activity, hasUnseenReply: unseen)
    }

    // MARK: - The date slot

    func testTheNameRidesTheSettledDateSlotOnly() {
        XCTAssertTrue(MessageRowFormatters.showsProjectName(for: .idle))
        XCTAssertTrue(MessageRowFormatters.showsProjectName(for: .answeredUnseen),
                      "a reply landing must not make the project vanish from the row")
        XCTAssertFalse(MessageRowFormatters.showsProjectName(for: .working(.live, since: noon)))
        XCTAssertFalse(MessageRowFormatters.showsProjectName(for: .failed))
    }

    func testTheDateLineNamesTheProjectBeforeTheDate() {
        let date = MessageRowFormatters.conversationListDate(from: noon, now: noon)
        let line = MessageRowFormatters.conversationDateLine(
            projectName: "Q3 launch", projectIsArchived: false, lastActivityAt: noon, now: noon)
        XCTAssertTrue(line.hasPrefix("Q3 launch"))
        XCTAssertTrue(line.hasSuffix(date))
        XCTAssertEqual(MessageRowFormatters.conversationDateLine(
            projectName: nil, projectIsArchived: false, lastActivityAt: noon, now: noon), date,
            "an unfiled row's slot is byte-identical to before")
        XCTAssertEqual(MessageRowFormatters.conversationDateLine(
            projectName: "   ", projectIsArchived: false, lastActivityAt: noon, now: noon), date,
            "a blank name is no name")
    }

    func testAnArchivedProjectTradesTheDateForTheSidebarsWord() {
        let line = MessageRowFormatters.conversationDateLine(
            projectName: "Q3 launch", projectIsArchived: true, lastActivityAt: noon, now: noon)
        XCTAssertTrue(line.hasPrefix("Q3 launch"))
        XCTAssertTrue(line.hasSuffix(MessageRowFormatters.archivedWord))
        XCTAssertFalse(line.contains(MessageRowFormatters.conversationListDate(from: noon, now: noon)))
    }

    func testTheNameIsProjectedWhereverItIsShown() {
        let hostile = "Q3\u{202E} launch\n\u{0007}"
        let shown = MessageRowFormatters.projectDisplayName(hostile)
        XCTAssertFalse(shown.contains("\u{202E}"), "a bidi override in a project name cannot reorder the row")
        XCTAssertFalse(shown.contains("\n"))
        let line = MessageRowFormatters.conversationDateLine(
            projectName: hostile, projectIsArchived: false, lastActivityAt: noon, now: noon)
        XCTAssertFalse(line.contains("\u{202E}"))
    }

    // MARK: - VoiceOver

    func testMembershipIsSpokenInEveryStateTheRowDrawsAFolderIn() {
        let membership = MessageRowFormatters.ProjectMembershipSpeech.named("Q3 launch", isArchived: false)
        for activity: ConversationActivity in [.idle, .answeredUnseen, .working(.live, since: noon), .failed] {
            let label = MessageRowFormatters.rowAccessibilityLabel(
                state: state(activity, unseen: activity == .answeredUnseen),
                title: "Draft pricing", subtitle: nil, gatewayName: "Hermes",
                lastActivityAt: noon, showsGateway: true, now: noon, projectMembership: membership)
            XCTAssertTrue(label.contains("Q3 launch"), "\(activity) dropped the project from the spoken row")
            let title = try? XCTUnwrap(label.range(of: "Draft pricing"))
            let project = try? XCTUnwrap(label.range(of: "Q3 launch"))
            let gateway = try? XCTUnwrap(label.range(of: "Hermes"))
            if let title, let project, let gateway {
                XCTAssertLessThan(title.lowerBound, project.lowerBound, "the title still leads")
                XCTAssertLessThan(project.lowerBound, gateway.lowerBound, "where the thread lives is heard before which agent")
            }
        }
    }

    func testAnUnsyncedProjectIsSpokenWithoutAName() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: state(.idle), title: "Draft pricing", subtitle: nil, gatewayName: "",
            lastActivityAt: noon, showsGateway: false, now: noon, projectMembership: .unsynced)
        XCTAssertTrue(label.contains(String(localized: "conversations.row.a11y.inUnsyncedProject", defaultValue: "In a project")))
    }

    func testAnArchivedProjectIsSpokenAsArchivedAndDropsTheSentStamp() {
        let label = MessageRowFormatters.rowAccessibilityLabel(
            state: state(.idle), title: "Draft pricing", subtitle: nil, gatewayName: "",
            lastActivityAt: noon, showsGateway: false, now: noon,
            projectMembership: .named("Q3 launch", isArchived: true))
        XCTAssertTrue(label.contains(MessageRowFormatters.archivedWord))
        XCTAssertFalse(label.contains("Sent"), "the eye stops at Archived where the date was; so does the ear")
    }

    func testAnUnfiledRowsLabelIsUnchanged() {
        let before = MessageRowFormatters.rowAccessibilityLabel(
            state: state(.idle), title: "Draft pricing", subtitle: "ok", gatewayName: "Hermes",
            lastActivityAt: noon, showsGateway: true, now: noon)
        let after = MessageRowFormatters.rowAccessibilityLabel(
            state: state(.idle), title: "Draft pricing", subtitle: "ok", gatewayName: "Hermes",
            lastActivityAt: noon, showsGateway: true, now: noon, projectMembership: nil)
        XCTAssertEqual(before, after)
    }

    // MARK: - Search

    func testTheDisplayedProjectNameIsSearchable() {
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "q3", title: "Draft pricing", titleSnippet: nil, projectName: "Q3 launch"))
        XCTAssertTrue(ConversationSearchFilter.titleMatches(
            query: "cafe", title: nil, titleSnippet: nil, projectName: "Café relaunch"),
            "the project name folds case and diacritics like every other Tier-1 field")
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "q3", title: "Draft pricing", titleSnippet: nil, projectName: "   "),
            "a blank project name never matches")
        XCTAssertFalse(ConversationSearchFilter.titleMatches(
            query: "q3", title: "Draft pricing", titleSnippet: nil, projectName: nil),
            "nil behaves exactly as the three-argument call did")
    }
}
