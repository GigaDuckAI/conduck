// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayProjectDetailLineTests.swift
//
// The recent row's detail line for a Work project's thread: the relative date
// first, then the project name projected to one safe display line and capped,
// so a clip at the line's end can only ever take the name; the date alone
// when there is no project, or the stored title projects away to nothing. And
// the placement:
// the recent row feeds the record's title into that line and keeps its
// trailing folder on the same row.

import XCTest
@testable import Conduck

final class CarPlayProjectDetailLineTests: XCTestCase {
    private static let sceneDelegatePath = "Conduck/CarPlay/CarPlaySceneDelegate.swift"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var hourAgo: Date { now.addingTimeInterval(-3600) }

    func testAnOrdinaryThreadShowsTheDateAlone() {
        let date = CarPlayConversationLabel.relativeDate(hourAgo, now: now)
        XCTAssertEqual(CarPlayConversationLabel.detailLine(projectTitle: nil, lastActivityAt: hourAgo, now: now), date)
    }

    func testAProjectThreadLeadsWithTheDateAndEndsWithItsName() {
        let date = CarPlayConversationLabel.relativeDate(hourAgo, now: now)
        let line = CarPlayConversationLabel.detailLine(projectTitle: "Q3 launch", lastActivityAt: hourAgo, now: now)
        XCTAssertTrue(line.hasPrefix(date), "the date leads — a clip at the end can only take the name: \(line)")
        XCTAssertTrue(line.hasSuffix("Q3 launch"), line)
        XCTAssertNotEqual(line, date)
    }

    func testALongNameIsCappedSoTheDateSurvives() throws {
        let long = String(repeating: "Launch readiness ", count: 4)  // 68 characters
        let name = try XCTUnwrap(CarPlayConversationLabel.projectName(from: long))
        XCTAssertTrue(name.hasSuffix("…"), name)
        XCTAssertLessThanOrEqual(name.count, CarPlayConversationLabel.maxProjectNameLength + 1)
        XCTAssertFalse(name.dropLast().hasSuffix(" "), "the cap never ends on a dangling space")
        let date = CarPlayConversationLabel.relativeDate(hourAgo, now: now)
        let line = CarPlayConversationLabel.detailLine(projectTitle: long, lastActivityAt: hourAgo, now: now)
        XCTAssertTrue(line.hasPrefix(date), line)
        XCTAssertTrue(line.hasSuffix(name), line)
        // A name exactly at the cap is left whole, and so is one whose only
        // excess is trailing whitespace.
        let exact = String(repeating: "a", count: CarPlayConversationLabel.maxProjectNameLength)
        XCTAssertEqual(CarPlayConversationLabel.projectName(from: exact), exact)
        XCTAssertEqual(CarPlayConversationLabel.projectName(from: exact + "  "), exact)
        // A cap that falls on a word boundary still says the next word was cut.
        XCTAssertEqual(CarPlayConversationLabel.projectName(from: exact + " b"), exact + "…")
    }

    func testTheNameIsProjectedToOneSafeLine() {
        XCTAssertEqual(CarPlayConversationLabel.projectName(from: "Q3\u{202E} launch\nplan"), "Q3 launch plan")
        XCTAssertNil(CarPlayConversationLabel.projectName(from: "\u{202E}\u{202C}"),
                     "a title that projects away names nothing; the folder still marks the row")
        let date = CarPlayConversationLabel.relativeDate(hourAgo, now: now)
        XCTAssertEqual(CarPlayConversationLabel.detailLine(projectTitle: "  ", lastActivityAt: hourAgo, now: now), date)
    }

    func testTheRecentRowFeedsTheTitleIntoTheDetailLineAndKeepsTheFolder() throws {
        let scene = try RefusalLaneSource.source(at: Self.sceneDelegatePath)
        let row = try RefusalLaneSource.trailingClosure(
            after: "let recentItems: [CPListItem] = recents.map", in: scene, path: Self.sceneDelegatePath
        )
        let detailAt = try XCTUnwrap(row.range(of: "detailText: CarPlayConversationLabel.detailLine(")?.lowerBound,
                                     "the recent row's second text slot is the shared detail line")
        XCTAssertTrue(row.contains("projectTitle: recent.projectTitle"))
        let folderAt = try XCTUnwrap(row.range(of: "item.setAccessoryImage(UIImage(systemName: \"folder\"))")?.lowerBound)
        XCTAssertLessThan(detailAt, folderAt)
        XCTAssertTrue(row.contains("if recent.inLiveProject {"), "the folder still marks live membership")
        XCTAssertFalse(row.contains("relativeDate(recent.lastActivityAt"),
                       "no second path builds the date without the project")
    }
}
