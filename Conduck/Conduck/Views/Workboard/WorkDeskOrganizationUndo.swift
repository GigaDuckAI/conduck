// SPDX-License-Identifier: Apache-2.0

// Filing uses the window's native undo history and a brief, touch-reachable
// Undo control. Store receipts validate the complete locations they restore.
// The inverse is registered synchronously during UndoManager's undo/redo group;
// its task waits for the preceding store write before supplying the next receipt.
// Restoring an appearance writes new revisions. Older native history follows
// only token substitutions this controller's successful restorations produced,
// including the store's marked first-layout exception. A synced edit with
// similar content never qualifies for rebasing.
// Text editors retain their normal responder-chain undo handling.

import SwiftUI
import Observation

@MainActor @Observable
final class WorkDeskOrganizationUndoController {
    private(set) var receipt: WorkDeskLocationUndo?
    private var activeOperations = 0
    var isApplying: Bool { activeOperations > 0 }
    var showsUndo = false
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var registered = Set<UUID>()
    @ObservationIgnored private var generated = Set<UUID>()
    @ObservationIgnored private var restoredTokens: [RestoredTokenKey: [WorkDeskLocationRecord]] = [:]

    private struct RestoredTokenKey: Hashable {
        let materialID: UUID
        let records: Set<WorkDeskLocationRecord>
    }

    func receive(_ change: WorkDeskLocationUndo, organization: WorkDeskOrganization, manager: UndoManager?) {
        guard !change.isRestoration, !generated.contains(change.id), registered.insert(change.id).inserted else { return }
        receipt = change
        showsUndo = true
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak organization, weak manager] target in
            guard let organization, let manager else { return }
            target.apply(Task { change }, organization: organization, manager: manager)
        }
        manager.setActionName(String(localized: "workdesk.undo.organization", defaultValue: "Organise materials"))
    }

    private func apply(_ operation: Task<WorkDeskLocationUndo?, Never>, organization: WorkDeskOrganization,
                       manager: UndoManager) {
        showsUndo = false
        activeOperations += 1
        let predecessor = operationTail
        let inverse = Task { @MainActor [weak self] () -> WorkDeskLocationUndo? in
            guard let self else { return nil }
            defer { activeOperations -= 1 }
            _ = await predecessor?.value
            guard let change = await operation.value else { return nil }
            return await restore(change, organization: organization)
        }
        operationTail = Task { _ = await inverse.value }
        manager.registerUndo(withTarget: self) { [weak organization, weak manager] target in
            guard let organization, let manager else { return }
            target.apply(inverse, organization: organization, manager: manager)
        }
        manager.setActionName(String(localized: "workdesk.undo.organization", defaultValue: "Organise materials"))
    }

    func undoLatest(organization: WorkDeskOrganization, manager: UndoManager? = nil) async {
        guard !isApplying, let receipt else { return }
        let name = String(localized: "workdesk.undo.organization", defaultValue: "Organise materials")
        if let manager, manager.canUndo, manager.undoActionName == name {
            manager.undo()
            return
        }
        // A later text edit owns the top undo entry. Undo this location receipt
        // directly without consuming the editor's history; retire our entries
        // so they cannot subsequently replay a receipt already restored here.
        manager?.removeAllActions(withTarget: self)
        activeOperations += 1
        showsUndo = false
        defer { activeOperations -= 1 }
        _ = await restore(receipt, organization: organization)
    }

    private func restore(_ change: WorkDeskLocationUndo,
                         organization: WorkDeskOrganization) async -> WorkDeskLocationUndo? {
        let rebased = Dictionary(uniqueKeysWithValues: change.after.map { id, records in
            (id, latestRestoredTokens(materialID: id, records: records))
        })
        let operation = WorkDeskLocationUndo(before: change.before, after: rebased, isRestoration: change.isRestoration)
        guard await organization.undo(operation), let next = organization.lastLocationUndo,
              next.isRestoration, matchesRestorationSource(next.before, expected: rebased),
              Set(next.after.keys) == Set(change.before.keys) else { return nil }
        generated.insert(next.id)
        for (id, original) in change.before {
            guard let committed = next.after[id], Set(original) != Set(committed) else { continue }
            restoredTokens[.init(materialID: id, records: Set(original))] = committed
        }
        return next
    }

    private func latestRestoredTokens(materialID: UUID,
                                     records: [WorkDeskLocationRecord]) -> [WorkDeskLocationRecord] {
        var current = records
        var visited = Set<RestoredTokenKey>()
        while true {
            let key = RestoredTokenKey(materialID: materialID, records: Set(current))
            guard visited.insert(key).inserted else { return current }
            if let restored = restoredTokens[key] {
                current = restored
                continue
            }
            // An earlier receipt may predate first layout, while the trusted
            // restoration began from that generated position. Match only keys
            // in our own confirmed chain, never arbitrary current store state.
            let seededMatches = restoredTokens.filter { known, _ in
                known.materialID == materialID && known.records.count == key.records.count
                    && known.records.allSatisfy { record in key.records.contains { record.matchesForUndo($0) } }
            }
            guard seededMatches.count == 1, let restored = seededMatches.first?.value else { return current }
            current = restored
        }
    }

    private func matchesRestorationSource(_ current: WorkDeskLocationTokens,
                                          expected: WorkDeskLocationTokens) -> Bool {
        guard Set(current.keys) == Set(expected.keys) else { return false }
        return current.allSatisfy { id, records in
            guard let earlier = expected[id], records.count == earlier.count else { return false }
            return records.allSatisfy { record in
                // The store permits only an automatic first layout to fill an
                // unset position without changing membership revision. Confirm
                // that same narrow exception before accepting its inverse.
                earlier.contains { record.matchesForUndo($0) }
            }
        }
    }
}

struct WorkDeskOrganizationUndo: ViewModifier {
    let workspace: WorkDeskWorkspaceState
    // Presented previews inherit the workspace history even if their native
    // sheet supplies a different responder-chain manager (or none).
    var undoManagerProvider: (() -> UndoManager?)? = nil
    // The compact preview and the workspace share one receipt/history owner;
    // showing Undo inside the sheet must not register the same operation twice.
    private var controller: WorkDeskOrganizationUndoController { workspace.organizationUndo }
    @Environment(\.undoManager) private var undoManager
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var manager: UndoManager? {
        if let undoManagerProvider { return undoManagerProvider() }
        return undoManager
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.organization.lastLocationUndo) { _, receipt in
                guard isActive, let receipt else { return }
                controller.receive(receipt, organization: workspace.organization, manager: manager)
            }
            .overlay(alignment: .bottomLeading) {
                if isActive, controller.showsUndo {
                    HStack(spacing: 12) {
                        Text(LocalizedStringResource("workdesk.undo.updated", defaultValue: "Materials organised"))
                            .font(.subheadline)
                        Button(LocalizedStringResource("workdesk.undo.action", defaultValue: "Undo")) {
                            Task { await controller.undoLatest(organization: workspace.organization, manager: manager) }
                        }
                        .inlineLinkButton()
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(controller.isApplying)
                        Button { controller.showsUndo = false } label: {
                            Image(systemName: "xmark").frame(width: 32, height: 44)
                        }.pointerIconButton(size: 32)
                        .accessibilityLabel(Text(LocalizedStringResource("workdesk.undo.dismiss", defaultValue: "Dismiss undo message")))
                    }
                    .padding(.leading, 16).padding(.trailing, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(AppColors.borderSubtle).allowsHitTesting(false) }
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                    .padding(12)
                    .transition(.opacity)
                    .task(id: controller.receipt?.id) {
                        do { try await Task.sleep(for: .seconds(7)) } catch { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { controller.showsUndo = false }
                    }
                }
            }
    }
}

struct WorkDeskRailDropTarget: ViewModifier {
    let workspace: WorkDeskWorkspaceState
    let scope: WorkDeskScope
    let title: String
    let isEnabled: Bool
    @State private var targetID = UUID()
    @State private var targetFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .workDeskMaterialLocationDrop(location: scope.location, isEnabled: isEnabled,
                organization: workspace.organization)
            .overlay {
                if workspace.transferCoordinator.isDragging,
                   workspace.transferCoordinator.destination?.surfaceID == targetID {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(AppColors.brandAmber, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                targetFrame = frame
                updateTarget()
            }
            .onChange(of: isEnabled) { _, _ in updateTarget() }
            .onAppear { updateTarget() }
            .onDisappear { workspace.transferCoordinator.removeSurface(id: targetID) }
    }
    private func updateTarget() {
        guard isEnabled else { workspace.transferCoordinator.removeSurface(id: targetID); return }
        workspace.transferCoordinator.register(WorkDeskTransferSurface(id: targetID,
            location: scope.location, title: title, frame: targetFrame, priority: 40, isSpatial: false))
    }

}
