// Conduck
// SpeechExclusivityTests.swift
//
// Pure-logic coverage for the macOS speech/mic exclusivity bus
// (`SpeechExclusivity`): claim stops every OTHER registered party (nil ⇒ all —
// the mic's call), auto-speak is refused while ANY registered mic authority
// reports a live capture (two distinct authorities coexist in production — the
// menu-bar `DictationService` and the main window's `InAppAudioRecorder`), the
// weak registries survive
// deallocation, and re-registration is idempotent. The TYPE is cross-platform
// (Foundation-only) precisely so this suite runs on the authoritative iOS-sim
// test pass even though only macOS call sites wire the bus. Tests use FRESH
// `SpeechExclusivity()` instances, never the production `.shared` (no global
// state bleed).

import XCTest
@testable import Conduck

@MainActor
final class SpeechExclusivityTests: XCTestCase {

    /// Spy party counting how many times the bus told it to stop.
    private final class SpyParty: SpeechExclusivityParty {
        private(set) var stopCount = 0
        func stopForSpeechExclusivity() { stopCount += 1 }
    }

    /// Fake mic authority with a settable live-capture flag.
    private final class FakeAuthority: RecordingExclusivityAuthority {
        var isActivelyRecording = false
    }

    // MARK: - claim(claimant) stops the OTHERS, never the claimant

    func testClaimStopsEveryOtherPartyButNotClaimant() {
        let bus = SpeechExclusivity()
        let a = SpyParty(), b = SpyParty(), c = SpyParty()
        bus.register(a)
        bus.register(b)
        bus.register(c)

        bus.claim(a)

        XCTAssertEqual(a.stopCount, 0, "The claimant must never be stopped by its own claim.")
        XCTAssertEqual(b.stopCount, 1, "Every other party must be stopped exactly once.")
        XCTAssertEqual(c.stopCount, 1, "Every other party must be stopped exactly once.")
    }

    // MARK: - claim(nil) is the mic's stop-ALL

    func testClaimNilStopsAllParties() {
        let bus = SpeechExclusivity()
        let a = SpyParty(), b = SpyParty()
        bus.register(a)
        bus.register(b)

        bus.claim(nil)

        XCTAssertEqual(a.stopCount, 1, "A nil claim (mic start) must stop ALL parties.")
        XCTAssertEqual(b.stopCount, 1, "A nil claim (mic start) must stop ALL parties.")
    }

    // MARK: - an unregistered claimant still silences the registered parties

    func testUnregisteredClaimantStillStopsRegisteredParties() {
        let bus = SpeechExclusivity()
        let registered = SpyParty()
        let outsider = SpyParty()  // never registered (e.g. mis-ordered wiring)
        bus.register(registered)

        bus.claim(outsider)

        XCTAssertEqual(registered.stopCount, 1,
                       "Claiming must not require the claimant itself to be registered.")
        XCTAssertEqual(outsider.stopCount, 0)
    }

    // MARK: - auto-speak refusal while the mic is live

    func testClaimForAutoSpeakRefusesWhileRecording() {
        let bus = SpeechExclusivity()
        let speaker = SpyParty(), other = SpyParty()
        bus.register(speaker)
        bus.register(other)
        let mic = FakeAuthority()
        mic.isActivelyRecording = true
        bus.register(recordingAuthority: mic)

        let granted = bus.claimForAutoSpeak(speaker)

        XCTAssertFalse(granted, "Auto-speak must be refused while the mic is recording.")
        XCTAssertEqual(other.stopCount, 0,
                       "A refused auto-speak claim must not stop anyone (the capture goes on).")
    }

    func testClaimForAutoSpeakGrantsAndStopsOthersWhenMicIdle() {
        let bus = SpeechExclusivity()
        let speaker = SpyParty(), other = SpyParty()
        bus.register(speaker)
        bus.register(other)
        let mic = FakeAuthority()  // idle
        bus.register(recordingAuthority: mic)

        let granted = bus.claimForAutoSpeak(speaker)

        XCTAssertTrue(granted, "With the mic idle, the auto-speak claim must be granted.")
        XCTAssertEqual(other.stopCount, 1, "A granted auto-speak claim stops the other parties.")
        XCTAssertEqual(speaker.stopCount, 0)
    }

    func testClaimForAutoSpeakGrantsWithNoAuthorityRegistered() {
        // No authority ⇒ no mic on this platform ⇒ never refuse (the iOS/watch
        // inert posture, and macOS before any DictationService is constructed).
        let bus = SpeechExclusivity()
        let speaker = SpyParty()
        bus.register(speaker)

        XCTAssertTrue(bus.claimForAutoSpeak(speaker))
    }

    // MARK: - isRecordingActive consults every live authority (any-true)

    func testIsRecordingActiveTracksAuthorityLive() {
        let bus = SpeechExclusivity()
        XCTAssertFalse(bus.isRecordingActive, "No authority registered ⇒ not recording.")

        let mic = FakeAuthority()
        bus.register(recordingAuthority: mic)
        XCTAssertFalse(bus.isRecordingActive)

        mic.isActivelyRecording = true
        XCTAssertTrue(bus.isRecordingActive, "The authority is consulted LIVE on every read.")

        mic.isActivelyRecording = false
        XCTAssertFalse(bus.isRecordingActive)
    }

    func testIsRecordingActiveIsAnyTrueAcrossMultipleAuthorities() {
        // TWO mic services exist in production (the popover's and the main
        // window's) — a single-slot probe would be stolen by whichever
        // registered last. The registry must report any-live-instance-recording.
        let bus = SpeechExclusivity()
        let popoverMic = FakeAuthority()
        let windowMic = FakeAuthority()
        bus.register(recordingAuthority: popoverMic)
        bus.register(recordingAuthority: windowMic)

        popoverMic.isActivelyRecording = true
        XCTAssertTrue(bus.isRecordingActive,
                      "The FIRST-registered authority recording must still be seen after a second registers.")

        popoverMic.isActivelyRecording = false
        windowMic.isActivelyRecording = true
        XCTAssertTrue(bus.isRecordingActive)

        windowMic.isActivelyRecording = false
        XCTAssertFalse(bus.isRecordingActive)
    }

    func testDeallocatedAuthorityIsCompactedAndIgnored() {
        // SwiftUI re-evaluates `@State` defaults, constructing throwaway mic
        // authorities (a `DictationService` / `InAppAudioRecorder`) that die
        // immediately — dead authorities must neither crash nor pin
        // `isRecordingActive`.
        let bus = SpeechExclusivity()
        var dying: FakeAuthority? = FakeAuthority()
        dying!.isActivelyRecording = true
        bus.register(recordingAuthority: dying!)
        dying = nil

        XCTAssertFalse(bus.isRecordingActive,
                       "A dead authority must not report recording (nor crash the walk).")

        let survivor = FakeAuthority()
        survivor.isActivelyRecording = true
        bus.register(recordingAuthority: survivor)
        XCTAssertTrue(bus.isRecordingActive)
    }

    // MARK: - weak registry: a deallocated party never crashes a claim

    func testDeallocatedPartyIsCompactedNotCrashed() {
        let bus = SpeechExclusivity()
        let survivor = SpyParty()
        bus.register(survivor)

        var dying: SpyParty? = SpyParty()
        bus.register(dying!)
        dying = nil  // the registry's weak box now holds a dead entry

        bus.claim(nil)

        XCTAssertEqual(survivor.stopCount, 1,
                       "A dead entry must not prevent live parties from being stopped.")
        // And a subsequent claim still works (the dead entry was compacted).
        bus.claim(nil)
        XCTAssertEqual(survivor.stopCount, 2)
    }

    // MARK: - re-registration is idempotent (ObjectIdentifier-keyed)

    func testReRegisteringSamePartyStopsItOnlyOncePerClaim() {
        let bus = SpeechExclusivity()
        let a = SpyParty(), b = SpyParty()
        bus.register(a)
        bus.register(a)  // double-register the SAME object
        bus.register(b)

        bus.claim(b)

        XCTAssertEqual(a.stopCount, 1,
                       "Re-registering the same object must not produce duplicate stop calls.")
    }

    // MARK: - acquireMicLease: cross-process mic arbitration

    func testAcquireMicLeaseGrantedWhenNoOtherAuthorityRecording() {
        let bus = SpeechExclusivity()
        let requester = FakeAuthority()
        let other = FakeAuthority()  // idle
        bus.register(recordingAuthority: requester)
        bus.register(recordingAuthority: other)

        XCTAssertTrue(bus.acquireMicLease(excluding: requester),
                      "With no OTHER authority capturing, the lease must be granted.")
    }

    func testAcquireMicLeaseRefusedWhenAnotherAuthorityIsRecording() {
        let bus = SpeechExclusivity()
        let requester = FakeAuthority()
        let other = FakeAuthority()
        other.isActivelyRecording = true  // the window/menu-bar mic already holds it
        bus.register(recordingAuthority: requester)
        bus.register(recordingAuthority: other)

        XCTAssertFalse(bus.acquireMicLease(excluding: requester),
                       "A live capture is sacred: a SECOND concurrent start must be refused.")
    }

    func testAcquireMicLeaseExcludesSelf() {
        // The requester's own `isActivelyRecording` may already be true (it set
        // `isStarting`/`.recording` synchronously before asking) — it must never
        // block itself, so ordering vs. its own state flip is irrelevant.
        let bus = SpeechExclusivity()
        let requester = FakeAuthority()
        requester.isActivelyRecording = true
        bus.register(recordingAuthority: requester)

        XCTAssertTrue(bus.acquireMicLease(excluding: requester),
                      "The requester must be excluded by identity so it can't block itself.")
    }

    func testAcquireMicLeaseGrantedWithNoAuthoritiesRegistered() {
        // iOS/watch inert posture: nothing registered ⇒ always granted.
        let bus = SpeechExclusivity()
        let requester = FakeAuthority()  // not even registered

        XCTAssertTrue(bus.acquireMicLease(excluding: requester))
    }

    func testAcquireMicLeaseIgnoresDeadAuthority() {
        // A throwaway authority that was recording then died must not block a new
        // capture (nor crash the walk) — the registry compacts dead entries.
        let bus = SpeechExclusivity()
        let requester = FakeAuthority()
        bus.register(recordingAuthority: requester)
        var dying: FakeAuthority? = FakeAuthority()
        dying!.isActivelyRecording = true
        bus.register(recordingAuthority: dying!)
        dying = nil

        XCTAssertTrue(bus.acquireMicLease(excluding: requester),
                      "A dead authority must not hold the mic lease against a live requester.")
    }
}
