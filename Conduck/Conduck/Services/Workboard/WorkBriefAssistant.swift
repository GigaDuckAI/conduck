// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkBriefAssistant.swift
//
// Optional on-device shaping for a captured thought. Manual drafting remains the
// complete path: when Apple's system model is unavailable this service fails
// closed and the original transcript stays editable and recoverable.

#if !os(watchOS)
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct WorkBriefSuggestion: Equatable, Sendable {
    let title: String
    let objective: String
    let context: String
    let desiredResult: String
    let originalTranscript: String
}

nonisolated enum WorkBriefAssistantAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum WorkBriefAssistantError: Error, Equatable {
    case unavailable
    case emptyTranscript
    case generationFailed
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct GeneratedWorkBrief {
    var title: String
    var objective: String
    var context: String
    var desiredResult: String
}
#endif

/// Uses only Apple's on-device system model. It never calls the configured AI
/// gateway and never sends a draft merely because it was shaped successfully.
actor WorkBriefAssistant {
    static let shared = WorkBriefAssistant()

    private init() {}

    nonisolated static var availability: WorkBriefAssistantAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return .available
            }
        }
        #endif
        return .unavailable
    }

    func shape(transcript rawTranscript: String) async throws -> WorkBriefSuggestion {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw WorkBriefAssistantError.emptyTranscript }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw WorkBriefAssistantError.unavailable
            }
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: """
                Turn the user's captured thought into a concise, editable agent work brief.
                Preserve facts and uncertainty. Do not invent requirements, deadlines, tools,
                people, or completion. The objective says what needs doing; context contains
                useful source detail; desiredResult describes the requested shape of success.
                Keep the title short. Never include meta-commentary.
                """
            )
            do {
                let response = try await session.respond(
                    to: transcript,
                    generating: GeneratedWorkBrief.self
                )
                return WorkBriefSuggestion(
                    title: Self.normalized(response.content.title),
                    objective: Self.normalized(response.content.objective),
                    context: Self.normalized(response.content.context),
                    desiredResult: Self.normalized(response.content.desiredResult),
                    originalTranscript: transcript
                )
            } catch {
                throw WorkBriefAssistantError.generationFailed
            }
        }
        #endif
        throw WorkBriefAssistantError.unavailable
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
