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

    private var selectedHost: HostProfile? { model.hosts.first { $0.id == selectedHostID } }

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } description: {
                    Text("Add an SSH host to start building your catalog.")
                } actions: {
                    Button("Add Host", systemImage: "plus") { editorDraft = HostDraft() }
                        .buttonStyle(.glassProminent).tint(.clear)
                        .accessibilityIdentifier("add-host-empty")
                }
            } else {
                #if os(macOS)
                HSplitView { hostList; hostDetail }
                #else
                NavigationSplitView { hostList } detail: { hostDetail }
                #endif
            }
        }
        .navigationTitle("Hosts")
        .searchable(text: $search, prompt: "Search hosts")
        .toolbar {
            ToolbarItemGroup {
                Button("Edit", systemImage: "pencil") {
                    if let selectedHost { editorDraft = HostDraft(host: selectedHost) }
                }.disabled(selectedHost == nil)
                Button("Add Host", systemImage: "plus") { editorDraft = HostDraft() }
                    .accessibilityIdentifier("add-host")
            }
        }
        .sheet(item: $editorDraft) { draft in
            HostEditor(draft: draft) { savedDraft in
                if await model.saveHost(savedDraft) { editorDraft = nil }
            }
        }
        .confirmationDialog(
            "Archive this host?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingDelete { Task { await model.deleteHost(id: pendingDelete.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The host can be restored from History. Its identity and credentials are retained.")
        }
    }

    private var hostList: some View {
        List(filteredHosts, selection: $selectedHostID) { host in
            HostRow(host: host, username: resolvedUsername(for: host))
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
            HostDetailView(
                host: selectedHost,
                identity: selectedHost.authentication.identityID.flatMap { id in model.identities.first { $0.id == id } },
                credentials: selectedHost.authentication.credentialIDs.compactMap { id in model.credentials.first { $0.id == id } }
            )
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a host", systemImage: "cursorarrow.click")
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return "Unavailable identity" }
        return model.identities.first { $0.id == id }?.username ?? "Unavailable identity"
    }
}

private struct HostRow: View {
    let host: HostProfile
    let username: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).fontWeight(.medium)
                Text("\(username)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 3)
    }
}

private struct HostDetailView: View {
    let host: HostProfile
    let identity: IdentityProfile?
    let credentials: [CredentialMetadata]

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Address", value: host.hostname)
                LabeledContent("Port", value: String(host.port))
                if let identity {
                    LabeledContent("Identity", value: identity.name)
                    LabeledContent("Username", value: identity.username)
                    LabeledContent("Methods", value: "\(identity.authenticationMethods.count)")
                } else if case .manual(let username, _) = host.authentication {
                    LabeledContent("Authentication", value: "Manual")
                    LabeledContent("Username", value: username)
                    LabeledContent("Methods", value: "\(host.authentication.authenticationMethods.count)")
                }
            }
            if let group = host.group {
                Section("Organization") {
                    LabeledContent("Group", value: group)
                    if !host.tags.isEmpty { LabeledContent("Tags", value: host.tags.joined(separator: ", ")) }
                }
            }
            if !host.notes.isEmpty { Section("Notes") { Text(host.notes).textSelection(.enabled) } }
            Section {
                Button("Connect", systemImage: "bolt.horizontal") {}.disabled(true)
            } footer: {
                Text("Authentication is configured; the network SSH transport is a separate milestone.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.displayName)
    }
}

private struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: HostDraft
    @State private var accessKeyDraft: AccessKeyDraft?
    let onSave: @MainActor (HostDraft) async -> Void

    init(draft: HostDraft, onSave: @escaping @MainActor (HostDraft) async -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Host") {
                    TextField("Display name (optional)", text: $draft.displayName, prompt: Text(draft.hostname))
                        .accessibilityIdentifier("host-display-name")
                    TextField("Hostname or IP address", text: $draft.hostname).accessibilityIdentifier("host-hostname")
                    TextField("Port", value: $draft.port, format: .number).accessibilityIdentifier("host-port")
                }
                Section("Authentication") {
                    Picker("Configuration", selection: $draft.usesIdentity) {
                        Text("Identity").tag(true)
                        Text("Manual").tag(false)
                    }.pickerStyle(.segmented)
                    if draft.usesIdentity {
                        Picker("Identity", selection: $draft.identityID) {
                            Text("Select Identity").tag(UUID?.none)
                            ForEach(model.activeIdentities) { identity in
                                Text("\(identity.name) · \(identity.username)").tag(Optional(identity.id))
                            }
                        }
                    } else {
                        TextField("Username", text: $draft.username).accessibilityIdentifier("host-username")
                        ForEach(Array(draft.authenticationMethods.enumerated()), id: \.element.id) { index, method in
                            HStack {
                                switch method.kind {
                                case .password(let existingSecretID):
                                    VStack(alignment: .leading, spacing: 3) {
                                        SecureField(
                                            existingSecretID == nil ? "Password" : "Stored password — enter to replace",
                                            text: $draft.authenticationMethods[index].password
                                        )
                                        Text("Password").font(.caption).foregroundStyle(.secondary)
                                    }
                                case .accessKey(let id):
                                    Text(model.credentials.first { $0.id == id }?.label ?? "Unavailable access key")
                                }
                                Spacer()
                                Button("Move Up", systemImage: "arrow.up") { move(index, -1) }
                                    .labelStyle(.iconOnly).disabled(index == 0)
                                Button("Move Down", systemImage: "arrow.down") { move(index, 1) }
                                    .labelStyle(.iconOnly).disabled(index == draft.authenticationMethods.count - 1)
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    draft.authenticationMethods.remove(at: index)
                                }.labelStyle(.iconOnly)
                            }
                        }
                        HStack {
                            if !hasPassword {
                                Button("Add Password", systemImage: "key") {
                                    draft.authenticationMethods.append(
                                        IdentityDraftMethod(kind: .password(existingSecretID: nil))
                                    )
                                }
                            }
                            Button("Add Access Key", systemImage: "key.horizontal") {
                                var value = AccessKeyDraft()
                                value.mode = .importExisting
                                value.suggestedLabelContext = hostLabelContext
                                value.suggestedOrdinal = accessKeyCount + 1
                                accessKeyDraft = value
                            }
                        }
                    }
                }
                Section("Organization") {
                    TextField("Group", text: $draft.group)
                    TextField("Tags, separated by commas", text: $draft.tagsText)
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await onSave(draft) } }
                    .buttonStyle(.glassProminent).tint(.clear).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-host")
            }.padding()
        }
        .frame(width: 600, height: 680)
        .sheet(item: $accessKeyDraft) { value in
            AccessKeyEditor(draft: value) { saved in
                if let id = await model.saveAccessKey(saved) {
                    draft.authenticationMethods.append(
                        IdentityDraftMethod(kind: .accessKey(id))
                    )
                    accessKeyDraft = nil
                }
            }
        }
    }

    private var hasPassword: Bool {
        draft.authenticationMethods.contains {
            if case .password = $0.kind { return true }
            return false
        }
    }

    private var accessKeyCount: Int {
        draft.authenticationMethods.filter { method in
            if case .accessKey = method.kind { return true }
            return false
        }.count
    }

    private var hostLabelContext: String {
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard draft.authenticationMethods.indices.contains(target) else { return }
        draft.authenticationMethods.swapAt(index, target)
    }
}
