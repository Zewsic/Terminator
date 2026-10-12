import SwiftUI
import TerminatorCore

struct SnippetEditor: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: SnippetDraft
    @State private var originalDraft: SnippetDraft
    @State private var showsExecute = false
    @State private var isOrganizationExpanded = true
    let onSave: @MainActor (SnippetDraft) async -> SnippetProfile?

    init(draft: SnippetDraft, onSave: @escaping @MainActor (SnippetDraft) async -> SnippetProfile?) {
        _draft = State(initialValue: draft)
        _originalDraft = State(initialValue: draft)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var savedSnippet: SnippetProfile? {
        guard let id = draft.id else { return nil }
        return model.snippets.first { $0.id == id }
    }

    var body: some View {
        InspectorScreen(title: draft.id == nil ? FeatureL10n.text(.snippetNew) : draft.name) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.snippetName)) {
                    TextField(FeatureL10n.text(.snippetName), text: $draft.name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }
            InspectorFieldGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FeatureL10n.text(.snippetScript))
                        .fontWeight(.medium)
                    TextField(FeatureL10n.text(.snippetScript), text: $draft.script, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .lineLimit(6...16)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            InspectorCollapsibleSection(FeatureL10n.text(.hostsOrganization), isExpanded: $isOrganizationExpanded) {
                InspectorFieldGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsGroup))
                            .fontWeight(.medium)
                        AutocompleteTextField(
                            title: FeatureL10n.text(.hostsGroup),
                            text: $draft.group,
                            suggestions: existingGroups
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    InspectorGroupDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsTags))
                            .fontWeight(.medium)
                        TagEditor(tags: tagsBinding, suggestions: existingTags)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    InspectorGroupDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsNotes))
                            .fontWeight(.medium)
                        TextField(FeatureL10n.text(.hostsNotes), text: $draft.notes, prompt: Text(FeatureL10n.text(.featureHostEditorEmpty)), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        } actions: {
            InspectorActionArea {
                if draft != originalDraft {
                    InspectorProminentAction(title: FeatureL10n.text(.actionSave), disabled: !canSave) {
                        Task { await save() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if savedSnippet != nil, draft == originalDraft {
                    InspectorProminentAction(title: FeatureL10n.text(.snippetExecute)) {
                        showsExecute = true
                    }
                }
            }
        }
        .sheet(isPresented: $showsExecute) {
            if let savedSnippet {
                HostPickerSheet(title: savedSnippet.name, actionTitle: FeatureL10n.text(.snippetExecute)) { host in
                    await model.executeSnippet(savedSnippet, on: host)
                }
            }
        }
    }

    private var existingGroups: [String] {
        let hosts = model.hosts.compactMap { host -> String? in
            let value = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let snippets = model.snippets.compactMap { snippet -> String? in
            let value = snippet.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        return Array(Set(hosts + snippets)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var existingTags: [String] {
        Array(Set(model.hosts.flatMap(\.tags) + model.snippets.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var tagsBinding: Binding<[String]> {
        Binding(
            get: { draft.tags },
            set: { draft.tagsText = $0.joined(separator: ", ") }
        )
    }

    private func save() async {
        guard let saved = await onSave(draft) else { return }
        let next = SnippetDraft(snippet: saved)
        draft = next
        originalDraft = next
    }
}
