// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkBriefPromptBuilder.swift
//
// Canonical, deterministic serialization for one deliberate Workboard dispatch.
// The preview, immutable snapshot, and gateway payload all consume the same
// packet so the user never approves one brief while the gateway receives another.

#if !os(watchOS)
import Foundation

/// Gateway-neutral material captured while a work item is still an inert draft.
/// Binary payloads travel beside the prompt; this value describes the exact
/// human-readable representation included in the canonical text packet.
nonisolated struct WorkBriefMaterialPacket: Equatable, Sendable {
    nonisolated enum Kind: String, CaseIterable, Codable, Sendable {
        case note
        case link
        case image
        case file
    }

    let id: UUID
    let kind: Kind
    let label: String
    let text: String?
    let url: String?
    let mimeType: String?
    let byteSize: Int64?
    let sequence: Int

    init(
        id: UUID,
        kind: Kind,
        label: String,
        text: String? = nil,
        url: String? = nil,
        mimeType: String? = nil,
        byteSize: Int64? = nil,
        sequence: Int
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.text = text
        self.url = url
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sequence = sequence
    }
}

/// The exact human-approved text and ordered material manifest for one send.
/// It is a value snapshot: editing the live work item can never mutate it.
nonisolated struct WorkBriefPacket: Equatable, Sendable {
    static let schemaVersion: Int16 = 1

    let workItemID: UUID
    let title: String
    let objective: String
    let context: String
    let constraints: String
    let desiredResult: String
    let reviewBy: Date?
    let materials: [WorkBriefMaterialPacket]
    let canonicalPrompt: String

    var materialIDs: [UUID] { materials.map(\.id) }
}

/// A single serializer for prompt preview and dispatch persistence.
nonisolated enum WorkBriefPromptBuilder {
    /// Builds a stable packet. Empty optional sections are omitted, materials
    /// are ordered by user sequence then UUID, and dates are UTC ISO-8601.
    static func build(
        workItemID: UUID,
        title: String,
        objective: String,
        context: String,
        constraints: String,
        desiredResult: String,
        reviewBy: Date?,
        materials: [WorkBriefMaterialPacket]
    ) -> WorkBriefPacket {
        let normalizedTitle = normalized(title)
        let normalizedObjective = normalized(objective)
        let normalizedContext = normalized(context)
        let normalizedConstraints = normalized(constraints)
        let normalizedDesiredResult = normalized(desiredResult)
        let orderedMaterials = materials.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }

        var sections: [String] = []
        appendSection("Title", value: normalizedTitle, to: &sections)
        appendSection("What needs doing", value: normalizedObjective, to: &sections)
        appendSection("Context", value: normalizedContext, to: &sections)
        appendSection("Constraints", value: normalizedConstraints, to: &sections)
        appendSection("A good result includes", value: normalizedDesiredResult, to: &sections)
        if let reviewBy {
            appendSection("Review by", value: iso8601(reviewBy), to: &sections)
        }

        let materialLines = orderedMaterials.map(materialLine)
        if !materialLines.isEmpty {
            sections.append("Materials\n\(materialLines.joined(separator: "\n\n"))")
        }

        return WorkBriefPacket(
            workItemID: workItemID,
            title: normalizedTitle,
            objective: normalizedObjective,
            context: normalizedContext,
            constraints: normalizedConstraints,
            desiredResult: normalizedDesiredResult,
            reviewBy: reviewBy,
            materials: orderedMaterials,
            canonicalPrompt: sections.joined(separator: "\n\n")
        )
    }

    /// True when a draft has enough human-authored substance to persist rather
    /// than becoming a blank ghost after dismissal.
    static func isSubstantive(
        title: String,
        objective: String,
        context: String,
        constraints: String,
        desiredResult: String,
        materialCount: Int
    ) -> Bool {
        materialCount > 0
            || !normalized(title).isEmpty
            || !normalized(objective).isEmpty
            || !normalized(context).isEmpty
            || !normalized(constraints).isEmpty
            || !normalized(desiredResult).isEmpty
    }

    private static func appendSection(_ heading: String, value: String, to sections: inout [String]) {
        guard !value.isEmpty else { return }
        sections.append("\(heading)\n\(value)")
    }

    private static func materialLine(_ material: WorkBriefMaterialPacket) -> String {
        let label = normalized(material.label)
        let heading = "- [\(material.kind.rawValue.capitalized)] \(label.isEmpty ? "Untitled" : label)"
        var details: [String] = []

        if let url = material.url.map(normalized), !url.isEmpty {
            details.append(url)
        }
        if let mimeType = material.mimeType.map(normalized), !mimeType.isEmpty {
            if let byteSize = material.byteSize, byteSize >= 0 {
                details.append("\(mimeType), \(byteSize) bytes")
            } else {
                details.append(mimeType)
            }
        }
        if let text = material.text.map(normalized), !text.isEmpty {
            details.append(text)
        }

        guard !details.isEmpty else { return heading }
        return heading + "\n  " + details.joined(separator: "\n  ")
    }

    /// Canonicalize user-edited line endings and surrounding whitespace without
    /// rewriting meaningful interior spacing or punctuation.
    private static func normalized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
#endif
