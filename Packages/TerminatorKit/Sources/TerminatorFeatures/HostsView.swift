import SwiftUI
import TerminatorCore

struct HostsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var selectedHostID: UUID?
    @State private var editorDraft: HostDraft?
    @State private var pendingDelete: HostProfile?

    private var filteredHosts: [HostProfile] {
        guard !search.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.hostname.localizedCaseInsensitiveContains(search)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var selectedHost: HostProfile? {
        model.hosts.first { $0.id == selectedHostID }
    }

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } description: {
                    Text("Add an SSH host to start building your catalog.")
                } actions: {
                    Button("Add Host", systemImage: "plus") {
                        editorDraft = HostDraft()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.clear)
                    .accessibilityIdentifier("add-host-empty")
                }
            } else {
                #if os(macOS)
                HSplitView {
                    hostList
                    hostDetail
                }
                #else
                NavigationSplitView {
                    hostList
                } detail: {
                    hostDetail
                }
                #endif
            }
        }
        .navigationTitle("Hosts")
        .searchable(text: $search, prompt: "Search hosts")
        .toolbar {
            ToolbarItemGroup {
                Button("Edit", systemImage: "pencil") {
                    if let selectedHost { editorDraft = HostDraft(host: selectedHost) }
                }
                .disabled(selectedHost == nil)

                Button("Add Host", systemImage: "plus") {
                    editorDraft = HostDraft()
                }
                .accessibilityIdentifier("add-host")
            }
        }
        .sheet(item: $editorDraft) { draft in
            HostEditor(draft: draft, credentials: model.activeCredentials) { savedDraft in
                let saved = await model.saveHost(savedDraft)
                if saved { editorDraft = nil }
            }
        }
        .confirmationDialog(
            "Archive this host?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingDelete {
                    Task { await model.deleteHost(id: pendingDelete.id) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The host can be restored from History. Its credential will be retained.")
        }
    }

    private func credential(for host: HostProfile) -> CredentialMetadata? {
        guard let id = host.credentialID else { return nil }
        return model.credentials.first { $0.id == id }
    }

    private var hostList: some View {
        List(filteredHosts, selection: $selectedHostID) { host in
            HostRow(host: host)
                .tag(host.id)
                .contextMenu {
                    Button("Edit") { editorDraft = HostDraft(host: host) }
                    Button("Archive", role: .destructive) { pendingDelete = host }
                }
        }
        .frame(minWidth: 280, idealWidth: 360)
        .accessibilityIdentifier("hosts-list")
    }

    @ViewBuilder
    private var hostDetail: some View {
        if let selectedHost {
            HostDetailView(host: selectedHost, credential: credential(for: selectedHost))
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a host", systemImage: "cursorarrow.click")
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HostRow: View {
    let host: HostProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .fontWeight(.medium)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

private struct HostDetailView: View {
    let host: HostProfile
    let credential: CredentialMetadata?

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Address", value: host.hostname)
                LabeledContent("Port", value: String(host.port))
                LabeledContent("Username", value: host.username)
                LabeledContent("Credential", value: credential?.label ?? "Ask when connecting")
            }
            if let group = host.group {
                Section("Organization") {
                    LabeledContent("Group", value: group)
                    if !host.tags.isEmpty {
                        LabeledContent("Tags", value: host.tags.joined(separator: ", "))
                    }
                }
            }
            if !host.notes.isEmpty {
                Section("Notes") { Text(host.notes).textSelection(.enabled) }
            }
            Section {
                Button("Connect", systemImage: "bolt.horizontal") {}
                    .disabled(true)
            } footer: {
                Text("SSH connectivity is intentionally not included in this foundation milestone.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.displayName)
    }
}

private struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostDraft
    let credentials: [CredentialMetadata]
    let onSave: @MainActor (HostDraft) async -> Void

    init(draft: HostDraft, credentials: [CredentialMetadata], onSave: @escaping @MainActor (HostDraft) async -> Void) {
        _draft = State(initialValue: draft)
        self.credentials = credentials
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Display name", text: $draft.displayName)
                        .accessibilityIdentifier("host-display-name")
                    TextField("Hostname or IP address", text: $draft.hostname)
                        .accessibilityIdentifier("host-hostname")
                    TextField("Username", text: $draft.username)
                        .accessibilityIdentifier("host-username")
                    TextField("Port", value: $draft.port, format: .number)
                        .accessibilityIdentifier("host-port")
                }
                Section("Authentication") {
                    Picker("Credential", selection: $draft.credentialID) {
                        Text("Ask when connecting").tag(UUID?.none)
                        ForEach(credentials) { credential in
                            Text(credential.label).tag(Optional(credential.id))
                        }
                    }
                }
                Section("Organization") {
                    TextField("Group", text: $draft.group)
                    TextField("Tags, separated by commas", text: $draft.tagsText)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    Task { await onSave(draft) }
                }
                .buttonStyle(.glassProminent)
                .tint(.clear)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save-host")
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }
}
