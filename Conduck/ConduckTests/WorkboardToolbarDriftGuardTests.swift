// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardToolbarDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over Work's OWN navigation bar in `WorkboardExperience`.
//
// Three facts decide whether that bar exists and what it carries, and none of
// them can fail anywhere else. (1) The bar is attached INSIDE Work's own
// `NavigationStack`. Toolbar items are collected by the nearest enclosing
// navigation container, so an item declared above one reaches no bar at all —
// the exact shape that left the section control invisible and Work a one-way
// trip on iPad. (2) Declaration order is left-to-right order within one
// placement: project navigation leads, and the section control stays last.
// Both iPhone and iPad share the same project-navigation button. (3) Each section
// item is gated by its own router; project navigation is not. Compact iPad has
// neither router and still needs access to the project picker. Layout selection
// lives once in the named workspace header control, not in this native bar.
//
// The whole bar is `#if os(iOS)`: the Mac's bar belongs to the window shell,
// which builds its own, so a Work-owned bar compiled there is a second bar.
//
// This is one SwiftUI expression whose behaviour is decided by structure rather
// than by values a unit test could call into, so each invariant is asserted
// where it is written: over the file's text with comments stripped and
// compilation directives intact (`RefusalLaneSource`), scoped to one
// declaration's closure. A guard that fails because the shape legitimately
// changed is a guard to update, not a bug to route around.
//
// Platform ownership is read by EXACT SPELLING, never by substring, because
// `!os(iOS)` and `os(iOS) || os(macOS)` both contain `os(iOS)` while meaning the
// opposite and a superset of it. `WorkboardSourceDirectives.ownership(of:)`
// recognises one canonical condition per platform and refuses every other shape,
// and `testPlatformOwnershipRefusesConditionsItCannotRead` drives that refusal
// over synthetic stacks — a guard nobody has seen fail reads as coverage.

import XCTest

final class WorkboardToolbarDriftGuardTests: XCTestCase {

    private static let path = "Conduck/Views/Workboard/WorkboardView.swift"

    private func workSource() throws -> String {
        try RefusalLaneSource.source(at: Self.path)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    /// Work's iOS-only bar keeps project navigation leading and its optional
    /// section control last, without borrowing the wide router for navigation.
    func testActiveIOSStackHostsProjectNavigationBeforeOptionalSectionControl() throws {
        let source = try workSource()
        let experience = try RefusalLaneSource.trailingClosure(
            after: "struct WorkboardExperience: View",
            in: source,
            path: Self.path
        )
        let body = try RefusalLaneSource.trailingClosure(
            after: "var body: some View",
            in: experience,
            path: Self.path
        )
        let stack = try RefusalLaneSource.trailingClosure(
            after: "NavigationStack",
            in: body,
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: ".toolbar", in: body), 1,
            "`WorkboardExperience` declares a number of toolbars other than one. Work carries exactly "
            + "one bar, and it is the one this guard follows into the navigation stack."
        )
        XCTAssertTrue(
            stack.contains(".toolbar { workbenchToolbar }"),
            "Work's toolbar is no longer attached inside its own `NavigationStack`. Toolbar items are "
            + "collected by the nearest enclosing navigation container, so an item declared above one "
            + "reaches no bar and renders nothing — the section control disappears and Work becomes a "
            + "one-way trip from Chats on iPad."
        )

        let attachment = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: ".toolbar { workbenchToolbar }", in: stack),
            "The toolbar attachment vanished from the navigation stack this guard just found it in."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: attachment), .exclusive(.iOS),
            "Work's toolbar attaches under something other than a bare `#if os(iOS)`. The Mac's bar "
            + "belongs to the persistent window shell, which declares its own items, so a second bar "
            + "preference from this surface fights the window for the same chrome — and a condition "
            + "this guard cannot read (a negation, a disjunction, an extra flag) is refused rather "
            + "than assumed: teach `WorkboardSourceDirectives.Platform` the new spelling on purpose."
        )
        let declaration = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: "private var workbenchToolbar", in: source),
            "`workbenchToolbar` is gone. Work's project navigation and section control both live there."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: declaration), .exclusive(.iOS),
            "`workbenchToolbar` no longer compiles under a bare `#if os(iOS)`. Widening or negating "
            + "that condition builds a second bar on macOS, where the window shell already owns the "
            + "chrome; a shape this guard cannot read is refused rather than assumed."
        )

        let toolbar = try RefusalLaneSource.trailingClosure(
            after: "private var workbenchToolbar: some ToolbarContent",
            in: source,
            path: Self.path
        )
        let active = try RefusalLaneSource.trailingClosure(
            after: "if isActive",
            in: toolbar,
            path: Self.path
        )

        let navigationPlacement = "ToolbarItem(placement: .topBarLeading)"
        let navigation = try RefusalLaneSource.trailingClosure(
            after: navigationPlacement, in: active, path: Self.path
        )
        XCTAssertTrue(navigation.contains("WorkDeskSidebarToolbarButton(workspace: viewModel.deskWorkspace, isActive: isActive)"))
        XCTAssertTrue(navigation.contains("phoneWorkbenchRouter?.dismissPhoneSection(for: .work)"))
        let navigationAt = try XCTUnwrap(active.range(of: "WorkDeskSidebarToolbarButton(")?.lowerBound)
        let controlAt = try XCTUnwrap(active.range(of: "WorkbenchSectionToolbarItem(")?.lowerBound)
        XCTAssertEqual(occurrences(of: "WorkDeskSidebarToolbarButton(", in: toolbar), 1,
                       "The native Work bar must own exactly one project-navigation control")
        XCTAssertEqual(occurrences(of: "WorkbenchSectionToolbarItem(", in: toolbar), 1,
                       "The wide Work/Chats section switch must keep one stable toolbar slot")
        XCTAssertLessThan(navigationAt, controlAt)
        XCTAssertTrue(stack.contains(".environment(\\.workDeskSidebarIsHosted, true)"),
                      "Native navigation must suppress the duplicate in-pane project toggle")
        XCTAssertFalse(source.contains("WorkboardLayoutMenu"),
                       "The stale layout glyph menu must not coexist with the named workspace layout control")
        XCTAssertFalse(toolbar.contains("layoutMode"),
                       "The native bar must not describe a saved layout that this search/scope cannot show")

        let gated = try RefusalLaneSource.trailingClosure(
            after: "if let personalWorkbenchModel",
            in: active,
            path: Self.path
        )
        XCTAssertEqual(
            occurrences(of: "WorkbenchSectionToolbarItem(", in: gated), 1,
            "The wide router must protect exactly one wide control; exposing it on iPhone "
            + "would duplicate the expandable section control."
        )
        XCTAssertFalse(
            gated.contains("WorkDeskSidebarToolbarButton("),
            "Project navigation must remain available without the wide router, including compact iPad."
        )

        let phone = try RefusalLaneSource.trailingClosure(
            after: "if let router = phoneWorkbenchRouter", in: active, path: Self.path
        )
        XCTAssertEqual(occurrences(of: "PhoneWorkbenchSectionButton(", in: active), 1)
        XCTAssertTrue(phone.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(phone.contains("PhoneWorkbenchSectionButton(router: router, destination: .work)"))
        XCTAssertFalse(phone.contains("WorkDeskSidebarToolbarButton("))
        XCTAssertTrue(stack.contains("PhoneWorkbenchSectionOverlay(router: router, destination: .work)"))
        let phoneControlAt = try XCTUnwrap(active.range(of: "PhoneWorkbenchSectionButton(")?.lowerBound)
        XCTAssertLessThan(navigationAt, phoneControlAt)
    }

    /// NEGATIVE CONTROL over the platform reader both this class and
    /// `WorkboardDeskSurfaceDriftGuardTests` lean on. The mutations listed here
    /// are the ones a `contains("os(iOS)")` check waves through, so this test is
    /// the evidence that the guards above can actually see them.
    func testPlatformOwnershipRefusesConditionsItCannotRead() {
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: ["os(iOS)"]), .exclusive(.iOS),
            "The canonical iOS condition is no longer recognised, so every guard that asks for "
            + "iOS-only compilation now fails on correct code."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: [" os(macOS)  "]), .exclusive(.macOS),
            "Surrounding whitespace defeats the reader, so a reformatted directive reads as drift."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: []), .unconditional,
            "A line under no directive at all no longer reads as unconditional, so the check that "
            + "`boardContent` compiles everywhere cannot be stated."
        )

        for condition in ["!os(iOS)", "os(iOS) || os(macOS)", "!(os(macOS))", "os(visionOS)"] {
            XCTAssertEqual(
                WorkboardSourceDirectives.ownership(of: [condition]), .unrecognized([condition]),
                "`#if \(condition)` reads as single-platform ownership. Negations and disjunctions "
                + "contain the platform token while meaning the opposite or a superset of it, which "
                + "is exactly the drift these guards exist to catch."
            )
        }
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: ["DEBUG", "os(iOS)"]), .unrecognized(["DEBUG", "os(iOS)"]),
            "A canonical condition nested under a further flag reads as plain platform ownership. "
            + "That shape ships the code to a subset of the platform — a bar that exists only in "
            + "debug builds is not the bar this guard vouched for."
        )
    }

    /// The toolbar observes the desk's own persistent navigation state. Width
    /// determines whether the same action controls the rail or opens a picker.
    func testProjectNavigationUsesTheCachedDeskAndRefusesHiddenActions() throws {
        let source = try workSource()
        let navigation = try RefusalLaneSource.trailingClosure(
            after: "struct WorkDeskSidebarToolbarButton: View", in: source, path: Self.path
        )
        XCTAssertTrue(navigation.contains("@Bindable var workspace: WorkDeskWorkspaceState"))
        XCTAssertTrue(navigation.contains("workspace.toggleProjectNavigation()"))
        XCTAssertTrue(navigation.contains("workspace.presentsSidebarInline"))
        XCTAssertTrue(navigation.contains("workspace.showsSidebar"))
        XCTAssertTrue(navigation.contains("guard isActive else { return }"))
        XCTAssertTrue(navigation.contains(".disabled(!isActive)"))
        XCTAssertTrue(navigation.contains(".accessibilityIdentifier(\"workdesk-sidebar-toggle\")"))
        XCTAssertFalse(navigation.contains("layoutMode"))
        XCTAssertFalse(navigation.contains(".pointerIconButton"),
                       "A native toolbar keeps the platform's own button treatment")
    }

}

/// Which `#if` conditions compile a given line, and whether that stack hands the
/// line to exactly one platform.
///
/// `RefusalLaneSource` strips comments but leaves compilation directives, so
/// platform ownership is readable from the text — and it is exactly what a
/// `contains` check cannot see: a control that moved out of a macOS-only region
/// into shared code still contains its own name. Shared with
/// `WorkboardDeskSurfaceDriftGuardTests`, which asks the same question of the
/// board's in-band arrangement row.
enum WorkboardSourceDirectives {

    /// The platform conditions these guards can read.
    enum Platform: String, CustomStringConvertible {
        case iOS = "os(iOS)"
        case macOS = "os(macOS)"

        var description: String { "#if \(rawValue)" }
    }

    /// What a stack of enclosing conditions means for one line.
    enum Ownership: Equatable, CustomStringConvertible {
        /// No directive at all — the line compiles on every platform.
        case unconditional
        /// One condition, and it is a canonical single-platform `#if`.
        case exclusive(Platform)
        /// Anything else, carried verbatim so a failure names what it refused.
        case unrecognized([String])

        var description: String {
            switch self {
            case .unconditional:
                return "compiled on every platform"
            case .exclusive(let platform):
                return "compiled only by `\(platform)`"
            case .unrecognized(let conditions):
                return "compiled under `#if " + conditions.joined(separator: "` inside `#if ") + "`"
            }
        }
    }

    /// Platform ownership of a stack of enclosing conditions.
    ///
    /// A substring test cannot ask this question. `!os(iOS)` contains `os(iOS)`
    /// and means the opposite; `os(iOS) || os(macOS)` contains it and means a
    /// superset; an `os(iOS)` nested under some further flag contains it and
    /// means a subset. Each of those keeps a `contains`-shaped guard green while
    /// moving code onto a platform it does not belong on. These guards do not
    /// evaluate boolean expressions, so rather than guess they recognise ONE
    /// canonical spelling per platform and refuse every other shape: a condition
    /// this helper cannot read is a guard to teach deliberately, never a pass.
    static func ownership(of conditions: [String]) -> Ownership {
        let normalized = conditions.map { condition in
            condition.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        guard !normalized.isEmpty else { return .unconditional }
        if normalized.count == 1, let platform = Platform(rawValue: normalized[0]) {
            return .exclusive(platform)
        }
        return .unrecognized(normalized)
    }

    /// The `#if` conditions active at the FIRST line containing `needle`,
    /// outermost first — `[]` when that line is compiled unconditionally, and
    /// `nil` when the needle is absent, which is a different failure and gets a
    /// different message.
    static func enclosingConditions(of needle: String, in source: String) -> [String]? {
        var stack: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                stack.append(String(trimmed.dropFirst(4)))
                continue
            }
            if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack.removeLast() }
                stack.append(String(trimmed.dropFirst(8)))
                continue
            }
            if trimmed == "#else" {
                // An `#else` arm is the negation of its own `#if`, so a needle
                // parked there must NOT read as compiled by that condition.
                let inverted = stack.popLast().map { "!(\($0))" } ?? "!"
                stack.append(inverted)
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if line.range(of: needle) != nil { return stack }
        }
        return nil
    }
}
