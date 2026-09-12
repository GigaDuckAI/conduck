// SPDX-License-Identifier: Apache-2.0

// The short Work introduction is armed only by the first explicit Chats → Work
// selection. Launches and capture routes cannot arm it. Its device-local flag
// is claimed before presentation, so closing or interrupting it never repeats it.
// The retained session keeps its page during temporary presentation blockers;
// leaving Work or starting a directed capture closes it for good.
//
// Private capture views publish blockers under their own identities so one
// surface disappearing cannot clear another surface's recorder or picker.

import SwiftUI
import Observation

struct WorkboardTutorialAvailability: Equatable {
    var isActive: Bool
    var isReady: Bool
    var isBlocked: Bool
    var blocksAutomatic = false
}

@Observable @MainActor
final class WorkboardTutorialSession {
    static let stepCount = 4

    private(set) var currentStep = 0

    private(set) var isRequested = false
    private var hasPresented = false
    private(set) var isDeferredForVisit = false
    private(set) var isEligibleVisit = false
    private var hasEnteredFromChats = false
    private var destinationIsActive = false
    private var presentationBlockers: Set<UUID> = []
    private var automaticBlockers: Set<UUID> = []
    @ObservationIgnored private let claimIntroduction: @MainActor () async -> Bool

    init(claimIntroduction: @escaping @MainActor () async -> Bool = {
        await SettingsManager.shared.claimWorkboardTutorial()
    }) {
        self.claimIntroduction = claimIntroduction
    }

    func advance() { currentStep = min(currentStep + 1, Self.stepCount - 1) }
    func goBack() { currentStep = max(currentStep - 1, 0) }

    /// Claim on the user action, even if loading or another presenter needs
    /// time to finish. The task belongs to the transition, not a view task whose
    /// cancellation could discard a successful device-wide claim.
    @discardableResult
    func beginChatToWorkTransition() -> Task<Void, Never>? {
        guard !hasEnteredFromChats else { return nil }
        hasEnteredFromChats = true
        isEligibleVisit = true
        isDeferredForVisit = false
        return Task { @MainActor [weak self, claimIntroduction] in
            let claimed = await claimIntroduction()
            guard let self, self.isEligibleVisit, !self.isDeferredForVisit else { return }
            self.isRequested = claimed
        }
    }

    /// Navigation is reported synchronously by the router. Scene activity and
    /// initial view mounting are not navigation and cannot request a tour.
    func setDestinationActive(_ active: Bool) {
        if destinationIsActive && !active {
            isEligibleVisit = false
            isRequested = false
            isDeferredForVisit = false
        }
        destinationIsActive = active
    }

    /// A capture, share or deep link takes priority for the rest of this visit.
    func deferAutomaticForVisit() {
        isDeferredForVisit = true
        isEligibleVisit = false
        isRequested = false
    }

    func setInteraction(owner: UUID, isBlocking: Bool, blocksAutomatic: Bool) {
        if isBlocking { presentationBlockers.insert(owner) }
        else { presentationBlockers.remove(owner) }
        if blocksAutomatic { automaticBlockers.insert(owner) }
        else { automaticBlockers.remove(owner) }
    }

    func removeInteraction(owner: UUID) {
        presentationBlockers.remove(owner)
        automaticBlockers.remove(owner)
    }

    func isPresented(_ availability: WorkboardTutorialAvailability) -> Bool {
        let canBegin = availability.isReady && !availability.blocksAutomatic
            && automaticBlockers.isEmpty
        return isRequested && availability.isActive && !availability.isBlocked
            && !isDeferredForVisit && presentationBlockers.isEmpty
            && (hasPresented || canBegin)
    }

    func didPresent() { hasPresented = true }

    /// Ignore dismissal echoes from a temporarily blocked presenter.
    @discardableResult
    func acknowledge(_ availability: WorkboardTutorialAvailability) -> Bool {
        guard isPresented(availability) else { return false }
        isRequested = false
        return true
    }

    var hasPresentationBlockers: Bool { !presentationBlockers.isEmpty }
    var hasAutomaticBlockers: Bool { !automaticBlockers.isEmpty }
}

private struct WorkboardTutorialBusyModifier: ViewModifier {
    let session: WorkboardTutorialSession?
    let isBlocking: Bool
    let blocksAutomatic: Bool
    @State private var owner = UUID()

    private struct Interaction: Equatable {
        let isBlocking: Bool
        let blocksAutomatic: Bool
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Interaction(isBlocking: isBlocking, blocksAutomatic: blocksAutomatic), initial: true) { _, state in
                session?.setInteraction(owner: owner, isBlocking: state.isBlocking,
                                        blocksAutomatic: state.blocksAutomatic)
            }
            .onDisappear { session?.removeInteraction(owner: owner) }
    }
}

extension View {
    func workboardTutorialBusy(session: WorkboardTutorialSession?, isBlocking: Bool,
                              blocksAutomatic: Bool = false) -> some View {
        modifier(WorkboardTutorialBusyModifier(session: session, isBlocking: isBlocking,
                                              blocksAutomatic: blocksAutomatic))
    }
}
