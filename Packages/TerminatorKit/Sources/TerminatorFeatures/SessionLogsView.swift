import SwiftUI
import TerminatorCore

struct SessionLogsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedLogID: UUID?

    var body: some View {
        Group {
            if model.sessionLogs.isEmpty {
                ContentUnavailableView(FeatureL10n.text("ui.session.logs.view.1"), systemImage: "text.document", description: Text(FeatureL10n.text("ui.session.logs.view.2")))
            } else {
                InspectorLayout {
                    List(model.sessionLogs, selection: $selectedLogID) { log in
                    HStack(spacing: 12) {
                        Image(systemName: log.isPinned ? "pin.fill" : "terminal")
                        VStack(alignment: .leading) {
                            Text(log.hostDisplayName).fontWeight(.medium)
                            Text(FeatureL10n.text(
                                "sessionLog.summary",
                                log.terminal.displayName,
                                log.startedAt.formatted(),
                                ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file)
                            ))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(log.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button(log.isPinned ? "Unpin" : "Pin") { Task { await model.setLogPinned(log.id, pinned: !log.isPinned) } }
                        Button(FeatureL10n.text("ui.session.logs.view.3")) { Task { await model.exportLog(log) } }.disabled(log.state == .active)
                        Button(FeatureL10n.text("ui.session.logs.view.4"), role: .destructive) { Task { await model.deleteLog(log) } }.disabled(log.state == .active)
                    }
                    .tag(log.id)
                }
                } inspector: {
                    if let log = model.sessionLogs.first(where: { $0.id == selectedLogID }) {
                        SessionLogInspector(log: log) { selectedLogID = nil }
                    }
                } onContentInteraction: { selectedLogID = nil }
            }
        }
        .navigationTitle(FeatureL10n.text("ui.session.logs.view.6"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Close inspector", systemImage: "arrow.left.to.line") { selectedLogID = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close inspector")
                    .disabled(selectedLogID == nil)
                    .opacity(selectedLogID == nil ? 0 : 1)
            }
            ToolbarItem(placement: .automatic) {
                Button(FeatureL10n.text("ui.session.logs.view.5"), systemImage: "arrow.clockwise") { Task { await model.load() } }
            }
        }
    }
}

private struct SessionLogInspector: View {
    let log: SessionLogMetadata
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(log.hostDisplayName).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                LabeledContent("Terminal", value: log.terminal.displayName)
                LabeledContent("State", value: log.state.rawValue.capitalized)
                LabeledContent("Started", value: log.startedAt.formatted())
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file))
            }
            .formStyle(.grouped)
        }
    }
}
