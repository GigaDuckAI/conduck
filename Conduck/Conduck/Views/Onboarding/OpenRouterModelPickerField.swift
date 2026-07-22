// Conduck
// OpenRouterModelPickerField.swift
//
// Shared model field for the guided hosted-model (OpenRouter) screens — the
// required "Model" text field, its helper line, and the `/v1/models` suggestion
// strip (with a lightweight filter for the large OpenRouter catalog). Extracted
// so the first-time SETUP body (`HostedModelGatewayStepView`) and the dedicated
// EDIT step (`HostedModelEditStepView`) render an IDENTICAL picker without
// duplicating ~100 lines of suggestion/filter logic.
//
// State-agnostic: the caller owns where the chosen model lives. Setup binds
// `selection` to the per-ref VM buffer (live edit); edit binds it to a LOCAL
// draft committed to the VM only at save. `suggestions` is the VM's discovered
// catalog (`remoteAgentModelSuggestions[ref]`), populated by a validate/retest
// probe; `filter` is a buffer-only local string.

import SwiftUI

/// The required model field + suggestion picker for the OpenRouter guided
/// screens. Copy is identical across setup and edit; only the bindings differ.
struct OpenRouterModelPickerField: View {
    /// The chosen model ID. Caller decides whether this is the live VM buffer
    /// (setup) or a local draft committed at save (edit).
    @Binding var selection: String

    /// Local filter buffer for the suggestion strip (appears only for large
    /// catalogs). Buffer-only — never persisted.
    @Binding var filter: String

    /// The discovered model catalog (`remoteAgentModelSuggestions[ref]`), empty
    /// until a validate/retest probe runs.
    let suggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Model") // xcstrings: hosted-model
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource("settings.field.required", defaultValue: "(required)"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            TextField(
                String(localized: LocalizedStringResource(
                    "settings.remoteAgent.model.placeholder.hosted",
                    defaultValue: "e.g. anthropic/claude-opus-4"
                )),
                text: $selection
            )
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .padding(14)
                .background(AppColors.cardBackground)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppColors.borderSubtle, lineWidth: 1)
                )
                .frame(maxWidth: Constants.Layout.buttonMaxWidth)

            Text(LocalizedStringResource(
                "settings.remoteAgent.model.helper.hosted.onboarding",
                defaultValue: "Validate your key to load the model list, or type a model ID."
            ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)

            suggestionList
        }
        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            let showFilter = suggestions.count > 12
            let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = (showFilter && !query.isEmpty)
                ? suggestions.filter { $0.localizedCaseInsensitiveContains(query) }
                : suggestions
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.model.suggestions.header",
                    defaultValue: "Available models"
                ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                if showFilter {
                    TextField(
                        String(localized: LocalizedStringResource(
                            "settings.remoteAgent.model.suggestions.filter.placeholder",
                            defaultValue: "Filter models"
                        )),
                        text: $filter
                    )
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                }
                if visible.isEmpty {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.model.suggestions.noMatch",
                        defaultValue: "No models match your filter."
                    ))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visible, id: \.self) { model in
                                Button {
                                    selection = model
                                } label: {
                                    Text(model)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(AppColors.backgroundSecondary))
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
