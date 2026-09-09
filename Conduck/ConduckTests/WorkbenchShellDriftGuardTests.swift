// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkbenchShellDriftGuardTests.swift
//
// SOURCE DRIFT GUARD over the iOS Work / Chats shell in `PersonalWorkbenchView`.
//
// Five facts about that shell decide whether the section switch exists at all,
// and none of them shows up as a failing assertion anywhere else. (1) The wide
// shell may declare NO toolbar item: each of its two layers owns its own
// navigation container, so an item declared out at the shell sits above every
// bar and is collected by nothing — the exact shape that left Work unreachable
// from Chats on iPad. (2) EACH wide layer must hand the router down through the
// environment, because that injection is the only thing a host has to discover
// the control from — and the compact shell must inject NOTHING, because absence
// is what keeps the control off the phone, which already carries a tab bar.
// (3) The tab order has to read Chats then Work, the same order as the wide
// shell's control, and the wide shell has to be gated on the same predicate
// `ContentView` gates its split layout on — a Plus/Max iPhone reports a regular
// width in landscape and would otherwise get a shell `ContentView` never builds.
// (4) The tab bar's amber reaches the bar and nothing else only because it is
// installed on the UIKit tab-bar appearance and NO SwiftUI tint is written
// anywhere in this view — a tint on the compact shell, or out on `body` above
// it, travels the UIKit view hierarchy too and repaints ambient-tint controls
// inside the tabs.
// (5) The section control draws its own filled container and therefore must
// suppress the system's shared background, or it ships double-wrapped.
//
// The shell is a single several-hundred-line SwiftUI expression whose behaviour
// is decided by structure, not by values a unit test could call into, so each
// invariant is asserted where it is written: over the file's text with comments
// stripped, scoped to ONE declaration, ONE conditional arm, and — where the
// claim is about a single layer or a single tab — one top-level statement
// inside that arm, read through that statement's OWN modifier chain with every
// closure body removed. Scoping this far is what stops a sibling, or a
// zero-size `.background { … }` child, from satisfying an assertion the layer
// it protects no longer earns.
//
// A guard that fails because the shape legitimately changed is a guard to
// update, not a bug to route around. The failure messages distinguish the two:
// a missing structural anchor says "update this guard", a demonstrated wrong
// shape says what broke on screen.

import XCTest

final class WorkbenchShellDriftGuardTests: XCTestCase {

    private static let path = "Conduck/Views/Workboard/PersonalWorkbenchView.swift"
    private static let contentViewPath = "Conduck/ContentView.swift"

    /// The one predicate both roots must ask, written exactly as it is written
    /// in each of them.
    private static let wideLayoutPredicate =
        "if horizontalSizeClass == .regular && DeviceCapabilities.isiPad {"

    // MARK: - Source scoping

    private func shellSource() throws -> String {
        try RefusalLaneSource.source(at: Self.path)
    }

    /// The body of `PersonalWorkbenchView` itself. Anchoring on the type before
    /// reaching for `var body` matters: this file declares half a dozen views,
    /// and the FIRST `var body: some View` in it belongs to the section control.
    private func personalWorkbenchViewDeclaration(_ source: String) throws -> String {
        try RefusalLaneSource.trailingClosure(
            after: "struct PersonalWorkbenchView<Chats: View>: View",
            in: source,
            path: Self.path
        )
    }

    private func shellDeclaration(_ source: String) throws -> String {
        try RefusalLaneSource.trailingClosure(
            after: "private var shell: some View",
            in: source,
            path: Self.path
        )
    }

    private func mountDeclaration(_ source: String) throws -> String {
        try RefusalLaneSource.trailingClosure(
            after: "private var mountedWideDestinations: some View",
            in: source,
            path: Self.path
        )
    }

    /// The `#else` arm of a `#if os(macOS)` block — i.e. everything the phone
    /// and iPad compile. `RefusalLaneSource` strips comments, not conditional
    /// compilation, so a count taken over a whole declaration is satisfied by
    /// the Mac branch that no iOS build ever sees.
    private func nonMacArm(of declaration: String, _ label: String) throws -> String {
        let elseAt = try XCTUnwrap(
            declaration.range(of: "#else"),
            "\(label) no longer splits Mac from iOS with `#if os(macOS)` / `#else`. This guard "
            + "reads the iOS arm by that split — update this guard for the new shape."
        )
        let endAt = try XCTUnwrap(
            declaration.range(of: "#endif", range: elseAt.upperBound..<declaration.endIndex),
            "\(label) opens a `#else` that never closes with `#endif`. Update this guard."
        )
        return String(declaration[elseAt.upperBound..<endAt.lowerBound])
    }

    /// The text each `#if !os(macOS)` region encloses — the part of the file
    /// ONLY the phone and iPad compile, read as its own text so nothing the Mac
    /// build sees can satisfy an iOS-only claim. Nesting is counted over `#if` /
    /// `#endif`, and an `#else` at the region's own level ends it, because
    /// everything past that belongs to the Mac arm.
    ///
    /// The sibling of `nonMacArm(of:_:)`, which reads the OTHER spelling of the
    /// same split (`#if os(macOS)` / `#else`). Both exist because this file uses
    /// both, and a reader for one silently finds nothing in the other.
    private func nonMacRegions(in source: String) -> [String] {
        var regions: [String] = []
        var searchFrom = source.startIndex
        while let opening = source.range(
            of: "#if !os(macOS)",
            range: searchFrom..<source.endIndex
        ) {
            var index = opening.upperBound
            var depth = 1
            var end = source.endIndex
            while index < source.endIndex {
                let rest = source[index...]
                if rest.hasPrefix("#endif") {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                } else if rest.hasPrefix("#else"), depth == 1 {
                    end = index
                    break
                } else if rest.hasPrefix("#if") {
                    depth += 1
                }
                index = source.index(after: index)
            }
            regions.append(String(source[opening.upperBound..<end]))
            searchFrom = end
        }
        return regions
    }

    /// The statements a closure declares at ITS OWN level, each with its whole
    /// modifier chain attached. Depth is counted over `{}`, `()` and `[]`, and a
    /// line that opens with `.` continues the statement above it.
    ///
    /// This is the first half of what makes "this layer injects the model" a
    /// claim about one layer: a `contains` over the enclosing closure is
    /// satisfied by the sibling layer, which is precisely how a guard keeps
    /// passing while one of the two halves it protects has lost its wiring.
    /// `ownModifierChain(of:)` is the second half.
    private func topLevelStatements(in closure: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var depth = 0
        for line in closure.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let opensAStatement =
                depth == 0 && !trimmed.isEmpty && !trimmed.hasPrefix(".") && !trimmed.hasPrefix("}")
            if opensAStatement, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statements.append(current)
                current = ""
            }
            if !trimmed.isEmpty {
                current += String(line) + "\n"
            }
            for character in line {
                if character == "{" || character == "(" || character == "[" { depth += 1 }
                if character == "}" || character == ")" || character == "]" { depth -= 1 }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statements.append(current)
        }
        return statements
    }

    /// One statement's OWN modifier chain: the same text with every
    /// brace-delimited body removed, argument lists left intact.
    ///
    /// A closure argument builds a DIFFERENT view. `.background { … }`,
    /// `.overlay { … }` and every `Tab { … }` body hang a child off the
    /// statement, and a modifier written inside one applies to that child, never
    /// to the statement carrying it. Text taken over the whole statement cannot
    /// tell the two apart, so an injection or a tint reset moved onto a
    /// zero-size background child keeps satisfying a guard while the view it
    /// was protecting has already lost it.
    private func ownModifierChain(of statement: String) -> String {
        var chain = ""
        var depth = 0
        for character in statement {
            if character == "{" {
                depth += 1
                continue
            }
            if character == "}" {
                depth = max(0, depth - 1)
                continue
            }
            if depth == 0 { chain.append(character) }
        }
        return chain
    }

    /// The argument list of the call a statement OPENS — the text between its
    /// first `(` and the matching `)`, so a trailing closure is left out.
    private func leadingCallArguments(of statement: String) -> String? {
        guard let opening = statement.firstIndex(of: "(") else { return nil }
        var index = statement.index(after: opening)
        let start = index
        var depth = 1
        while index < statement.endIndex {
            if statement[index] == "(" { depth += 1 }
            if statement[index] == ")" {
                depth -= 1
                if depth == 0 { return String(statement[start..<index]) }
            }
            index = statement.index(after: index)
        }
        return nil
    }

    /// An argument list split on the commas that separate arguments at depth
    /// zero — a nested call's own commas belong to the argument holding it.
    private func topLevelArguments(in arguments: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in arguments {
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The expression written for `label:`, read off the top-level arguments
    /// rather than searched for in the text: a `Tab`'s title argument nests a
    /// `defaultValue:`, and a plain search for `value:` finds that instead.
    private func argument(labelled label: String, in arguments: String) -> String? {
        for part in topLevelArguments(in: arguments) where part.hasPrefix("\(label):") {
            return String(part.dropFirst(label.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Every run of whitespace collapsed to one space, so an assertion about
    /// what the code SAYS survives a reflow that only changed how it is laid
    /// out. Brace matching is unaffected: no brace is whitespace.
    private func whitespaceNormalized(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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

    // MARK: - The wide shell

    /// The wide shell hands the hosts a router and declares no bar of its own.
    func testWideShellDeclaresNoToolbarOfItsOwn() throws {
        let mount = try mountDeclaration(shellSource())

        XCTAssertNil(
            mount.range(of: ".toolbar"),
            "`mountedWideDestinations` declares a toolbar again. Each layer here owns its own "
            + "navigation container, so an item declared at this level sits ABOVE every bar, is "
            + "collected by none of them, and renders nothing — which is how Work became unreachable "
            + "from Chats on iPad. The control belongs to the hosts, inside their own containers."
        )
    }

    /// EACH wide layer injects the router, on its own modifier chain.
    ///
    /// Asserted per layer rather than as a count over the mount: the Mac arm of
    /// the same declaration injects the model too, so any total taken over the
    /// whole property is still reached when one of the two iOS layers has lost
    /// its injection and gone one-way. And per CHAIN rather than per statement,
    /// because the environment flows DOWN: an injection written into a closure
    /// argument reaches the child that closure builds and never the layer the
    /// closure hangs off, so the statement still reads as compliant while its
    /// host finds no model.
    func testEachWideIOSLayerReceivesTheWorkbenchModel() throws {
        let mount = try mountDeclaration(shellSource())
        let iOSArm = try nonMacArm(of: mount, "`mountedWideDestinations`")
        let stack = try RefusalLaneSource.trailingClosure(
            after: "ZStack",
            in: iOSArm,
            path: Self.path
        )

        let layers = topLevelStatements(in: stack)
        XCTAssertEqual(
            layers.count, 2,
            "The wide iOS mount no longer holds exactly two top-level layers (found \(layers.count)). "
            + "This guard reads one injection per layer — update it for the new shape."
        )

        for layer in layers {
            let chain = ownModifierChain(of: layer)
            let name = chain.contains("WorkboardView") ? "Work"
                : chain.contains("chats") ? "Chats"
                : "an unrecognised layer"
            XCTAssertEqual(
                occurrences(of: ".environment(\\.personalWorkbenchModel, model)", in: chain), 1,
                "The \(name) layer of the wide iOS shell does not inject `personalWorkbenchModel` "
                + "exactly once ON ITS OWN modifier chain. A host discovers the section router ONLY "
                + "through that environment value, and one written inside a closure argument — onto a "
                + "`.background { … }` child, say — reaches that child instead. So this layer draws no "
                + "section control and the section becomes a one-way trip: the user reaches it and "
                + "cannot get back."
            )
        }
    }

    /// The compact shell injects nothing, and no ancestor injects for it.
    ///
    /// Absence is the mechanism: the hosts draw the control when they find a
    /// model and nothing when they do not, which is what keeps the phone free
    /// of it without a single platform check in either host. An injection here
    /// — or anywhere above the shell — would put a second, redundant section
    /// switch in the nav bar of a phone that already carries the tab bar.
    func testCompactShellDoesNotInjectTheWorkbenchModel() throws {
        let source = try shellSource()
        let shell = try shellDeclaration(source)
        let arms = try XCTUnwrap(
            RefusalLaneSource.branches(ofIf: Self.wideLayoutPredicate, in: shell),
            "`shell` no longer branches on `\(Self.wideLayoutPredicate)`. This guard reads the "
            + "compact arm off that `if` — update this guard for the new shape."
        )

        XCTAssertNil(
            arms.else.range(of: "personalWorkbenchModel"),
            "The compact arm injects `personalWorkbenchModel`. The hosts draw the Chats | Work "
            + "control whenever they find that model, so the phone would carry a nav-bar section "
            + "switch on top of the tab bar that already does the same job."
        )

        let viewBody = try RefusalLaneSource.trailingClosure(
            after: "var body: some View",
            in: try personalWorkbenchViewDeclaration(source),
            path: Self.path
        )
        XCTAssertNil(
            viewBody.range(of: "personalWorkbenchModel"),
            "`PersonalWorkbenchView.body` injects `personalWorkbenchModel` above `shell`. The "
            + "environment flows down, so an injection here reaches the compact tab shell too and "
            + "puts the section control back on the phone."
        )
    }

    /// The wide shell is gated on the same predicate `ContentView` gates on.
    ///
    /// Presence of the iPad token alone is not the property: a shell that asked
    /// `.regular || DeviceCapabilities.isiPad` still names it, and would hand a
    /// Plus/Max iPhone in landscape a two-layer wide shell `ContentView` never
    /// builds — one device, two roots disagreeing about which chrome exists. So
    /// the whole conjunction is pinned, in both files, and each arm is checked
    /// for the layout it is supposed to carry.
    func testWideShellRequiresRegularIPadAndMatchesContentView() throws {
        let shell = whitespaceNormalized(try shellDeclaration(try shellSource()))
        let shellArms = try XCTUnwrap(
            RefusalLaneSource.branches(ofIf: Self.wideLayoutPredicate, in: shell),
            "`shell` does not branch on `\(Self.wideLayoutPredicate)`. Either the conjunction was "
            + "weakened — `.regular` alone hands a landscape Plus/Max iPhone the iPad shell — or the "
            + "shape changed and this guard needs updating."
        )
        XCTAssertTrue(
            shellArms.then.contains("mountedWideDestinations"),
            "The iPad arm of `shell` no longer mounts `mountedWideDestinations`, so the two-layer "
            + "wide shell — and with it the Chats | Work control — is gone from iPad."
        )
        XCTAssertTrue(
            shellArms.else.contains("TabView"),
            "The compact arm of `shell` no longer builds a `TabView`, so the phone loses the tab bar "
            + "that is its only way between Chats and Work."
        )

        let contentView = whitespaceNormalized(
            try RefusalLaneSource.trailingClosure(
                after: "struct ContentView: View",
                in: try RefusalLaneSource.source(at: Self.contentViewPath),
                path: Self.contentViewPath
            )
        )
        let rootArms = try XCTUnwrap(
            RefusalLaneSource.branches(ofIf: Self.wideLayoutPredicate, in: contentView),
            "`ContentView` no longer branches on `\(Self.wideLayoutPredicate)`. The two roots have to "
            + "ask ONE question about which layout a device gets; if this one legitimately changed, "
            + "`shell` and this guard change with it."
        )
        XCTAssertTrue(
            rootArms.then.contains("ConversationLibraryView"),
            "`ContentView`'s iPad arm no longer builds `ConversationLibraryView`. This guard pins the "
            + "two roots to the same predicate by reading what each arm builds — update it."
        )
        XCTAssertTrue(
            rootArms.else.contains("phoneLayout"),
            "`ContentView`'s compact arm no longer builds `phoneLayout`. This guard pins the two roots "
            + "to the same predicate by reading what each arm builds — update it."
        )
    }

    // MARK: - The compact tab bar

    /// The `else` arm of the shell's layout branch — everything the phone builds.
    private func compactArm() throws -> String {
        let shell = try shellDeclaration(try shellSource())
        let arms = try XCTUnwrap(
            RefusalLaneSource.branches(ofIf: Self.wideLayoutPredicate, in: shell),
            "`shell` no longer branches on `\(Self.wideLayoutPredicate)`; this guard reads the compact "
            + "arm off that `if` — update this guard."
        )
        return arms.else
    }

    /// The compact arm's `TabView(…)` statement, its whole modifier chain attached.
    private func compactTabViewStatement() throws -> String {
        let arm = try compactArm()
        return try XCTUnwrap(
            topLevelStatements(in: arm).first {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("TabView(")
            },
            "The compact arm no longer opens a `TabView(…)` statement of its own. This guard reads the "
            + "bar's tint off that statement's modifier chain — update this guard."
        )
    }

    /// One `Tab(…)` declaration, with the destination it carries.
    private struct TabDeclaration {
        let destination: String?
        let content: String
    }

    /// The `Tab` declarations the compact shell writes, in declaration order,
    /// each named by the destination its `value:` argument carries and paired
    /// with its own content.
    ///
    /// Read as declarations rather than as first mentions anywhere in `shell`:
    /// a destination hoisted into a local constant above the tabs would move
    /// the first mention without moving a single tab, and an order assertion
    /// built on first mentions would report a reversal that never happened.
    ///
    /// And named from the `value:` argument alone rather than from the whole
    /// declaration, because what a tab's CONTENT mentions says nothing about
    /// which tab it is: a comparison against the other destination inside a tab
    /// body — a `.disabled(…)` on the selected state, say — would rename the tab
    /// and fake a reversal just as convincingly.
    private func compactTabDeclarations() throws -> [TabDeclaration] {
        let arm = try compactArm()
        let tabView = try RefusalLaneSource.trailingClosure(
            after: "TabView(",
            in: arm,
            path: Self.path
        )
        var tabs: [TabDeclaration] = []
        for declaration in topLevelStatements(in: tabView)
        where declaration.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Tab(") {
            let value = leadingCallArguments(of: declaration)
                .flatMap { argument(labelled: "value", in: $0) }
                .map { whitespaceNormalized($0) }
            let destination: String?
            if value?.hasSuffix(".chats") == true {
                destination = "chats"
            } else if value?.hasSuffix(".work") == true {
                destination = "work"
            } else {
                destination = nil
            }
            tabs.append(TabDeclaration(
                destination: destination,
                content: try RefusalLaneSource.trailingClosure(
                    after: "Tab(",
                    in: declaration,
                    path: Self.path
                )
            ))
        }
        return tabs
    }

    /// Chats leads, Work follows — the same reading order as the wide control.
    func testCompactTabDeclarationsOrderChatsBeforeWork() throws {
        let tabs = try compactTabDeclarations()

        XCTAssertEqual(
            tabs.count, 2,
            "The compact `TabView` no longer declares exactly two tabs (found \(tabs.count)). This "
            + "guard reads their order off those declarations — update this guard."
        )
        for tab in tabs where tab.destination == nil {
            XCTFail(
                "A compact tab's `value:` argument ends in neither `.chats` nor `.work` — it is "
                + "written some other way (a hoisted constant, say). This guard cannot read the order "
                + "any more; update it rather than assuming the order reversed."
            )
        }
        guard tabs.count == 2, tabs.allSatisfy({ $0.destination != nil }) else { return }

        XCTAssertEqual(
            tabs.compactMap(\.destination), ["chats", "work"],
            "The compact tabs are declared Work before Chats. The wide shell's "
            + "`WorkbenchSectionControl` reads Chats | Work, so a phone that reads Work | Chats "
            + "teaches the opposite mental model of the same two sections on the same account."
        )
    }

    /// The compact shell writes no SwiftUI tint at all.
    ///
    /// A tint on the `TabView` does colour the selected tab, and it also leaks
    /// into the tabs: a tint is one environment value, and SwiftUI additionally
    /// hands the colour to the tab-bar controller's own view, where a UIKit
    /// `tintColor` cascades to every hosted view and `Color.accentColor`
    /// resolves through it. Ambient-tint controls inside the tabs then turn
    /// amber — `PendingRetryCard`'s `.borderedProminent` Retry button, the
    /// composer's text selection — while the same controls stay in the system
    /// accent on iPad and inside any presented sheet. Resetting the environment
    /// tint at each tab root does not undo that, because the leak does not
    /// travel the environment.
    ///
    /// So the assertion is absence, checked at five scopes: the `TabView`'s own
    /// modifier chain, each tab root's own chain, the whole compact arm,
    /// `body`'s own chain, and the whole `PersonalWorkbenchView` declaration.
    /// The arm alone is not enough — `body` wraps `shell`, so a tint written out
    /// there, behind an `#if !os(macOS)` included, reaches the `TabView` from
    /// above while every arm-scoped assertion still passes. The widest two also
    /// refuse the tempting repair of hard-coding `.tint(.blue)` on the controls
    /// that went amber.
    func testCompactShellWritesNoSwiftUITint() throws {
        let arm = try compactArm()
        let tabViewStatement = try compactTabViewStatement()
        let tabViewContent = try RefusalLaneSource.trailingClosure(
            after: "TabView(",
            in: arm,
            path: Self.path
        )

        XCTAssertFalse(
            ownModifierChain(of: tabViewStatement).contains(".tint("),
            "The compact `TabView` carries a `.tint(…)` on its own modifier chain again. That paints "
            + "the selected tab AND every ambient-tint control inside both tabs, because SwiftUI hands "
            + "the colour to the tab-bar controller's view as well and a UIKit tint cascades from "
            + "there. The bar's colour belongs on the tab-bar appearance (`WorkbenchTabBarTint`), "
            + "which reaches `UITabBar` instances and nothing else."
        )

        for tab in try compactTabDeclarations() {
            let name = tab.destination ?? "an unrecognised"
            let roots = topLevelStatements(in: tab.content)
            XCTAssertFalse(
                roots.isEmpty,
                "The \(name) tab declares no content this guard can read — update this guard."
            )
            for root in roots {
                XCTAssertFalse(
                    ownModifierChain(of: root).contains(".tint("),
                    "A root of the \(name) tab's content carries a `.tint(…)` on its own chain. A "
                    + "reset here is the repair that does not work — the bar's colour never travels "
                    + "the environment — so its presence means an environment tint came back above "
                    + "it, and a colour written here paints this tab's controls instead."
                )
            }
        }

        XCTAssertNil(
            arm.range(of: ".tint("),
            "The compact shell writes a `.tint(…)` somewhere. Nothing on the phone may name a tint: "
            + "the bar takes its colour from the tab-bar appearance, and a tint written to force a "
            + "control back to blue hard-codes an accent the Mac deliberately leaves to the user "
            + "(the app ships an EMPTY AccentColor asset for exactly that reason)."
        )
        XCTAssertNil(
            tabViewContent.range(of: "brandAmber"),
            "Brand amber is applied INSIDE the compact `TabView`'s content, where it paints the "
            + "workspace rather than the bar. The bar's amber belongs on the tab-bar appearance."
        )

        // Above the arm. `body` builds `shell`, so a tint written on the body's
        // own chain sits over the `TabView` and everything it hosts, and every
        // arm-scoped assertion above is blind to it.
        let declaration = try personalWorkbenchViewDeclaration(try shellSource())
        let viewBody = try RefusalLaneSource.trailingClosure(
            after: "var body: some View",
            in: declaration,
            path: Self.path
        )
        let bodyRoots = topLevelStatements(in: viewBody)
        XCTAssertFalse(
            bodyRoots.isEmpty,
            "`PersonalWorkbenchView.body` declares no statement this guard can read — update this "
            + "guard."
        )
        for root in bodyRoots {
            XCTAssertFalse(
                ownModifierChain(of: root).contains(".tint("),
                "`PersonalWorkbenchView.body` carries a `.tint(…)` on its own modifier chain. `body` "
                + "wraps `shell`, so a tint written there reaches the compact `TabView` from ABOVE: "
                + "the selected tab turns amber and so does every ambient-tint control inside both "
                + "tabs, because SwiftUI hands the colour to the tab-bar controller's view and a "
                + "UIKit tint cascades from there. An `#if !os(macOS)` around it changes nothing — "
                + "the phone is the platform that has the bar."
            )
        }

        XCTAssertNil(
            declaration.range(of: ".tint("),
            "`PersonalWorkbenchView` names a `.tint(…)` somewhere in its declaration. This view has "
            + "no legitimate use for one: the bar's colour is installed on the UIKit tab-bar "
            + "appearance (`WorkbenchTabBarTint`), which reaches `UITabBar` instances and nothing "
            + "else. Every other tint here either leaks into the tabs or — written to force a leaked "
            + "control back to blue — hard-codes an accent the Mac deliberately leaves to the user, "
            + "which is why the app ships an EMPTY AccentColor asset."
        )
    }

    /// The bar's amber is installed once, on the UIKit tab-bar appearance, and
    /// `PersonalWorkbenchView.init` touches that install before the bar it
    /// paints reaches a window.
    ///
    /// Every half is load-bearing. UIKit applies an appearance proxy's values as
    /// a view ENTERS a window and does not repaint one already there, so an
    /// install nothing touches never runs at all, and one touched from a body
    /// edge lands after this shell's bar is already on screen. That is why the
    /// touch is pinned to `init` rather than counted anywhere in the view, and
    /// why the holder has to stay a STORED `static let`: run-once-on-first-
    /// access is the `let`'s behaviour, and a computed `static var` spelled the
    /// same way reads identically in a diff while re-running the install on
    /// every touch.
    ///
    /// And the colour has to sit in the per-layout appearances rather than in
    /// the proxy's `tintColor`: on iOS 26.5 the bar reads its selected item's
    /// colour from the appearance objects, so a proxy `tintColor` alone leaves
    /// the selected tab in the system accent — a shape that looks right in the
    /// diff and ships no brand colour at all. Icon and title are separate
    /// appearance properties, and the three item layouts are picked at runtime
    /// by device, orientation and size class, so every one of them is pinned.
    func testTabBarAmberIsInstalledOnTheTabBarAppearanceExactlyOnce() throws {
        let source = try shellSource()

        XCTAssertEqual(
            occurrences(of: "UITabBar.appearance()", in: source), 1,
            "This file no longer holds exactly one `UITabBar.appearance()` install. The proxy is "
            + "process-wide, so a second one racing the first decides the bar's colour by build order "
            + "— and none at all leaves the phone's one piece of brand colour unpainted."
        )

        let regions = nonMacRegions(in: source)
        let install = try XCTUnwrap(
            regions.first { $0.contains("UITabBar.appearance()") },
            "The `UITabBar.appearance()` install is not inside a `#if !os(macOS)` region. UIKit is "
            + "not there to import on the Mac, and the Mac has no tab bar to paint — or the region "
            + "spelling changed, in which case update this guard."
        )

        // The holder, then the closure it stores. Read separately because they
        // carry different claims: the holder has to stay a STORED `static let`,
        // and the closure has to paint every surface the bar draws.
        let tintHolder = try RefusalLaneSource.trailingClosure(
            after: "private enum WorkbenchTabBarTint",
            in: install,
            path: Self.path
        )
        XCTAssertTrue(
            whitespaceNormalized(tintHolder).contains("static let installed: Void = {"),
            "`WorkbenchTabBarTint.installed` is no longer a stored `static let installed: Void = "
            + "{ … }()`. That spelling IS the guarantee: Swift runs a stored static's initializer "
            + "lazily and exactly once, on first access. A computed `static var` reads identically at "
            + "the touch site and re-runs the whole appearance install on every read, which turns the "
            + "ordering this bar depends on into a question of who read it last."
        )

        let installer: String
        if tintHolder.contains("static let installed: Void") {
            installer = try RefusalLaneSource.trailingClosure(
                after: "static let installed: Void",
                in: tintHolder,
                path: Self.path
            )
        } else {
            installer = tintHolder
        }

        XCTAssertTrue(
            installer.contains("UIColor(AppColors.brandAmber)"),
            "The tab-bar appearance no longer names `AppColors.brandAmber`, so the selected tab stops "
            + "carrying the one piece of brand colour the phone shows."
        )
        XCTAssertTrue(
            installer.contains("selected.iconColor"),
            "The tab-bar appearance no longer colours the SELECTED item's icon. A proxy `tintColor` "
            + "alone does not reach it on iOS 26.5 — the bar reads the appearance objects — so the "
            + "selected tab renders in the system accent while the code reads as if it were amber."
        )
        XCTAssertTrue(
            installer.contains("selected.titleTextAttributes"),
            "The tab-bar appearance no longer colours the selected item's TITLE. The glyph and the "
            + "label take their colour from separate appearance properties, so an icon-only write "
            + "ships a half-painted tab — amber glyph over a system-accent word — which reads as a "
            + "rendering bug rather than as a brand colour."
        )
        for property in ["standardAppearance", "scrollEdgeAppearance"] {
            XCTAssertTrue(
                installer.contains(property),
                "The tab-bar appearance is not written to `\(property)`. The bar draws different "
                + "appearances in different states, so a colour written to only one of them "
                + "disappears in the other."
            )
        }
        for layout in [
            "stackedLayoutAppearance",
            "inlineLayoutAppearance",
            "compactInlineLayoutAppearance"
        ] {
            XCTAssertTrue(
                installer.contains(layout),
                "The tab-bar appearance leaves `\(layout)` uncoloured. iOS picks the item layout at "
                + "runtime from device, orientation and size class, so an appearance that paints only "
                + "some of them drops back to the system accent on whichever geometry selects the "
                + "missing one — a regression that no amount of reading the code reveals."
            )
        }

        // Scoped to `init`, not to the view. A count taken over the whole
        // declaration passes just as happily once the touch has moved onto
        // `.onAppear`, which is exactly the move that breaks it.
        let declaration = try personalWorkbenchViewDeclaration(source)
        let initializer = try RefusalLaneSource.trailingClosure(
            after: "init(@ViewBuilder chats: () -> Chats)",
            in: declaration,
            path: Self.path
        )
        let touchedInInit = nonMacRegions(in: initializer)
            .reduce(0) { $0 + occurrences(of: "WorkbenchTabBarTint.installed", in: $1) }
        XCTAssertEqual(
            touchedInInit, 1,
            "`PersonalWorkbenchView.init` does not touch `WorkbenchTabBarTint.installed` exactly once "
            + "inside a `#if !os(macOS)` region. That touch is what RUNS the install, and it has to "
            + "run before this shell's bar reaches a window: UIKit applies appearance-proxy values as "
            + "a view enters a window and does not repaint one already there. So an untouched install "
            + "never runs at all, and a touch moved to `.onAppear` — or any other body edge — lands "
            + "after the body has built the `TabView`, leaving the bar it was meant to paint in the "
            + "system accent."
        )

        let touchedInDeclaration = occurrences(of: "WorkbenchTabBarTint.installed", in: declaration)
        XCTAssertEqual(
            touchedInDeclaration, 1,
            "`PersonalWorkbenchView` touches `WorkbenchTabBarTint.installed` \(touchedInDeclaration) "
            + "times rather than the single time in `init`. A second touch on a body edge reads as a "
            + "harmless re-assurance while repainting nothing — the bar is in a window by then — and "
            + "it invites deleting the `init` touch that is doing the actual work."
        )
    }

    // MARK: - The section control

    /// The selected half of the section control is the amber one.
    func testSelectedSegmentFillsWithBrandAmber() throws {
        let segmentStyle = try RefusalLaneSource.trailingClosure(
            after: "private struct WorkbenchSectionSegmentButtonStyle: ButtonStyle",
            in: try shellSource(),
            path: Self.path
        )

        XCTAssertEqual(
            occurrences(of: "brandAmber", in: segmentStyle), 1,
            "The section control's selected segment no longer fills with brand amber exactly once, so "
            + "the two halves stop reading as selected and unselected."
        )
    }

    /// The shared toolbar item is a primary action, hides the system's
    /// background container, and drives the router through the binding the
    /// behavioural test covers.
    func testSectionToolbarItemUsesTheTestedBindingInItsPrimaryAction() throws {
        let item = try RefusalLaneSource.trailingClosure(
            after: "struct WorkbenchSectionToolbarItem: ToolbarContent",
            in: try shellSource(),
            path: Self.path
        )
        let body = try RefusalLaneSource.trailingClosure(
            after: "var body: some ToolbarContent",
            in: item,
            path: Self.path
        )

        XCTAssertTrue(
            item.contains("static func selectionBinding("),
            "`WorkbenchSectionToolbarItem.selectionBinding(for:)` is gone. That helper is the only "
            + "part of this item a test can drive — a binding rebuilt inline in an opaque "
            + "`ToolbarContent` body is unreachable, and a setter that wrote nowhere would make the "
            + "control a decoration with nothing failing."
        )
        XCTAssertTrue(
            body.contains("Self.selectionBinding(for: model.router)"),
            "The item's body no longer builds its selection from `selectionBinding(for:)`. The tested "
            + "helper and the shipped wiring have to be the same code, or the test passes on a "
            + "binding the toolbar does not use."
        )
        XCTAssertTrue(
            body.contains("ToolbarItem(placement: .primaryAction)"),
            "The section control left `.primaryAction`. That placement is what puts it trailing-most "
            + "in every bar that hosts it, which is the one position it holds on Mac and iPad alike."
        )
        XCTAssertTrue(
            body.contains(".sharedBackgroundVisibility(.hidden)"),
            "`WorkbenchSectionToolbarItem` no longer hides the shared background. The control draws "
            + "its own filled, stroked container, so without this it ships double-wrapped in the "
            + "system's glass capsule in every bar that hosts it."
        )
    }
}
