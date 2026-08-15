import SwiftUI
import TerminatorCore

struct HistoryView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var filter: HistoryEntity?
    @State private var pendingRestore: HistoryEntry?
    @State private var selectedEntryID: UUID?

    private var entries: [HistoryEntry] {
        guard let filter else { return model.history }
        return model.history.filter { $0.entity == filter }
    }

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(FeatureL10n.text(.historyEmpty),
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text(FeatureL10n.text(.historyHostIdentityAndCredentialMetadataChangesWill))
                )
            } else {
                InspectorLayout {
                    List(entries, selection: $selectedEntryID) { entry in
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
                        Button(FeatureL10n.text(.historyRevert)) { pendingRestore = entry }
                            .disabled(entry.operation == .purged)
                    }
                    .padding(.vertical, 4)
                    .tag(entry.id)
                }
                .accessibilityIdentifier("history-list")
                } inspector: {
                    if let entry = entries.first(where: { $0.id == selectedEntryID }) {
                        HistoryInspector(entry: entry, summary: summary(for: entry)) { selectedEntryID = nil }
                    }
                } onContentInteraction: { selectedEntryID = nil }
            }
        }
        .navigationTitle(FeatureL10n.text(.historyHistory))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(FeatureL10n.text(.featureHistoryCloseInspector), systemImage: "arrow.left.to.line") { selectedEntryID = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(FeatureL10n.text(.featureHistoryCloseInspector))
                    .disabled(selectedEntryID == nil)
                    .opacity(selectedEntryID == nil ? 0 : 1)
            }
            ToolbarItem(placement: .automatic) {
                Picker(FeatureL10n.text(.historyEntity), selection: $filter) {
                    Text(FeatureL10n.text(.historyAll)).tag(HistoryEntity?.none)
                    Text(FeatureL10n.text(.overviewHosts)).tag(Optional(HistoryEntity.host))
                    Text(FeatureL10n.text(.overviewCredentials)).tag(Optional(HistoryEntity.credential))
                    Text(FeatureL10n.text(.historyIdentities)).tag(Optional(HistoryEntity.identity))
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        }
        .confirmationDialog(FeatureL10n.text(.historyRevertConfirmationTitle),
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.historyRevert)) {
                if let pendingRestore {
                    Task { await model.revert(historyEntryID: pendingRestore.id) }
                }
                pendingRestore = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingRestore = nil }
        } message: {
            Text(FeatureL10n.text(.historyRevertingCreatesANewHistoryEntryExisting))
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
                return FeatureL10n.text(.historyCredentialSummary, credential.label, credential.kind.displayName)
            }
        case .identity:
            if let data = entry.afterSnapshot,
               let identity = try? JSONDecoder().decode(IdentityProfile.self, from: data) {
                return FeatureL10n.text(.historyIdentitySummary, identity.name, identity.username, identity.authenticationMethods.count)
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

private struct HistoryInspector: View {
    let entry: HistoryEntry
    let summary: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.title).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                LabeledContent(FeatureL10n.text(.featureHistoryOperation), value: entry.operation.rawValue.capitalized)
                LabeledContent(FeatureL10n.text(.featureHistoryWhen), value: entry.timestamp.formatted())
                Section(FeatureL10n.text(.credentialsDetails)) { Text(summary).textSelection(.enabled) }
            }
            .formStyle(.grouped)
        }
    }
}
