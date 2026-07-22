// Conduck
// SpeechExclusivity.swift
//
// The macOS speech/mic exclusivity bus. macOS has NO AVAudioSession
// arbitration, and Mac speech runs on SEPARATE engine instances that cannot
// see each other (each thread view owns a `ThreadSpeaker(engine: ReplyVoice())`;
// the quick-lane arrival speak and the Settings sample preview run on
// `ReplyVoice.shared`) — so without arbitration two voices can overlap, and a
// playing voice bleeds straight into a starting mic capture. This bus is the
// ONE place those parties coordinate, replacing the point-to-point
// `ReplyVoice.shared.cancel()` calls that each covered only a single pair.
//
// PRIORITY RULES:
//   - Mic start → ALL speakers stop (`claim(nil)` from
//     `DictationService.startRecording`). The mic is never registered as a
//     party, so it is never preempted — a live capture is sacred.
//   - Any speaker start/resume → every OTHER speaker stops (`claim(self)`).
//     Last-speaker-wins.
//   - AUTO-speak (the quick-lane arrival path) is suppressed entirely while
//     the mic is recording (`claimForAutoSpeak` returns false) — non-user-
//     initiated audio must never play over a live capture; the reply stays
//     tappable in the thread. MANUAL bubble taps are NOT suppressed during
//     recording: user-initiated audio obeys the user.
//
// PARTIES (macOS): each view-owned `ThreadSpeaker` (registered in its init —
// the party is the STATE MACHINE, not its engine, because cancelling a
// `ReplyVoice` directly never fires its completion and would leave the
// speaker's bubble stuck in `.playing`), and `ReplyVoice.shared` (registered
// lazily when the singleton is first built). The mic side is a weak registry
// of `RecordingExclusivityAuthority` objects queried LIVE (each service's own
// state machine stays the source of truth — no transition bookkeeping, and
// distinct authorities coexist: the menu-bar `DictationService` and the main
// window's `InAppAudioRecorder`; see the protocol doc).
//
// The TYPE is deliberately cross-platform (Foundation-only, no gate) so it
// compiles into every target and its tests run on the authoritative iOS-sim
// test pass — but ONLY macOS call sites register/claim. iOS, watchOS, and
// CarPlay never touch it: CarPlay's own `ReplyVoice` instance must never be
// preemptible (exactly-once completion / deactivate-once are load-bearing).

import Foundation

/// A speech producer that can be told to stop because another party (a
/// different speaker, or the mic) is starting. Conformers: `ThreadSpeaker`
/// (stops via its own `stop()`, keeping bubble UI state in sync) and
/// `ReplyVoice` (stops via `cancel()`). macOS-only conformances.
@MainActor
protocol SpeechExclusivityParty: AnyObject {
    func stopForSpeechExclusivity()
}

/// A mic owner the bus consults before granting an auto-speak claim.
/// Conformers: `DictationService` (the menu-bar / quick-capture path) and
/// `InAppAudioRecorder` (the main-window composer mic) — each reporting
/// `isActivelyRecording` off its own state machine. A REGISTRY of authorities —
/// not a single probe slot — because multiple authorities exist by design (the
/// two above), and SwiftUI re-evaluates an `@State` default initializer on every
/// struct init, constructing throwaway instances: a single slot would be stolen
/// by whichever instance registered last (or left pointing at a dead one),
/// silently disabling the mid-capture auto-speak refusal.
@MainActor
protocol RecordingExclusivityAuthority: AnyObject {
    var isActivelyRecording: Bool { get }
}

/// The exclusivity registry. Parties are held WEAKLY (keyed by
/// `ObjectIdentifier`) so a deallocated view's speaker simply drops out — no
/// unregister call needed from a `deinit` that couldn't legally touch
/// main-actor state anyway. Dead entries are compacted on every broadcast.
@MainActor
final class SpeechExclusivity {

    static let shared = SpeechExclusivity()

    /// Weak box so the registry never keeps a party alive.
    private struct WeakParty {
        weak var party: SpeechExclusivityParty?
    }

    /// Weak box so the registry never keeps a mic service alive (SwiftUI
    /// `@State` default re-evaluation constructs throwaway instances).
    private struct WeakAuthority {
        weak var authority: RecordingExclusivityAuthority?
    }

    private var parties: [ObjectIdentifier: WeakParty] = [:]
    private var authorities: [ObjectIdentifier: WeakAuthority] = [:]

    /// True while ANY live mic authority is actively capturing — queried LIVE
    /// on every read (each authority's own state machine stays the source of
    /// truth). False when none are registered (iOS/watch — the bus is inert
    /// there). Compacts dead authorities as it walks.
    var isRecordingActive: Bool {
        var anyRecording = false
        for (id, box) in authorities {
            guard let authority = box.authority else {
                authorities.removeValue(forKey: id)
                continue
            }
            if authority.isActivelyRecording {
                anyRecording = true
            }
        }
        return anyRecording
    }

    /// Register a speech party. Idempotent — re-registering the same object
    /// overwrites its own slot.
    func register(_ party: SpeechExclusivityParty) {
        parties[ObjectIdentifier(party)] = WeakParty(party: party)
    }

    /// Register a mic authority. Idempotent, weakly held.
    func register(recordingAuthority: RecordingExclusivityAuthority) {
        authorities[ObjectIdentifier(recordingAuthority)] = WeakAuthority(authority: recordingAuthority)
    }

    /// Mic-lease arbitration. Returns `true` iff NO OTHER registered authority is
    /// currently capturing — the caller may bring the mic up. Returns `false`
    /// when any OTHER live authority `isActivelyRecording` (the menu-bar
    /// `DictationService` vs. the main-window `InAppAudioRecorder` own SEPARATE
    /// `AVAudioRecorder` instances, and macOS has no AVAudioSession arbitration —
    /// two concurrent starts produce the HAL "there already is a thread" / error
    /// 35 thrash). A live capture is sacred: the SECOND start is refused, never
    /// the first. `requester` is excluded by `ObjectIdentifier` so it can't block
    /// itself — ordering vs. its own `isStarting`/`state` flip is irrelevant.
    /// Compacts dead authorities as it walks. Inert on iOS/watch (no authorities
    /// registered → always `true`).
    func acquireMicLease(excluding requester: RecordingExclusivityAuthority) -> Bool {
        let requesterID = ObjectIdentifier(requester)
        for (id, box) in authorities {
            guard let authority = box.authority else {
                authorities.removeValue(forKey: id)
                continue
            }
            if id != requesterID, authority.isActivelyRecording {
                return false
            }
        }
        return true
    }

    /// A party is about to produce audio: stop every OTHER registered party.
    /// `nil` claimant ⇒ stop ALL parties — the mic's call (the mic is not a
    /// registered party, so nothing can reciprocally stop it). Iterates over a
    /// snapshot so a `stopForSpeechExclusivity()` that mutates the registry
    /// can't corrupt the walk, and compacts dead entries as it goes.
    func claim(_ claimant: SpeechExclusivityParty?) {
        let claimantID = claimant.map(ObjectIdentifier.init)
        for (id, box) in parties {
            guard let party = box.party else {
                parties.removeValue(forKey: id)
                continue
            }
            if id != claimantID {
                party.stopForSpeechExclusivity()
            }
        }
    }

    /// AUTO-speak entry (the quick-lane arrival path): refuses while the mic
    /// is live — the caller must stay silent (the reply remains tappable in
    /// the thread). Otherwise claims for `claimant` and returns true.
    func claimForAutoSpeak(_ claimant: SpeechExclusivityParty) -> Bool {
        guard !isRecordingActive else { return false }
        claim(claimant)
        return true
    }
}
