// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardAudioCardTests.swift
//
// The parts of the desk's audio card that are decidable without audio
// hardware: the transport's clock/progress arithmetic, the exclusivity registry
// that makes starting one card stop another, the audio-output claim (who may
// deactivate the session, and what a live capture or a refused activation does
// to a tap), and the card's presentation rules — which affordances a card
// offers and what each one says it will do. Playback itself needs a real
// `AVAudioPlayer` and a real session, so it is a founder-QA item; these hold
// the rules where a silent regression would actually live.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardAudioCardTests: XCTestCase {

    // MARK: - Clock and progress

    func testProgressIsZeroUntilAClipLengthIsKnown() {
        // A card that has never been played has no duration, and a bar that
        // started full would say the opposite of the truth.
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 0, duration: 0), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: 0), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: -1), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: .nan, duration: 30), 0)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 5, duration: .infinity), 0)
    }

    func testProgressIsTheClampedFractionOfTheClip() {
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 15, duration: 30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 30, duration: 30), 1, accuracy: 0.0001)
        // `currentTime` can read a shade past the end on the last tick; the bar
        // must not overflow its track.
        XCTAssertEqual(WorkboardAudioTiming.fraction(elapsed: 31, duration: 30), 1, accuracy: 0.0001)
    }

    func testTheClockReadsAsMinutesAndSecondsAndGrowsAnHourField() {
        XCTAssertEqual(WorkboardAudioTiming.label(0), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(7), "0:07")
        XCTAssertEqual(WorkboardAudioTiming.label(59), "0:59")
        XCTAssertEqual(WorkboardAudioTiming.label(60), "1:00")
        XCTAssertEqual(WorkboardAudioTiming.label(723), "12:03")
        XCTAssertEqual(WorkboardAudioTiming.label(3600), "1:00:00")
        XCTAssertEqual(WorkboardAudioTiming.label(3723), "1:02:03")
    }

    func testTheClockTruncatesRatherThanRoundsSoItNeverShowsAnUnreachedSecond() {
        // 7.9s into a clip is still the seventh second: rounding up would show
        // 0:08 against a bar that has not reached it.
        XCTAssertEqual(WorkboardAudioTiming.label(7.9), "0:07")
        XCTAssertEqual(WorkboardAudioTiming.label(59.999), "0:59")
    }

    func testAnUnusableClockValueReadsAsTheStartOfTheClip() {
        XCTAssertEqual(WorkboardAudioTiming.label(-3), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(.nan), "0:00")
        XCTAssertEqual(WorkboardAudioTiming.label(.infinity), "0:00")
    }

    // MARK: - Exclusivity

    @MainActor
    private final class StubPlayer: WorkboardAudioExclusive {
        private(set) var stopCount = 0
        func stopForExclusivity() { stopCount += 1 }
    }

    func testStartingOneCardStopsTheCardThatHeldOutput() {
        let registry = WorkboardAudioExclusivity()
        let first = StubPlayer()
        let second = StubPlayer()

        registry.claim(first)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === first)

        registry.claim(second)
        XCTAssertEqual(first.stopCount, 1, "The card that held output must be stopped, not left playing under the new one.")
        XCTAssertEqual(second.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === second)
    }

    func testReclaimingTheSameCardDoesNotStopIt() {
        let registry = WorkboardAudioExclusivity()
        let player = StubPlayer()

        registry.claim(player)
        registry.claim(player)

        // Resuming after a pause claims again; stopping itself there would make
        // resume unreachable.
        XCTAssertEqual(player.stopCount, 0)
        XCTAssertTrue(registry.currentHolder === player)
    }

    func testAStaleTerminalCannotSilenceTheCardThatTookOutput() {
        let registry = WorkboardAudioExclusivity()
        let first = StubPlayer()
        let second = StubPlayer()

        registry.claim(first)
        registry.claim(second)
        // `first`'s own teardown resigns AFTER `second` claimed. It must not
        // clear the slot the newer card owns.
        registry.resign(first)

        XCTAssertTrue(registry.currentHolder === second)
        XCTAssertEqual(second.stopCount, 0)
    }

    func testResigningClearsTheSlotWhenTheHolderIsTheOneResigning() {
        let registry = WorkboardAudioExclusivity()
        let player = StubPlayer()

        registry.claim(player)
        registry.resign(player)

        XCTAssertNil(registry.currentHolder)
    }

    func testTheRegistryDoesNotKeepAFinishedCardAlive() {
        let registry = WorkboardAudioExclusivity()
        var player: StubPlayer? = StubPlayer()
        registry.claim(player!)

        player = nil

        // A card scrolled out of existence without resigning must read as no
        // holder, or the next card would send `stopForExclusivity` to a corpse.
        XCTAssertNil(registry.currentHolder)
    }

    // MARK: - Transport phase

    func testAFreshPlayerIsIdleAndItsNextTapStartsPlayback() {
        let player = WorkboardAudioCardPlayer(exclusivity: WorkboardAudioExclusivity())

        XCTAssertEqual(player.phase, .idle)
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.fraction, 0)
        XCTAssertTrue(player.willStartPlayback)
    }

    func testBytesThatDoNotDecodeLeaveTheCardFailedAndStillTappable() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .failed })

        XCTAssertEqual(player.phase, .failed)
        // Failure is a state the person can retry out of: the next tap must
        // still mean "play", and the failed card must not be holding output.
        XCTAssertTrue(player.willStartPlayback)
        XCTAssertNil(registry.currentHolder)
        XCTAssertEqual(player.duration, 0)
    }

    func testACardWithNoBytesBehindItFailsRatherThanClaimingOutput() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        // What a `.syncPending` or reattachable card answers if it is ever
        // asked for bytes.
        player.toggle { nil }
        await settle(until: { player.phase == .failed })

        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(registry.currentHolder)
    }

    func testLeavingTheBoardReturnsTheCardToIdle() async {
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(exclusivity: registry)

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .failed })
        player.deactivate()

        XCTAssertEqual(player.phase, .idle)
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertNil(registry.currentHolder)
    }

    func testASecondTapWhileBytesAreInFlightAbandonsTheAttempt() async {
        let player = WorkboardAudioCardPlayer(exclusivity: WorkboardAudioExclusivity())
        let gate = Gate()

        player.toggle {
            await gate.wait()
            return Data("not audio".utf8)
        }
        XCTAssertEqual(player.phase, .loading)

        player.toggle { nil }
        XCTAssertEqual(player.phase, .idle, "A tap during the load cancels it rather than queueing a second read.")

        await gate.open()
    }

    // MARK: - Audio output ownership

    /// A client of the audio-output claim. Plain object identity is all the
    /// arbiter keys on.
    private final class OutputClient {}

    private struct SessionRefused: Error {}

    func testOnlyTheClientThatClaimedOutputCanDeactivateTheSession() {
        let counts = SessionCounts()
        let output = WorkboardAudioOutput(
            captureIsLive: { false },
            activateSession: { counts.activations += 1 },
            deactivateSession: { counts.deactivations += 1 }
        )
        let first = OutputClient()
        let second = OutputClient()

        XCTAssertEqual(output.claim(for: first), .granted)
        XCTAssertEqual(output.claim(for: second), .granted)
        XCTAssertEqual(counts.activations, 2)

        // A terminal from the card that already LOST output. An unconditional
        // release would deactivate the session under the card now playing.
        output.release(for: first)
        XCTAssertEqual(counts.deactivations, 0, "Only the holder may deactivate the session.")
        XCTAssertTrue(output.currentHolder === second)

        output.release(for: second)
        XCTAssertEqual(counts.deactivations, 1)
        XCTAssertNil(output.currentHolder)
    }

    func testAClaimTheSessionRefusedLeavesNoHolderAndNeverDeactivates() {
        let counts = SessionCounts()
        let output = WorkboardAudioOutput(
            captureIsLive: { false },
            activateSession: { counts.activations += 1; throw SessionRefused() },
            deactivateSession: { counts.deactivations += 1 }
        )
        let client = OutputClient()

        XCTAssertEqual(output.claim(for: client), .sessionUnavailable)
        // Nothing was brought up, so nothing may be torn down: a later release
        // must not deactivate a session this client never owned.
        XCTAssertNil(output.currentHolder)
        output.release(for: client)
        XCTAssertEqual(counts.deactivations, 0)
    }

    func testALiveCaptureIsRefusedBeforeTheSessionIsTouched() {
        let counts = SessionCounts()
        let output = WorkboardAudioOutput(
            captureIsLive: { true },
            activateSession: { counts.activations += 1 },
            deactivateSession: { counts.deactivations += 1 }
        )

        XCTAssertEqual(output.claim(for: OutputClient()), .captureIsLive)
        XCTAssertEqual(counts.activations, 0, "A live capture must not have its session reconfigured.")
        XCTAssertNil(output.currentHolder)
    }

    func testTheHolderReclaimingDoesNotReactivateTheSession() {
        let counts = SessionCounts()
        let output = WorkboardAudioOutput(
            captureIsLive: { false },
            activateSession: { counts.activations += 1 },
            deactivateSession: { counts.deactivations += 1 }
        )
        let client = OutputClient()

        XCTAssertEqual(output.claim(for: client), .granted)
        XCTAssertEqual(output.claim(for: client), .granted)

        XCTAssertEqual(counts.activations, 1, "A second claim by the holder rides the route it already has.")
    }

    // MARK: - The player's session discipline

    func testALiveCaptureRefusesTheCardWithoutClaimingAnything() async {
        let registry = WorkboardAudioExclusivity()
        let output = StubOutput()
        output.captureIsLive = true
        let player = WorkboardAudioCardPlayer(
            exclusivity: registry,
            output: output,
            speechBus: SpeechExclusivity()
        )

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .blocked })

        XCTAssertTrue(output.claims.isEmpty, "A refusal must not claim output on its way to saying no.")
        XCTAssertNil(registry.currentHolder, "A refused card must not stop the card that is playing.")
        // The refusal is about the moment, not the recording: the next tap
        // must still mean "play".
        XCTAssertTrue(player.willStartPlayback)
    }

    func testASessionThatRefusesToActivateFailsTheCardInsteadOfPlayingBlind() async {
        let registry = WorkboardAudioExclusivity()
        let output = StubOutput()
        output.nextClaim = .sessionUnavailable
        let player = WorkboardAudioCardPlayer(
            exclusivity: registry,
            output: output,
            speechBus: SpeechExclusivity()
        )

        player.toggle { Data("not audio".utf8) }
        await settle(until: { player.phase == .failed })

        // `AVAudioPlayer.play()` can return true into a session that permits no
        // output, so a refused activation is the answer — not a transport that
        // looks like it is playing.
        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(registry.currentHolder)
        XCTAssertTrue(output.releases.isEmpty, "Nothing was claimed, so nothing is released.")
    }

    func testAMicrophoneClaimStopsACardThatIsBringingAudioUp() async {
        let bus = SpeechExclusivity()
        let registry = WorkboardAudioExclusivity()
        let player = WorkboardAudioCardPlayer(
            exclusivity: registry,
            output: StubOutput(),
            speechBus: bus
        )
        let gate = Gate()

        player.toggle {
            await gate.wait()
            return Data("not audio".utf8)
        }
        XCTAssertEqual(player.phase, .loading)

        // The mic's own call: stop every registered party. The card is a party
        // from the moment it starts reading bytes, so a capture starting during
        // the read cannot be raced to output.
        bus.claim(nil)

        XCTAssertEqual(player.phase, .idle)
        await gate.open()
    }

    func testTheBusCannotStopACardThatIsNotProducingAudio() {
        let bus = SpeechExclusivity()
        let player = WorkboardAudioCardPlayer(
            exclusivity: WorkboardAudioExclusivity(),
            output: StubOutput(),
            speechBus: bus
        )

        bus.register(player)
        bus.claim(nil)

        // Every claim broadcasts to every party; an idle card has nothing to
        // stop and must not report a state change for someone else's audio.
        XCTAssertEqual(player.phase, .idle)
    }

    // MARK: - Presentation rules

    func testTheLoadingPhaseOffersCancelRatherThanPlay() {
        // Activating a loading card cancels the payload read, so announcing
        // "Play" would describe the opposite of what the tap does.
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .loading), .cancelLoading)
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .playing), .pause)
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .idle), .play)
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .paused), .play)
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .failed), .play)
        XCTAssertEqual(WorkboardAudioCardPresentation.transportAction(for: .blocked), .play)
    }

    func testOpenIsOfferedOnlyForReadableBytesAndOnlyWhenTheBoardWiredIt() {
        let everyAvailability: [WorkboardMaterialAvailability] =
            [.available, .localOnly, .syncPending, .unavailableOnThisDevice]
        for availability in everyAvailability {
            XCTAssertFalse(
                WorkboardAudioCardPresentation.showsOpenAction(
                    availability: availability,
                    hasOpenAction: false
                ),
                "A card with no open action must not offer Open (\(availability))."
            )
            XCTAssertEqual(
                WorkboardAudioCardPresentation.showsOpenAction(
                    availability: availability,
                    hasOpenAction: true
                ),
                availability.isAvailable,
                "Open must be offered exactly for bytes this device can read (\(availability))."
            )
        }
    }

    func testTheUnavailableChipIsAnActionOnlyWhenReattachIsWired() {
        XCTAssertEqual(
            WorkboardAudioCardPresentation.chip(for: .unavailableOnThisDevice, hasReattachAction: true),
            .reattach
        )
        XCTAssertTrue(WorkboardAudioCardChip.reattach.isAction)

        // With nowhere to send the person, the corner states the fact instead
        // of naming a repair the card cannot perform.
        XCTAssertEqual(
            WorkboardAudioCardPresentation.chip(for: .unavailableOnThisDevice, hasReattachAction: false),
            .notOnThisDevice
        )
        XCTAssertFalse(WorkboardAudioCardChip.notOnThisDevice.isAction)
    }

    func testTheOtherAvailabilityStatesAreNeverActionsWhateverIsWired() {
        for hasReattach in [true, false] {
            XCTAssertNil(
                WorkboardAudioCardPresentation.chip(for: .available, hasReattachAction: hasReattach),
                "Bytes that are here need no chip."
            )
            XCTAssertEqual(
                WorkboardAudioCardPresentation.chip(for: .syncPending, hasReattachAction: hasReattach),
                .syncPending
            )
            XCTAssertEqual(
                WorkboardAudioCardPresentation.chip(for: .localOnly, hasReattachAction: hasReattach),
                .localOnly
            )
        }
        // A card waiting for iCloud is repaired by the sync landing, not by the
        // person, so its chip is never a control.
        XCTAssertFalse(WorkboardAudioCardChip.syncPending.isAction)
        XCTAssertFalse(WorkboardAudioCardChip.localOnly.isAction)
    }

    // MARK: - The transport glyph

    /// "Cannot play" is TWO answers, and the transport has to say which.
    ///
    /// A recording arriving through iCloud is repaired by waiting; one whose
    /// bytes this device no longer holds is repaired by the person pointing at
    /// the file again. Drawn with one cloud-download symbol they were the same
    /// picture, which on the gallery's band — a surface with no card, no chip
    /// and no menu beside it — was the ONLY account of a control that did
    /// nothing.
    func testTheTransportGlyphSeparatesWaitingForICloudFromMissingBytes() {
        XCTAssertEqual(
            WorkboardAudioTransport.symbolName(phase: .idle, availability: .syncPending),
            "icloud.and.arrow.down"
        )
        XCTAssertEqual(
            WorkboardAudioTransport.symbolName(phase: .idle, availability: .unavailableOnThisDevice),
            "paperclip.badge.ellipsis"
        )
        XCTAssertNotEqual(
            WorkboardAudioTransport.symbolName(phase: .idle, availability: .syncPending),
            WorkboardAudioTransport.symbolName(phase: .idle, availability: .unavailableOnThisDevice)
        )
    }

    /// The unreadable glyph outranks the phase, and it comes from the SAME
    /// availability policy the card's chip is drawn from — so a transport and
    /// the chip beside it cannot disagree about which state a recording is in.
    func testAnUnreadableRecordingDrawsItsAvailabilityRatherThanItsPhase() {
        for phase in [WorkboardAudioPhase.idle, .playing, .loading, .paused, .failed, .blocked] {
            for availability in [WorkboardMaterialAvailability.syncPending, .unavailableOnThisDevice] {
                XCTAssertEqual(
                    WorkboardAudioTransport.symbolName(phase: phase, availability: availability),
                    WorkboardCardFacePolicy.availabilityGlyphName(for: availability),
                    "\(availability) must not be drawn as a transport in phase \(phase)."
                )
            }
        }
    }

    /// Readable bytes are a transport again, whichever lane they are on: a
    /// local-only recording plays exactly as a synced one does.
    func testReadableBytesStillDrawTheirPhase() {
        for availability in [WorkboardMaterialAvailability.available, .localOnly] {
            XCTAssertEqual(
                WorkboardAudioTransport.symbolName(phase: .idle, availability: availability),
                "play.fill"
            )
            XCTAssertEqual(
                WorkboardAudioTransport.symbolName(phase: .playing, availability: availability),
                "pause.fill"
            )
        }
    }

    /// The chip's words and glyph are stated ONCE, on the chip itself, because
    /// the gallery's companion band draws the same chip as the audio card. Two
    /// spellings of "Waiting for iCloud…" is the duplication this wave removed.
    func testAChipCarriesItsOwnWordsAndTheSharedAvailabilityGlyph() {
        XCTAssertEqual(WorkboardAudioCardChip.syncPending.availability, .syncPending)
        XCTAssertEqual(WorkboardAudioCardChip.reattach.availability, .unavailableOnThisDevice)
        XCTAssertEqual(WorkboardAudioCardChip.notOnThisDevice.availability, .unavailableOnThisDevice)
        XCTAssertEqual(WorkboardAudioCardChip.localOnly.availability, .localOnly)

        for chip in [
            WorkboardAudioCardChip.localOnly,
            .syncPending,
            .reattach,
            .notOnThisDevice
        ] {
            XCTAssertEqual(
                chip.glyphName,
                WorkboardCardFacePolicy.availabilityGlyphName(for: chip.availability)
            )
            XCTAssertFalse(String(localized: chip.label).isEmpty)
        }
        // The two states a person cannot tell apart from a glyph alone say
        // different things in words.
        XCTAssertNotEqual(
            String(localized: WorkboardAudioCardChip.syncPending.label),
            String(localized: WorkboardAudioCardChip.notOnThisDevice.label)
        )
    }

    // MARK: - Helpers

    /// Reference-typed tallies so the injected session closures can count
    /// without the test capturing mutable locals across escapes.
    private final class SessionCounts {
        var activations = 0
        var deactivations = 0
    }

    /// The audio-output claim under test control: it records who asked, answers
    /// what the case needs, and keeps the same ownership rule the real arbiter
    /// does.
    @MainActor
    private final class StubOutput: WorkboardAudioOutputArbiter {
        var captureIsLive = false
        var nextClaim: WorkboardAudioOutputClaim = .granted
        private(set) var claims: [ObjectIdentifier] = []
        private(set) var releases: [ObjectIdentifier] = []
        private(set) weak var holder: AnyObject?

        func claim(for client: AnyObject) -> WorkboardAudioOutputClaim {
            claims.append(ObjectIdentifier(client))
            if nextClaim == .granted { holder = client }
            return nextClaim
        }

        func release(for client: AnyObject) {
            releases.append(ObjectIdentifier(client))
            if holder === client { holder = nil }
        }
    }

    /// Spins the main actor until `condition` holds, so an assertion never
    /// races a payload read that hops off and back.
    private func settle(
        until condition: () -> Bool,
        attempts: Int = 200,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never held", file: file, line: line)
    }

    /// A payload read the test controls the timing of.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
