// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardCompanionCardTests.swift
//
// The CARD half of the companion fold: a screenshot that swallowed the
// recording spoken over it has to show that recording, name it, play it, and
// say all of it to VoiceOver — or the fold has hidden a material.
//
// Everything asserted here is a pure rule the card reads rather than a rendered
// tile, for the reason `WorkboardImageCardLayoutTests` states: an image-forward
// card hands VoiceOver no picture at all, so the words ARE the card there, and a
// label built inside a view body cannot be asserted. What is left — where the
// band goes, what it says, which rows the two files offer — is decided by
// `WorkboardCompanionBand` and by `WorkboardCardAccessibility`, so those are
// what the tests drive.
//
// Two things cannot be stated as pure functions and are pinned as source
// guards instead: that the transport is a control OUTSIDE the tile's button (a
// control nested in a button's label never receives the tap, so a band drawn
// inside the tile would be a play button that does nothing), and that every
// surface drawing a recording holds ONE player from the process-wide
// exclusivity registry rather than minting a second one, which is what keeps a
// band from playing over the card beside it.

import Foundation
import SwiftUI
import XCTest
@testable import Conduck

@MainActor
final class WorkboardCompanionCardTests: XCTestCase {

    // MARK: - Fixtures

    private func recording(
        name: String = "Ship the review",
        transcript: String? = "Ship the review before Friday",
        availability: WorkboardMaterialAvailability = .available
    ) -> WorkboardCompanionSnapshot {
        WorkboardCompanionSnapshot(
            WorkboardMaterialSnapshot(
                kind: .audio,
                name: name,
                textContent: transcript,
                byteCount: 2_048,
                availability: availability
            )
        )
    }

    private func picture(
        thumbnail: Bool = true,
        companion: WorkboardCompanionSnapshot? = nil,
        availability: WorkboardMaterialAvailability = .available
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            kind: .image,
            name: "screenshot.jpg",
            thumbnailData: thumbnail ? Data([0x01, 0x02]) : nil,
            byteCount: 120_000,
            availability: availability,
            companion: companion
        )
    }

    // MARK: - Where the band goes

    /// The founder's case, at every footprint the mosaic can hand a picture: the
    /// recording is visible on the card that hid it. The image-forward tile puts
    /// it on the scrim over the photograph; a picture with no thumbnail to fill
    /// itself with puts it in that card's own text column; the smallest tile
    /// has room for the control alone.
    ///
    /// Negative control: a band drawn only in the image-forward branch leaves
    /// the small and thumbnail-less cards with a recording that is on the desk,
    /// hidden, and drawn nowhere — this fails.
    func testAFoldedPictureDrawsItsBandInEveryVariantTheTileCanTake() {
        let folded = picture(companion: recording())

        XCTAssertEqual(WorkboardCompanionBand.placement(for: folded, footprint: .standard), .scrim)
        XCTAssertEqual(WorkboardCompanionBand.placement(for: folded, footprint: .large), .scrim)
        XCTAssertEqual(
            WorkboardCompanionBand.placement(for: folded, footprint: .small), .compact,
            "one grid unit has room for the transport and not for words"
        )

        let previewless = picture(thumbnail: false, companion: recording())
        for footprint in WorkMaterialCardSize.allCases {
            XCTAssertEqual(
                WorkboardCompanionBand.placement(for: previewless, footprint: footprint),
                footprint == .small ? .compact : .inline,
                "\(footprint) without a thumbnail"
            )
        }
    }

    /// The smallest tile is ONE grid unit, and everything a folded card draws
    /// has to fit inside it: a card that overflows does not scroll, it is
    /// clipped, and the band is drawn ON the tile, so what overflows ends up
    /// hidden BEHIND the band rather than merely cut off. The picture's own name
    /// and its availability glyph are what would go.
    ///
    /// That unit is not one number. The four-column grid a compact board
    /// settles on hands out 81 points at width 360, 71 at 320 and 64 at 292 —
    /// the last width before it gives way to two columns — so the budget is
    /// asserted at every width and every type size the engine can be asked
    /// for, through the placement the card actually draws and against the same
    /// `unitSize(forWidth:)` the card reads.
    ///
    /// Negative control: with the compact branch off, the small tile draws the
    /// strip band the other footprints use standing on the stacked
    /// thumbnail-and-name body — ~116 points inside a tile of 64 to 81 — so the
    /// placement flips and every width in the sweep fails.
    func testAFoldedSmallCardFitsEveryGridUnitTheMosaicCanGrantIt() throws {
        let folded = picture(companion: recording())
        let placement = try XCTUnwrap(
            WorkboardCompanionBand.placement(for: folded, footprint: .small)
        )

        // The four-column grid's whole range, its floor included: a small card
        // is one of these units and nothing else.
        for (width, unit) in [(CGFloat(360), CGFloat(81)), (320, 71), (292, 64)] {
            XCTAssertEqual(
                WorkboardMosaicEngine().unitSize(forWidth: width).height,
                unit,
                accuracy: 0.5,
                "the grid unit at width \(width)"
            )
        }

        for dynamicTypeSize in DynamicTypeSize.allCases {
            let engine = WorkboardMosaicEngine(metrics: .scaled(for: dynamicTypeSize))
            for width in stride(from: CGFloat(240), through: 1_400, by: 4) {
                let unit = engine.unitSize(forWidth: width).height
                // The card and the grid read ONE unit: a card sized from a
                // second arithmetic would fit a tile nothing draws.
                XCTAssertEqual(
                    unit,
                    engine.place(spans: [.small], availableWidth: width).unitSize.height,
                    accuracy: 0.001,
                    "width \(width), \(dynamicTypeSize)"
                )
                XCTAssertLessThanOrEqual(
                    WorkboardCompanionBand.foldedHeight(drawing: placement, inTileOfHeight: unit),
                    unit,
                    "a folded small card asks for more tile than the mosaic grants it "
                        + "at width \(width), \(dynamicTypeSize)"
                )
            }
        }
    }

    /// The compact sizes are a CEILING, not a promise: the reference unit draws
    /// them as designed, a wider board draws no bigger — a 46-point transport
    /// beside neighbours drawn at 26 — and a narrower one genuinely shrinks,
    /// which is what makes the budget above hold rather than merely pass.
    func testTheCompactDrawingShrinksWithTheTileAndNeverGrowsPastIt() {
        let reference = WorkboardCompanionBand.compactMetrics(
            forTileHeight: WorkboardCompanionBand.referenceUnitHeight
        )
        XCTAssertEqual(reference.transport, WorkboardCompanionBand.compactTransport)
        XCTAssertEqual(reference.artwork, WorkboardCompanionBand.compactArtwork)
        XCTAssertEqual(reference.inset, WorkboardCompanionBand.compactInset)
        XCTAssertEqual(reference.bandPadding, WorkboardCompanionBand.compactBandPadding)
        XCTAssertEqual(
            WorkboardCompanionBand.compactMetrics(forTileHeight: 144), reference,
            "a wide board draws the same control, never a bigger one"
        )

        let narrow = WorkboardCompanionBand.compactMetrics(forTileHeight: 64)
        XCTAssertLessThan(narrow.transport, reference.transport)
        XCTAssertLessThan(narrow.artwork, reference.artwork)
        XCTAssertLessThanOrEqual(narrow.foldedHeight, 64)

        // A card the layout has not measured yet draws the reference rather
        // than collapsing to nothing.
        for unmeasured in [CGFloat(0), -12, .nan, .infinity] {
            XCTAssertEqual(
                WorkboardCompanionBand.compactMetrics(forTileHeight: unmeasured), reference,
                "\(unmeasured)"
            )
        }
    }

    /// A picture with no recording draws no band anywhere, and neither does any
    /// other kind: the band is a consequence of the fold, never of the layout.
    func testAPlainCardDrawsNoBand() {
        for footprint in WorkMaterialCardSize.allCases {
            XCTAssertNil(WorkboardCompanionBand.placement(for: picture(), footprint: footprint))
            for kind in WorkboardMaterialKind.allCases {
                XCTAssertNil(
                    WorkboardCompanionBand.placement(
                        for: WorkboardMaterialSnapshot(kind: kind, name: "x"),
                        footprint: footprint
                    ),
                    "\(kind) \(footprint)"
                )
            }
        }
    }

    /// The band follows the tile it is drawn on, which is the footprint the
    /// mosaic GRANTED: a `large` card clamped into a standard slot draws the
    /// standard tile, so it draws the standard band.
    func testTheGrantedFootprintDecidesTheBandJustAsItDecidesTheTile() {
        let folded = picture(companion: recording())
        XCTAssertEqual(
            WorkboardCompanionBand.placement(for: folded, footprint: .standard),
            WorkboardCompanionBand.placement(for: folded, footprint: .large)
        )
        XCTAssertNotEqual(
            WorkboardCompanionBand.placement(for: folded, footprint: .small),
            WorkboardCompanionBand.placement(for: folded, footprint: .standard)
        )
    }

    // MARK: - What the band says

    /// The band is not a second naming path: it shows the title the recording's
    /// own card showed, which the publication lane already set to the
    /// transcript's lead line.
    func testTheBandNamesTheRecordingExactlyAsItsOwnCardDid() {
        XCTAssertEqual(
            WorkboardCompanionBand.title(for: recording(name: "Ship the review")),
            "Ship the review"
        )
    }

    /// A recording whose words never arrived — pending, or a failed
    /// transcription — keeps the placeholder its own card carried rather than
    /// showing an empty band.
    func testARecordingWithNoNameYetKeepsThePlaceholderItsOwnCardCarried() {
        let placeholder = String(localized: LocalizedStringResource(
            "workboard.voice.recording.untitled",
            defaultValue: "Voice note"
        ))
        XCTAssertEqual(WorkboardCompanionBand.title(for: recording(name: "   ")), placeholder)
        XCTAssertEqual(WorkboardCompanionBand.title(for: recording(name: "")), placeholder)
    }

    /// The words under the name are the transcript, and nothing at all when
    /// there is no transcript: the recording is the material and the words are
    /// an extra, exactly as on the standalone card.
    func testTheTranscriptIsTheWordsAndNothingWhenThereAreNone() {
        XCTAssertEqual(
            WorkboardCompanionBand.transcript(for: recording(transcript: " Ship it \n")),
            "Ship it"
        )
        XCTAssertNil(WorkboardCompanionBand.transcript(for: recording(transcript: nil)))
        XCTAssertNil(WorkboardCompanionBand.transcript(for: recording(transcript: "   \n ")))
    }

    /// The smallest tile has one line of name and a 30pt piece of artwork, so
    /// it carries no transcript at all; the large tile spends its height on the
    /// words.
    func testTheTranscriptBudgetGrowsWithTheFootprint() {
        XCTAssertNil(WorkboardCompanionBand.transcriptLineLimit(for: .small))
        XCTAssertEqual(WorkboardCompanionBand.transcriptLineLimit(for: .standard), 2)
        XCTAssertEqual(WorkboardCompanionBand.transcriptLineLimit(for: .large), 6)
    }

    // MARK: - What the card SAYS

    /// The spoken card names both halves and then reads the words. An
    /// image-forward tile shows VoiceOver a photograph and a hidden transport,
    /// so this label is the only place the recording exists for it.
    ///
    /// Negative control: leaving the summary keyed on `material.kind` announces
    /// "Image. screenshot.jpg" and never mentions the recording — this fails.
    func testTheSpokenCardNamesTheScreenshotAndCarriesTheWords() {
        let summary = WorkboardCardAccessibility.summary(
            material: picture(companion: recording(transcript: "Ship the review before Friday")),
            boardPosition: 1,
            boardCount: 3
        )

        XCTAssertTrue(
            summary.contains(String(localized: WorkboardCompanionBand.accessibilityKindLabel)),
            summary
        )
        XCTAssertTrue(summary.contains("screenshot.jpg"), summary)
        XCTAssertTrue(summary.contains("Ship the review before Friday"), summary)
        XCTAssertTrue(summary.contains(WorkboardCardAccessibility.boardPositionLabel(
            position: 1, count: 3
        )), summary)
    }

    /// With no transcript yet, the card still says what the recording is called
    /// rather than falling silent about it.
    func testTheSpokenCardFallsBackToTheRecordingsNameWhenThereAreNoWords() {
        let summary = WorkboardCardAccessibility.summary(
            material: picture(companion: recording(name: "Ship it", transcript: nil)),
            boardPosition: 0,
            boardCount: 0
        )
        XCTAssertTrue(summary.contains("Ship it"), summary)
    }

    /// A picture with no recording is unchanged: it still announces its kind.
    func testAPlainPictureStillAnnouncesItsOwnKind() {
        let summary = WorkboardCardAccessibility.summary(
            material: picture(),
            boardPosition: 0,
            boardCount: 0
        )
        XCTAssertTrue(summary.contains(String(localized: WorkboardMaterialKind.image.title)), summary)
        XCTAssertFalse(
            summary.contains(String(localized: WorkboardCompanionBand.accessibilityKindLabel)),
            summary
        )
    }

    /// What the card says the RECORDING is doing, which is the only place a
    /// folded tile can say it: the band is accessibility-hidden — its transport
    /// is a control drawn beside an element whose children are ignored — so a
    /// refusal reaches VoiceOver here or nowhere.
    ///
    /// Negative control: with no value, a failed decode and an output another
    /// capture already holds both re-offer "Play Recording" and say nothing
    /// about why it did not start — the two assertions below fail.
    func testTheSpokenCardStatesWhyTheRecordingRefusedToPlay() {
        let failed = WorkboardCompanionBand.accessibilityValue(
            for: recording(),
            phase: .failed,
            elapsed: 0,
            duration: 0
        )
        XCTAssertEqual(failed, String(localized: LocalizedStringResource(
            "workboard.audio.failed",
            defaultValue: "This recording couldn’t be played"
        )), failed)

        let blocked = WorkboardCompanionBand.accessibilityValue(
            for: recording(),
            phase: .blocked,
            elapsed: 0,
            duration: 0
        )
        XCTAssertEqual(blocked, String(localized: LocalizedStringResource(
            "workboard.audio.busy",
            defaultValue: "Audio is in use right now"
        )), blocked)
    }

    /// The clock is a fact only a decoded clip has, and it is the recording's
    /// OWN availability that is spoken — the picture being readable here says
    /// nothing about where the audio's bytes are.
    func testTheSpokenCardCarriesTheClockOnlyOnceAClipHasLoaded() {
        let idle = WorkboardCompanionBand.accessibilityValue(
            for: recording(),
            phase: .idle,
            elapsed: 0,
            duration: 0
        )
        XCTAssertEqual(idle, "", "an idle, readable recording is doing nothing worth saying")

        let playing = WorkboardCompanionBand.accessibilityValue(
            for: recording(),
            phase: .playing,
            elapsed: 3,
            duration: 12
        )
        XCTAssertTrue(playing.contains(String(localized: LocalizedStringResource(
            "workboard.audio.playing",
            defaultValue: "Playing"
        ))), playing)
        XCTAssertTrue(
            playing.contains(WorkboardAudioTransport.clockText(elapsed: 3, duration: 12)),
            playing
        )

        let away = WorkboardCompanionBand.accessibilityValue(
            for: recording(availability: .unavailableOnThisDevice),
            phase: .idle,
            elapsed: 0,
            duration: 0
        )
        XCTAssertEqual(away, String(localized: WorkboardCardAccessibility.availabilityLabel(
            for: .unavailableOnThisDevice
        )), away)
    }

    // MARK: - What the card OFFERS

    /// Everything the recording's own card could do, from the card that folded
    /// it: play it, open it, share it. Each row acts on the recording alone,
    /// through the single-material routes it already had.
    func testTheFoldedCardOffersPlayOpenAndShareForTheRecordingItself() {
        let actions = WorkboardCompanionBand.actions(
            for: recording(),
            phase: .idle,
            hasOpenRecording: true,
            hasShareRecording: true
        )
        XCTAssertEqual(actions, [.play, .openRecording, .shareRecording])
    }

    /// The transport row states what the NEXT activation does, including the
    /// loading phase, where it cancels the payload read rather than playing.
    func testTheTransportRowStatesWhatTheNextActivationDoes() {
        func transportRow(_ phase: WorkboardAudioPhase) -> WorkboardCompanionAction? {
            WorkboardCompanionBand.actions(
                for: recording(),
                phase: phase,
                hasOpenRecording: false,
                hasShareRecording: false
            ).first
        }
        XCTAssertEqual(transportRow(.idle), .play)
        XCTAssertEqual(transportRow(.paused), .play)
        XCTAssertEqual(transportRow(.failed), .play)
        XCTAssertEqual(transportRow(.blocked), .play)
        XCTAssertEqual(transportRow(.playing), .pause)
        XCTAssertEqual(transportRow(.loading), .cancelLoading)
    }

    /// A row the board never wired is not offered: the card never names an
    /// action it cannot perform.
    func testRowsTheBoardDidNotWireAreNotOffered() {
        XCTAssertEqual(
            WorkboardCompanionBand.actions(
                for: recording(),
                phase: .idle,
                hasOpenRecording: false,
                hasShareRecording: false
            ),
            [.play]
        )
    }

    /// The RECORDING's availability decides its rows. A screenshot that is
    /// readable here says nothing about whether the audio's bytes arrived, and
    /// a card that asked the picture would offer playback over nothing.
    ///
    /// Negative control: gating on `material.availability` offers play, open and
    /// share for a recording still arriving from iCloud — this fails.
    func testTheRecordingsOwnAvailabilityDecidesItsRows() {
        for availability in [WorkboardMaterialAvailability.syncPending, .unavailableOnThisDevice] {
            XCTAssertEqual(
                WorkboardCompanionBand.actions(
                    for: recording(availability: availability),
                    phase: .idle,
                    hasOpenRecording: true,
                    hasShareRecording: true
                ),
                [],
                "\(availability)"
            )
        }
        XCTAssertEqual(
            WorkboardCompanionBand.actions(
                for: recording(availability: .localOnly),
                phase: .idle,
                hasOpenRecording: true,
                hasShareRecording: true
            ),
            [.play, .openRecording, .shareRecording]
        )
    }

    /// Folding must not cost the recording its repair. A recording whose local
    /// bytes are gone keeps the route back that its own card had — and the
    /// picture's Reattach is not it, because that replaces the screenshot.
    ///
    /// Negative control: dropping the row leaves a folded card whose only
    /// repair replaces the wrong file — this fails.
    func testAMissingRecordingKeepsItsOwnRepairRoute() {
        XCTAssertEqual(
            WorkboardCompanionBand.actions(
                for: recording(availability: .unavailableOnThisDevice),
                phase: .idle,
                hasOpenRecording: true,
                hasShareRecording: true,
                hasReattachRecording: true
            ),
            [.reattachRecording],
            "missing bytes are repaired, never opened or shared"
        )
        // Bytes that are simply still arriving are not something to repair, and
        // readable bytes need no repair at all.
        for availability in [WorkboardMaterialAvailability.syncPending, .available, .localOnly] {
            XCTAssertFalse(
                WorkboardCompanionBand.actions(
                    for: recording(availability: availability),
                    phase: .idle,
                    hasOpenRecording: true,
                    hasShareRecording: true,
                    hasReattachRecording: true
                ).contains(.reattachRecording),
                "\(availability)"
            )
        }
    }

    /// A folded card holds two files, so its Share row has to say which one
    /// leaves; an ordinary card keeps the unqualified word.
    func testTheShareRowSaysWhichOfTheTwoFilesLeaves() {
        let folded = String(localized: WorkboardCompanionBand.shareTitle(hasCompanion: true))
        let plain = String(localized: WorkboardCompanionBand.shareTitle(hasCompanion: false))
        XCTAssertNotEqual(folded, plain)
        XCTAssertFalse(folded.isEmpty)
        XCTAssertFalse(plain.isEmpty)
    }

    /// Four rows, four distinct sentences: a person choosing between "Open
    /// Recording" and the picture's own "Open" must be able to hear the
    /// difference.
    func testEveryCompanionRowIsNamedDistinctly() {
        let titles = [
            WorkboardCompanionAction.play,
            .pause,
            .openRecording,
            .shareRecording,
            .reattachRecording
        ].map { String(localized: WorkboardCompanionBand.title(for: $0)) }
        XCTAssertEqual(Set(titles).count, titles.count, "\(titles)")
        for title in titles {
            XCTAssertFalse(title.isEmpty)
            XCTAssertNotEqual(
                title,
                String(localized: LocalizedStringResource(
                    "workboard.material.share",
                    defaultValue: "Share"
                ))
            )
        }
    }

    // MARK: - Source guards

    private static let canvasPath = "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"
    private static let rowPath = "Conduck/Views/Workboard/WorkboardMaterialListRow.swift"
    private static let audioPath = "Conduck/Views/Workboard/WorkboardAudioCardView.swift"

    /// The brace-matched body of a computed property. `RefusalLaneSource` can
    /// scope an assertion to a `func`; a SwiftUI card is mostly properties, and
    /// an unscoped `contains` over a 2,000-line view is satisfied by anything.
    private func propertyBody(named name: String, in source: String) throws -> String {
        let declaration = try XCTUnwrap(
            source.range(of: "var \(name): some View {"),
            "no `var \(name): some View` — update this guard"
        )
        var index = declaration.upperBound
        let start = index
        var depth = 1
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    /// THE structural rule of the band: its transport is a sibling of the tile,
    /// never content inside it. A control nested in a `Button`'s label does not
    /// receive the tap, so a band drawn inside the tile would be a play button
    /// that silently opens the gallery instead.
    func testTheBandIsDrawnOutsideTheTilesButton() throws {
        let source = try RefusalLaneSource.source(at: Self.canvasPath)
        let surface = try propertyBody(named: "cardSurface", in: source)
        XCTAssertTrue(surface.contains("companionBand("), "the band is drawn by the card surface")
        XCTAssertTrue(surface.contains("tileControl"), "the tile is the band's sibling")

        let tileControl = try propertyBody(named: "tileControl", in: source)
        XCTAssertTrue(tileControl.contains("Button(action: primaryAction)"))
        XCTAssertFalse(
            tileControl.contains("companionBand("),
            "the band must not be inside the button that opens the gallery"
        )

        // The other half of the same rule: the band sits ON the tile, so
        // everything in it except the transport has to let the touch through,
        // or the bottom of every folded card stops opening the gallery.
        let band = try RefusalLaneSource.body(
            ofFunction: "companionBand",
            in: source,
            path: Self.canvasPath
        )
        XCTAssertTrue(band.contains("WorkboardAudioTransport("))
        XCTAssertEqual(
            band.components(separatedBy: "allowsHitTesting(false)").count - 1, 2,
            "the words and the band's own surface both pass their taps through"
        )
    }

    /// The compact drawing is sized from the tile the MOSAIC granted, and the
    /// board is what hands that tile over. A band left on the reference unit
    /// draws 76 points into a tile that can be 64, and because the band is ON
    /// the tile the overflow hides the picture's name and its availability
    /// glyph rather than merely clipping them.
    ///
    /// Negative control: resolving `isCompact` to a constant, reinstating a
    /// per-footprint branch inside the card body, or a board that stopped
    /// handing the card its unit all leave the budget test above passing over a
    /// layout that no longer honours it — these assertions are what fail.
    func testTheCompactBandIsDrawnFromTheUnitTheMosaicGranted() throws {
        let source = try RefusalLaneSource.source(at: Self.canvasPath)
        let band = try RefusalLaneSource.body(
            ofFunction: "companionBand",
            in: source,
            path: Self.canvasPath
        )
        XCTAssertTrue(
            band.contains("placement == .compact"),
            "the band takes its compact form from the placement it was handed"
        )
        XCTAssertTrue(band.contains("if !isCompact {"), "the compact band gives up the words")
        XCTAssertTrue(band.contains("isCompact ? compactMetrics.transport"), band)
        XCTAssertTrue(band.contains("isCompact ? compactMetrics.bandPadding"), band)
        XCTAssertFalse(
            band.contains("WorkboardCompanionBand.compactTransport"),
            "the drawn transport is the granted size, never the reference constant"
        )

        // The card itself no longer forks on a footprint: the board grants one
        // slot, so there is one drawing, and what changes between kinds is
        // which face slots are filled. A density branch reappearing inside the
        // body is the drift these two assertions exist to catch.
        let body = try propertyBody(named: "cardBody", in: source)
        XCTAssertTrue(body.contains("faceText"), body)
        XCTAssertFalse(
            body.contains("case .small") || body.contains("compactMetrics"),
            "one drawing at one footprint — no per-size branch inside the card body"
        )
        XCTAssertTrue(
            source.contains("private var layoutSize: WorkMaterialCardSize { .standard }"),
            "a row still carrying a stored small or large renders at the granted slot"
        )

        XCTAssertTrue(
            source.contains("WorkboardCompanionBand.compactMetrics(forTileHeight: grantedUnitHeight)"),
            "the card sizes its compact drawing from the unit it was granted"
        )
        XCTAssertTrue(
            source.contains("grantedUnitHeight: gridUnitHeight"),
            "the board hands the card the unit the engine granted"
        )
        XCTAssertTrue(
            source.contains("WorkboardMosaicEngine(metrics: metrics).unitSize(forWidth: boardWidth)"),
            "that unit is the engine's own, not a second arithmetic beside it"
        )
    }

    /// The recording's state is spoken by the TILE, in both of the forms the
    /// tile takes: a card whose bytes are still arriving is not wrapped in a
    /// button — it is not a control at all — and a folded card in that state
    /// still holds a recording that can fail or be refused.
    ///
    /// Negative control: adding the value to the button branch alone leaves the
    /// arriving-bytes card silent about its recording — the count is 1 and this
    /// fails.
    func testBothFormsOfTheTileSayWhatTheRecordingIsDoing() throws {
        let source = try RefusalLaneSource.source(at: Self.canvasPath)
        let tileControl = try propertyBody(named: "tileControl", in: source)
        XCTAssertEqual(
            tileControl.components(separatedBy: ".accessibilityValue(companionAccessibilityValue)").count - 1,
            2,
            "both the button form and the plain form carry the recording's state"
        )
        // And the band it comes from stays hidden: two elements saying the same
        // thing is why the value exists on the tile in the first place.
        let band = try RefusalLaneSource.body(
            ofFunction: "companionBand",
            in: source,
            path: Self.canvasPath
        )
        XCTAssertTrue(band.contains("accessibilityHidden(true)"))
    }

    /// One recording, one player, one holder of process audio. A surface that
    /// minted its own `WorkboardAudioExclusivity` would take the registry out of
    /// the picture entirely: a band and the card beside it would play at once.
    func testEverySurfaceDrawingARecordingSharesTheProcessWideRegistry() throws {
        for path in [Self.canvasPath, Self.rowPath, Self.audioPath] {
            let source = try RefusalLaneSource.source(at: path)
            // The registry is constructed exactly once in the whole family —
            // its own `shared` — and by no surface that draws a recording.
            let constructions = source.components(separatedBy: "WorkboardAudioExclusivity(").count - 1
            XCTAssertEqual(
                constructions,
                path == Self.audioPath ? 1 : 0,
                "\(path) constructs a registry of its own instead of using `.shared`"
            )
            if path == Self.audioPath {
                XCTAssertTrue(
                    source.contains("static let shared = WorkboardAudioExclusivity()"),
                    "the one construction is the process-wide singleton"
                )
            }
            XCTAssertTrue(
                source.contains("WorkboardAudioCardPlayer()"),
                "\(path) should hold exactly one default-constructed player"
            )
        }

        // The card's band and its transport are handed the SAME player the card
        // owns, rather than one per transport.
        let canvas = try RefusalLaneSource.source(at: Self.canvasPath)
        XCTAssertTrue(canvas.contains("player: companionPlayer"))
        XCTAssertEqual(
            canvas.components(separatedBy: "WorkboardAudioCardPlayer()").count - 1, 1,
            "one player per card, not one per transport"
        )
        let row = try RefusalLaneSource.source(at: Self.rowPath)
        XCTAssertEqual(
            row.components(separatedBy: "WorkboardAudioCardPlayer()").count - 1, 1,
            "the row's audio row and its folded row share one player"
        )
    }

    /// Bytes are read on the first activation and never on a draw. A transport
    /// that loaded on appearance would read every recording on the desk to show
    /// a duration nobody asked for.
    func testTheTransportReadsNoBytesUntilItIsActivated() throws {
        let source = try RefusalLaneSource.source(at: Self.audioPath)
        let transport = try XCTUnwrap(
            source.range(of: "struct WorkboardAudioTransport: View {"),
            "no `WorkboardAudioTransport` — update this guard"
        )
        let end = source.range(of: "struct WorkboardAudioProgressTrack", range: transport.upperBound..<source.endIndex)
        let body = String(source[transport.upperBound..<(end?.lowerBound ?? source.endIndex)])
        XCTAssertTrue(body.contains("player.toggle"), "the transport plays through the card player")
        XCTAssertFalse(body.contains(".task"), "no draw-time payload read")
        XCTAssertFalse(body.contains(".onAppear"), "no draw-time payload read")
    }

    /// The list row draws the same two strings the band draws, from the same
    /// ONE rule — a folded row that re-derived its own pair would drift from
    /// the tile showing that pair. It reads the deduplicated face rather than
    /// the two raw slots, because a recording named after its own opening line
    /// stacked that line on itself everywhere the raw pair was drawn.
    func testTheListRowDrawsTheRecordingsTitleAndTranscript() throws {
        let source = try RefusalLaneSource.source(at: Self.rowPath)
        XCTAssertTrue(source.contains("WorkboardCompanionBand.face(for: companion).leadLine"))
        XCTAssertTrue(source.contains("WorkboardCompanionBand.face(for: companion).trailingExcerpt"))
        XCTAssertFalse(
            source.contains("WorkboardCompanionBand.transcript(for: companion)"),
            "the row draws the deduplicated face, never the raw transcript beside the raw title"
        )
        XCTAssertTrue(
            source.contains("Text(verbatim: rowTitle)"),
            "the row's headline is the folded title"
        )
        XCTAssertTrue(
            source.contains("WorkboardAudioTransport("),
            "the row draws the shared transport rather than a second player"
        )
    }

    // MARK: - The folded pair says itself once

    /// A recording is NAMED from its transcript's lead line, so a folded card
    /// drawing the raw title over the raw transcript repeats that line. The
    /// folded pair therefore goes through the same suppression rule a
    /// standalone recording already used: the lead line becomes the words
    /// themselves and nothing is drawn under them.
    ///
    /// Negative control: reading `title(for:)` and `transcript(for:)` straight
    /// into the two slots leaves "Ship the review" above "Ship the review
    /// before Friday" — this fails.
    func testAFoldedRecordingNamedFromItsOwnWordsSaysThemOnce() {
        let transcript = "Ship the review before Friday"
        let face = WorkboardCompanionBand.face(for: recording(
            name: WorkVoiceCaptureCoordinator.title(forTranscript: transcript),
            transcript: transcript
        ))

        XCTAssertNil(face.heading)
        XCTAssertEqual(face.leadLine, transcript)
        XCTAssertNil(face.trailingExcerpt)
        XCTAssertEqual(face.spokenParts, [transcript])
    }

    /// A title that is NOT what the words say is identity and stays: the rule
    /// removes a repeat, never a second thing the card knows.
    func testAFoldedRecordingKeepsATitleItsWordsDoNotSay() {
        let face = WorkboardCompanionBand.face(for: recording(
            name: "Kitchen walkthrough",
            transcript: "Ship the review before Friday"
        ))

        XCTAssertEqual(face.leadLine, "Kitchen walkthrough")
        XCTAssertEqual(face.trailingExcerpt, "Ship the review before Friday")
        XCTAssertEqual(face.spokenParts, ["Kitchen walkthrough", "Ship the review before Friday"])
    }

    /// With no words at all the card keeps the recording's name, exactly as the
    /// spoken label already did — suppression needs a body to suppress against.
    func testAFoldedRecordingWithNoWordsKeepsItsName() {
        let face = WorkboardCompanionBand.face(for: recording(name: "Ship it", transcript: nil))

        XCTAssertEqual(face.leadLine, "Ship it")
        XCTAssertNil(face.trailingExcerpt)
    }

    // MARK: - Opening hands the recording over

    /// The gallery presents its OWN transport for the folded recording, so the
    /// surface that opened it must stop producing audio first: otherwise the
    /// sheet offers Play over a clip that is already sounding, and the sheet's
    /// page-change teardown silences only its own copy.
    ///
    /// Negative control: wiring `openAction` straight to `onOpen` leaves the
    /// board player running behind the sheet — the second assertion fails.
    ///
    /// The tile's guard is spelled as a statement rather than as a ternary
    /// because a ternary whose branches are a method reference and `nil` makes
    /// the Swift 6.2 type checker abandon the expression ("failed to produce
    /// diagnostic"). The routing under test is identical either way.
    func testOpeningAFoldedCardStopsTheBoardsOwnPlayerFirst() throws {
        let canvas = try RefusalLaneSource.source(at: Self.canvasPath)
        XCTAssertTrue(
            canvas.contains(
                "guard permittedActions.contains(.open) else { return nil }\n"
                    + "        return { openMaterial() }"
            ),
            "the tile opens through the handover, not through the raw callback"
        )
        XCTAssertFalse(
            canvas.contains("permittedActions.contains(.open) ? onOpen : nil"),
            "the tile must not hand back the presenting callback unguarded"
        )
        XCTAssertTrue(
            canvas.contains("companionPlayer.deactivate()\n        onOpen()"),
            "the handover deactivates before it presents"
        )

        let row = try RefusalLaneSource.source(at: Self.rowPath)
        XCTAssertTrue(
            row.contains("player.deactivate()\n        onOpen()"),
            "the list row hands its recording over on the same rule"
        )
        XCTAssertFalse(
            row.contains("case .open: return onOpen"),
            "the row's primary action opens through the handover"
        )
    }
}
