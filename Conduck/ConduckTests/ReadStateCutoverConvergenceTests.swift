// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReadStateCutoverConvergenceTests.swift
//
// The account cutover as a CONVERGENCE contract: what several devices and a
// late iCloud delivery end up agreeing on, and in what order they are allowed
// to disagree on the way there.
//
// WHY THIS IS A SEPARATE FILE FROM `ReadStateStoreTests`. That file pins the
// single-device rules — one store, one register, one `resolveAccountCutover()`
// — and every case there answers "what does THIS device do with the value it
// finds". The bugs this design can actually ship are not there. They are in the
// interleavings: a value published before iCloud had spoken, a delivery that
// lands after the launch merge has already returned, a second device launching
// in the wrong order, a peer's push read as an instruction to clear. Those need
// two stores over one register, or a delivery arriving after the fact, and they
// read as a different subject rather than more of the same one. Nothing here
// re-asserts a single-device rule.
//
// THE INVARIANT EVERY CASE BELOW IS A COROLLARY OF: the account's cutover only
// ever moves EARLIER. It answers "from what moment does the ABSENCE of a marker
// mean NOT READ, rather than we were not recording yet", so the account's
// answer has to be the earliest moment ANY of its devices could have been
// recording. The failure this forbids is silent and permanent: let an iPad set
// up last week raise the account to last week, and every genuinely unread reply
// from the months before it goes dark on every device at once, with nothing in
// this app that ever re-bolds a row. Over-reporting is recoverable with a tap;
// under-reporting is a reply the user never learns arrived.
//
// `min` is idempotent, commutative and associative, which is the whole reason
// the register needs no compare-and-swap, no ordering guarantee and no
// tie-break: it self-heals whatever order values arrive in, however many
// devices push, and however many times the same value is re-applied. The cases
// named "…whichever order…" and "…never drifts" are that algebra observed
// through the real store rather than asserted about the static meet.
//
// EVERY CASE OWNS ITS DOUBLES. `SettingsDependencies.processDefault` hands
// every suite in the process the SAME in-memory stores, so a cutover that
// reached those would be read by the next suite as its own account's — and
// because the meet is `min`, a stray early value STICKS rather than being
// overwritten by whoever writes next. A shared register here is shared between
// the two stores of ONE case and nothing else.

import XCTest
@testable import Conduck

@MainActor
final class ReadStateCutoverConvergenceTests: XCTestCase {

    /// A fixed instant so "earlier" and "later" are statements about the design
    /// rather than about when the suite happened to run.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var earlier: Date { now.addingTimeInterval(-86_400) }
    private var earliest: Date { now.addingTimeInterval(-864_000) }
    private var later: Date { now.addingTimeInterval(86_400) }

    // MARK: - Fixtures

    /// One device: its own local mirror, wired to a register a case may share
    /// with a second device.
    ///
    /// `cloudAvailable` defaults true — the iPhone/iPad/Mac answer. The wrist's
    /// answer is always false (`CloudAvailability` tracks iCloud DRIVE, which
    /// does not exist on watchOS), and the cases that care say so.
    private func device(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        register: InMemoryUbiquitousStore,
        cloudAvailable: Bool = true
    ) -> ReadStateStore {
        ReadStateStore(
            defaults: defaults,
            writer: NullReadStateWriter(),
            ubiquitous: register,
            cloudAvailability: StubCloudAvailability(available: cloudAvailable),
            changes: InMemoryKVSChangeSource(store: register)
        )
    }

    /// Defaults that already carry a cutover — a device on its SECOND launch.
    ///
    /// Load-bearing in most cases here rather than convenience: a value minted
    /// in THIS launch is provisional and is deliberately never published into an
    /// empty register, so a case about publication that started from a fresh
    /// mint would be testing the provisional hold instead of the convergence.
    private func settledDevice(
        at cutover: Date,
        register: InMemoryUbiquitousStore,
        cloudAvailable: Bool = true
    ) -> ReadStateStore {
        device(
            defaults: InMemoryDefaultsStore(
                seed: [Constants.conversationReadStateEpochKey: cutover.timeIntervalSince1970]
            ),
            register: register,
            cloudAvailable: cloudAvailable
        )
    }

    /// What the register actually holds, distinguishing ABSENT from the 1970 an
    /// absent numeric key reads as. Reading the `Double` alone would make an
    /// empty register indistinguishable from the single most destructive value
    /// this system can hold.
    private func registerCutover(_ register: InMemoryUbiquitousStore) -> Date? {
        guard register.object(forKey: Constants.conversationReadCutoverKVSKey) != nil else { return nil }
        return Date(timeIntervalSince1970: register.double(forKey: Constants.conversationReadCutoverKVSKey))
    }

    /// The locally mirrored cutover, read back out of defaults rather than off
    /// the store. Every case that adopts a value checks BOTH: an adoption that
    /// updates only the in-memory property is lost at the next launch, and the
    /// device silently reverts to its own later stamp while iCloud is offline.
    private func mirroredCutover(_ defaults: InMemoryDefaultsStore) -> Date? {
        let seconds = defaults.double(forKey: Constants.conversationReadStateEpochKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// A peer device's push, as the app really receives it: values land in the
    /// register and an external-change notification follows.
    private func peerPublishes(_ cutover: Date, into register: InMemoryUbiquitousStore) {
        register.simulateRemoteChange(
            values: [Constants.conversationReadCutoverKVSKey: cutover.timeIntervalSince1970]
        )
    }

    /// Suspends until `condition()` holds, failing by name so an expiry reports
    /// itself rather than surfacing as a confusing assertion further down.
    ///
    /// The inbound arm hops through `Task { @MainActor in … }`, so the merge is
    /// one scheduling turn behind the notification that triggered it. A
    /// monotonic `ContinuousClock` rather than wall time — the same rule the
    /// rest of this suite follows.
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out after \(timeout) waiting for \(what)", file: file, line: line)
    }

    // MARK: - A delivery that lands after the launch merge

    func testALateRemoteArrivalLowersAFreshlyClaimedCutover() async {
        // THE case a fresh install depends on. `synchronize()` schedules an
        // exchange; it does not wait for a download, so the launch merge sees an
        // empty register and the device keeps the value it just minted. The
        // account's real cutover arrives seconds or minutes later, through the
        // change feed — and it has to lower this device even though the merge
        // that would have adopted it has long since returned.
        //
        // Without this the device would answer reads from a cutover LATER than
        // the account's, and every conversation whose last activity fell between
        // the two would show as viewed on this device alone. Nothing re-bolds a
        // row, so that is permanent.
        let register = InMemoryUbiquitousStore()
        let defaults = InMemoryDefaultsStore()
        let store = device(defaults: defaults, register: register)

        store.resolveAccountCutover(now: now)
        XCTAssertEqual(store.currentAccountCutover(), now, "the launch merge finds nothing and keeps its own stamp")

        peerPublishes(earlier, into: register)

        await waitUntil("the late delivery to lower this device's cutover") {
            store.currentAccountCutover() == earlier
        }
        XCTAssertEqual(
            mirroredCutover(defaults), earlier,
            "the adopted value has to reach the local mirror too, or the next offline launch reverts to this device's own stamp"
        )
        XCTAssertEqual(registerCutover(register), earlier, "and this device's later value is never pushed back up")
    }

    func testALateRemoteArrivalNeverRaisesThisDevicesCutover() async {
        // The same delivery in the forbidden direction. A peer that installed
        // AFTER this device published a later moment; adopting it would declare
        // everything this device recorded in between already read.
        let register = InMemoryUbiquitousStore()
        let defaults = InMemoryDefaultsStore(
            seed: [Constants.conversationReadStateEpochKey: earlier.timeIntervalSince1970]
        )
        let store = device(defaults: defaults, register: register)
        store.resolveAccountCutover(now: now)

        peerPublishes(later, into: register)

        await waitUntil("the peer's later value to be pushed back down") {
            registerCutover(register) == earlier
        }
        XCTAssertEqual(store.currentAccountCutover(), earlier, "the later value is not adopted")
        XCTAssertEqual(mirroredCutover(defaults), earlier, "and the mirror is not raised behind it either")
    }

    func testAnEmptiedRegisterIsReseededRatherThanAdopted() async {
        // `min` HAS NO INVERSE — there is no value that undoes an earlier one —
        // so an empty register is the ABSENCE of an opinion, never an
        // instruction to forget one. A device that read it as a clear would drop
        // the account's floor to nothing and answer every read from whatever it
        // stamps next, which on a device set up recently is months of unread
        // replies going dark at once.
        let register = InMemoryUbiquitousStore()
        let defaults = InMemoryDefaultsStore(
            seed: [Constants.conversationReadStateEpochKey: earlier.timeIntervalSince1970]
        )
        let store = device(defaults: defaults, register: register)
        store.resolveAccountCutover(now: now)
        XCTAssertEqual(registerCutover(register), earlier)

        // An account signed out and back in, or a peer that wrote the register
        // away: the key is genuinely gone and a delivery says so.
        register.simulateRemoteChange(values: [Constants.conversationReadCutoverKVSKey: nil])

        await waitUntil("this device to put the account's value back") { registerCutover(register) != nil }
        XCTAssertEqual(registerCutover(register), earlier, "the register is re-seeded from the surviving local mirror")
        XCTAssertEqual(store.currentAccountCutover(), earlier, "and the device never lost it in the first place")
    }

    // MARK: - Several devices, one register

    func testTwoDevicesConvergeOnTheEarliestWhicheverOrderTheyLaunchIn() {
        // Order independence is the property that lets this work with no
        // compare-and-swap: the register is a shared cell two devices write
        // without coordinating, and `min` is commutative, so whoever gets there
        // second cannot undo the first.
        for (first, second) in [(earlier, later), (later, earlier)] {
            let register = InMemoryUbiquitousStore()
            let deviceA = settledDevice(at: first, register: register)
            let deviceB = settledDevice(at: second, register: register)

            deviceA.resolveAccountCutover(now: now)
            deviceB.resolveAccountCutover(now: now)

            XCTAssertEqual(
                registerCutover(register), earlier,
                "launching \(first) then \(second) must still leave the account at the earliest moment either device could have been recording"
            )
            // Whoever launched with the LATER value still holds it until it next
            // reads the register — a device is only ever lowered by a merge it
            // actually runs. Its next launch is that merge.
            deviceA.resolveAccountCutover(now: now)
            deviceB.resolveAccountCutover(now: now)
            XCTAssertEqual(deviceA.currentAccountCutover(), earlier)
            XCTAssertEqual(deviceB.currentAccountCutover(), earlier)
            XCTAssertEqual(registerCutover(register), earlier, "and the second pass moves nothing")
        }
    }

    func testANewDeviceJoiningLaterCannotRaiseTheAccount() {
        // A brand-new iPad on an old account: it mints today, finds the account
        // already recording from months ago, and adopts. This is the case the
        // per-device epoch could not express — a device epoch means "I was not
        // here before this date", never "the account read everything before it".
        let register = InMemoryUbiquitousStore()
        settledDevice(at: earliest, register: register).resolveAccountCutover(now: now)

        let defaults = InMemoryDefaultsStore()
        let freshDevice = device(defaults: defaults, register: register)
        freshDevice.resolveAccountCutover(now: now)

        XCTAssertEqual(freshDevice.currentAccountCutover(), earliest, "the new device adopts the account's floor")
        XCTAssertEqual(mirroredCutover(defaults), earliest)
        XCTAssertEqual(registerCutover(register), earliest, "and contributes nothing of its own")
    }

    func testAThreeDeviceFleetConvergesRegardlessOfWhoLaunchesWhen() {
        // Associativity, observed through the store rather than asserted about
        // the static meet: three values, every launch order, one answer.
        let orders: [[Date]] = [
            [earliest, earlier, later],
            [later, earlier, earliest],
            [earlier, later, earliest],
            [later, earliest, earlier]
        ]
        for order in orders {
            let register = InMemoryUbiquitousStore()
            let fleet = order.map { settledDevice(at: $0, register: register) }
            for member in fleet { member.resolveAccountCutover(now: now) }

            XCTAssertEqual(registerCutover(register), earliest, "launch order \(order) diverged")
            // Only the devices that launched AFTER the earliest value reached
            // the register can have seen it; re-resolving stands in for their
            // next launch, which is when a real fleet converges.
            for member in fleet { member.resolveAccountCutover(now: now) }
            for member in fleet {
                XCTAssertEqual(member.currentAccountCutover(), earliest, "a device stayed above the account's floor")
            }
        }
    }

    func testResolvingRepeatedlyNeverDrifts() {
        // Idempotence, and the reason `resolveAccountCutover()` is safe to call
        // from a launch path that runs again on every background wake, App
        // Intent resume and macOS reopen. A merge that moved the value on a
        // no-op would ratchet the cutover forward one relaunch at a time.
        let register = InMemoryUbiquitousStore()
        let defaults = InMemoryDefaultsStore(
            seed: [Constants.conversationReadStateEpochKey: earlier.timeIntervalSince1970]
        )
        let store = device(defaults: defaults, register: register)

        for offset in 0..<5 {
            store.resolveAccountCutover(now: now.addingTimeInterval(Double(offset) * 3_600))
            XCTAssertEqual(store.currentAccountCutover(), earlier)
            XCTAssertEqual(mirroredCutover(defaults), earlier)
            XCTAssertEqual(registerCutover(register), earlier)
        }
    }

    // MARK: - The device with no iCloud

    func testADeviceWithNoICloudReadsThroughItsOwnMirrorAndPublishesNothing() {
        // Coherent rather than degraded, and that is the point: with no iCloud
        // there is no CloudKit mirror either, so this is a single-device world
        // and the local value IS the account value. The read side has to keep
        // working — an unstamped cutover would leave `lastViewed` nil for every
        // conversation, which the resolver reads as VIEWED, and the device would
        // show no unread state at all.
        let register = InMemoryUbiquitousStore()
        let defaults = InMemoryDefaultsStore()
        let store = device(defaults: defaults, register: register, cloudAvailable: false)

        store.resolveAccountCutover(now: now)

        XCTAssertEqual(store.currentAccountCutover(), now, "the device still stamps, so reads have a floor")
        XCTAssertEqual(mirroredCutover(defaults), now, "and the stamp is durable across launches")
        XCTAssertNil(registerCutover(register), "nothing is published from a device with no account")

        let conversation = UUID()
        XCTAssertEqual(
            store.lastViewed(conversation, stored: nil), now,
            "a conversation with no marker anywhere answers from the local cutover"
        )
        XCTAssertTrue(
            unseenReply(store, conversation, lastActivityAt: now.addingTimeInterval(60), at: now.addingTimeInterval(60)),
            "a reply after the stamp is still unseen — the fallback is a floor, not a blanket 'already read'"
        )
        XCTAssertFalse(
            unseenReply(store, conversation, lastActivityAt: earlier, at: now),
            "and history from before it stays dark, which is what the cutover exists for"
        )
    }

    // MARK: - Helpers

    /// Ask the REAL resolver whether a reply would show as unseen, so the
    /// read-side consequence of a cutover is locked end to end rather than
    /// through a comparison re-implemented here.
    private func unseenReply(
        _ store: ReadStateStore,
        _ id: UUID,
        lastActivityAt: Date,
        at instant: Date
    ) -> Bool {
        ConversationActivityResolver.resolve(
            ConversationActivityInputs(
                lastActivityAt: lastActivityAt,
                newestSendingAt: nil,
                newestFailed: nil,
                storedLastViewedAt: nil,
                storedFailureSeenAttemptID: nil,
                tailRole: .agent
            ),
            locallyLiveSince: nil,
            lastViewedAt: store.lastViewed(id, stored: nil),
            now: instant
        ).hasUnseenReply
    }
}

// MARK: - Doubles

/// A writer that records nothing and answers every fold as covered.
///
/// The durable side is irrelevant to every case in this file — the cutover
/// never touches a conversation record — but `ReadStateStore` still requires
/// one, and the default is `ConversationStore.shared`, which opens the real
/// App-Group sqlite. That is one of the documented carve-outs from the storage
/// seam, so a case that let the default through would write files beside the
/// installed app's for no reason at all.
private actor NullReadStateWriter: ConversationReadStateWriter {
    func markConversationViewed(_ id: UUID, at date: Date) async {}
    func acknowledgeConversationFailure(_ id: UUID, attemptID: UUID) async {}
    func markConversationViewedAndAcknowledged(_ id: UUID, at date: Date, attemptID: UUID?) async {}
    func foldLegacyReadMarker(_ id: UUID, localMarker: Date) async -> ReadMarkerFoldOutcome { .alreadyCovered }
}
