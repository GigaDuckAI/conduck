// SPDX-License-Identifier: Apache-2.0

// Native Tiles/List drags and spatial project drop targets share one typed,
// own-process representation. It carries organization identity and revisions,
// never material text or files. Loading begins inside the accepting callback;
// a consumed request, changed destination, disappearance or stale source cannot
// later file the material somewhere else. The store repeats revision validation
// in its mutation lane before changing only the source and destination places.

import SwiftUI
import Observation
import UniformTypeIdentifiers

extension WorkMaterialDragPayload {
    @MainActor
    static func deskMaterial(materialID: UUID, materialIDs: [UUID], source: WorkDeskLocation,
                             organization: WorkDeskOrganization) -> Self? {
        let ids = [materialID] + Set(materialIDs).subtracting([materialID]).sorted { $0.uuidString < $1.uuidString }
        guard ids.allSatisfy({ organization.contains(materialID: $0, at: source) }) else { return nil }
        return .init(itemID: Constants.workboardDeskItemID, materialID: materialID,
                     sourceLocation: source, additionalMaterialIDs: Array(ids.dropFirst()),
                     expectedLocationTokens: organization.locationTokens(for: ids))
    }

    /// Missing location fields identify an older reorder payload, not a claim
    /// that the material came from Home. Foreign and incomplete groups refuse.
    nonisolated func validatedLocationMove(to destination: WorkDeskLocation,
                                          current: WorkDeskLocationTokens) -> WorkDeskMaterialLocationMove? {
        guard itemID == Constants.workboardDeskItemID, let sourceLocation,
              let expectedLocationTokens,
              Set(materialIDs).count == materialIDs.count,
              Set(expectedLocationTokens.keys) == Set(materialIDs) else { return nil }
        for id in materialIDs {
            guard let expected = expectedLocationTokens[id], !expected.isEmpty,
                  expected.allSatisfy({ $0.materialID == id }),
                  expected.contains(where: { $0.location == sourceLocation }),
                  Set(expected) == Set(current[id] ?? []) else { return nil }
        }
        return .init(materialIDs: materialIDs, source: sourceLocation, destination: destination,
                     expected: expectedLocationTokens)
    }
}

nonisolated struct WorkDeskMaterialLocationMove: Equatable, Sendable {
    let materialIDs: [UUID]
    let source: WorkDeskLocation
    let destination: WorkDeskLocation
    let expected: WorkDeskLocationTokens
}

@MainActor @Observable
final class WorkDeskMaterialDropSession {
    private var pendingID: UUID?
    private var acceptedDestination: WorkDeskLocation?
    var isResolving: Bool { pendingID != nil }

    func accept(at destination: WorkDeskLocation) -> UUID? {
        guard pendingID == nil else { return nil }
        let id = UUID()
        pendingID = id
        acceptedDestination = destination
        return id
    }

    func cancel() {
        pendingID = nil
        acceptedDestination = nil
    }

    func resolve(_ payload: WorkMaterialDragPayload?, token: UUID, destination: WorkDeskLocation,
                 isEnabled: Bool, current: WorkDeskLocationTokens) -> WorkDeskMaterialLocationMove? {
        guard pendingID == token else { return nil }
        let accepted = acceptedDestination
        cancel()
        guard isEnabled, accepted == destination else { return nil }
        return payload?.validatedLocationMove(to: destination, current: current)
    }
}

private struct WorkDeskMaterialLocationDrop: ViewModifier {
    let location: WorkDeskLocation
    let isEnabled: Bool
    let organization: WorkDeskOrganization
    let acceptsPoint: (CGPoint) -> Bool
    let positions: (WorkMaterialDragPayload, CGPoint) -> [UUID: WorkDeskPoint]
    let onMoved: ([UUID]) -> Void
    @State private var session = WorkDeskMaterialDropSession()
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.conduckWorkboardMaterial], delegate: WorkboardReorderDropDelegate(
                isEnabled: isEnabled && !session.isResolving,
                onLocation: { point in isTargeted = point.map(acceptsPoint) ?? false },
                onDrop: receive
            ))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AppColors.accent, lineWidth: 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: location) { _, _ in cancel() }
            .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
            .onDisappear { cancel() }
    }

    private func cancel() {
        session.cancel()
        isTargeted = false
    }

    private func receive(_ provider: NSItemProvider, _ point: CGPoint) -> Bool {
        guard isEnabled, point.x.isFinite, point.y.isFinite,
              acceptsPoint(point),
              let token = session.accept(at: location) else { return false }
        // Begin the provider read synchronously while drop access is granted.
        provider.loadDataRepresentation(forTypeIdentifier: UTType.conduckWorkboardMaterial.identifier) { data, _ in
            let payload = data.flatMap { try? JSONDecoder().decode(WorkMaterialDragPayload.self, from: $0) }
            Task { @MainActor in
                let current = organization.locationTokens(for: payload?.materialIDs ?? [])
                guard let move = session.resolve(payload, token: token, destination: location,
                    isEnabled: isEnabled && acceptsPoint(point), current: current), let payload else { return }
                let saved = await organization.move(materialIDs: move.materialIDs, from: move.source,
                    to: move.destination, positions: positions(payload, point), expected: move.expected)
                if saved { onMoved(move.materialIDs) }
            }
        }
        return true
    }
}

extension View {
    func workDeskMaterialLocationDrop(
        location: WorkDeskLocation, isEnabled: Bool, organization: WorkDeskOrganization,
        acceptsPoint: @escaping (CGPoint) -> Bool = { _ in true },
        positions: @escaping (WorkMaterialDragPayload, CGPoint) -> [UUID: WorkDeskPoint] = { _, _ in [:] },
        onMoved: @escaping ([UUID]) -> Void = { _ in }
    ) -> some View {
        modifier(WorkDeskMaterialLocationDrop(location: location, isEnabled: isEnabled,
            organization: organization, acceptsPoint: acceptsPoint, positions: positions, onMoved: onMoved))
    }
}
