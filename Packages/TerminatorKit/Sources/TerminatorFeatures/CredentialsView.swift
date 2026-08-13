import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CredentialsView: View {
    private enum Pane: String, CaseIterable {
        case identities = "Identities"
        case credentials = "Credentials"
    }

    @Environment(TerminatorAppModel.self) private var model
    @State private var pane: Pane = .identities
    @State private var accessKeyDraft: AccessKeyDraft?
    @State private var identityDraft: IdentityDraft?
    @State private var selectedCredential: CredentialMetadata?
    @State private var pendingArchive: CredentialMetadata?
    @State private var pendingPurge: CredentialMetadata?
    @State private var pendingIdentityArchive: IdentityProfile?

    var body: some View {
        Group {
            switch pane {
            case .identities: identitiesContent
            case .credentials: credentialsContent
            }
        }
        .navigationTitle("Credentials")
        .toolbar {
            ToolbarItem {
                Picker("Section", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem { addMenu }
        }
        .sheet(item: $accessKeyDraft) { draft in
            AccessKeyEditor(draft: draft) { value in
                if await model.saveAccessKey(value) != nil { accessKeyDraft = nil }
            }
        }
        .sheet(item: $identityDraft) { draft in
            IdentityEditor(draft: draft) { value in
                if await model.saveIdentity(value) { identityDraft = nil }
            }
        }
        .sheet(item: $selectedCredential) { credential in
            AccessKeyEditor(credential: credential) { value in
                if await model.replaceAccessKey(value) { selectedCredential = nil }
            }
        }
        .confirmationDialog(
            "Archive this credential?",
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingArchive { Task { await model.deleteCredential(id: pendingArchive.id) } }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("Its Keychain material remains available until you purge it explicitly.")
        }
        .confirmationDialog(
            "Permanently purge this secret?",
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Purge Secret", role: .destructive) {
                if let pendingPurge { Task { await model.purgeCredential(id: pendingPurge.id) } }
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("All associated private material and any saved passphrase will be removed. This cannot be undone from History.")
        }
        .confirmationDialog(
            "Archive this identity?",
            isPresented: Binding(get: { pendingIdentityArchive != nil }, set: { if !$0 { pendingIdentityArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingIdentityArchive { Task { await model.deleteIdentity(id: pendingIdentityArchive.id) } }
                pendingIdentityArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingIdentityArchive = nil }
        }
    }

    private var addMenu: some View {
        Menu("Add", systemImage: "plus") {
            Button("Identity", systemImage: "person.badge.key") {
                pane = .identities
                identityDraft = IdentityDraft()
            }
            Button("Access Key", systemImage: "key.horizontal") {
                pane = .credentials
                var draft = AccessKeyDraft()
                draft.mode = .importExisting
                draft.suggestedOrdinal = model.activeCredentials.count + 1
                accessKeyDraft = draft
            }
        }
        .accessibilityIdentifier("add-credential")
    }

    @ViewBuilder
    private var identitiesContent: some View {
        let active = model.identities.filter { !$0.isDeleted }
        let archived = model.identities.filter(\.isDeleted)
        if model.identities.isEmpty {
            ContentUnavailableView {
                Label("No identities", systemImage: "person.badge.key")
            } description: {
                Text("An identity combines a username with ordered authentication methods.")
            } actions: {
                Button("Add Identity", systemImage: "plus") { identityDraft = IdentityDraft() }
                    .buttonStyle(.glassProminent)
                    .tint(.clear)
            }
        } else {
            List {
                Section("Available") {
                    ForEach(active) { identity in identityRow(identity) }
                }
                if !archived.isEmpty {
                    Section("Archived") { ForEach(archived) { identity in identityRow(identity) } }
                }
            }
            .accessibilityIdentifier("identities-list")
        }
    }

    private func identityRow(_ identity: IdentityProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name).fontWeight(.medium)
                Text("\(identity.username) · \(identity.authenticationMethods.count) method\(identity.authenticationMethods.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") {
                if !identity.isDeleted {
                    Button("Edit") { identityDraft = IdentityDraft(identity: identity) }
                    Button("Archive", role: .destructive) { pendingIdentityArchive = identity }
                        .disabled(model.identityUsageCount(id: identity.id) > 0)
                }
            }
            .menuStyle(.borderlessButton)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !identity.isDeleted { identityDraft = IdentityDraft(identity: identity) } }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var credentialsContent: some View {
        let available = model.credentials.filter { !$0.isDeleted && $0.isSecretAvailable }
        let keys = available.filter { $0.kind == .accessKey }
        let legacy = available.filter { $0.kind != .accessKey }
        let archived = model.credentials.filter { $0.isDeleted || !$0.isSecretAvailable }
        if model.credentials.isEmpty {
            ContentUnavailableView {
                Label("No credentials", systemImage: "key")
            } description: {
                Text("Secret material is stored in the device-only Keychain, never in the catalog database.")
            } actions: { addMenu.buttonStyle(.glassProminent).tint(.clear) }
        } else {
            List {
                if !keys.isEmpty { Section("Access Keys") { ForEach(keys) { credentialRow($0) } } }
                if !legacy.isEmpty { Section("Needs Review") { ForEach(legacy) { credentialRow($0) } } }
                if !archived.isEmpty { Section("Archived and Purged") { ForEach(archived) { credentialRow($0) } } }
            }
            .accessibilityIdentifier("credentials-list")
        }
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: credential.kind == .accessKey ? "key.horizontal" : "key")
                .foregroundStyle(credential.isSecretAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label).fontWeight(.medium)
                Text(status(for: credential)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") {
                if credential.kind == .accessKey { Button("Details") { selectedCredential = credential } }
                if !credential.isDeleted {
                    Button("Archive", role: .destructive) { pendingArchive = credential }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0)
                }
                if credential.isSecretAvailable, model.credentialUsageCount(id: credential.id) == 0 {
                    Button("Purge Secret", role: .destructive) { pendingPurge = credential }
                }
            }
            .menuStyle(.borderlessButton)
        }
        .contentShape(Rectangle())
        .onTapGesture { if credential.kind == .accessKey { selectedCredential = credential } }
        .padding(.vertical, 3)
    }

    private func status(for credential: CredentialMetadata) -> String {
        if !credential.isSecretAvailable { return "Secret purged · metadata only" }
        if credential.kind == .legacyPassphrase { return "Legacy passphrase · attach manually or archive" }
        let usage = model.credentialUsageCount(id: credential.id)
        let detail = credential.accessKey?.algorithm.displayName ?? credential.kind.displayName
        if credential.isDeleted { return "Archived · secret retained" }
        if usage == 0 { return "Unused · \(detail)" }
        return "Used by \(usage) profile\(usage == 1 ? "" : "s") · \(detail)"
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
    let onSave: @MainActor (AccessKeyDraft) async -> Void

    init(draft: AccessKeyDraft, onSave: @escaping @MainActor (AccessKeyDraft) async -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    init(credential: CredentialMetadata, onSave: @escaping @MainActor (AccessKeyDraft) async -> Void) {
        var value = AccessKeyDraft()
        value.credentialID = credential.id
        value.label = credential.label
        value.mode = credential.accessKey?.backend == .secureEnclave ? .generateSecureEnclave : .importExisting
        value.publicKey = credential.accessKey?.publicKey ?? ""
        value.originalAlgorithm = credential.accessKey?.algorithm
        value.acceptLegacyRSA1024 = credential.accessKey?.compatibility == .legacyRSA1024
        _draft = State(initialValue: value)
        self.onSave = onSave
    }

    var body: some View {
        editorShell(title: title, width: 600, height: 680) {
            Form {
                Section("Key") {
                    TextField("Name (optional)", text: $draft.label, prompt: Text(draft.automaticLabel))
                    if draft.credentialID == nil {
                        Picker("Action", selection: $draft.mode) {
                            Text("Import").tag(AccessKeyDraftMode.importExisting)
                            Text("Generate").tag(AccessKeyDraftMode.generateSoftware)
                            Text("Secure Enclave").tag(AccessKeyDraftMode.generateSecureEnclave)
                        }
                        .pickerStyle(.segmented)
                    } else if let algorithm = draft.originalAlgorithm {
                        LabeledContent("Detected algorithm", value: algorithm.displayName)
                    }
                    if draft.mode == .generateSoftware {
                        Picker("Algorithm", selection: $generationType) {
                            Text("Ed25519").tag(0)
                            Text("ECDSA").tag(1)
                            Text("RSA").tag(2)
                        }
                        .onChange(of: generationType) { _, _ in updateGeneration() }
                        if generationType == 1 {
                            Picker("Curve", selection: $curve) {
                                ForEach(ECDSACurve.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }.onChange(of: curve) { _, _ in updateGeneration() }
                        } else if generationType == 2 {
                            Picker("Bits", selection: $rsaBits) {
                                Text("2048").tag(2_048)
                                Text("4096").tag(4_096)
                            }.onChange(of: rsaBits) { _, _ in updateGeneration() }
                        }
                        TextField("Public key comment", text: $draft.comment)
                    }
                }
                if draft.mode == .importExisting {
                    Section {
                        if draft.requiresUnlock {
                            Label("Enter the existing passphrase, then unlock the key.", systemImage: "lock")
                                .foregroundStyle(.secondary)
                            Button("Unlock Private Key", systemImage: "lock.open") {
                                Task {
                                    if let value = await model.accessKeyDraft(
                                        id: draft.credentialID ?? UUID(),
                                        unlockingWith: draft.passphrase
                                    ) { draft = value }
                                }
                            }
                            .disabled(draft.passphrase.isEmpty)
                        } else {
                            TextEditor(text: $draft.privateKey)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 170)
                                .dropDestination(for: URL.self) { urls, _ in
                                    guard let url = urls.first else { return false }
                                    loadPrivateKeyFile(url)
                                    return true
                                }
                            Button("Load Private Key File…", systemImage: "doc.badge.plus") {
                                isImportingPrivateKey = true
                            }
                        }
                    } header: {
                        Text("Private Key")
                    } footer: {
                        Text("Drop a private-key file here or choose one. Saving creates new immutable Keychain items; the previous version remains available to History.")
                    }
                    Section {
                        TextEditor(text: $draft.publicKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .dropDestination(for: URL.self) { urls, _ in
                                return loadDroppedText(urls.first, into: \AccessKeyDraft.publicKey)
                            }
                        Button("Load Public Key File…", systemImage: "doc.badge.plus") {
                            isImportingPublicKey = true
                        }
                    } header: {
                        Text("Public Key")
                    } footer: {
                        Text("Optional during import. If supplied, it must match the private key; the stored public key is always derived from private material.")
                    }
                    Section("Compatibility") {
                        Toggle("Allow RSA-1024 legacy compatibility", isOn: $draft.acceptLegacyRSA1024)
                    }
                }
                if draft.mode != .generateSecureEnclave {
                    Section {
                        HStack {
                            Group {
                                if revealPassphrase {
                                    TextField("Passphrase (optional)", text: $draft.passphrase)
                                } else {
                                    SecureField("Passphrase (optional)", text: $draft.passphrase)
                                }
                            }
                            Button(revealPassphrase ? "Hide" : "Reveal", systemImage: revealPassphrase ? "eye.slash" : "eye") {
                                revealPassphrase.toggle()
                            }
                            .labelStyle(.iconOnly)
                        }
                        if revealPassphrase {
                            TextField("Confirm passphrase", text: $draft.passphraseConfirmation)
                        } else {
                            SecureField("Confirm passphrase", text: $draft.passphraseConfirmation)
                        }
                        Toggle("Save passphrase in Keychain", isOn: $draft.savePassphrase)
                            .disabled(draft.passphrase.isEmpty)
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text(draft.savePassphrase
                             ? "The encrypted key and passphrase use separate device-only Keychain items."
                             : "If protected, the passphrase will be requested for every connection.")
                    }
                } else {
                    Section {
                        Label("ECDSA P-256 · private key cannot be exported", systemImage: "touchid")
                    } footer: {
                        Text("Each signature is authorized by Touch ID or the Mac login password.")
                    }
                }
                Section {
                    TextField("SSH certificate support is planned", text: .constant(""))
                        .disabled(true)
                } header: {
                    Text("Certificate")
                } footer: {
                    Text("An SSH certificate is a public CA-signed attachment to this key. It will be enabled when transport-side certificate authentication is implemented.")
                }
            }.formStyle(.grouped)
        } save: {
            updateGeneration()
            await onSave(draft)
        } cancel: { dismiss() }
        .task(id: draft.credentialID) {
            guard let id = draft.credentialID, draft.privateKey.isEmpty else { return }
            if let value = await model.accessKeyDraft(id: id) { draft = value }
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
}

private struct IdentityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: IdentityDraft
    @State private var accessKeyDraft: AccessKeyDraft?
    let onSave: @MainActor (IdentityDraft) async -> Void

    init(draft: IdentityDraft, onSave: @escaping @MainActor (IdentityDraft) async -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        editorShell(title: draft.id == nil ? "Add Identity" : "Edit Identity", width: 560, height: 600) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Username", text: $draft.username)
                }
                Section("Authentication Methods") {
                    ForEach(Array(draft.authenticationMethods.enumerated()), id: \.element.id) { index, method in
                        HStack {
                            switch method.kind {
                            case .password(let existingSecretID):
                                VStack(alignment: .leading, spacing: 3) {
                                    SecureField(
                                        existingSecretID == nil ? "Password" : "Stored password — enter to replace",
                                        text: $draft.authenticationMethods[index].password
                                    )
                                    Text("Password")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            case .accessKey(let id):
                                VStack(alignment: .leading) {
                                    Text(credential(id)?.label ?? "Unavailable access key")
                                    Text(credential(id)?.accessKey?.algorithm.displayName ?? "Access Key")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Move Up", systemImage: "arrow.up") { move(index, by: -1) }
                                .labelStyle(.iconOnly).disabled(index == 0)
                            Button("Move Down", systemImage: "arrow.down") { move(index, by: 1) }
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
                            value.suggestedLabelContext = identityLabelContext
                            value.suggestedOrdinal = accessKeyCount + 1
                            accessKeyDraft = value
                        }
                    }
                }
            }.formStyle(.grouped)
        } save: { await onSave(draft) } cancel: { dismiss() }
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

    private func credential(_ id: UUID) -> CredentialMetadata? { model.credentials.first { $0.id == id } }
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
    private var identityLabelContext: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? draft.username.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard draft.authenticationMethods.indices.contains(target) else { return }
        draft.authenticationMethods.swapAt(index, target)
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
                    Section("Access Key") {
                        LabeledContent("Algorithm", value: key.algorithm.displayName)
                        LabeledContent("Storage", value: key.backend.displayName)
                        LabeledContent("Passphrase", value: key.passphraseProtection.displayName)
                        LabeledContent("Fingerprint", value: key.fingerprint)
                        if let warning = key.compatibility.warning {
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    Section("Public Key") {
                        Text(key.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy Public Key", systemImage: "doc.on.doc") { copyToPasteboard(key.publicKey) }
                    }
                    if key.backend == .software {
                        Section {
                            if key.passphraseProtection == .promptEveryConnection {
                                SecureField("Key passphrase", text: $passphrase)
                            }
                            Button("Export Private Key…", systemImage: "square.and.arrow.up") {
                                Task {
                                    if let data = await model.exportPrivateKey(id: credential.id, passphrase: passphrase) {
                                        document = PrivateKeyDocument(data: data)
                                        isExporting = true
                                    }
                                }
                            }
                        } header: {
                            Text("Private Key Export")
                        } footer: {
                            Text("Export requires system authentication. Keep the resulting file private.")
                        }
                    }
                    Section {
                        if !credential.isDeleted {
                            Button("Archive Key", systemImage: "archivebox") {
                                Task {
                                    model.errorMessage = nil
                                    await model.deleteCredential(id: credential.id)
                                    if model.errorMessage == nil { dismiss() }
                                }
                            }
                            .disabled(model.credentialUsageCount(id: credential.id) > 0)
                        }
                        Button("Purge Private Material…", systemImage: "trash", role: .destructive) {
                            isConfirmingPurge = true
                        }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0 || !credential.isSecretAvailable)
                    } header: {
                        Text("Management")
                    } footer: {
                        if model.credentialUsageCount(id: credential.id) > 0 {
                            Text("Detach this key from every Host and Identity before archiving or purging it.")
                        } else {
                            Text("Purge permanently removes private material and any saved passphrase. Public metadata remains in history.")
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
        .alert("Permanently purge this key?", isPresented: $isConfirmingPurge) {
            Button("Purge", role: .destructive) {
                Task {
                    model.errorMessage = nil
                    await model.purgeCredential(id: credential.id)
                    if model.errorMessage == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private key and saved passphrase cannot be recovered from history.")
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
    width: CGFloat,
    height: CGFloat,
    saveTitle: String = "Save",
    @ViewBuilder content: () -> Content,
    save: @escaping @MainActor () async -> Void,
    cancel: @escaping () -> Void
) -> some View {
    VStack(spacing: 0) {
        HStack { Text(title).font(.title2).fontWeight(.semibold); Spacer() }.padding()
        content()
        Divider()
        HStack {
            Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(saveTitle) { Task { await save() } }
                .buttonStyle(.glassProminent).tint(.clear).keyboardShortcut(.defaultAction)
        }.padding()
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
