// SPDX-License-Identifier: Apache-2.0

// A Work tour belongs to the retained workspace, not its presented sheet.
// Dismissing acknowledges it; hiding Work or prioritizing a capture parks it
// with its page and example choices intact. The examples own no real material,
// conversation, recorder, navigation or composer state.
//
// Private capture views publish blockers under their own identities. A source
// board disappearing must never clear a recorder or picker owned by another
// mounted surface. Draft/focus blockers defer the automatic introduction only;
// an explicit Help request can still explain Work without clearing that draft.

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
    static let stepCount = 5

    private(set) var currentStep = 0
    var projectStage = 0
    var includesResearch = false
    var reviewsRequest = false

    private(set) var isRequested = false
    private(set) var hasEvaluatedAutomatic = false
    private(set) var isDeferredForVisit = false
    private var destinationIsActive = false
    private var presentationBlockers: Set<UUID> = []
    private var automaticBlockers: Set<UUID> = []

    func advance() { currentStep = min(currentStep + 1, Self.stepCount - 1) }
    func goBack() { currentStep = max(currentStep - 1, 0) }

    func reset() {
        currentStep = 0
        projectStage = 0
        includesResearch = false
        reviewsRequest = false
    }

    func requestReplay() {
        reset()
        isDeferredForVisit = false
        isRequested = true
    }

    /// Called with Work/Chats visibility, not scene activity. A backgrounded
    /// capture must not become an ordinary visit merely by foregrounding again.
    func setDestinationActive(_ active: Bool) {
        if destinationIsActive && !active { isDeferredForVisit = false }
        destinationIsActive = active
    }

    /// A requested capture/open wins for this whole visit, including the gap
    /// after its one-shot route has been consumed and before its sheet appears.
    func deferAutomaticForVisit() { isDeferredForVisit = true }

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

    func canEvaluateAutomatically(_ availability: WorkboardTutorialAvailability) -> Bool {
        !hasEvaluatedAutomatic && !isRequested && !isDeferredForVisit
            && availability.isActive && availability.isReady && !availability.isBlocked
            && !availability.blocksAutomatic
            && presentationBlockers.isEmpty && automaticBlockers.isEmpty
    }

    /// Rechecks current availability after the settings actor hop. A late
    /// response cannot present above a capture that started while awaiting it.
    func resolveAutomaticDecision(_ shouldShow: Bool, availability: WorkboardTutorialAvailability) {
        guard canEvaluateAutomatically(availability) else { return }
        hasEvaluatedAutomatic = true
        isRequested = shouldShow
    }

    func isPresented(_ availability: WorkboardTutorialAvailability) -> Bool {
        isRequested && availability.isActive && !availability.isBlocked
            && !isDeferredForVisit && presentationBlockers.isEmpty
    }

    /// A programmatic dismissal caused by a hidden/blocked presenter is not
    /// acknowledgement. Only a currently presentable tour may consume its flag.
    @discardableResult
    func acknowledge(_ availability: WorkboardTutorialAvailability) -> Bool {
        guard isPresented(availability) else { return false }
        isRequested = false
        hasEvaluatedAutomatic = true
        return true
    }

    /// Included in the presenter's task identity so releasing the last local
    /// blocker retries an introduction whose settings flag was never consumed.
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

/// Declared inside each platform's existing native toolbar, so a retained Work
/// layer cannot contribute Help to Chats or lose it outside a navigation host.
struct WorkboardTutorialHelpButton: View {
    let session: WorkboardTutorialSession

    var body: some View {
        Button { session.requestReplay() } label: {
            Image(systemName: "questionmark.circle")
        }
        .help(String(localized: "workdesk.tour.help", defaultValue: "Work tour"))
        .accessibilityLabel(Text(LocalizedStringResource("workdesk.tour.help", defaultValue: "Work tour")))
        .accessibilityIdentifier("workboard-tour-help")
    }
}
