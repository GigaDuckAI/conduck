// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardToolbarDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over Work's OWN navigation bar in `WorkboardExperience`.
//
// Work's native iPad sidebar owns project navigation outside the desk's capture
// inset. Its explicit workspace toggle lives in whichever column is visible;
// compact layouts use the same button for the Projects picker. Both bars must
// be attached inside their navigation container, and the
// section control stays last. The native sidebar and picker share the host's
// Settings route; inactive layers must not change remembered visibility.
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
        let compact = try RefusalLaneSource.trailingClosure(
            after: "private var compactNavigation: some View",
            in: experience,
            path: Self.path
        )
        let stack = try RefusalLaneSource.trailingClosure(
            after: "NavigationStack",
            in: compact,
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: ".toolbar", in: compact), 1,
            "The compact Work stack must carry exactly one toolbar attachment."
        )
        XCTAssertTrue(
            stack.contains(".toolbar { workbenchToolbar(showsProjectNavigation: true) }"),
            "Work's toolbar is no longer attached inside its own `NavigationStack`. Toolbar items are "
            + "collected by the nearest enclosing navigation container, so an item declared above one "
            + "reaches no bar and renders nothing — the section control disappears and Work becomes a "
            + "one-way trip from Chats on iPad."
        )

        let attachment = try XCTUnwrap(
            WorkboardSourceDirectives.enclosingConditions(of: "private var compactNavigation", in: source),
            "The compact navigation declaration vanished."
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
            WorkboardSourceDirectives.enclosingConditions(of: "private func workbenchToolbar", in: source),
            "`workbenchToolbar` is gone. Work's project navigation and section control both live there."
        )
        XCTAssertEqual(
            WorkboardSourceDirectives.ownership(of: declaration), .exclusive(.iOS),
            "`workbenchToolbar` no longer compiles under a bare `#if os(iOS)`. Widening or negating "
            + "that condition builds a second bar on macOS, where the window shell already owns the "
            + "chrome; a shape this guard cannot read is refused rather than assumed."
        )

        let toolbar = try RefusalLaneSource.trailingClosure(
            after: "private func workbenchToolbar(showsProjectNavigation: Bool) -> some ToolbarContent",
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
        let detailControls = try RefusalLaneSource.trailingClosure(
            after: "if showsProjectNavigation", in: active, path: Self.path
        )
        XCTAssertTrue(detailControls.contains("WorkDeskSidebarToolbarButton("),
                      "The detail bar must expose Projects on compact layouts and restore a hidden iPad sidebar")
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

    func testRegularIPadOwnsNavigationOutsideTheDeskCaptureInset() throws {
        let source = try workSource()
        let experience = try RefusalLaneSource.trailingClosure(
            after: "struct WorkboardExperience: View", in: source, path: Self.path
        )
        let host = try RefusalLaneSource.trailingClosure(after: "var body: some View", in: experience, path: Self.path)
        XCTAssertTrue(host.contains(".onChange(of: usesNativeSidebar, initial: true)"))
        XCTAssertTrue(host.contains("viewModel.deskWorkspace.updateSidebarLayout(isInline: usesSidebar)"),
                      "The toolbar must know its navigation mode even before a desk has loaded")
        let idiom = try RefusalLaneSource.trailingClosure(
            after: "private var usesNativeSidebar: Bool", in: source, path: Self.path
        )
        XCTAssertTrue(idiom.contains("horizontalSizeClass == .regular && DeviceCapabilities.isiPad"),
                      "A landscape iPhone must retain its compact Projects picker")
        let wide = try RefusalLaneSource.trailingClosure(
            after: "private var wideNavigation: some View", in: source, path: Self.path
        )
        let sidebar = try RefusalLaneSource.trailingClosure(
            after: "NavigationSplitView(columnVisibility: sidebarColumnVisibility)", in: wide, path: Self.path
        )
        let detail = try RefusalLaneSource.trailingClosure(after: "detail:", in: wide, path: Self.path)
        XCTAssertTrue(sidebar.contains("WorkDeskSidebarView(viewModel: viewModel)"))
        XCTAssertTrue(sidebar.contains("SidebarSettingsFooter(onOpenSettings: openSettings)"))
        XCTAssertFalse(sidebar.contains("detailColumn"),
                       "Capture belongs in the detail column so the sidebar reaches the window bottom")
        XCTAssertTrue(detail.contains("detailColumn"))
        XCTAssertTrue(detail.contains(".toolbar { workbenchToolbar(showsProjectNavigation: !showsSidebar) }"),
                      "Work/Chats must remain reachable inside the native split's detail bar")
        let observedAt = try XCTUnwrap(wide.range(of: "let showsSidebar = viewModel.deskWorkspace.showsSidebar")?.lowerBound)
        let splitAt = try XCTUnwrap(wide.range(of: "NavigationSplitView(columnVisibility:")?.lowerBound)
        XCTAssertLessThan(observedAt, splitAt,
                          "Visibility must be observed by the host before constructing escaping toolbar content")
        XCTAssertFalse(detail.contains("SidebarSettingsFooter"))
        XCTAssertTrue(wide.contains(".environment(\\.workDeskNavigationIsExternal, true)"))
        XCTAssertTrue(wide.contains(".environment(\\.workDeskSidebarIsHosted, true)"))
        XCTAssertTrue(sidebar.contains(".toolbar(removing: isActive ? .sidebarToggle : nil)"))
        XCTAssertTrue(detail.contains(".toolbar(removing: isActive ? .sidebarToggle : nil)"),
                      "Both bars must remove the inert default button before supplying the explicit workspace toggle")
        let sidebarControls = try RefusalLaneSource.trailingClosure(
            after: "if isActive", in: sidebar, path: Self.path
        )
        XCTAssertTrue(sidebarControls.contains("ToolbarItem(placement: .topBarTrailing)"))
        XCTAssertTrue(sidebarControls.contains("WorkDeskSidebarToolbarButton(workspace: viewModel.deskWorkspace, isActive: isActive)"))
        XCTAssertEqual(occurrences(of: "WorkDeskSidebarToolbarButton(", in: sidebar), 1)
        XCTAssertFalse(sidebar.contains("showsSidebar"),
                       "The column's lifetime removes its own bar; gating again loses the toolbar after reopening")
    }

    func testNativeIPadSidebarPreservesTheWorkspaceVisibilityAndIgnoresHiddenWrites() throws {
        let source = try workSource()
        let binding = try RefusalLaneSource.trailingClosure(
            after: "private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility>",
            in: source, path: Self.path
        )
        XCTAssertTrue(binding.contains("Self.sidebarVisibilityBinding("),
                      "The native split must use the binding exercised across retained destination changes")
        XCTAssertTrue(binding.contains("workspace: viewModel.deskWorkspace"))
        XCTAssertTrue(binding.contains("router: personalWorkbenchModel?.router"),
                      "Native write-backs must consult the live destination rather than a captured host flag")
        XCTAssertFalse(binding.contains("chatColumnVisibility"))
    }

    func testIOSWorkReusesSettingsContainersAndProtectsUnsavedPhoneEdits() throws {
        let source = try workSource()
        let experience = try RefusalLaneSource.trailingClosure(
            after: "struct WorkboardExperience: View", in: source, path: Self.path
        )
        XCTAssertFalse(experience.contains("@State private var settingsViewModel"),
                       "Work's navigation is rebuilt on iPad resizing and cannot own a live Settings editor")
        let open = try RefusalLaneSource.body(ofFunction: "openSettings", in: experience, path: Self.path)
        let guardAt = try XCTUnwrap(open.range(of: "guard isActive else { return }")?.lowerBound)
        let actionAt = try XCTUnwrap(open.range(of: "workDeskOpenSettings?()")?.lowerBound)
        XCTAssertLessThan(guardAt, actionAt)

        let hostPath = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
        let host = try RefusalLaneSource.source(at: hostPath)
        let persistentHost = try RefusalLaneSource.trailingClosure(
            after: "struct PersonalWorkbenchView<Chats: View>: View", in: host, path: hostPath
        )
        let hostBody = try RefusalLaneSource.trailingClosure(
            after: "var body: some View", in: persistentHost, path: hostPath
        )
        XCTAssertTrue(hostBody.contains("shell"))
        XCTAssertTrue(hostBody.contains(".modifier(WorkSettingsPresentationModifier(router: model.router))"),
                      "Settings presentation must live above the regular/compact shell branches")
        let modifier = try RefusalLaneSource.trailingClosure(
            after: "private struct WorkSettingsPresentationModifier: ViewModifier", in: host, path: hostPath
        )
        XCTAssertTrue(modifier.contains("@State private var settingsViewModel = SettingsViewModel()"))
        let body = try RefusalLaneSource.trailingClosure(
            after: "func body(content: Content) -> some View", in: modifier, path: hostPath
        )
        XCTAssertTrue(body.contains(".environment(\\.workDeskOpenSettings, openSettings)"))
        let compact = try RefusalLaneSource.trailingClosure(
            after: ".sheet(item: sheetPresentation)", in: body, path: hostPath
        )
        XCTAssertTrue(compact.contains("SettingsView(viewModel: settingsViewModel)"))
        XCTAssertTrue(compact.contains(".interactiveDismissDisabled(settingsViewModel.editorHasUnsavedChanges)"))
        let wide = try RefusalLaneSource.trailingClosure(
            after: ".fullScreenCover(item: fullScreenPresentation)", in: body, path: hostPath
        )
        XCTAssertTrue(wide.contains("IpadSettingsView(viewModel: settingsViewModel, onDone:"))
    }

    func testWorkSettingsFreezesItsStyleAndDismissesOnlyCleanEditorsOnConversationRoutes() throws {
        let path = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
        let source = try RefusalLaneSource.source(at: path)
        let modifier = try RefusalLaneSource.trailingClosure(
            after: "private struct WorkSettingsPresentationModifier: ViewModifier", in: source, path: path
        )
        let open = try RefusalLaneSource.body(ofFunction: "openSettings", in: modifier, path: path)
        XCTAssertTrue(open.contains("guard router.destination == .work else { return }"))
        XCTAssertTrue(open.contains("usesFullScreen: horizontalSizeClass == .regular && DeviceCapabilities.isiPad"))
        for bindingName in ["sheetPresentation", "fullScreenPresentation"] {
            let binding = try RefusalLaneSource.trailingClosure(
                after: "private var \(bindingName): Binding<Presentation?>", in: modifier, path: path
            )
            XCTAssertTrue(binding.contains("presentation?.usesFullScreen"))
            XCTAssertFalse(binding.contains("horizontalSizeClass"),
                           "Window resizing must not swap the presenter and discard the editor")
        }
        let destination = try RefusalLaneSource.trailingClosure(
            after: ".onChange(of: router.destination)", in: modifier, path: path
        )
        let guardAt = try XCTUnwrap(destination.range(of: "guard destination != .work, !settingsViewModel.editorHasUnsavedChanges else { return }")?.lowerBound)
        let dismissAt = try XCTUnwrap(destination.range(of: "presentation = nil")?.lowerBound)
        XCTAssertLessThan(guardAt, dismissAt,
                          "A conversation request must respect the Settings editor's existing Done/Discard guard")
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
