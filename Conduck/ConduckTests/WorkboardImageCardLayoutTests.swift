// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardImageCardLayoutTests.swift
//
// A picture on the desk should look like the picture, not like a row about a
// picture — but only when there IS a picture to spend the tile on, and only at
// a footprint big enough to caption. These tests hold that decision as pure
// logic, because the alternative is asserting it against a rendered card.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardImageCardLayoutTests: XCTestCase {
    private func mode(
        _ kind: WorkboardMaterialKind,
        thumbnail: Bool,
        _ footprint: WorkMaterialCardSize
    ) -> WorkboardCardArtworkMode {
        WorkboardCardArtworkMode.resolve(
            kind: kind,
            hasThumbnail: thumbnail,
            footprint: footprint
        )
    }

    func testAnImageWithAThumbnailFillsTheStandardAndLargeFootprints() {
        XCTAssertEqual(mode(.image, thumbnail: true, .standard), .imageForward)
        XCTAssertEqual(mode(.image, thumbnail: true, .large), .imageForward)
    }

    /// The smallest tile is a 30pt piece of artwork with one line of name beside
    /// it. A caption over that is unreadable, so the picture stays artwork.
    func testTheSmallFootprintNeverFillsItsTileWithThePicture() {
        for kind in WorkboardMaterialKind.allCases {
            for hasThumbnail in [true, false] {
                XCTAssertEqual(
                    mode(kind, thumbnail: hasThumbnail, .small),
                    .inline,
                    "\(kind) small, thumbnail: \(hasThumbnail)"
                )
            }
        }
    }

    /// The regression this guards: an image card whose bytes never produced a
    /// preview would otherwise draw an empty tile with a caption floating over
    /// nothing. It keeps the glyph layout instead.
    func testAnImageWithoutAThumbnailKeepsTheTextLayoutAtEveryFootprint() {
        for footprint in WorkMaterialCardSize.allCases {
            XCTAssertEqual(mode(.image, thumbnail: false, footprint), .inline, "\(footprint)")
        }
    }

    /// A note carrying preview bytes is still a note. Only `.image` may spend
    /// its tile on a picture, so no other kind can be pulled image-forward by a
    /// thumbnail arriving on its row.
    func testNoOtherKindGoesImageForwardEvenWithThumbnailBytes() {
        for kind in WorkboardMaterialKind.allCases where kind != .image {
            for footprint in WorkMaterialCardSize.allCases {
                XCTAssertEqual(
                    mode(kind, thumbnail: true, footprint),
                    .inline,
                    "\(kind) \(footprint)"
                )
            }
        }
    }

    /// Every kind × thumbnail × footprint combination, against the rule stated
    /// once: a kind or a footprint added later cannot slip through with an
    /// accidental verdict.
    func testTheWholeKindThumbnailFootprintMatrixMatchesTheStatedRule() {
        var checked = 0
        for kind in WorkboardMaterialKind.allCases {
            for hasThumbnail in [true, false] {
                for footprint in WorkMaterialCardSize.allCases {
                    let isImageForward = kind == .image
                        && hasThumbnail
                        && footprint != .small
                    XCTAssertEqual(
                        mode(kind, thumbnail: hasThumbnail, footprint),
                        isImageForward ? .imageForward : .inline,
                        "\(kind) \(footprint) thumbnail: \(hasThumbnail)"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertEqual(
            checked,
            WorkboardMaterialKind.allCases.count * 2 * WorkMaterialCardSize.allCases.count
        )
    }

    /// `resolve` is asked about the footprint the mosaic GRANTED, never the
    /// stored choice: a `large` card the grid clamped to a standard slot must
    /// caption a standard tile, and a clamped card and a truly standard one are
    /// therefore the same question with the same answer.
    func testTheGrantedFootprintIsWhatDecides() {
        XCTAssertEqual(
            mode(.image, thumbnail: true, .standard),
            mode(.image, thumbnail: true, .large)
        )
        XCTAssertNotEqual(
            mode(.image, thumbnail: true, .small),
            mode(.image, thumbnail: true, .standard)
        )
    }
}
