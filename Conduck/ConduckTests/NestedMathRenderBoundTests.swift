// SPDX-License-Identifier: Apache-2.0

// Conduck — deeply nested LaTeX must never hang the reply surface.
//
// THE FAILURE THIS EXISTS FOR: SwiftUIMath's typesetter nests a display node per
// grouping level and its cost grows at roughly `O(n^2.7)` in nesting depth. That
// cost is paid inside `sizeThatFits` during SwiftUI layout — i.e. ON THE MAIN
// THREAD — so an expensive expression is not a slow draw, it is an unrecoverable
// beachball on a reply the user cannot dismiss. Reply text is attacker-chosen
// (the agent writes it, and the agent reads whatever the user's tools fed it), so
// the depth is attacker-chosen too.
//
// THE CONTRACT: render, or fall back to the plain code block that shows the
// source. Either is a pass. Only a hang is a failure.
//
// WHERE THE BOUND LIVES: not in the app. `StructuredText` is Textual's, and the
// gate is `MathComplexity.isWithinBudget`, consulted at the ONE reachable math
// entry point — the ` ```math ` fence case in `BlockContent`. Over budget falls
// through to `CodeBlock`. Conduck never enables the `$…$` syntax extension
// (`StructuredText(markdown:)` defaults `syntaxExtensions: []` and the app passes
// none), so the fence is the whole live surface. The fork is pinned by REVISION
// for exactly this reason; `testTheTextualDependencyIsPinnedByRevision` keeps a
// floating pin from quietly reintroducing an unbounded typesetter.
//
// WHY BOTH A PREDICATE TEST AND A RENDER TEST: the predicate tests are pure and
// instant and pin the SHAPE of the decision (accepted vs refused) at the exact
// boundary. They cannot see the wiring — a `BlockContent` that stopped consulting
// the budget would leave every one of them green. The render tests drive the real
// `StructuredText` through `ImageRenderer`, which forces the same synchronous
// layout pass the app performs, and assert BOTH that it finishes inside a budget
// and that the pixels it produced are the ones the contract calls for.
//
// TIME BUDGET: 5 s per render, matching `FileTransferOutputDetectorTests`.
// Deliberately loose — the point is to catch a return to superlinear cost, not to
// benchmark.
//
// WHICH ASSERTION DOES THE WORK, measured by removing the bound and re-running:
//   - Bare `{` nesting is CHEAP to typeset (2000 levels lay out in 0.03 s), so on
//     those payloads only the SHAPE comparison catches an unbounded renderer. The
//     time assertion beside it is a free tripwire, not the guard.
//   - `\left(…\right)` is the shape the fork profiled and is where the cost is.
//     Unbounded, 640 levels does not overrun the budget — it TERMINATES THE TEST
//     HOST (the typesetter recurses per level and exhausts the stack). A crashed
//     test is a failed test, so that payload bites hardest of all, but it bites as
//     a crash rather than an assertion, which is worth knowing before reading a
//     red run.
// Both kinds are present deliberately: the shape assertions fail cleanly and say
// what broke, and the deep `\left(` payloads prove the failure is not cosmetic.

import Foundation
import SwiftUI
import XCTest
@testable import Conduck
@testable import Textual

@MainActor
final class NestedMathRenderBoundTests: XCTestCase {

    /// Generous on purpose: loose enough to survive a loaded machine, tight
    /// enough that a return to `O(n^2.7)` cannot hide under it.
    private let renderBudget: TimeInterval = 5.0

    // MARK: - Adversarial payloads

    /// `{{{…x…}}}` — one byte per level, so this reaches a depth the LENGTH cap
    /// would otherwise cut off first. The only payload here that isolates the
    /// DEPTH cap on its own.
    private func nestedBraces(depth: Int) -> String {
        String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth)
    }

    /// `\sqrt{\sqrt{…}}` — 7 bytes per level. Real notation, nested absurdly.
    private func nestedSqrt(depth: Int) -> String {
        String(repeating: "\\sqrt{", count: depth) + "x" + String(repeating: "}", count: depth)
    }

    /// `\left(…\right)` — the exact shape the fork measured at `O(n^2.7)`.
    /// 13 bytes per level, so past ~315 levels it trips the LENGTH cap first.
    private func nestedLeftRight(depth: Int) -> String {
        String(repeating: "\\left(", count: depth) + "x" + String(repeating: "\\right)", count: depth)
    }

    private func mathFence(_ latex: String) -> String { "```math\n\(latex)\n```" }

    /// The same body in a fence the math path can never claim — the reference for
    /// "fell back to a plain code block".
    private func plainFence(_ body: String) -> String { "```text\n\(body)\n```" }

    /// The house timing idiom (`ReplySanitizerLinkScannerTests`,
    /// `FileTransferOutputDetectorTests`): a wall-clock delta, not `measure`.
    private func timing(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    // MARK: - The decision: what is accepted, what is refused

    func testConventionalNotationIsAlwaysTypeset() {
        let real = [
            "\\frac{1}{2}",
            "\\sqrt{x^2 + y^2}",
            "\\left(\\frac{a}{b}\\right)^{2}",
            "\\begin{matrix} 1 & 2 \\\\ 3 & 4 \\end{matrix}",
            "\\int_{0}^{\\infty} e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
            nestedSqrt(depth: 10),
        ]
        for latex in real {
            XCTAssertTrue(
                MathComplexity.isWithinBudget(latex),
                "the budget is meant to reject only expressions built to be expensive; it just refused ordinary notation"
            )
        }
    }

    /// Ceiling acceptance — the boundary has to be inclusive, or the cap is
    /// silently one level tighter than it says.
    func testAnExpressionExactlyAtTheDepthCapIsStillTypeset() {
        XCTAssertTrue(MathComplexity.isWithinBudget(nestedBraces(depth: MathComplexity.maxNestingDepth)))
    }

    func testNestingPastTheCapIsRefusedAtEveryScale() {
        for depth in [MathComplexity.maxNestingDepth + 1, 128, 512, 2000] {
            XCTAssertFalse(
                MathComplexity.isWithinBudget(nestedBraces(depth: depth)),
                "depth \(depth) must be refused so the fence degrades to source instead of typesetting for seconds on the main thread"
            )
        }
    }

    /// Depth bounds the growth rate; length bounds the constant. A wide, shallow
    /// expression is expensive too.
    func testAnOverlongButShallowExpressionIsRefused() {
        let shallow = String(repeating: "x + ", count: 2000) + "x"
        XCTAssertGreaterThan(shallow.utf8.count, MathComplexity.maxSourceLength, "fixture")
        XCTAssertFalse(MathComplexity.isWithinBudget(shallow))
    }

    /// The obvious way to smuggle depth past a naive counter: open with a run of
    /// stray closers so the depth counter goes negative and buys headroom.
    func testStrayClosersCannotBuyDepthHeadroom() {
        let smuggled = String(repeating: "}", count: 1000)
            + nestedBraces(depth: MathComplexity.maxNestingDepth + 1)
        XCTAssertFalse(MathComplexity.isWithinBudget(smuggled))
    }

    /// `\{` is a brace GLYPH, not a group — counting it as depth would reject
    /// legitimate notation.
    func testEscapedBracesAreGlyphsNotDepth() {
        let glyphs = String(repeating: "\\{", count: 500) + String(repeating: "\\}", count: 500)
        XCTAssertLessThan(glyphs.utf8.count, MathComplexity.maxSourceLength, "fixture: inside the length budget")
        XCTAssertTrue(MathComplexity.isWithinBudget(glyphs))
    }

    /// The guard must not become the cost it prevents.
    func testTheBudgetCheckItselfIsLinear() {
        let hostile = String(repeating: "\\left(", count: 200_000)
        let elapsed = timing { _ = MathComplexity.isWithinBudget(hostile) }
        XCTAssertLessThan(
            elapsed, 2.0,
            "the budget check took \(elapsed)s over 1.2 MB — it runs inside `body`, so it has to be a single linear scan"
        )
    }

    /// A sanity floor on the constants themselves. Not an exact-value pin (the
    /// fork may legitimately retune), but a cap raised to something that no longer
    /// bounds anything is the regression this whole file exists to catch.
    func testTheBudgetConstantsStillBoundSomething() {
        XCTAssertGreaterThan(MathComplexity.maxNestingDepth, 8, "too tight to render real notation")
        XCTAssertLessThanOrEqual(
            MathComplexity.maxNestingDepth, 256,
            "at O(n^2.7) a cap this high stops bounding the main-thread cost"
        )
        XCTAssertLessThanOrEqual(MathComplexity.maxSourceLength, 65_536)
    }

    // MARK: - The real render path

    /// One synchronous layout+draw of the app's actual reply surface. Returns the
    /// raster so the SHAPE of the outcome can be compared, not merely its timing.
    private func snapshot(_ markdown: String) -> (width: Int, height: Int, bytes: Data)? {
        let renderer = ImageRenderer(
            content: StructuredText(markdown: markdown)
                .appliesUntrustedMarkdownPolicy()
                .frame(width: 320, alignment: .leading)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let provider = image.dataProvider,
              let data = provider.data else { return nil }
        return (image.width, image.height, data as Data)
    }

    /// POSITIVE CONTROL for every shape assertion below. If a typeset expression
    /// and a plain code block rastered the same, "fell back to a code block" would
    /// be unfalsifiable and the fallback assertions would pass vacuously.
    func testAnInBudgetFenceTypesetsAndDoesNotLookLikeACodeBlock() throws {
        let latex = "\\frac{1}{2}"
        let math = try XCTUnwrap(
            snapshot(mathFence(latex)),
            "ImageRenderer produced no raster — this harness cannot observe the render path at all, so every shape assertion in this file is meaningless."
        )
        let plain = try XCTUnwrap(snapshot(plainFence(latex)))

        XCTAssertNotEqual(
            math.bytes, plain.bytes,
            "an in-budget `math` fence must actually typeset. If it rasters the same as a `text` fence, math rendering is off entirely and the fallback assertions below prove nothing."
        )
    }

    /// The depth cap, through the real view. 2000 levels inside the length budget,
    /// so this is the DEPTH cap on its own — the case the fork measured as taking
    /// tens of seconds unbounded.
    func testDeeplyNestedMathFallsBackToTheSourceWithinTheTimeBudget() throws {
        let latex = nestedBraces(depth: 2000)
        XCTAssertLessThan(latex.utf8.count, MathComplexity.maxSourceLength,
                          "fixture: inside the LENGTH budget, so only depth can refuse it")

        var math: (width: Int, height: Int, bytes: Data)?
        let elapsed = timing { math = self.snapshot(self.mathFence(latex)) }

        XCTAssertLessThan(
            elapsed, renderBudget,
            "2000 nesting levels took \(elapsed)s to lay out. Unbounded, this measured in the tens of seconds — and it is paid in `sizeThatFits` on the main thread, so the user sees a beachball on a reply they cannot dismiss."
        )
        let rendered = try XCTUnwrap(math)
        let plain = try XCTUnwrap(snapshot(plainFence(latex)))
        XCTAssertEqual(
            rendered.bytes, plain.bytes,
            "an over-budget fence must degrade to the plain code block that shows the source — not typeset, and not vanish"
        )
    }

    /// The length cap, through the real view: 640 `\left(…\right)` levels is
    /// 8 321 bytes, over the source-length budget.
    func testAnOverlongMathFenceFallsBackToTheSourceWithinTheTimeBudget() throws {
        let latex = nestedLeftRight(depth: 640)
        XCTAssertGreaterThan(latex.utf8.count, MathComplexity.maxSourceLength, "fixture")

        var math: (width: Int, height: Int, bytes: Data)?
        let elapsed = timing { math = self.snapshot(self.mathFence(latex)) }

        XCTAssertLessThan(elapsed, renderBudget, "an over-length fence took \(elapsed)s to lay out")
        let rendered = try XCTUnwrap(math)
        let plain = try XCTUnwrap(snapshot(plainFence(latex)))
        XCTAssertEqual(rendered.bytes, plain.bytes, "over the length budget the fence shows its source")
    }

    /// The staircase, on the shape that actually costs. Ramping `{` depth proves
    /// nothing about cost — measured unbounded, 2000 levels of bare braces lay out
    /// in 0.03 s, so only the SHAPE assertions above catch that regression.
    /// `\left(…\right)` is the shape the fork profiled, and it is where the cost
    /// lives: unbounded, the 640-level entry below does not merely exceed this
    /// budget, it terminates the process outright (the typesetter recurses per
    /// level and blows the stack).
    func testRenderCostDoesNotClimbWithNestingDepth() throws {
        for depth in [8, 64, 128, 320, 640] {
            let latex = nestedLeftRight(depth: depth)
            var rendered: (width: Int, height: Int, bytes: Data)?
            let elapsed = timing { rendered = self.snapshot(self.mathFence(latex)) }

            XCTAssertLessThan(
                elapsed, renderBudget,
                "depth \(depth) took \(elapsed)s — layout cost is climbing with nesting depth again"
            )
            guard depth > MathComplexity.maxNestingDepth else { continue }
            XCTAssertEqual(
                try XCTUnwrap(rendered).bytes, try XCTUnwrap(snapshot(plainFence(latex))).bytes,
                "depth \(depth) is past the cap and must show its source instead of typesetting"
            )
        }
    }

    /// Math inside real prose, not alone in the document: the reply the agent
    /// actually sends has text around the fence, and the surrounding blocks must
    /// still render when the fence degrades.
    func testAnOverBudgetFenceDoesNotTakeTheRestOfTheReplyWithIt() throws {
        let latex = nestedLeftRight(depth: 640)
        func reply(_ fence: String) -> String {
            """
            Here is the derivation you asked for.

            \(fence)

            The second step is where the sign flips.
            """
        }

        var rendered: (width: Int, height: Int, bytes: Data)?
        let elapsed = timing { rendered = self.snapshot(reply(self.mathFence(latex))) }

        XCTAssertLessThan(elapsed, renderBudget, "a whole reply containing an adversarial fence took \(elapsed)s")
        let image = try XCTUnwrap(rendered, "the reply produced no raster at all")
        XCTAssertGreaterThan(image.height, 0, "the surrounding prose must still render")
        XCTAssertEqual(
            image.bytes, try XCTUnwrap(snapshot(reply(plainFence(latex)))).bytes,
            "the adversarial fence must degrade to its source with the prose around it untouched"
        )
    }

    // MARK: - The pin
    //
    // The bound is in the dependency, so the dependency has to be pinned to a
    // revision that HAS it. A version range, or a branch, can float onto upstream
    // — where the typesetter is unbounded — without a single source change.

    /// `.../Conduck/Conduck` — the Xcode project container.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// What a `Package.resolved` pin entry is allowed to be. Split out as a pure
    /// classifier so it can be exercised against synthetic fixtures — the same
    /// shape `MarkdownAttachmentPolicyDriftGuardTests` uses for its scanner. The
    /// real file cannot serve as the negative case: SwiftPM refuses to resolve a
    /// version-shaped pin at all when the project requires a revision, and it
    /// rewrites the file on the next resolve, so a mutation there fails the BUILD
    /// instead of this assertion.
    enum PinVerdict: Equatable {
        case pinnedByRevision
        case missing
        case pinnedByVersion
        case abbreviatedRevision
    }

    func classifyTextualPin(_ pins: [[String: Any]]) -> PinVerdict {
        guard let textual = pins.first(where: { ($0["identity"] as? String)?.lowercased() == "textual" }),
              let state = textual["state"] as? [String: Any] else { return .missing }
        if state["version"] != nil { return .pinnedByVersion }
        guard let revision = state["revision"] as? String else { return .missing }
        return revision.count == 40 ? .pinnedByRevision : .abbreviatedRevision
    }

    // MARK: The classifier's own coverage — synthetic fixtures, not the real file.

    func testThePinClassifierAcceptsAFullRevisionPin() {
        XCTAssertEqual(
            classifyTextualPin([["identity": "textual",
                                 "state": ["revision": String(repeating: "a", count: 40)]]]),
            .pinnedByRevision
        )
    }

    func testThePinClassifierRejectsAVersionPin() {
        XCTAssertEqual(
            classifyTextualPin([["identity": "textual",
                                 "state": ["version": "0.9.0",
                                           "revision": String(repeating: "a", count: 40)]]]),
            .pinnedByVersion,
            "a version pin resolves to whatever that tag points at — upstream, where the typesetter is unbounded"
        )
    }

    func testThePinClassifierRejectsAnAbbreviatedRevision() {
        XCTAssertEqual(
            classifyTextualPin([["identity": "textual", "state": ["revision": "380a7db"]]]),
            .abbreviatedRevision
        )
    }

    func testThePinClassifierReportsAMissingDependency() {
        XCTAssertEqual(classifyTextualPin([["identity": "swift-nio", "state": ["revision": "x"]]]), .missing)
    }

    func testTheTextualDependencyIsPinnedByRevision() throws {
        let resolved = projectContainerURL()
            .appendingPathComponent("Conduck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let data = try? Data(contentsOf: resolved) else {
            throw XCTSkip("Package.resolved unreadable at \(resolved.path) — this guard runs against a checkout only.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = root["pins"] as? [[String: Any]] else {
            return XCTFail("Package.resolved is not the shape this guard expects — re-point it before trusting it.")
        }

        XCTAssertEqual(
            classifyTextualPin(pins), .pinnedByRevision,
            "The math typesetting bound lives only on the GigaDuckAI fork, so the pin has to name the exact commit that carries it. If the fork was dropped, drop this guard with it — but the bound goes too."
        )
    }
}
