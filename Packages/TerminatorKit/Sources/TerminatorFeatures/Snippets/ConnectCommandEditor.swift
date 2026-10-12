import SwiftUI
import TerminatorCore

struct ConnectCommandEditor: View {
    @Binding var segments: [ConnectCommandSegment]
    let snippets: [SnippetProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($segments) { $segment in
                if let snippetID = segment.snippetID {
                    snippetChip(id: segment.id, snippetID: snippetID)
                } else {
                    TextField(
                        FeatureL10n.text(.hostConnectCommands),
                        text: $segment.text,
                        prompt: Text(FeatureL10n.text(.hostConnectCommandsPrompt)),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .lineLimit(1...8)
                }
            }
            Menu {
                if snippets.isEmpty {
                    Text(FeatureL10n.text(.snippetEmpty))
                } else {
                    ForEach(snippets) { snippet in
                        Button(snippet.name) { insert(snippet.id) }
                    }
                }
            } label: {
                Label(FeatureL10n.text(.snippetAddSnippet), systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .onAppear {
            if segments.isEmpty { segments = [ConnectCommandSegment()] }
        }
    }

    private func snippetChip(id: UUID, snippetID: UUID) -> some View {
        let name = snippets.first { $0.id == snippetID }?.name ?? FeatureL10n.text(.snippetMissing)
        return HStack(spacing: 6) {
            Image(systemName: "curlybraces")
                .font(.caption.weight(.bold))
            Text(name)
                .lineLimit(1)
            Button {
                segments.removeAll { $0.id == id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private func insert(_ snippetID: UUID) {
        let snippet = ConnectCommandSegment(snippetID: snippetID)
        if let last = segments.indices.last, segments[last].snippetID == nil, segments[last].text.isEmpty {
            segments.insert(snippet, at: last)
        } else {
            segments.append(snippet)
            segments.append(ConnectCommandSegment())
        }
    }
}
