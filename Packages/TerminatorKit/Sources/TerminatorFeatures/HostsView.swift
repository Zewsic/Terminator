import SwiftUI
import TerminatorCore

struct HostsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var selectedHostID: UUID?
    @State private var editorDraft: HostDraft?
    @State private var pendingDelete: HostProfile?
    @State private var pendingImport: DiscoveredSSHHost?
    @State private var pendingTrust: DiscoveredKnownHost?
    @State private var exportHost: HostProfile?
    @State private var importedKeyDraft: AccessKeyDraft?
    @State private var queuedKeyDrafts: [AccessKeyDraft] = []
    @State private var keyImportHost: DiscoveredSSHHost?

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
            if model.hosts.isEmpty && model.openSSH.hosts.isEmpty {
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
                if model.capabilities.externalFileAccess {
                    Button("Refresh OpenSSH", systemImage: "arrow.clockwise") {
                        Task { await model.refreshOpenSSH() }
                    }
                    .disabled(model.isScanningOpenSSH)
                }
            }
        }
        .sheet(item: $editorDraft) { draft in
            HostEditor(draft: draft) { savedDraft in
                if await model.saveHost(savedDraft) { editorDraft = nil }
            }
        }
        .sheet(item: $pendingImport) { discovered in
            OpenSSHHostImportReview(
                discovered: discovered,
                existing: model.matchingHost(for: discovered),
                existingUsername: model.matchingHost(for: discovered).map(model.resolvedUsername),
                availableKeys: discovered.identityFiles.compactMap(model.discoveredKey)
            ) { selected in
                pendingImport = nil
                Task { await importHost(discovered, selectedKeys: selected) }
            }
        }
        .sheet(item: $importedKeyDraft) { draft in
            AccessKeyEditor(draft: draft) { value in
                let wasNew = value.credentialID == nil
                if let id = await model.saveAccessKey(value) {
                    if wasNew, let keyImportHost { _ = await model.importHost(keyImportHost, credentialIDs: [id]) }
                    importedKeyDraft = nil
                    showNextImportedKey()
                }
            }
        }
        .sheet(item: $exportHost) { host in
            OpenSSHExportView(host: host) { exportHost = nil }
        }
        .confirmationDialog(
            pendingTrust?.status == .changed ? "Replace changed server key?" : "Trust this server key?",
            isPresented: Binding(get: { pendingTrust != nil }, set: { if !$0 { pendingTrust = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingTrust?.status == .changed ? "Replace Key" : "Import Trust", role: pendingTrust?.status == .changed ? .destructive : nil) {
                if let item = pendingTrust {
                    Task { _ = await model.importKnownHost(item, replaceChanged: item.status == .changed) }
                }
                pendingTrust = nil
            }
            Button("Cancel", role: .cancel) { pendingTrust = nil }
        } message: {
            if let pendingTrust { Text("\(pendingTrust.endpoint)\n\(pendingTrust.fingerprint)") }
        }
        .alert("OpenSSH", isPresented: Binding(
            get: { model.openSSHResultMessage != nil },
            set: { if !$0 { model.openSSHResultMessage = nil } }
        )) {
            Button("OK") { model.openSSHResultMessage = nil }
        } message: {
            Text(model.openSSHResultMessage ?? "")
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
        List(selection: $selectedHostID) {
            Section("Catalog") {
                ForEach(filteredHosts) { host in
                    HostRow(host: host, username: resolvedUsername(for: host))
                        .tag(host.id)
                        .contextMenu {
                            if model.capabilities.externalTerminal {
                                Menu("Connect with") {
                                    ForEach(model.terminalApplications) { terminal in
                                        Button(terminal.displayName) { Task { await model.connect(host, with: terminal) } }
                                    }
                                }
                                Divider()
                            }
                            Button("Edit") { editorDraft = HostDraft(host: host) }
                            if model.capabilities.externalFileAccess {
                                Button("Export to OpenSSH…") { exportHost = host }
                            }
                            Button("Archive", role: .destructive) { pendingDelete = host }
                        }
                }
            }
            if model.capabilities.externalFileAccess, !model.openSSH.hosts.isEmpty {
                Section("Available from OpenSSH") {
                    ForEach(model.openSSH.hosts) { host in
                        HStack {
                            Image(systemName: host.status == .existing ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                            VStack(alignment: .leading) {
                                Text(host.alias).fontWeight(.medium)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(host.status == .existing ? "Compare" : "Import")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(host.status == .existing ? "Compare and Update…" : "Import…") {
                                pendingImport = host
                            }
                        }
                    }
                }
            }
            if model.capabilities.externalFileAccess, !model.openSSH.knownHosts.isEmpty {
                Section("OpenSSH Trusted Endpoints") {
                    ForEach(model.openSSH.knownHosts) { item in
                        HStack {
                            Image(systemName: item.status == .changed ? "exclamationmark.shield" : "checkmark.shield")
                                .foregroundStyle(item.status == .changed ? .red : .secondary)
                            VStack(alignment: .leading) {
                                Text(item.endpoint)
                                Text("\(item.algorithm) · \(item.fingerprint)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            if item.status != .existing {
                                Button(item.status == .changed ? "Review Changed Key…" : "Import Trust") {
                                    pendingTrust = item
                                }
                            }
                        }
                    }
                }
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

    private func importHost(_ host: DiscoveredSSHHost, selectedKeys: [DiscoveredAccessKey]) async {
        var credentialIDs: [UUID] = []
        var editors: [AccessKeyDraft] = []
        keyImportHost = host
        for key in selectedKeys {
            if let fingerprint = key.fingerprint,
               let existing = model.activeCredentials.first(where: { $0.accessKey?.fingerprint == fingerprint }) {
                credentialIDs.append(existing.id)
                continue
            }
            var draft = model.draft(for: key)
            if key.isEncrypted {
                editors.append(draft)
            } else if let id = await model.saveAccessKey(draft) {
                credentialIDs.append(id)
                draft.credentialID = id
                editors.append(draft)
            }
        }
        _ = await model.importHost(host, credentialIDs: credentialIDs)
        queuedKeyDrafts = editors
        showNextImportedKey()
    }

    private func showNextImportedKey() {
        guard importedKeyDraft == nil, !queuedKeyDrafts.isEmpty else { return }
        importedKeyDraft = queuedKeyDrafts.removeFirst()
    }
}

private struct OpenSSHHostImportReview: View {
    @Environment(\.dismiss) private var dismiss
    let discovered: DiscoveredSSHHost
    let existing: HostProfile?
    let existingUsername: String?
    let availableKeys: [DiscoveredAccessKey]
    let onImport: ([DiscoveredAccessKey]) -> Void
    @State private var selectedPaths: Set<String>

    init(
        discovered: DiscoveredSSHHost, existing: HostProfile?, existingUsername: String?,
        availableKeys: [DiscoveredAccessKey],
        onImport: @escaping ([DiscoveredAccessKey]) -> Void
    ) {
        self.discovered = discovered; self.existing = existing; self.existingUsername = existingUsername
        self.availableKeys = availableKeys; self.onImport = onImport
        _selectedPaths = State(initialValue: Set(availableKeys.map { $0.privateKeyURL.path }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(existing == nil ? "Host to Import" : "Compare Host") {
                    comparison("Alias", current: existing?.displayName, incoming: discovered.alias)
                    comparison("Hostname", current: existing?.hostname, incoming: discovered.hostname)
                    comparison("Port", current: existing.map { String($0.port) }, incoming: String(discovered.port))
                    comparison("Username", current: existingUsername, incoming: discovered.username)
                }
                if !availableKeys.isEmpty {
                    Section("Identity Files") {
                        ForEach(availableKeys) { key in
                            Toggle(isOn: Binding(
                                get: { selectedPaths.contains(key.privateKeyURL.path) },
                                set: { selected in
                                    if selected { selectedPaths.insert(key.privateKeyURL.path) }
                                    else { selectedPaths.remove(key.privateKeyURL.path) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(key.label)
                                    Text(key.fingerprint ?? (key.isEncrypted ? "Encrypted OpenSSH key" : key.privateKeyURL.path))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if existing != nil {
                    Section {
                        Text("OpenSSH values replace the fields shown above. Existing password and access-key methods are retained; selected keys are added without duplicates.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "Import" : "Update") {
                    onImport(availableKeys.filter { selectedPaths.contains($0.privateKeyURL.path) })
                }
                .buttonStyle(.glassProminent).tint(.clear).keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 650, height: 560)
    }

    @ViewBuilder
    private func comparison(_ label: String, current: String?, incoming: String) -> some View {
        LabeledContent(label) {
            if let current, current != incoming {
                HStack {
                    Text(current).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                    Text(incoming).fontWeight(.medium)
                }
            } else { Text(incoming) }
        }
    }
}

private struct OpenSSHExportView: View {
    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    let onFinish: () -> Void
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

    init(host: HostProfile, onFinish: @escaping () -> Void) {
        self.host = host; self.onFinish = onFinish
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        _alias = State(initialValue: host.displayName.replacingOccurrences(of: " ", with: "-"))
        _configPath = State(initialValue: ssh.appending(path: "config").path)
        _keyDirectory = State(initialValue: ssh.path)
    }

    private var credentials: [CredentialMetadata] {
        let ids = host.authentication.credentialIDs
        return ids.compactMap { id in model.credentials.first { $0.id == id && $0.kind == .accessKey } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Destination") {
                    TextField("Host alias", text: $alias)
                    TextField("SSH config", text: $configPath)
                    TextField("Key directory", text: $keyDirectory)
                }
                if !credentials.isEmpty {
                    Section("Keys") {
                        ForEach(credentials) { credential in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(credential.label).fontWeight(.medium)
                                Toggle("Export public key", isOn: selectionBinding(credential.id, in: $publicKeyIDs))
                                Toggle(
                                    credential.accessKey?.backend == .secureEnclave
                                        ? "Private key cannot be exported from Secure Enclave"
                                        : "Export private key",
                                    isOn: selectionBinding(credential.id, in: $privateKeyIDs)
                                )
                                .disabled(credential.accessKey?.backend != .software)
                                if privateKeyIDs.contains(credential.id),
                                   case .promptEveryConnection = credential.accessKey?.passphraseProtection {
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
                        Toggle("Allow replacing selected key files", isOn: $replaceKeyFiles)
                        Text("Private-key export requires system authentication. Secure Enclave private keys are never exported.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Proposed Host Block") {
                    Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let comparison {
                    Section("Existing Host Block") {
                        Text(comparison.existingBlock).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Toggle("Replace this Host block", isOn: $replaceHostBlock)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Refresh Comparison") { Task { await refreshPreview() } }
                Button("Export") { Task { await performExport() } }
                    .buttonStyle(.glassProminent).tint(.clear)
                    .disabled(comparison != nil && !replaceHostBlock)
            }.padding()
        }
        .frame(width: 720, height: 680)
        .task {
            if publicKeyIDs.isEmpty { publicKeyIDs = Set(credentials.map(\.id)) }
            await refreshPreview()
        }
        .onChange(of: alias) { _, _ in Task { await refreshPreview() } }
        .onChange(of: configPath) { _, _ in Task { await refreshPreview() } }
        .onChange(of: keyDirectory) { _, _ in Task { await refreshPreview() } }
        .onChange(of: privateKeyIDs) { _, _ in Task { await refreshPreview() } }
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
        ) { onFinish() }
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

    private func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(result).isEmpty ? "id_terminator" : String(result)
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
    @Environment(TerminatorAppModel.self) private var model
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
                if model.capabilities.externalTerminal {
                    Menu("Connect with", systemImage: "bolt.horizontal") {
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
                                Text(FeatureL10n.text("identity.nameAndUsername", identity.name, identity.username)).tag(Optional(identity.id))
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
                            Menu("Add Access Key", systemImage: "key.horizontal") {
                                Button("Add New Access Key…", systemImage: "plus") {
                                    beginCreatingAccessKey()
                                }
                                Divider()
                                if availableAccessKeys.isEmpty {
                                    Text("No Available Access Keys")
                                } else {
                                    ForEach(availableAccessKeys) { credential in
                                        Button {
                                            addAccessKey(credential.id)
                                        } label: {
                                            Label(
                                                credential.label,
                                                systemImage: credential.accessKey?.backend == .secureEnclave
                                                    ? "touchid"
                                                    : "key.horizontal"
                                            )
                                        }
                                    }
                                }
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

    private var selectedAccessKeyIDs: Set<UUID> {
        Set(draft.authenticationMethods.compactMap { method in
            if case .accessKey(let id) = method.kind { return id }
            return nil
        })
    }

    private var availableAccessKeys: [CredentialMetadata] {
        model.activeCredentials.filter { !selectedAccessKeyIDs.contains($0.id) }
    }

    private var hostLabelContext: String {
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    private func beginCreatingAccessKey() {
        var value = AccessKeyDraft()
        value.mode = .importExisting
        value.suggestedLabelContext = hostLabelContext
        value.suggestedOrdinal = accessKeyCount + 1
        accessKeyDraft = value
    }

    private func addAccessKey(_ id: UUID) {
        guard !selectedAccessKeyIDs.contains(id) else { return }
        draft.authenticationMethods.append(IdentityDraftMethod(kind: .accessKey(id)))
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard draft.authenticationMethods.indices.contains(target) else { return }
        draft.authenticationMethods.swapAt(index, target)
    }
}
