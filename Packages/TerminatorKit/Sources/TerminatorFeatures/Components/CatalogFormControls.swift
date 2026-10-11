import SwiftUI
import TerminatorCore

extension SSHConnectionPhase {
    var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

struct AutocompleteTextField: View {
    let title: String
    @Binding var text: String
    let suggestions: [String]
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return suggestions.filter {
            $0.localizedCaseInsensitiveContains(query)
                && $0.localizedCaseInsensitiveCompare(query) != .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if isFocused, !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches.prefix(4), id: \.self) { suggestion in
                        Button(suggestion) { text = suggestion }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
            }
        }
    }
}

struct TagEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return suggestions.filter { suggestion in
            suggestion.localizedCaseInsensitiveContains(query)
                && !tags.contains { $0.localizedCaseInsensitiveCompare(suggestion) == .orderedSame }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            TextField(FeatureL10n.text(.featureCatalogFormControlsTag), text: $input)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { commitInput() }
            if isFocused, !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches.prefix(4), id: \.self) { suggestion in
                        Button(suggestion) { add(suggestion) }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitInput() }
        }
    }

    private func commitInput() {
        add(input)
    }

    private func add(_ value: String) {
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { input = ""; return }
        if !tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        input = ""
    }
}
