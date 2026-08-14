import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CredentialsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @Binding private var isArchivePresented: Bool
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var accessKeyDraft: AccessKeyDraft?
    @State private var identityDraft: IdentityDraft?
    @State private var selectedCredential: CredentialMetadata?
    @State private var isImportingOpenSSHKey = false
    @State private var inspectorSessionID = UUID()
    @State private var isDiscardingInspector = false
    @State private var pendingArchive: CredentialMetadata?
    @State private var pendingPurge: CredentialMetadata?
    @State private var pendingIdentityArchive: IdentityProfile?
    @State private var exportDocument: PrivateKeyDocument?
    @State private var exportingCredential: CredentialMetadata?
    @State private var isExportingCredential = false

    init(isArchivePresented: Binding<Bool>) {
        _isArchivePresented = isArchivePresented
    }

    var body: some View {
        InspectorLayout(content: {
            credentialsContent
        }, inspector: {
            AnyView(ZStack {
            if let accessKeyDraft {
                AccessKeyEditor(
                    draft: accessKeyDraft,
                    inline: true,
                    explicitImport: isExplicitAccessKeyImport,
                    onDraftChange: updateAccessKeyDraft,
                    isDiscarding: isDiscarding
                ) { value in
                    let saved = await model.saveAccessKey(value)
                    if isExplicitAccessKeyImport, saved != nil { closeInspector() }
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let selectedCredential {
                AccessKeyEditor(credential: selectedCredential, inline: true, isDiscarding: isDiscarding) { value in
                    _ = await model.replaceAccessKey(value)
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let identityDraft {
                IdentityEditor(draft: identityDraft, inline: true, onDraftChange: updateIdentityDraft, isDiscarding: isDiscarding) { value in
                    _ = await model.saveIdentity(value)
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            .animation(.easeInOut(duration: 0.22), value: inspectorSessionID))
        }, isInspectorPresented: hasInspector, onContentInteraction: { closeInspector() })
        .navigationTitle(FeatureL10n.text("ui.overview.view.9"))
        .searchable(text: $searchText, prompt: "Search identities and credentials")
        .searchFocused($isSearchFocused)
        .toolbar {
            credentialsToolbar
        }
        .fileExporter(
            isPresented: $isExportingCredential,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportingCredential?.label.replacingOccurrences(of: " ", with: "-") ?? "access-key"
        ) { _ in
            exportDocument = nil
            exportingCredential = nil
        }
        .confirmationDialog(
            "Archive this credential?",
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text("ui.hosts.view.9"), role: .destructive) {
                if let pendingArchive { Task { await model.deleteCredential(id: pendingArchive.id) } }
                pendingArchive = nil
            }
            Button(FeatureL10n.text("ui.history.view.9"), role: .cancel) { pendingArchive = nil }
        } message: {
            Text(FeatureL10n.text("ui.credentials.view.4"))
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            if isFocused { closeInspector() }
        }
        .confirmationDialog(
            "Permanently purge this secret?",
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text("ui.credentials.view.5"), role: .destructive) {
                if let pendingPurge { Task { await model.purgeCredential(id: pendingPurge.id) } }
                pendingPurge = nil
            }
            Button(FeatureL10n.text("ui.history.view.9"), role: .cancel) { pendingPurge = nil }
        } message: {
            Text(FeatureL10n.text("ui.credentials.view.7"))
        }
        .confirmationDialog(
            "Archive this identity?",
            isPresented: Binding(get: { pendingIdentityArchive != nil }, set: { if !$0 { pendingIdentityArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text("ui.hosts.view.9"), role: .destructive) {
                if let pendingIdentityArchive { Task { await model.deleteIdentity(id: pendingIdentityArchive.id) } }
                pendingIdentityArchive = nil
            }
            Button(FeatureL10n.text("ui.history.view.9"), role: .cancel) { pendingIdentityArchive = nil }
        }
    }

    private var addMenu: some View {
        Menu(FeatureL10n.text("ui.credentials.view.10"), systemImage: "plus") {
            Button(FeatureL10n.text("ui.hosts.view.37"), systemImage: "person.badge.key") {
                openIdentity(IdentityDraft())
            }
            Button(FeatureL10n.text("ui.credentials.view.12"), systemImage: "key.horizontal") {
                var draft = AccessKeyDraft()
                draft.suggestedOrdinal = model.activeCredentials.count + 1
                openAccessKey(draft)
            }
        }
        .accessibilityIdentifier("add-credential")
    }

    @ToolbarContentBuilder
    private var credentialsToolbar: some ToolbarContent {
        ToolbarItemGroup {
            addMenu
            Button("Archive", systemImage: "archivebox") { isArchivePresented = true }
                .accessibilityIdentifier("archive-button")
        }
        if hasInspector && !isExplicitAccessKeyImport {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button("Cancel", systemImage: "xmark") { discardInspector() }
                    Button("Save and close", systemImage: "checkmark") {
                        Task { await saveInspectorAndClose() }
                    }
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private func identityRow(_ identity: IdentityProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(identityDisplayName(identity)).fontWeight(.medium)
                Text(FeatureL10n.text(identity.authenticationMethods.count == 1 ? "identity.summary.one" : "identity.summary.many", identity.username, identity.authenticationMethods.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if !identity.isDeleted { openIdentity(IdentityDraft(identity: identity)) } }
        .contextMenu {
            if !identity.isDeleted {
                Button("Edit", systemImage: "pencil") { openIdentity(IdentityDraft(identity: identity)) }
                Button("Archive", systemImage: "archivebox", role: .destructive) { pendingIdentityArchive = identity }
                    .disabled(model.identityUsageCount(id: identity.id) > 0)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var credentialsContent: some View {
        let activeIdentities = model.identities.filter { !$0.isDeleted }
        let activeCredentials = model.credentials.filter { !$0.isDeleted && $0.isSecretAvailable }
        let identities = activeIdentities
            .filter { matchesSearch($0.name) || matchesSearch($0.username) }
        let available = activeCredentials
            .filter { matchesSearch($0.label) }
        let openSSHKeys = availableOpenSSHKeys
        if activeIdentities.isEmpty && activeCredentials.isEmpty && openSSHKeys.isEmpty {
            ContentUnavailableView {
                Label("No identities or credentials", systemImage: "key")
            } description: {
                Text("Create an identity or add a credential to get started.")
            } actions: { addMenu.buttonStyle(.glassProminent).tint(.blue) }
        } else if identities.isEmpty && available.isEmpty && openSSHKeys.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if !identities.isEmpty {
                    Section("Identity") { ForEach(identities) { identity in identityRow(identity) } }
                }
                if !available.isEmpty {
                    Section("Credentials") { ForEach(available) { credential in credentialRow(credential) } }
                }
                if model.capabilities.externalFileAccess, !openSSHKeys.isEmpty {
                    Section {
                        ForEach(openSSHKeys) { key in
                            HStack {
                                if let importError = key.importError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .help(importError)
                                } else {
                                    Image(systemName: "key.horizontal")
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.label).fontWeight(.medium)
                                    Text(key.importError ?? key.fingerprint ?? (key.isEncrypted ? "Encrypted OpenSSH key" : key.privateKeyURL.path))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if key.importError == nil {
                                    Button("Import", systemImage: "square.and.arrow.down") {
                                        openDiscoveredKey(key)
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }
                            .help(key.importError ?? key.privateKeyURL.path)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Import", systemImage: "square.and.arrow.down") {
                                    openDiscoveredKey(key)
                                }
                                .disabled(key.importError != nil)
                            }
                        }
                    } header: {
                        Text("Available from OpenSSH")
                    }
                }
            }
            .accessibilityIdentifier("credentials-list")
        }
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: credentialIcon(for: credential))
                .foregroundStyle(credential.isSecretAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label).fontWeight(.medium)
                Text(status(for: credential)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if credential.kind == .accessKey { openCredential(credential) } }
        .contextMenu {
            if credential.kind == .accessKey {
                Button("Edit", systemImage: "pencil") { openCredential(credential) }
                Button("Export to OpenSSH…", systemImage: "square.and.arrow.up") { exportToOpenSSH(credential) }
                    .disabled(credential.accessKey?.backend == .secureEnclave || !credential.isSecretAvailable)
                Divider()
            }
                if !credential.isDeleted {
                    Button("Archive", systemImage: "archivebox", role: .destructive) { pendingArchive = credential }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0)
                }
                if credential.isSecretAvailable, model.credentialUsageCount(id: credential.id) == 0 {
                    Button("Purge", systemImage: "trash", role: .destructive) { pendingPurge = credential }
                }
        }
        .padding(.vertical, 3)
    }

    private var availableOpenSSHKeys: [DiscoveredAccessKey] {
        model.openSSH.accessKeys.filter { $0.status != .existing && matchesSearch($0.label) }
    }

    private func exportToOpenSSH(_ credential: CredentialMetadata) {
        Task {
            guard let data = await model.exportPrivateKey(id: credential.id) else { return }
            exportingCredential = credential
            exportDocument = PrivateKeyDocument(data: data)
            isExportingCredential = true
        }
    }

    private func status(for credential: CredentialMetadata) -> String {
        if !credential.isSecretAvailable { return "Secret purged · metadata only" }
        if credential.kind == .legacyPassphrase { return "Legacy passphrase · attach manually or archive" }
        let usage = model.credentialUsageCount(id: credential.id)
        let detail = credential.accessKey?.algorithm.displayName ?? credential.kind.displayName
        if credential.isDeleted { return "Archived · secret retained" }
        if usage == 0 { return FeatureL10n.text("credential.status.unused", detail) }
        return FeatureL10n.text(usage == 1 ? "credential.status.used.one" : "credential.status.used.many", usage, detail)
    }

    private func credentialIcon(for credential: CredentialMetadata) -> String {
        if credential.accessKey?.backend == .secureEnclave { return "touchid" }
        return credential.kind == .accessKey ? "key.horizontal" : "key"
    }

    private func matchesSearch(_ value: String) -> Bool {
        searchText.isEmpty || value.localizedCaseInsensitiveContains(searchText)
    }

    private func identityDisplayName(_ identity: IdentityProfile) -> String {
        let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "Identity" : username
    }

    private func closeInspector() {
        accessKeyDraft = nil
        selectedCredential = nil
        identityDraft = nil
        isImportingOpenSSHKey = false
    }

    private func updateAccessKeyDraft(_ draft: AccessKeyDraft) { accessKeyDraft = draft }
    private func updateIdentityDraft(_ draft: IdentityDraft) { identityDraft = draft }
    private func isDiscarding() -> Bool { isDiscardingInspector }

    private var hasInspector: Bool {
        accessKeyDraft != nil || selectedCredential != nil || identityDraft != nil
    }

    private var isExplicitAccessKeyImport: Bool {
        isImportingOpenSSHKey
            || (accessKeyDraft?.credentialID == nil && accessKeyDraft?.mode == .importExisting)
    }

    private func discardInspector() {
        isDiscardingInspector = true
        closeInspector()
    }

    private func saveInspectorAndClose() async {
        isDiscardingInspector = true
        if let accessKeyDraft {
            _ = await model.saveAccessKey(accessKeyDraft)
        } else if let selectedCredential {
            var draft = AccessKeyDraft()
            draft.credentialID = selectedCredential.id
            draft.label = selectedCredential.label
            _ = await model.replaceAccessKey(draft)
        } else if let identityDraft {
            _ = await model.saveIdentity(identityDraft)
        }
        closeInspector()
    }

    private func openAccessKey(_ draft: AccessKeyDraft, importingFromOpenSSH: Bool = false) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = importingFromOpenSSH
        accessKeyDraft = draft
        selectedCredential = nil
        identityDraft = nil
    }

    private func openDiscoveredKey(_ key: DiscoveredAccessKey) {
        let draft = model.draft(for: key)
        closeInspector()
        DispatchQueue.main.async {
            openAccessKey(draft, importingFromOpenSSH: true)
        }
    }

    private func openCredential(_ credential: CredentialMetadata) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = false
        selectedCredential = credential
        accessKeyDraft = nil
        identityDraft = nil
    }

    private func openIdentity(_ draft: IdentityDraft) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = false
        identityDraft = draft
        accessKeyDraft = nil
        selectedCredential = nil
    }

}

struct AccessKeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: AccessKeyDraft
    @State private var generationType = 0
    @State private var curve: ECDSACurve = .p256
    @State private var rsaBits = 2_048
    @State private var revealPassphrase = false
    @State private var isImportingPrivateKey = false
    @State private var isImportingPublicKey = false
    @State private var hasTriggeredSave = false
    @State private var isExportToHostPresented = false
    let onSave: @MainActor (AccessKeyDraft) async -> Void
    let inline: Bool
    let explicitImport: Bool
    let onDraftChange: ((AccessKeyDraft) -> Void)?
    let isDiscarding: () -> Bool
    let onClose: (() -> Void)?

    init(
        draft: AccessKeyDraft,
        inline: Bool = false,
        explicitImport: Bool = false,
        onDraftChange: ((AccessKeyDraft) -> Void)? = nil,
        isDiscarding: @escaping () -> Bool = { false },
        onSave: @escaping @MainActor (AccessKeyDraft) async -> Void,
        onClose: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.inline = inline
        self.explicitImport = explicitImport
        self.onDraftChange = onDraftChange
        self.isDiscarding = isDiscarding
        self.onClose = onClose
    }

    init(
        credential: CredentialMetadata,
        inline: Bool = false,
        explicitImport: Bool = false,
        onDraftChange: ((AccessKeyDraft) -> Void)? = nil,
        isDiscarding: @escaping () -> Bool = { false },
        onSave: @escaping @MainActor (AccessKeyDraft) async -> Void,
        onClose: (() -> Void)? = nil
    ) {
        var value = AccessKeyDraft()
        value.credentialID = credential.id
        value.label = credential.label
        value.mode = credential.accessKey?.backend == .secureEnclave ? .generateSecureEnclave : .importExisting
        value.publicKey = credential.accessKey?.publicKey ?? ""
        value.originalAlgorithm = credential.accessKey?.algorithm
        value.acceptLegacyRSA1024 = credential.accessKey?.compatibility == .legacyRSA1024
        _draft = State(initialValue: value)
        self.onSave = onSave
        self.inline = inline
        self.explicitImport = explicitImport
        self.onDraftChange = onDraftChange
        self.isDiscarding = isDiscarding
        self.onClose = onClose
    }

    var body: some View {
        editorShell(
            title: title,
            width: inline ? nil : 600,
            height: inline ? nil : 680,
            saveTitle: explicitImport ? "Import Key" : "Save",
            autoSave: inline && !explicitImport,
            trailingActions: explicitImport
        ) {
            VStack(spacing: 0) {
                if draft.credentialID == nil {
                    Picker("", selection: $draft.mode) {
                        Text("Import").tag(AccessKeyDraftMode.importExisting)
                        Text("Generate").tag(AccessKeyDraftMode.generateSoftware)
                        Text("Secure Enclave").tag(AccessKeyDraftMode.generateSecureEnclave)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                Form {
                Section {
                    TextField("Name", text: $draft.label)
                    if draft.mode == .generateSoftware {
                        Picker(FeatureL10n.text("ui.root.view.12"), selection: $generationType) {
                            Text(FeatureL10n.text("ui.credentials.view.40")).tag(0)
                            Text(FeatureL10n.text("ui.credentials.view.41")).tag(1)
                            Text(FeatureL10n.text("ui.credentials.view.42")).tag(2)
                        }
                        .onChange(of: generationType) { _, _ in updateGeneration() }
                        if generationType == 1 {
                            Picker(FeatureL10n.text("ui.credentials.view.43"), selection: $curve) {
                                ForEach(ECDSACurve.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }.onChange(of: curve) { _, _ in updateGeneration() }
                        } else if generationType == 2 {
                            Picker(FeatureL10n.text("ui.credentials.view.44"), selection: $rsaBits) {
                                Text(FeatureL10n.text("ui.credentials.view.45")).tag(2_048)
                                Text(FeatureL10n.text("ui.credentials.view.46")).tag(4_096)
                            }.onChange(of: rsaBits) { _, _ in updateGeneration() }
                        }
                        TextField(FeatureL10n.text("ui.field.2"), text: $draft.comment)
                    }
                }
                if draft.mode == .importExisting {
                    Section {
                        if draft.privateKey.isEmpty, let credentialID = draft.credentialID {
                            HStack {
                                Text("Private Key is locked.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Unlock", systemImage: "lock.open") {
                                    Task {
                                        if let value = await model.accessKeyDraft(
                                            id: credentialID
                                        ) { draft = value }
                                    }
                                }
                            }
                        }
                        TextEditor(text: $draft.privateKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 170, idealHeight: 170, maxHeight: 170)
                            .disabled(draft.privateKey.isEmpty && draft.credentialID != nil)
                        if draft.requiresUnlock {
                            Button("Unlock", systemImage: "lock.open") {
                                Task {
                                    if let value = await model.accessKeyDraft(
                                        id: draft.credentialID ?? UUID(),
                                        unlockingWith: draft.passphrase
                                    ) { draft = value }
                                }
                            }
                            .disabled(draft.passphrase.isEmpty)
                        }
                    } header: {
                        Text("Private Key")
                    }
                    Section {
                        TextEditor(text: $draft.publicKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                    } header: {
                        Text("Public Key")
                    }
                }
                if draft.mode == .generateSecureEnclave, !draft.publicKey.isEmpty {
                    Section {
                        Text(draft.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            copyToPasteboard(draft.publicKey)
                        }
                    } header: {
                        Text("Public Key")
                    }
                }
                if draft.mode != .generateSecureEnclave {
                    Section {
                        HStack {
                            Group {
                                if revealPassphrase {
                                    TextField(FeatureL10n.text("ui.field.3"), text: $draft.passphrase)
                                } else {
                                    SecureField(FeatureL10n.text("ui.field.3"), text: $draft.passphrase)
                                }
                            }
                            .disabled(isPrivateKeyLocked)
                            if isPrivateKeyLocked {
                                Text("Unlock private key first")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(revealPassphrase ? "Hide" : "Reveal", systemImage: revealPassphrase ? "eye.slash" : "eye") {
                                    revealPassphrase.toggle()
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                        if !isPrivateKeyLocked && !draft.passphrase.isEmpty {
                            Toggle(FeatureL10n.text("ui.credentials.view.57"), isOn: $draft.savePassphrase)
                        }
                    } header: {
                        Text("Security")
                    } footer: {
                        Text(isPrivateKeyLocked ? "Unlock private key first." : passphraseStorageDescription)
                    }
                } else {
                    Section {
                        Label(FeatureL10n.text("ui.credentials.view.59"), systemImage: "touchid")
                    } header: {
                        Text("Security")
                    } footer: {
                        Text(FeatureL10n.text("ui.credentials.view.60"))
                    }
                }
                Section {
                    TextField(FeatureL10n.text("ui.field.5"), text: .constant(""))
                        .disabled(true)
                } header: {
                    Text(FeatureL10n.text("ui.credentials.view.61"))
                } footer: {
                    Text(FeatureL10n.text("ui.credentials.view.62"))
                }
                }
                .formStyle(.grouped)
                if inline, draft.credentialID != nil, !explicitImport {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Export to Host", systemImage: "server.rack") {
                            isExportToHostPresented = true
                        }
                    }
                    .padding()
                }
            }
        } save: {
            hasTriggeredSave = true
            draft.passphraseConfirmation = draft.passphrase
            updateGeneration()
            await onSave(draft)
        } cancel: {
            hasTriggeredSave = true
            close()
        }
        .onDisappear {
            guard inline && !explicitImport && !hasTriggeredSave && !isDiscarding() else { return }
            Task { await onSave(draft) }
        }
        .onChange(of: draft) { _, value in onDraftChange?(value) }
        .alert("Unable to Save Access Key", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $isExportToHostPresented) {
            VStack(spacing: 18) {
                Image(systemName: "server.rack")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Export to Host")
                    .font(.title2.weight(.semibold))
                Text("Coming Soon")
                    .font(.headline)
                Text("Exporting an access key directly to a host is not implemented yet.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK") { isExportToHostPresented = false }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(32)
            .frame(width: 420, height: 260)
        }
        .fileImporter(isPresented: $isImportingPrivateKey, allowedContentTypes: [.data, .plainText]) { result in
            if case .success(let url) = result { loadPrivateKeyFile(url) }
        }
        .fileImporter(isPresented: $isImportingPublicKey, allowedContentTypes: [.data, .plainText]) { result in
            if case .success(let url) = result { loadFile(url, into: \AccessKeyDraft.publicKey) }
        }
    }

    private var title: String {
        if draft.credentialID != nil { return "Edit Access Key" }
        return switch draft.mode {
        case .importExisting: "Import Access Key"
        case .generateSoftware: "Generate Access Key"
        case .generateSecureEnclave: "Create Secure Enclave Key"
        }
    }

    private var isPrivateKeyLocked: Bool {
        draft.credentialID != nil && draft.mode == .importExisting && draft.privateKey.isEmpty
    }

    private var passphraseStorageDescription: String {
        if draft.passphrase.isEmpty {
            return "An encrypted imported key is saved as-is; its passphrase is requested for every connection."
        }
        if draft.savePassphrase {
            return "The encrypted key stays encrypted. Its passphrase is stored with Keychain user-presence protection, so every connection requires Touch ID or the Mac login password."
        }
        return "The key is unlocked before storage and connections are automatic. The private key remains device-only in Keychain."
    }

    private func updateGeneration() {
        switch generationType {
        case 1: draft.generation = .ecdsa(curve)
        case 2: draft.generation = .rsa(bitCount: rsaBits)
        default: draft.generation = .ed25519
        }
    }

    private func loadDroppedText(_ url: URL?, into keyPath: WritableKeyPath<AccessKeyDraft, String>) -> Bool {
        guard let url else { return false }
        loadFile(url, into: keyPath)
        return true
    }

    private func loadFile(_ url: URL, into keyPath: WritableKeyPath<AccessKeyDraft, String>) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            draft[keyPath: keyPath] = try String(contentsOf: url, encoding: .utf8)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func loadPrivateKeyFile(_ url: URL) {
        loadFile(url, into: \AccessKeyDraft.privateKey)
        draft.publicKey = ""
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct CredentialInspector: View {
    let credential: CredentialMetadata
    let onReplace: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close", systemImage: "arrow.left.to.line") { onClose() }
                    .labelStyle(.iconOnly)
                Image(systemName: "key.horizontal").foregroundStyle(.tint)
                Text(credential.label).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                if let key = credential.accessKey {
                    Section("Access Key") {
                        LabeledContent("Algorithm", value: key.algorithm.displayName)
                        LabeledContent("Storage", value: key.backend.displayName)
                        LabeledContent("Fingerprint", value: key.fingerprint)
                    }
                    Section("Public Key") {
                        Text(key.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Replace private key…", systemImage: "arrow.triangle.2.circlepath") {
                        onReplace()
                    }
                } footer: {
                    Text("Private key material is never read until you explicitly replace or export it.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct IdentityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: IdentityDraft
    @State private var hasTriggeredSave = false
    @State private var revealPassword = false
    @State private var isLoadingStoredPassword: Bool
    let onSave: @MainActor (IdentityDraft) async -> Void
    let inline: Bool
    let onDraftChange: ((IdentityDraft) -> Void)?
    let isDiscarding: () -> Bool
    let onClose: (() -> Void)?

    init(
        draft: IdentityDraft,
        inline: Bool = false,
        onDraftChange: ((IdentityDraft) -> Void)? = nil,
        isDiscarding: @escaping () -> Bool = { false },
        onSave: @escaping @MainActor (IdentityDraft) async -> Void,
        onClose: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)
        _isLoadingStoredPassword = State(initialValue: draft.authenticationMethods.contains { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        })
        self.onSave = onSave
        self.inline = inline
        self.onDraftChange = onDraftChange
        self.isDiscarding = isDiscarding
        self.onClose = onClose
    }

    var body: some View {
        editorShell(title: draft.id == nil ? "Add Identity" : "Edit Identity", width: inline ? nil : 560, height: inline ? nil : 600, autoSave: inline) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                }
                Section("Authentication") {
                    TextField(FeatureL10n.text("host.username"), text: $draft.username)
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
                                VStack(alignment: .leading) {
                                    Text(credential(id)?.label ?? "Unavailable access key")
                                    Text(credential(id)?.accessKey?.algorithm.displayName ?? "Access Key")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let position = accessKeyIndices.firstIndex(of: index) ?? 0
                                Button("Move Up", systemImage: "arrow.up") { moveAccessKey(index, by: -1) }
                                    .labelStyle(.iconOnly).disabled(position == 0)
                                Button("Move Down", systemImage: "arrow.down") { moveAccessKey(index, by: 1) }
                                    .labelStyle(.iconOnly).disabled(position == accessKeyIndices.count - 1)
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    draft.authenticationMethods.remove(at: index)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                    if model.activeCredentials.isEmpty {
                        Text("No access keys yet. Create one in the Credentials section.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if availableAccessKeys.isEmpty {
                        Text("All available access keys are already added.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu("Add Access Key", systemImage: "key.horizontal") {
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
            }.formStyle(.grouped)
        } save: {
            hasTriggeredSave = true
            await onSave(draft)
        } cancel: {
            hasTriggeredSave = true
            close()
        }
        .onDisappear {
            guard inline && !hasTriggeredSave && !isDiscarding() else { return }
            Task { await onSave(draft) }
        }
        .onChange(of: draft) { _, value in onDraftChange?(value) }
        .task {
            guard isLoadingStoredPassword else { return }
            let loaded = await model.loadIdentityPassword(into: draft)
            draft = loaded
            isLoadingStoredPassword = false
        }
        .alert("Unable to Load Identity Password", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func credential(_ id: UUID) -> CredentialMetadata? { model.credentials.first { $0.id == id } }
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
    private var selectedAccessKeyIDs: Set<UUID> {
        Set(draft.authenticationMethods.compactMap { method in
            if case .accessKey(let id) = method.kind { return id }
            return nil
        })
    }
    private var availableAccessKeys: [CredentialMetadata] {
        model.activeCredentials.filter { !selectedAccessKeyIDs.contains($0.id) }
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
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct CredentialDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    let credential: CredentialMetadata
    @State private var passphrase = ""
    @State private var document: PrivateKeyDocument?
    @State private var isExporting = false
    @State private var isConfirmingPurge = false

    var body: some View {
        editorShell(title: credential.label, width: 620, height: 560, saveTitle: "Done") {
            Form {
                if let key = credential.accessKey {
                    Section(FeatureL10n.text("ui.credentials.view.12")) {
                        LabeledContent(FeatureL10n.text("ui.root.view.12"), value: key.algorithm.displayName)
                        LabeledContent(FeatureL10n.text("ui.credentials.view.75"), value: key.backend.displayName)
                        LabeledContent(FeatureL10n.text("ui.credentials.view.58"), value: key.passphraseProtection.displayName)
                        LabeledContent(FeatureL10n.text("ui.credentials.view.77"), value: key.fingerprint)
                        if let warning = key.compatibility.warning {
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    Section(FeatureL10n.text("ui.credentials.view.53")) {
                        Text(key.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button(FeatureL10n.text("ui.credentials.view.79"), systemImage: "doc.on.doc") { copyToPasteboard(key.publicKey) }
                    }
                    if key.backend == .software {
                        Section {
                            if key.passphraseProtection == .promptEveryConnection {
                                SecureField(FeatureL10n.text("ui.field.7"), text: $passphrase)
                            }
                            Button(FeatureL10n.text("ui.credentials.view.80"), systemImage: "square.and.arrow.up") {
                                Task {
                                    if let data = await model.exportPrivateKey(id: credential.id, passphrase: passphrase) {
                                        document = PrivateKeyDocument(data: data)
                                        isExporting = true
                                    }
                                }
                            }
                        } header: {
                            Text(FeatureL10n.text("ui.credentials.view.81"))
                        } footer: {
                            Text(FeatureL10n.text("ui.credentials.view.82"))
                        }
                    }
                    Section {
                        if !credential.isDeleted {
                            Button(FeatureL10n.text("ui.credentials.view.83"), systemImage: "archivebox") {
                                Task {
                                    model.errorMessage = nil
                                    await model.deleteCredential(id: credential.id)
                                    if model.errorMessage == nil { dismiss() }
                                }
                            }
                            .disabled(model.credentialUsageCount(id: credential.id) > 0)
                        }
                        Button(FeatureL10n.text("ui.credentials.view.84"), systemImage: "trash", role: .destructive) {
                            isConfirmingPurge = true
                        }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0 || !credential.isSecretAvailable)
                    } header: {
                        Text(FeatureL10n.text("ui.credentials.view.85"))
                    } footer: {
                        if model.credentialUsageCount(id: credential.id) > 0 {
                            Text(FeatureL10n.text("ui.credentials.view.86"))
                        } else {
                            Text(FeatureL10n.text("ui.credentials.view.87"))
                        }
                    }
                }
            }.formStyle(.grouped)
        } save: { dismiss() } cancel: { dismiss() }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .plainText,
            defaultFilename: credential.label.replacingOccurrences(of: " ", with: "-")
        ) { _ in document = nil }
        .alert(FeatureL10n.text("ui.credentials.view.93"), isPresented: $isConfirmingPurge) {
            Button(FeatureL10n.text("ui.credentials.view.88"), role: .destructive) {
                Task {
                    model.errorMessage = nil
                    await model.purgeCredential(id: credential.id)
                    if model.errorMessage == nil { dismiss() }
                }
            }
            Button(FeatureL10n.text("ui.history.view.9"), role: .cancel) {}
        } message: {
            Text(FeatureL10n.text("ui.credentials.view.90"))
        }
    }
}

private struct PrivateKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
@ViewBuilder
private func editorShell<Content: View>(
    title: String,
    width: CGFloat?,
    height: CGFloat?,
    saveTitle: String = "Save",
    autoSave: Bool = false,
    trailingActions: Bool = false,
    @ViewBuilder content: () -> Content,
    save: @escaping @MainActor () async -> Void,
    cancel: @escaping () -> Void
) -> some View {
    VStack(spacing: 0) {
        HStack {
            Text(title).font(.title2).fontWeight(.semibold)
            Spacer()
        }
        .padding()
        content()
        if !autoSave {
            Divider()
            HStack {
                if trailingActions { Spacer() }
                Button(FeatureL10n.text("ui.history.view.9")) { cancel() }.keyboardShortcut(.cancelAction)
                if !trailingActions { Spacer() }
                Button(saveTitle) { Task { await save() } }
                    .buttonStyle(.glassProminent).tint(.blue).keyboardShortcut(.defaultAction)
            }.padding()
        }
    }.frame(width: width, height: height)
}

private func copyToPasteboard(_ value: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = value
    #endif
}
