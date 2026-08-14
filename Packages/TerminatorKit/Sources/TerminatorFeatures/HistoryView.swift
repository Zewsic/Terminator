import SwiftUI
import TerminatorCore

struct HistoryView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var filter: HistoryEntity?
    @State private var pendingRestore: HistoryEntry?

    private var entries: [HistoryEntry] {
        guard let filter else { return model.history }
        return model.history.filter { $0.entity == filter }
    }

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("Host, identity, and credential metadata changes will appear here.")
                )
            } else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: entry.operation))
                            .foregroundStyle(color(for: entry.operation))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .fontWeight(.medium)
                            Text(summary(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Revert") { pendingRestore = entry }
                            .disabled(entry.operation == .purged)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("history-list")
            }
        }
        .navigationTitle("History")
        .toolbar {
            Picker("Entity", selection: $filter) {
                Text("All").tag(HistoryEntity?.none)
                Text("Hosts").tag(Optional(HistoryEntity.host))
                Text("Credentials").tag(Optional(HistoryEntity.credential))
                Text("Identities").tag(Optional(HistoryEntity.identity))
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
        .confirmationDialog(
            "Revert this change?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revert") {
                if let pendingRestore {
                    Task { await model.revert(historyEntryID: pendingRestore.id) }
                }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Reverting creates a new history entry. Existing history is never rewritten.")
        }
    }

    private func summary(for entry: HistoryEntry) -> String {
        switch entry.entity {
        case .host:
            if let data = entry.afterSnapshot,
               let host = try? JSONDecoder().decode(HostProfile.self, from: data) {
                return "\(host.displayName) · \(host.username)@\(host.hostname):\(host.port)"
            }
        case .credential:
            if let data = entry.afterSnapshot,
               let credential = try? JSONDecoder().decode(CredentialMetadata.self, from: data) {
                return FeatureL10n.text("history.credentialSummary", credential.label, credential.kind.displayName)
            }
        case .identity:
            if let data = entry.afterSnapshot,
               let identity = try? JSONDecoder().decode(IdentityProfile.self, from: data) {
                return FeatureL10n.text("history.identitySummary", identity.name, identity.username, identity.authenticationMethods.count)
            }
        }
        return entry.entityID.uuidString
    }

    private func icon(for operation: HistoryOperation) -> String {
        switch operation {
        case .created: "plus.circle"
        case .updated: "pencil.circle"
        case .deleted: "archivebox.circle"
        case .restored: "arrow.uturn.backward.circle"
        case .purged: "trash.circle"
        }
    }

    private func color(for operation: HistoryOperation) -> Color {
        switch operation {
        case .created: .green
        case .updated: .blue
        case .deleted: .orange
        case .restored: .purple
        case .purged: .red
        }
    }
}
