// SPDX-License-Identifier: Apache-2.0

// The desk's presentation preference and drag feedback. A drag only advertises
// card identity, within this process; the pane's file/text import destination
// cannot claim it. Hover changes an insertion marker, never persisted order,
// so cancelling a drag needs no database rollback. Both layouts commit through
// the same revision-aware view-model operation on release.

import SwiftUI
import UniformTypeIdentifiers

enum WorkboardLayoutMode: String, CaseIterable {
    case tiles
    case list

    var title: LocalizedStringResource {
        switch self {
        case .tiles: LocalizedStringResource("workboard.layout.tiles", defaultValue: "Tiles")
        case .list: LocalizedStringResource("workboard.layout.list", defaultValue: "List")
        }
    }

    var symbol: String {
        self == .tiles ? "square.grid.2x2" : "list.bullet"
    }

    static func load() -> Self {
        let value = SettingsDependencies.processDefault.defaults.string(forKey: Constants.workboardLayoutKey)
        return value.flatMap(Self.init(rawValue:)) ?? .tiles
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
