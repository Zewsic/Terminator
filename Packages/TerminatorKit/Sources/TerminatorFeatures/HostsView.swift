import SwiftUI
import TerminatorCore

struct HostsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedHostID: UUID?
    @State private var editorDraft: HostDraft?
    @State private var isImportingOpenSSHHost = false
    @State private var editorSessionID = UUID()
    @State private var pendingDelete: HostProfile?
    @State private var exportHost: HostProfile?
    @State private var collapsedHostGroups: Set<String> = []

    private struct HostListGroup: Identifiable {
        let id: String
        let title: String
        let hosts: [HostProfile]
    }

    private var filteredHosts: [HostProfile] {
        guard !search.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.hostname.localizedCaseInsensitiveContains(search)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var selectedHost: HostProfile? { model.hosts.first { $0.id == selectedHostID } }

    private var hostGroups: [HostListGroup] {
        let grouped = Dictionary(grouping: filteredHosts) { host -> String? in
            let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return group.isEmpty ? nil : group
        }
        var result: [HostListGroup] = []
        if let ungrouped = grouped[nil], !ungrouped.isEmpty {
            result.append(.init(id: "__catalog", title: FeatureL10n.text("ui.hosts.view.12"), hosts: ungrouped))
        }
        result.append(contentsOf: grouped.compactMap { name, hosts -> HostListGroup? in
            guard let name else { return nil }
            return .init(id: "group:\(name)", title: name, hosts: hosts)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        return result
    }

    var body: some View {
        Group {
            if model.hosts.isEmpty && availableOpenSSHHosts.isEmpty {
                ContentUnavailableView {
                    Label(FeatureL10n.text("ui.hosts.view.1"), systemImage: "server.rack")
                } description: {
                    Text(FeatureL10n.text("ui.hosts.view.2"))
                } actions: {
                    Button(FeatureL10n.text("ui.hosts.view.3"), systemImage: "plus") { openEditor(HostDraft()) }
                        .buttonStyle(.glassProminent).tint(.blue)
                        .accessibilityIdentifier("add-host-empty")
                }
            } else {
                InspectorLayout(content: {
                    hostList
                }, inspector: {
                    if let editorDraft {
                        HostEditor(draft: editorDraft, explicitImport: isImportingOpenSSHHost) { savedDraft in
                            await model.saveHost(savedDraft)
                        } onClose: {
                            closeInspector()
                        }
                        .id(editorSessionID)
                    } else if let exportHost {
                        OpenSSHExportView(host: exportHost) {
                            closeInspector()
                        }
                        .id(exportHost.id)
                    }
                }, isInspectorPresented: editorDraft != nil || exportHost != nil, onContentInteraction: {
                    closeInspector()
                })
            }
        }
        .navigationTitle(FeatureL10n.text("ui.overview.view.8"))
        .searchable(text: $search, prompt: FeatureL10n.text("ui.hosts.view.68"))
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItemGroup {
                Button(FeatureL10n.text("ui.hosts.view.3"), systemImage: "plus") { openEditor(HostDraft()) }
                    .accessibilityIdentifier("add-host")
            }
        }
        .alert(FeatureL10n.text("ui.hosts.view.67"), isPresented: Binding(
            get: { model.openSSHResultMessage != nil },
            set: { if !$0 { model.openSSHResultMessage = nil } }
        )) {
            Button(FeatureL10n.text("ui.root.view.1")) { model.openSSHResultMessage = nil }
        } message: {
            Text(model.openSSHResultMessage ?? "")
        }
        .confirmationDialog(
            "Archive this host?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text("ui.hosts.view.9"), role: .destructive) {
                if let pendingDelete { Task { await model.deleteHost(id: pendingDelete.id) } }
                pendingDelete = nil
            }
            Button(FeatureL10n.text("ui.history.view.9"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(FeatureL10n.text("ui.hosts.view.11"))
        }
        .onChange(of: selectedHostID) { _, id in
            if let host = id.flatMap({ hostID in model.hosts.first { $0.id == hostID } }) {
                openEditor(HostDraft(host: host))
            } else {
                editorDraft = nil
            }
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            if isFocused { closeInspector() }
        }
    }

    private var hostList: some View {
        List(selection: $selectedHostID) {
            ForEach(hostGroups) { group in
                Section {
                    if !collapsedHostGroups.contains(group.id) {
                        ForEach(group.hosts) { host in
                            hostRow(host)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if collapsedHostGroups.contains(group.id) {
                                collapsedHostGroups.remove(group.id)
                            } else {
                                collapsedHostGroups.insert(group.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsedHostGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                            Text(group.title)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.capabilities.externalFileAccess, !availableOpenSSHHosts.isEmpty {
                Section {
                    ForEach(availableOpenSSHHosts) { host in
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(host.alias).fontWeight(.medium)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import", systemImage: "square.and.arrow.down") {
                                openDiscoveredHost(host)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Import", systemImage: "square.and.arrow.down") {
                                openDiscoveredHost(host)
                            }
                        }
                    }
                } header: {
                    Text("Available from OpenSSH")
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 360)
        .accessibilityIdentifier("hosts-list")
    }

    private func hostRow(_ host: HostProfile) -> some View {
        HostRow(host: host, username: resolvedUsername(for: host), phase: model.connectionPhase(for: host.id))
            .tag(host.id)
            .contextMenu {
                if model.capabilities.externalTerminal {
                    Menu(FeatureL10n.text("ui.hosts.view.13")) {
                        ForEach(model.terminalApplications) { terminal in
                            Button(terminal.displayName) { Task { await model.connect(host, with: terminal) } }
                        }
                    }
                    if !model.connectionPhase(for: host.id).isDisconnected {
                        Button("Disconnect", systemImage: "xmark.circle") {
                            Task { await model.disconnect(host) }
                        }
                    }
                    Divider()
                }
                Button(FeatureL10n.text("ui.hosts.view.4")) { openEditor(HostDraft(host: host)) }
                if model.capabilities.externalFileAccess {
                    Button(FeatureL10n.text("ui.hosts.view.15")) { openExporter(host) }
                }
                Button(FeatureL10n.text("ui.hosts.view.9"), role: .destructive) { pendingDelete = host }
            }
    }

    private func closeInspector() {
        selectedHostID = nil
        editorDraft = nil
        exportHost = nil
        isImportingOpenSSHHost = false
    }

    private func openEditor(_ draft: HostDraft, importingFromOpenSSH: Bool = false) {
        editorSessionID = UUID()
        exportHost = nil
        isImportingOpenSSHHost = importingFromOpenSSH
        editorDraft = draft
    }

    private var availableOpenSSHHosts: [DiscoveredSSHHost] {
        model.openSSH.hosts.filter { host in
            host.status == .available && (
                search.isEmpty
                    || host.alias.localizedCaseInsensitiveContains(search)
                    || host.hostname.localizedCaseInsensitiveContains(search)
                    || host.username.localizedCaseInsensitiveContains(search)
            )
        }
    }

    private func openExporter(_ host: HostProfile) {
        closeInspector()
        DispatchQueue.main.async {
            exportHost = host
        }
    }

    private func openDiscoveredHost(_ discovered: DiscoveredSSHHost) {
        let existing = model.matchingHost(for: discovered)
        var draft = HostDraft(host: existing)
        draft.displayName = discovered.alias
        draft.hostname = discovered.hostname
        draft.port = discovered.port
        if existing == nil || !draft.usesIdentity {
            draft.usesIdentity = false
            draft.identityID = nil
            draft.username = discovered.username
        }
        closeInspector()
        DispatchQueue.main.async {
            if let existing {
                selectedHostID = existing.id
            }
            openEditor(draft, importingFromOpenSSH: true)
        }
    }

    private func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return "Unavailable identity" }
        return model.identities.first { $0.id == id }?.username ?? "Unavailable identity"
    }

}

private struct OpenSSHExportView: View {
    @Environment(TerminatorAppModel.self) private var model
    let host: HostProfile
    let onClose: () -> Void
    @State private var alias: String
    @State private var configPath: String
    @State private var keyDirectory: String
    @State private var publicKeyIDs: Set<UUID> = []
    @State private var privateKeyIDs: Set<UUID> = []
    @State private var passphrases: [UUID: String] = [:]
    @State private var replaceHostBlock = false
    @State private var replaceKeyFiles = false
    @State private var preview = ""
    @State private var comparison: OpenSSHHostExportComparison?
    @State private var isExporting = false
    @State private var didExport = false

    init(host: HostProfile, onClose: @escaping () -> Void) {
        self.host = host; self.onClose = onClose
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        _alias = State(initialValue: host.displayName.replacingOccurrences(of: " ", with: "-"))
        _configPath = State(initialValue: ssh.appending(path: "config").path)
        _keyDirectory = State(initialValue: ssh.path)
    }

    private var credentials: [CredentialMetadata] {
        let ids: [UUID]
        switch host.authentication {
        case .manual:
            ids = host.authentication.credentialIDs
        case .identity(let identityID):
            ids = model.identities.first { $0.id == identityID }?.credentialIDs ?? []
        }
        return ids.compactMap { id in model.credentials.first { $0.id == id && $0.kind == .accessKey } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("OpenSSH") {
                    TextField(FeatureL10n.text("ui.field.8"), text: $alias)
                    TextField(FeatureL10n.text("ui.field.9"), text: $configPath)
                    TextField(FeatureL10n.text("ui.field.10"), text: $keyDirectory)
                }
                if hasExistingSelectedKeyFiles {
                    Section {
                        Toggle("Replace existing key files", isOn: $replaceKeyFiles)
                    } footer: {
                        Text("One or more selected key files already exist at the export destination.")
                    }
                }
                ForEach(credentials) { credential in
                    Section("Key “\(credential.label)”") {
                        Toggle(FeatureL10n.text("ui.hosts.view.25"), isOn: selectionBinding(credential.id, in: $publicKeyIDs))
                        if credential.accessKey?.backend == .secureEnclave {
                            LabeledContent("Export private key") {
                                Text("Can’t be exported")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Toggle("Export private key", isOn: selectionBinding(credential.id, in: $privateKeyIDs))
                            if privateKeyIDs.contains(credential.id) {
                                Text("Private-key export requires system authentication.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if case .promptEveryConnection = credential.accessKey?.passphraseProtection {
                                    SecureField(
                                        "Private-key passphrase",
                                        text: Binding(
                                            get: { passphrases[credential.id, default: ""] },
                                            set: { passphrases[credential.id] = $0 }
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
                Section(FeatureL10n.text("ui.hosts.view.28")) {
                    Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let comparison {
                    Section(FeatureL10n.text("ui.hosts.view.29")) {
                        Text(comparison.existingBlock).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Toggle(FeatureL10n.text("ui.hosts.view.30"), isOn: $replaceHostBlock)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting || didExport)
                Button {
                    Task { await performExport() }
                } label: {
                    HStack {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else if didExport {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(didExport ? "Host “\(alias)” exported" : "Export Host")
                    }
                    .contentTransition(.opacity)
                }
                .buttonStyle(.glassProminent)
                .tint(didExport ? Color.green : Color.blue)
                .disabled(isExporting || didExport || (comparison != nil && !replaceHostBlock))
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .task {
            if publicKeyIDs.isEmpty { publicKeyIDs = Set(credentials.map(\.id)) }
            await refreshPreview()
        }
        .onChange(of: alias) { _, _ in Task { await refreshPreview() } }
        .onChange(of: configPath) { _, _ in Task { await refreshPreview() } }
        .onChange(of: keyDirectory) { _, _ in Task { await refreshPreview() } }
        .onChange(of: privateKeyIDs) { _, _ in Task { await refreshPreview() } }
        .onChange(of: hasExistingSelectedKeyFiles) { _, hasExistingFiles in
            if !hasExistingFiles { replaceKeyFiles = false }
        }
    }

    private func request(replaceExisting: Bool) -> OpenSSHHostExportRequest {
        // OpenSSH IdentityFile must point to usable private key material. A
        // public-only export (including Secure Enclave keys) is intentionally
        // not added to the generated Host block.
        let keyURLs = credentials.filter { privateKeyIDs.contains($0.id) }.map { credential in
            URL(fileURLWithPath: keyDirectory).appending(path: safeFilename(credential.label))
        }
        return .init(
            alias: alias, hostname: host.hostname, port: host.port,
            username: model.resolvedUsername(for: host), identityFiles: keyURLs,
            configURL: URL(fileURLWithPath: configPath), replaceExisting: replaceExisting
        )
    }

    private func refreshPreview() async {
        let value = request(replaceExisting: false)
        preview = await model.previewOpenSSHExport(value)
        comparison = await model.compareOpenSSHExport(value)
        replaceHostBlock = false
    }

    private func performExport() async {
        guard !isExporting else { return }
        isExporting = true
        defer { if !didExport { isExporting = false } }
        let directory = URL(fileURLWithPath: keyDirectory)
        let exports = credentials.map { credential in
            let base = directory.appending(path: safeFilename(credential.label))
            return (
                credentialID: credential.id,
                privateURL: privateKeyIDs.contains(credential.id) && credential.accessKey?.backend == .software ? base : nil,
                publicURL: publicKeyIDs.contains(credential.id) ? URL(fileURLWithPath: base.path + ".pub") : nil
            )
        }
        if await model.exportHostToOpenSSH(
            request(replaceExisting: replaceHostBlock), keyExports: exports,
            replaceFiles: replaceKeyFiles, passphrases: passphrases
        ) {
            model.openSSHResultMessage = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                isExporting = false
                didExport = true
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            onClose()
        }
    }

    private func selectionBinding(_ id: UUID, in selection: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { selected in
                if selected { selection.wrappedValue.insert(id) }
                else { selection.wrappedValue.remove(id) }
            }
        )
    }

    private var hasExistingSelectedKeyFiles: Bool {
        let directory = URL(fileURLWithPath: keyDirectory)
        return credentials.contains { credential in
            let base = directory.appending(path: safeFilename(credential.label))
            let hasPrivateConflict = privateKeyIDs.contains(credential.id)
                && credential.accessKey?.backend == .software
                && FileManager.default.fileExists(atPath: base.path)
            let hasPublicConflict = publicKeyIDs.contains(credential.id)
                && FileManager.default.fileExists(atPath: base.path + ".pub")
            return hasPrivateConflict || hasPublicConflict
        }
    }

    private func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(result).isEmpty ? "id_terminator" : String(result)
    }
}

private struct HostRow: View {
    let host: HostProfile
    let username: String
    let phase: SSHConnectionPhase
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).fontWeight(.medium)
                Text("\(username)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !host.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(host.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if host.tags.count > 3 {
                        Text("+\(host.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch phase {
        case .connected: .green
        case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct HostDetailView: View {
    @Environment(TerminatorAppModel.self) private var model
    let host: HostProfile
    let identity: IdentityProfile?
    let credentials: [CredentialMetadata]

    var body: some View {
        Form {
            Section(FeatureL10n.text("ui.hosts.view.34")) {
                LabeledContent(FeatureL10n.text("ui.hosts.view.35"), value: host.hostname)
                LabeledContent(FeatureL10n.text("ui.hosts.view.36"), value: String(host.port))
                if let identity {
                    LabeledContent(FeatureL10n.text("ui.hosts.view.37"), value: identity.name)
                    LabeledContent(FeatureL10n.text("ui.hosts.view.38"), value: identity.username)
                    LabeledContent(FeatureL10n.text("ui.hosts.view.39"), value: "\(identity.authenticationMethods.count)")
                } else if case .manual(let username, _) = host.authentication {
                    LabeledContent(FeatureL10n.text("ui.hosts.view.40"), value: "Manual")
                    LabeledContent(FeatureL10n.text("ui.hosts.view.38"), value: username)
                    LabeledContent(FeatureL10n.text("ui.hosts.view.39"), value: "\(host.authentication.authenticationMethods.count)")
                }
            }
            if let group = host.group {
                Section(FeatureL10n.text("ui.hosts.view.43")) {
                    LabeledContent(FeatureL10n.text("ui.hosts.view.44"), value: group)
                    if !host.tags.isEmpty { LabeledContent(FeatureL10n.text("ui.hosts.view.45"), value: host.tags.joined(separator: ", ")) }
                }
            }
            if !host.notes.isEmpty { Section(FeatureL10n.text("ui.hosts.view.46")) { Text(host.notes).textSelection(.enabled) } }
            Section {
                if model.capabilities.externalTerminal {
                    Menu(FeatureL10n.text("ui.hosts.view.13"), systemImage: "bolt.horizontal") {
                        ForEach(model.terminalApplications) { terminal in
                            Button(terminal.displayName) { Task { await model.connect(host, with: terminal) } }
                        }
                    }
                }
            } footer: {
                Text(model.capabilities.externalTerminal
                    ? "Terminator owns the SSH connection; the selected terminal renders it through a protected local attach socket."
                    : "External terminal connections are available in the Direct macOS edition.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.displayName)
    }
}

private struct HostEditor: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: HostDraft
    @State private var hasTriggeredSave = false
    @State private var revealPassword = false
    @State private var isLoadingStoredPassword: Bool
    let explicitImport: Bool
    let onSave: @MainActor (HostDraft) async -> Bool
    let onClose: @MainActor () -> Void

    init(
        draft: HostDraft,
        explicitImport: Bool = false,
        onSave: @escaping @MainActor (HostDraft) async -> Bool,
        onClose: @escaping @MainActor () -> Void
    ) {
        _draft = State(initialValue: draft)
        _isLoadingStoredPassword = State(initialValue: draft.authenticationMethods.contains { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        })
        self.explicitImport = explicitImport
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Display Name", text: $draft.displayName)
                        .accessibilityIdentifier("host-display-name")
                }
                Section("Host") {
                    TextField("Hostname or IP Address", text: $draft.hostname, prompt: Text("127.0.0.1"))
                        .accessibilityIdentifier("host-hostname")
                    TextField("Port", value: $draft.port, format: .number)
                        .accessibilityIdentifier("host-port")
                    if !model.activeIdentities.isEmpty {
                        Picker("Authentication", selection: authenticationChoice) {
                            Text("Manual").tag(AuthenticationChoice.manual)
                            Divider()
                            ForEach(model.activeIdentities) { identity in
                                Text(FeatureL10n.text("identity.nameAndUsername", identity.name, identity.username))
                                    .tag(AuthenticationChoice.identity(identity.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if model.activeIdentities.isEmpty || !draft.usesIdentity {
                        manualAuthenticationFields
                    }
                }
                Section("Organization") {
                    AutocompleteTextField(
                        title: "Group",
                        text: $draft.group,
                        suggestions: existingGroups
                    )
                    TagEditor(tags: tagsBinding, suggestions: existingTags)
                    TextField("Notes", text: $draft.notes, prompt: Text("Empty"), axis: .vertical)
                        .lineLimit(3...8)
                }
            }.formStyle(.grouped)
            if explicitImport {
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") {
                        hasTriggeredSave = true
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import Host") {
                        Task {
                            if await onSave(draft) {
                                hasTriggeredSave = true
                                onClose()
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            } else if draft.id != nil, model.capabilities.externalTerminal {
                Divider()
                HStack {
                    Spacer()
                    if let host = persistedHost, !model.connectionPhase(for: host.id).isDisconnected {
                        Button("Disconnect", systemImage: "xmark.circle") {
                            Task { await model.disconnect(host) }
                        }
                    }
                    Menu {
                        connectionDestinations
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.fill")
                    } primaryAction: {
                        connect(using: .terminal)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .contextMenu {
                        connectionDestinations
                    }
                    .disabled(draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
        }
        .onDisappear {
            guard !explicitImport && !hasTriggeredSave else { return }
            let closingDraft = draft
            guard closingDraft.id != nil || !closingDraft.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.errorMessage = nil
                return
            }
            Task {
                let saved = await onSave(closingDraft)
                if !saved, closingDraft.id == nil { model.errorMessage = nil }
            }
        }
        .toolbar {
            if !explicitImport {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button("Cancel", systemImage: "xmark") {
                            hasTriggeredSave = true
                            onClose()
                        }
                        Button("Save and close", systemImage: "checkmark") {
                            hasTriggeredSave = true
                            Task {
                                _ = await onSave(draft)
                                onClose()
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .task {
            if model.activeIdentities.isEmpty, draft.usesIdentity {
                draft.usesIdentity = false
                draft.identityID = nil
            }
            guard isLoadingStoredPassword else { return }
            draft = await model.loadHostPassword(into: draft)
            isLoadingStoredPassword = false
        }
    }

    private var selectedAccessKeyIDs: Set<UUID> {
        Set(draft.authenticationMethods.compactMap {
            if case .accessKey(let id) = $0.kind { return id }
            return nil
        })
    }

    private var availableAccessKeys: [CredentialMetadata] {
        model.activeCredentials.filter { !selectedAccessKeyIDs.contains($0.id) }
    }

    private var persistedHost: HostProfile? {
        guard let id = draft.id else { return nil }
        return model.hosts.first { $0.id == id }
    }

    private enum AuthenticationChoice: Hashable {
        case manual
        case identity(UUID)
    }

    private var authenticationChoice: Binding<AuthenticationChoice> {
        Binding(
            get: {
                if draft.usesIdentity, let id = draft.identityID { return .identity(id) }
                return .manual
            },
            set: { choice in
                switch choice {
                case .manual:
                    draft.usesIdentity = false
                    draft.identityID = nil
                case .identity(let id):
                    draft.usesIdentity = true
                    draft.identityID = id
                }
            }
        )
    }

    @ViewBuilder
    private var manualAuthenticationFields: some View {
        TextField("Username", text: $draft.username)
            .accessibilityIdentifier("host-username")
        if let index = passwordIndex {
            HStack {
                Group {
                    if revealPassword {
                        TextField("Password", text: passwordBinding(at: index))
                    } else {
                        SecureField("Password", text: passwordBinding(at: index))
                    }
                }
                .disabled(isLoadingStoredPassword)
                if isLoadingStoredPassword {
                    ProgressView().controlSize(.small)
                } else {
                    Button(revealPassword ? "Hide" : "Show", systemImage: revealPassword ? "eye.slash" : "eye") {
                        revealPassword.toggle()
                    }
                }
            }
        }
        ForEach(accessKeyIndices, id: \.self) { index in
            if case .accessKey(let id) = draft.authenticationMethods[index].kind {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential(id)?.label ?? "Unavailable access key")
                        Text(credential(id)?.accessKey?.algorithm.displayName ?? "Access Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let position = accessKeyIndices.firstIndex(of: index) ?? 0
                    Button("Move Up", systemImage: "arrow.up") { moveAccessKey(index, by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(position == 0)
                    Button("Move Down", systemImage: "arrow.down") { moveAccessKey(index, by: 1) }
                        .labelStyle(.iconOnly)
                        .disabled(position == accessKeyIndices.count - 1)
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        draft.authenticationMethods.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        if model.activeCredentials.isEmpty {
            Text("No access keys yet. Create one in the Credentials section.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if availableAccessKeys.isEmpty {
            Text("All available access keys are already added.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Menu("Add Access Key", systemImage: "key.horizontal") {
                ForEach(availableAccessKeys) { credential in
                    Button {
                        addAccessKey(credential.id)
                    } label: {
                        Label(
                            credential.label,
                            systemImage: credential.accessKey?.backend == .secureEnclave ? "touchid" : "key.horizontal"
                        )
                    }
                }
            }
        }
    }

    private var passwordIndex: Int? {
        draft.authenticationMethods.firstIndex {
            if case .password = $0.kind { return true }
            return false
        }
    }

    private var accessKeyIndices: [Int] {
        draft.authenticationMethods.indices.filter { index in
            if case .accessKey = draft.authenticationMethods[index].kind { return true }
            return false
        }
    }

    private func credential(_ id: UUID) -> CredentialMetadata? {
        model.credentials.first { $0.id == id }
    }

    private func passwordBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { draft.authenticationMethods[index].password },
            set: { value in
                draft.authenticationMethods[index].password = value
                draft.authenticationMethods[index].passwordChanged = true
            }
        )
    }

    private var existingGroups: [String] {
        Array(Set(model.hosts.compactMap { host in
            let value = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var existingTags: [String] {
        Array(Set(model.hosts.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var tagsBinding: Binding<[String]> {
        Binding(
            get: {
                draft.tagsText.split(separator: ",").compactMap { value in
                    let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return tag.isEmpty ? nil : tag
                }
            },
            set: { draft.tagsText = $0.joined(separator: ",") }
        )
    }

    @ViewBuilder
    private var connectionDestinations: some View {
        Section("Connect with") {
            ForEach(model.terminalApplications.filter { $0 != .other }) { terminal in
                Button(terminal.displayName) { connect(using: terminal) }
            }
        }
        if model.terminalApplications.contains(.other) {
            Divider()
            Button(TerminalApplication.other.displayName) { connect(using: .other) }
        }
    }

    private func connect(using terminal: TerminalApplication) {
        Task {
            guard await onSave(draft),
                  let hostID = draft.id,
                  let host = model.hosts.first(where: { $0.id == hostID }) else { return }
            await model.connect(host, with: terminal)
        }
    }

    private func addAccessKey(_ id: UUID) {
        guard !selectedAccessKeyIDs.contains(id) else { return }
        draft.authenticationMethods.append(IdentityDraftMethod(kind: .accessKey(id)))
    }

    private func moveAccessKey(_ index: Int, by delta: Int) {
        let indices = accessKeyIndices
        guard let position = indices.firstIndex(of: index) else { return }
        let targetPosition = position + delta
        guard indices.indices.contains(targetPosition) else { return }
        let target = indices[targetPosition]
        draft.authenticationMethods.swapAt(index, target)
    }
}

private extension SSHConnectionPhase {
    var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

private struct AutocompleteTextField: View {
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

private struct TagEditor: View {
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
            TextField("Tag", text: $input)
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
