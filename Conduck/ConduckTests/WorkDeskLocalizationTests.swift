// SPDX-License-Identifier: Apache-2.0

// Exercise the English resources compiled into the application, not only the
// source catalog or localization defaults. Generated-symbol extraction once
// replaced real translations with their keys and stripped the words around
// interpolated counts and gateway names; both still compiled successfully.
// Explicit English bundle lookup makes a missing resource fail even when a
// source default could otherwise conceal it.

import XCTest
@testable import Conduck

final class WorkDeskLocalizationTests: XCTestCase {
    private let missingTranslation = "__MISSING_WORK_DESK_TRANSLATION__"

    func testEveryWorkDeskKeyResolvesToReadableCompiledEnglish() throws {
        let bundle = try englishAppBundle()
        let keys = try workDeskCatalogKeys()
        XCTAssertFalse(keys.isEmpty, "The broad compiled-resource check must exercise Work desk keys.")

        for key in keys.sorted() {
            let value = compiledValue(for: key, bundle: bundle)
            XCTAssertNotEqual(value, missingTranslation, "Missing compiled English resource: \(key)")
            XCTAssertNotEqual(value, key, "The English translation contains the internal key: \(key)")
            XCTAssertFalse(value.hasPrefix("workdesk."), "Another internal key was stored as English: \(key)")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty English translation: \(key)")
        }
    }

    func testNavigationAndProjectWorkflowHaveTheirEnglishLabels() throws {
        let bundle = try englishAppBundle()
        let expected = [
            "workdesk.all": "Home",
            "workdesk.projects": "Projects",
            "workdesk.projects.archived": "Archived",
            "workdesk.project.archive": "Archive project",
            "workdesk.project.restore": "Restore project",
            "workdesk.removeFromThisProject": "Remove from this project",
            "workdesk.search": "Find an idea or file",
            "workdesk.select": "Select",
            "workdesk.select.all": "Select all",
            "workdesk.layout.desk": "Desk",
            "workdesk.group": "Create project",
            "workdesk.move": "Move to",
            "workdesk.conversation.new": "New conversation…",
            "workdesk.conversation.review": "Review",
            "workdesk.brief.openChat": "Open chat"
        ]

        for (key, value) in expected {
            XCTAssertEqual(compiledValue(for: key, bundle: bundle), value, key)
        }
    }

    func testMaterialCountsKeepTheirMeaningAroundTheNumber() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.material.count", bundle: bundle), "%lld materials")
        XCTAssertEqual(compiledValue(for: "workdesk.material.count.one", bundle: bundle), "1 material")

        for count in [0, 1, 14] {
            var label = WorkDeskCopy.materialCount(count)
            label.locale = Locale(identifier: "en")
            let rendered = String(localized: label)
            XCTAssertEqual(rendered, count == 1 ? "1 material" : "\(count) materials")
        }
    }

    func testProjectLimitPreservesItsCountAndRecoveryInstructions() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.error.projectLimit", bundle: bundle),
            "The free plan includes %lld active projects. Archive a project to make room. Its materials and conversations stay available.")
    }

    func testSelectionCountsKeepTheirMeaningAroundTheNumber() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.selected.count", bundle: bundle), "%lld selected")

        for count in [0, 1, 14] {
            let rendered = String(
                localized: "workdesk.selected.count",
                defaultValue: "\(count) selected",
                bundle: bundle,
                locale: Locale(identifier: "en")
            )
            XCTAssertEqual(rendered, "\(count) selected")
        }
    }

    func testSendActionNamesBothTheActionAndTheSelectedGateway() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.brief.sendTo", bundle: bundle), "Send to %@")

        for gatewayName in ["My gateway", "Lab %@ gateway"] {
            let rendered = String(
                localized: "workdesk.brief.sendTo",
                defaultValue: "Send to \(gatewayName)",
                bundle: bundle,
                locale: Locale(identifier: "en")
            )
            XCTAssertEqual(rendered, "Send to \(gatewayName)")
        }
    }

    func testWorkTourDescribesArrangementAndEndsWithoutStartingCapture() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(
            compiledValue(for: "workdesk.tour.project.subtitle", bundle: bundle),
            "Use Select to group related materials in a project. Open its folder to see them together."
        )
        XCTAssertEqual(
            compiledValue(for: "workdesk.tour.done", bundle: bundle),
            "Go to Work"
        )
    }

    func testProjectCaptureNamesItsActualDestinationInTheCompiledBundle() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.capture.all.prompt", bundle: bundle), "Add to Home…")
        XCTAssertEqual(compiledValue(for: "workdesk.capture.project.prompt", bundle: bundle), "Add to %@…")
        for title in ["Research", "Notes %@ 100%", "旅行"] {
            var label = WorkboardCaptureDestination.project(UUID(), title: title).composerPrompt
            label.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: label), "Add to \(title)…")
        }
        XCTAssertEqual(compiledValue(for: "workdesk.project.empty.title", bundle: bundle), "This project is ready for ideas")
        XCTAssertEqual(compiledValue(for: "workdesk.all.empty.message", bundle: bundle),
            "Capture a thought or add a file below. Move related materials into projects to make room on your desk.")
    }

    /// Both drop titles name the frozen destination; the shared caption keeps
    /// the capture-only promise without contradicting project membership.
    func testTheDropOverlayNamesItsActualDestination() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.capture.all.drop", bundle: bundle), "Drop into Home")
        XCTAssertEqual(compiledValue(for: "workdesk.capture.project.drop", bundle: bundle), "Drop into %@")
        for title in ["Research", "Notes %@ 100%", "旅行"] {
            var label = WorkboardCaptureDestination.project(UUID(), title: title).dropTitle
            label.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: label), "Drop into \(title)")
        }
        XCTAssertEqual(
            compiledValue(for: "workboard.workspace.drop.overlay.caption", bundle: bundle),
            "Files, photos, screenshots, links and text will be added here. Nothing is sent."
        )
    }

    func testTheSpatialLayoutLabelIsDistinctFromTheHomeScope() throws {
        let bundle = try englishAppBundle()
        let scope = compiledValue(for: "workdesk.all", bundle: bundle)
        let layout = compiledValue(for: "workdesk.layout.desk", bundle: bundle)
        XCTAssertEqual(scope, "Home")
        XCTAssertEqual(layout, "Desk")
        XCTAssertNotEqual(layout, scope)
    }

    /// The count asks whether the DESK holds anything; the brief state is a fact
    /// about the project. While one gated the other, creating a project on an
    /// otherwise-empty desk and saving instructions showed nothing at all, and
    /// deleting the desk's last material hid a project's saved instructions.
    func testAProjectReportsItsStateEvenWhenTheDeskHoldsNothingElse() {
        // The whole truth table, so the rule is pinned rather than sampled:
        // exactly one of the eight combinations stays silent.
        for materials in [false, true] {
            for searching in [false, true] {
                for project in [false, true] {
                    let shows = WorkDeskCopy.showsHeaderSubtitle(
                        deskHasMaterials: materials, isSearching: searching, hasProject: project)
                    let expected = materials || searching || project
                    XCTAssertEqual(
                        shows, expected,
                        "materials=\(materials) searching=\(searching) project=\(project)"
                    )
                }
            }
        }

        // The one silent case, named: an empty desk, no project, no query.
        XCTAssertFalse(WorkDeskCopy.showsHeaderSubtitle(
            deskHasMaterials: false, isSearching: false, hasProject: false))
        // The case the bug hid: a project with saved instructions on an empty desk.
        XCTAssertTrue(WorkDeskCopy.showsHeaderSubtitle(
            deskHasMaterials: false, isSearching: false, hasProject: true))
    }

    func testProjectBriefStateReadsAsContentsRatherThanReadiness() throws {
        let bundle = try englishAppBundle()
        let saved = compiledValue(for: "workdesk.project.context.saved", bundle: bundle)
        let none = compiledValue(for: "workdesk.project.context.add", bundle: bundle)

        XCTAssertEqual(saved, "Project context")
        XCTAssertEqual(none, "Add context")
        for value in [saved, none] {
            XCTAssertFalse(value.lowercased().contains("ready"),
                           "readiness needs a reachable gateway and present bytes, which this header cannot know: \(value)")
        }
    }

    private func englishAppBundle() throws -> Bundle {
        // ConduckTests is app-hosted: the production resource must be in the
        // app, never supplied by a test fixture or the test runner's bundle.
        let englishURL = try XCTUnwrap(
            Bundle.main.url(forResource: "en", withExtension: "lproj"),
            "The application must contain its compiled English localization."
        )
        return try XCTUnwrap(Bundle(url: englishURL))
    }

    private func compiledValue(for key: String, bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: missingTranslation, table: "Localizable")
    }

    private func workDeskCatalogKeys() throws -> Set<String> {
        // The source file enumerates scope only. All wording assertions above
        // use compiled bundle resources, so catalog presence cannot pass them.
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        return Set(strings.keys.filter { $0.hasPrefix("workdesk.") })
    }
}
