import SwiftUI
import TerminatorCore

struct SessionLogsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedLogID: UUID?
    @State private var search = ""

    private var filteredLogs: [SessionLogMetadata] {
        guard !search.isEmpty else { return model.sessionLogs }
        return model.sessionLogs.filter { log in
            log.hostDisplayName.localizedCaseInsensitiveContains(search)
                || log.terminal.displayName.localizedCaseInsensitiveContains(search)
                || log.state.rawValue.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.sessionLogs.isEmpty {
                ContentUnavailableView(FeatureL10n.text(.sessionLogsNoSessionLogs), systemImage: "text.document", description: Text(FeatureL10n.text(.sessionLogsRemoteTerminalOutputWillBeEncryptedAnd)))
            } else {
                InspectorLayout {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredLogs) { log in
                                HStack(spacing: 12) {
                                    Image(systemName: log.isPinned ? "pin.fill" : "terminal")
                                    VStack(alignment: .leading) {
                                        Text(log.hostDisplayName).fontWeight(.medium)
                                        Text(FeatureL10n.text(
                                            .sessionlogSummary,
                                            log.terminal.displayName,
                                            log.startedAt.formatted(),
                                            ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file)
                                        ))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(log.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    if selectedLogID == log.id {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedLogID = log.id }
                                .contextMenu {
                                    Button(FeatureL10n.text(log.isPinned ? .actionUnpin : .actionPin)) { Task { await model.setLogPinned(log.id, pinned: !log.isPinned) } }
                                    Button(FeatureL10n.text(.sessionLogsExport)) { Task { await model.exportLog(log) } }.disabled(log.state == .active)
                                    Button(FeatureL10n.text(.sessionLogsDelete), role: .destructive) { Task { await model.deleteLog(log) } }.disabled(log.state == .active)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } inspector: {
                    if let log = model.sessionLogs.first(where: { $0.id == selectedLogID }) {
                        SessionLogInspector(log: log) { selectedLogID = nil }
                    }
                } onContentInteraction: { selectedLogID = nil }
            }
        }
        .navigationTitle(FeatureL10n.text(.sessionLogsLogs))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button(FeatureL10n.text(.featureHistoryCloseInspector), systemImage: "arrow.left.to.line") { selectedLogID = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(FeatureL10n.text(.featureHistoryCloseInspector))
                    .disabled(selectedLogID == nil)
                    .opacity(selectedLogID == nil ? 0 : 1)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button(FeatureL10n.text(.sessionLogsRefresh), systemImage: "arrow.clockwise") { Task { await model.load() } }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: "Search logs")
            }
            .sharedBackgroundVisibility(.hidden)
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
                LabeledContent(FeatureL10n.text(.featureSessionLogsTerminal), value: log.terminal.displayName)
                LabeledContent(FeatureL10n.text(.featureContainersState), value: log.state.rawValue.capitalized)
                LabeledContent(FeatureL10n.text(.featureSessionLogsStarted), value: log.startedAt.formatted())
                LabeledContent(FeatureL10n.text(.featureSessionLogsSize), value: ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file))
            }
            .formStyle(.grouped)
        }
    }
}
