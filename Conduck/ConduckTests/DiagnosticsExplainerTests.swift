// Conduck
// DiagnosticsExplainerTests.swift
//
// Coverage for the pure Diagnostics helpers: every AppError code maps to a
// non-empty plain-English cause + fix, the opaque/provider-message codes NEVER
// surface reconstructed provider text (privacy), provider IDs normalize to their
// archetype (no UUID/label leak), and every code has a stable copy-report slug.

import XCTest
@testable import Conduck

final class DiagnosticsExplainerTests: XCTestCase {

    /// Every live AppError code (1–62 minus the reserved 27 gap, plus 99).
    private let allCodes: [Int] = Array(1...62).filter { $0 != 27 } + [99]

    // MARK: - explain(code:)

    func testEveryCodeYieldsNonEmptyCauseAndFix() {
        for code in allCodes {
            let (cause, fix) = DiagnosticsExplainer.explain(code: code)
            XCTAssertFalse(cause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "code \(code) produced an empty cause")
            XCTAssertFalse(fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "code \(code) produced an empty fix")
        }
    }

    func testConfigFixableCodesGiveSpecificCause() {
        // A representative config-fixable set should describe the actual problem,
        // not collapse to the generic fallback cause.
        let generic = DiagnosticsExplainer.explain(code: 10).cause  // opaque → generic
        for code in [12, 23, 26, 30, 44, 46, 51] {
            let cause = DiagnosticsExplainer.explain(code: code).cause
            XCTAssertNotEqual(cause, generic, "config code \(code) should have a specific cause")
        }
    }

    /// Privacy guard: opaque / provider-message codes must resolve to the generic
    /// cause — reconstructing them with `message: nil` must never surface live
    /// provider text on screen or in the copy block.
    func testOpaqueCodesUseGenericCause() {
        let generic = DiagnosticsExplainer.explain(code: 99).cause
        for code in [1, 6, 7, 9, 10, 25, 99] {
            XCTAssertEqual(DiagnosticsExplainer.explain(code: code).cause, generic,
                           "opaque code \(code) must use the generic cause, not provider text")
        }
    }

    // MARK: - archetype(forProviderID:)

    func testArchetypeStripsPerUUIDSuffix() {
        XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: "custom-openai_A1B2C3"), "custom-openai")
        XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: "custom-openai-tts_A1B2C3"), "custom-openai-tts")
    }

    func testArchetypePassesThroughBuiltInIDs() {
        for id in ["mistral-voxtral", "apple-on-device", "openrouter-stt", "apple-tts"] {
            XCTAssertEqual(DiagnosticsExplainer.archetype(forProviderID: id), id,
                           "built-in id \(id) has no UUID suffix and must pass through unchanged")
        }
    }

    // MARK: - slug(forCode:)

    func testEveryCodeHasNonEmptyKebabSlug() {
        for code in allCodes {
            let slug = DiagnosticsExplainer.slug(forCode: code)
            XCTAssertFalse(slug.isEmpty, "code \(code) has an empty slug")
            XCTAssertFalse(slug.contains(" "), "slug for code \(code) should be kebab (no spaces): \(slug)")
        }
    }

    func testUnknownCodeSlugFallsBack() {
        XCTAssertEqual(DiagnosticsExplainer.slug(forCode: 1234), "error-1234")
    }
}
