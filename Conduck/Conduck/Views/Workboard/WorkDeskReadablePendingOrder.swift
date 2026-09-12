// SPDX-License-Identifier: Apache-2.0

// A released native drag shows its intended order while the existing mutation
// lane saves it. This is presentation only: current snapshots supply the cards,
// and any new membership, navigation or canonical order supersedes the preview.
// Failure removes the preview; there is no stale snapshot to roll back into storage.

import Foundation

struct WorkDeskReadablePendingOrder {
    let id = UUID()
    private let context: WorkDeskReadableReorderContext
    private let orderedIDs: [UUID]

    init?(moving materialID: UUID, relativeTo targetID: UUID, placement: WorkboardReorderPlacement,
          materials: [WorkboardMaterialSnapshot], context: WorkDeskReadableReorderContext) {
        guard materials.map(\.id) == context.visibleIDs,
              let order = WorkboardMaterialOrdering.order(moving: materialID, relativeTo: targetID,
                                                         placement: placement, in: materials) else { return nil }
        self.context = context
        orderedIDs = order
    }

    func project(_ materials: [WorkboardMaterialSnapshot], context current: WorkDeskReadableReorderContext)
        -> [WorkboardMaterialSnapshot] {
        guard current == context, materials.map(\.id) == context.visibleIDs else { return materials }
        let byID = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedIDs.compactMap { byID[$0] }
    }
}
