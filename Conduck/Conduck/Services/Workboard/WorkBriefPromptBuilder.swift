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
    /// Second sort key. Two devices capturing offline both derive the same
    /// `sequence` from the order they can see, so the prompt must break that
    /// tie exactly the way the board does or the person approves one order and
    /// the gateway receives another.
    let createdAt: Date

    init(
        id: UUID,
        kind: Kind,
        label: String,
        text: String? = nil,
        url: String? = nil,
        mimeType: String? = nil,
        byteSize: Int64? = nil,
        sequence: Int,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.text = text
        self.url = url
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

extension WorkBriefMaterialPacket {
    /// The ONE mapping from a stored material to its canonical prompt row.
    ///
    /// Dispatch uses this initializer directly. Preview cannot: it composes from
    /// a `WorkboardItemSnapshot`, so `WorkboardPromptComposer.compose` builds its
    /// packet inline from snapshot fields — but those fields come from
    /// `WorkboardLiveRepository.presentationKind` / `.materialName`, which
    /// delegate to `packetKind` / `label` below. So both sides still resolve one
    /// record through ONE kind decision and ONE naming decision, which is what
    /// the send boundary requires: it refuses any brief whose final prompt
    /// differs from the previewed one by a byte, so a second hand-written
    /// mapping would turn a routine material into a permanent, unexplainable
    /// refusal that reopening Review & Send cannot clear.
    init(record: WorkMaterialRecord) {
        let kind = Self.packetKind(for: record)
        self.init(
            id: record.id,
            kind: kind,
            label: Self.label(for: record, kind: kind),
            // File extraction belongs to the attachment delivery lane, and the
            // store already keeps a file/image extract out of the mirrored row.
            // Whatever a row does carry was shown in the preview, so it must
            // also be what the gateway receives.
            text: record.textContent,
            url: record.urlString,
            mimeType: record.mimeType,
            // Zero is a valid empty file, not a missing size. Printing
            // "0 bytes" would describe the material with a fact the human
            // never saw.
            byteSize: record.byteSize > 0 ? record.byteSize : nil,
            sequence: record.sequence,
            createdAt: record.createdAt
        )
    }

    /// Not private: the presentation mapping calls it so the preview and the
    /// dispatch cannot disagree about what a record IS.
    static func packetKind(for record: WorkMaterialRecord) -> Kind {
        switch record.kind {
        case .image: return .image
        case .file, .audio: return .file
        case .link: return .link
        case .note, .transcript: return .note
        case .unknown: return record.filename != nil || record.hasPayload ? .file : .note
        }
    }

    /// Title, then filename, then the link's host, then the kind's own noun.
    /// Each candidate is judged on its trimmed form but emitted verbatim: the
    /// serializer owns the final normalization.
    ///
    /// Not private, for the same reason as `packetKind`: the card's name and the
    /// prompt row's label are the same decision, made once.
    static func label(for record: WorkMaterialRecord, kind: Kind) -> String {
        let candidates = [record.title, record.filename ?? ""]
        if let value = candidates.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return value
        }
        if let value = record.urlString,
           let host = URLComponents(string: value)?.host,
           !host.isEmpty {
            return host
        }
        switch kind {
        case .image:
            return String(localized: "workboard.material.image", defaultValue: "Image")
        case .file:
            return String(localized: "workboard.material.file", defaultValue: "File")
        case .link:
            return String(localized: "workboard.material.link", defaultValue: "Link")
        case .note:
            return String(localized: "workboard.material.note", defaultValue: "Note")
        }
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
    /// are ordered by `(sequence, createdAt, id)` — the SAME key the board
    /// renders with, so the arrangement the person approved is the arrangement
    /// that ships — and dates are UTC ISO-8601.
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
            ($0.sequence, $0.createdAt, $0.id.uuidString)
                < ($1.sequence, $1.createdAt, $1.id.uuidString)
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
