import SwiftUI
import TerminatorCore

struct SessionLogsView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        Group {
            if model.sessionLogs.isEmpty {
                ContentUnavailableView("No session logs", systemImage: "text.document", description: Text("Remote terminal output will be encrypted and saved automatically."))
            } else {
                List(model.sessionLogs) { log in
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
                        Button("Export…") { Task { await model.exportLog(log) } }.disabled(log.state == .active)
                        Button("Delete", role: .destructive) { Task { await model.deleteLog(log) } }.disabled(log.state == .active)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } } }
    }
}
