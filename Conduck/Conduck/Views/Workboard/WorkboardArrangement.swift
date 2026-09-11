// SPDX-License-Identifier: Apache-2.0

// The desk's presentation preference and drag feedback. A drag only advertises
// card identity, within this process; the pane's file/text import destination
// cannot claim it. Hover rearranges what is DRAWN — the lifted card leaves the
// board and a placeholder stands in the slot it would land in — and never
// persisted order, so cancelling a drag needs no database rollback. Both
// layouts commit through the same rebase-aware view-model operation on release.

import SwiftUI
import UniformTypeIdentifiers

/// The free-placement layout. `.desk` and its stored raw value are frozen —
/// `save()` persists `rawValue`, so the label is free to differ — and the label
/// is "Canvas" because "Your desk" is a SCOPE in the same sidebar: a project's
/// view menu offering "Desk" would name something that is not the desk.
enum WorkboardLayoutMode: String, CaseIterable {
    case desk
    case tiles
    case list

    var title: LocalizedStringResource {
        switch self {
        case .desk: LocalizedStringResource("workdesk.layout.desk", defaultValue: "Canvas")
        case .tiles: LocalizedStringResource("workboard.layout.tiles", defaultValue: "Tiles")
        case .list: LocalizedStringResource("workboard.layout.list", defaultValue: "List")
        }
    }

    var symbol: String {
        switch self {
        case .desk: "rectangle.3.group"
        case .tiles: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    static func load() -> Self {
        let value = SettingsDependencies.processDefault.defaults.string(forKey: Constants.workboardLayoutKey)
        return value.flatMap(Self.init(rawValue:)) ?? .desk
    }

    func save() {
        SettingsDependencies.processDefault.defaults.set(rawValue, forKey: Constants.workboardLayoutKey)
    }
}

/// Measured list rows, including Dynamic Type height, in the board's space.
/// A preference replaces the whole map each layout pass so deleted rows leave
/// no stale drop targets behind.
struct WorkboardRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

extension WorkMaterialDragPayload {
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        // UUID-only Codable data cannot fail to encode. Keep the representation
        // explicit on both ends instead of relying on Transferable's wire codec.
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.conduckWorkboardMaterial.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

struct WorkboardReorderDropDelegate: DropDelegate {
    let isEnabled: Bool
    let onLocation: (CGPoint?) -> Void
    let onDrop: (NSItemProvider, CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.conduckWorkboardMaterial])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        onLocation(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            onLocation(nil)
            return DropProposal(operation: .cancel)
        }
        onLocation(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onLocation(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onLocation(nil)
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [.conduckWorkboardMaterial]).first else { return false }
        return onDrop(provider, info.location)
    }
}

// MARK: - What the board draws while a card is lifted

/// The board's appearance during a drag, as a pure value.
///
/// One footprint makes the slot rectangles fixed for a given (count, width),
/// so live reflow is affordable: the lifted card leaves the sequence and a
/// same-sized placeholder takes the slot it would land in, which is the answer
/// a person can read directly. A destination ghost drawn over the CURRENT
/// arrangement cannot say the same thing — it lands on top of an occupied card
/// and reads as replacement rather than insertion.
///
/// THE INDEX CONTRACT, which is the whole reason this is a named type. A slot
/// is always expressed in the CURRENT, source-PRESENT order, `0...count` —
/// exactly what `WorkboardMosaicEngine.insertionSlot` returns and exactly what
/// `WorkboardMaterialOrdering.order(moving:toInsertionIndex:)` expects, because
/// that planner performs the source-removal adjustment itself. `entries` does
/// the same subtraction to decide where the placeholder DRAWS, and that
/// converted index never travels back out: handing it to the planner would
/// subtract twice and land the card one slot early.
nonisolated enum WorkboardDragArrangement {
    /// One drawn position: a real card, or the gap the lifted card would fall
    /// into. The placeholder carries no identity — it is the source's own
    /// footprint, and there is at most one on the board.
    nonisolated enum Entry: Hashable, Sendable {
        case card(UUID)
        case placeholder
    }

    /// What the board draws. With no drag in flight, or a source the board no
    /// longer holds — deleted under the finger, or folded into a picture that
    /// arrived — this is the plain card order, so a drag whose subject
    /// disappears leaves no placeholder behind.
    static func entries(
        displayedIDs: [UUID],
        sourceID: UUID?,
        acceptedSlot: Int?
    ) -> [Entry] {
        guard let sourceID,
              let acceptedSlot,
              let sourceIndex = displayedIDs.firstIndex(of: sourceID) else {
            return displayedIDs.map(Entry.card)
        }
        var lifted = displayedIDs.map(Entry.card)
        lifted.remove(at: sourceIndex)
        let position = placeholderIndex(
            forSlot: acceptedSlot,
            sourceIndex: sourceIndex,
            count: displayedIDs.count
        )
        lifted.insert(.placeholder, at: min(position, lifted.count))
        return lifted
    }

    /// Where the placeholder DRAWS, in the source-removed array.
    ///
    /// A slot is a gap between cards of the current order, so removing the
    /// lifted card first shifts every later gap down by one — the same
    /// adjustment `WorkboardMaterialOrdering.order(moving:toInsertionIndex:)`
    /// makes on the way to a permutation. This is presentation only: feeding
    /// the result back to that planner applies the subtraction a second time.
    static func placeholderIndex(forSlot slot: Int, sourceIndex: Int?, count: Int) -> Int {
        let cards = max(0, count)
        let bounded = min(max(slot, 0), cards)
        guard let sourceIndex, sourceIndex >= 0, sourceIndex < cards else {
            return bounded
        }
        let adjusted = bounded > sourceIndex ? bounded - 1 : bounded
        return min(max(adjusted, 0), max(0, cards - 1))
    }

    /// The commit a slot means, named by a CARD rather than by an integer.
    ///
    /// A slot index is only true of the order the pointer was over. The drop
    /// decodes its payload asynchronously and the reorder then waits for the
    /// desk's mutation lane, and an arrival landing in either gap silently
    /// changes which gap an integer names — so release resolves the slot to a
    /// visible neighbour and a side, and the planner re-finds that neighbour in
    /// whatever order it eventually sees. A neighbour that has since gone makes
    /// the move a refusal the person can see, which is the honest outcome; a
    /// stale integer would move a different card instead.
    static func commitTarget(
        slot: Int,
        displayedIDs: [UUID]
    ) -> (neighbourID: UUID, placement: WorkboardReorderPlacement)? {
        guard !displayedIDs.isEmpty else { return nil }
        let bounded = min(max(slot, 0), displayedIDs.count)
        let neighbour = displayedIDs[min(bounded, displayedIDs.count - 1)]
        return (neighbour, bounded == displayedIDs.count ? .after : .before)
    }
}
