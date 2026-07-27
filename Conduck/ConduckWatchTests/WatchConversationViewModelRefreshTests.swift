// SPDX-License-Identifier: Apache-2.0

// Conduck — Watch refresh-machinery contract tests: a refresh pass publishes
// ONLY what changed. Field baseline: one wrist session logged 85 refresh
// passes, each toggling `isLoading` twice and bumping `changeGeneration`
// even when the fetch returned identical data — every pass re-evaluated the
// list body and cancelled/restarted the content-search `.task(id:)`.
// Contracts under test:
//   1. a no-op reload writes NO published state (`isLoading` untouched,
//      `changeGeneration` unchanged);
//   2. a data change bumps `changeGeneration` exactly once per pass;
//   3. the spinner flips true→false only on the FIRST successful load (empty
//      list AND no prior successful fetch) — a genuinely empty store's later
//      refresh passes never re-cycle it;
//   4. never-drop — a `.conversationsDidChange` burst coalesces but the final
//      write always surfaces (the load-bearing dirty-flag guarantee).
//
// Runs against an injected in-memory store (CloudKit off), same seam as
// `WatchDraftMintTests`. `.conversationsDidChange` observers register with
// `object: nil`, so each test tears its VM down before the next store exists.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchConversationViewModelRefreshTests: XCTestCase {

    private var store: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        store = ConversationStore(inMemory: true)
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Expectation-style bounded poll on the main actor — exits the moment the
    /// condition flips rather than sleeping a fixed interval.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Records every write to the VM's `isLoading`. `withObservationTracking`
    /// fires `onChange` synchronously at willSet on the mutating thread — the
    /// VM is `@MainActor`, so `assumeIsolated` is sound — and each registration
    /// is one-shot, so the recorder re-arms itself inside the callback. At
    /// willSet the property still holds its OLD value, so `transitionsFrom`
    /// is the sequence of values each write transitioned FROM:
    /// a true→false spinner flip records `[false, true]`.
    @MainActor
    private final class IsLoadingRecorder {
        private(set) var transitionsFrom: [Bool] = []
        private weak var vm: WatchConversationViewModel?

        init(_ vm: WatchConversationViewModel) {
            self.vm = vm
            arm()
        }

        var writeCount: Int { transitionsFrom.count }

        private func arm() {
            guard let vm else { return }
            withObservationTracking {
                _ = vm.isLoading
            } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let vm = self.vm else { return }
                    self.transitionsFrom.append(vm.isLoading)
                    self.arm()
                }
            }
        }
    }

    // MARK: - Tests

    func testNoOpReloadPublishesNothing() async throws {
        _ = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        let vm = WatchConversationViewModel(store: store)
        try await waitUntil("Initial load must populate the list.") {
            vm.conversations.count == 1
        }

        let generation = vm.changeGeneration
        let recorder = IsLoadingRecorder(vm)

        let changed = await vm.reload()

        XCTAssertFalse(changed, "Identical fetch result must report no change.")
        XCTAssertEqual(vm.changeGeneration, generation,
                       "A no-op reload must not move the change generation.")
        XCTAssertEqual(recorder.writeCount, 0,
                       "A steady-state reload must not publish `isLoading` at all — " +
                       "every write re-evaluates the list body.")
        XCTAssertFalse(vm.isLoading)
    }

    func testDataChangeBumpsGenerationExactlyOncePerPass() async throws {
        _ = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        let vm = WatchConversationViewModel(store: store)
        try await waitUntil("Initial load must populate the list.") {
            vm.conversations.count == 1
        }

        let generation = vm.changeGeneration
        _ = try await store.createConversation(backend: "custom_\(UUID().uuidString)")

        try await waitUntil("The store write must surface via the change notification.") {
            vm.changeGeneration == generation + 1
        }
        XCTAssertEqual(vm.conversations.count, 2)

        // Negative half needs a grace window: any straggler pass (e.g. a second
        // notification coalesced into its own no-op pass) must NOT double-bump.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(vm.changeGeneration, generation + 1,
                       "Exactly one bump per data-changing pass — no-op follow-up passes stay silent.")
    }

    func testFirstLoadFromEmptyFlipsSpinnerTrueThenFalse() async throws {
        _ = try await store.createConversation(backend: "custom_\(UUID().uuidString)")

        let vm = WatchConversationViewModel(store: store)
        // The init reload runs in a Task on the main actor, so arming the
        // recorder before the first await deterministically precedes it.
        let recorder = IsLoadingRecorder(vm)

        try await waitUntil("First load must populate the list.") {
            vm.conversations.count == 1
        }

        XCTAssertEqual(recorder.transitionsFrom, [false, true],
                       "First population flips the spinner true then false " +
                       "(recorder logs the value each write transitions FROM).")
        XCTAssertFalse(vm.isLoading)
    }

    func testEmptyStoreReloadAfterFirstLoadPublishesNoSpinner() async throws {
        // Genuinely empty store: the first load must cycle the spinner exactly
        // once, and every subsequent refresh pass must leave `isLoading`
        // untouched — otherwise the "no conversations" empty state flickers to
        // a spinner on every CloudKit echo / delete-last-conversation echo.
        let vm = WatchConversationViewModel(store: store)
        let recorder = IsLoadingRecorder(vm)

        try await waitUntil("First load on an empty store must cycle the spinner once.") {
            recorder.transitionsFrom == [false, true]
        }
        XCTAssertTrue(vm.conversations.isEmpty)

        let changed = await vm.reload()

        XCTAssertFalse(changed, "An empty→empty fetch must report no change.")
        XCTAssertEqual(recorder.writeCount, 2,
                       "A refresh on a still-empty store after the first successful " +
                       "load must not write `isLoading` — the empty state must not " +
                       "flicker to a spinner.")
        XCTAssertFalse(vm.isLoading)
    }

    func testNotificationBurstNeverDropsFinalWrite() async throws {
        _ = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        let vm = WatchConversationViewModel(store: store)
        try await waitUntil("Initial load must populate the list.") {
            vm.conversations.count == 1
        }
        let recorder = IsLoadingRecorder(vm)

        // Burst: interleave real writes (each posts `.conversationsDidChange`)
        // with extra bare posts so notifications land while a pass is already
        // in flight — the dirty flag must earn another pass, never drop one.
        var lastID: UUID?
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
            let record = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
            lastID = record.id
            NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
        }

        try await waitUntil("The FINAL write must surface — coalescing may skip passes, never data.") {
            vm.conversations.count == 6
        }
        XCTAssertTrue(vm.conversations.contains { $0.id == lastID },
                      "The last-minted conversation must be published after the burst drains.")
        XCTAssertEqual(recorder.writeCount, 0,
                       "Steady-state burst passes must never publish `isLoading`.")
        XCTAssertFalse(vm.isLoading)
    }
}
