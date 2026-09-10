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
            "workdesk.desk": "Your desk",
            "workdesk.all": "All materials",
            "workdesk.pinned": "Pinned",
            "workdesk.projects": "Projects",
            "workdesk.search": "Find an idea or file",
            "workdesk.select": "Select",
            "workdesk.select.all": "Select all",
            "workdesk.layout.desk": "Desk",
            "workdesk.group": "Create project",
            "workdesk.move": "Move to",
            "workdesk.prepare": "Prepare",
            "workdesk.brief.title": "Project brief",
            "workdesk.brief.chooseAI": "Choose your AI",
            "workdesk.brief.reviewButton": "Review handoff",
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

    func testUpdatedTutorialDescribesArrangementAndReviewedHandoff() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(
            compiledValue(for: "workboard.tutorial.point.arrange", bundle: bundle),
            "Drag anywhere on a card to arrange it. Hold it over another idea to create a project, or use Select."
        )
        XCTAssertEqual(
            compiledValue(for: "workdesk.tutorial.prepare", bundle: bundle),
            "Shape a project brief, choose your AI, then review before sending."
        )
    }

    func testProjectCaptureNamesItsActualDestinationInTheCompiledBundle() throws {
        let bundle = try englishAppBundle()
        XCTAssertEqual(compiledValue(for: "workdesk.capture.prompt", bundle: bundle), "Add to your desk…")
        XCTAssertEqual(compiledValue(for: "workdesk.capture.destination.short", bundle: bundle), "Captures go to Your desk")
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
