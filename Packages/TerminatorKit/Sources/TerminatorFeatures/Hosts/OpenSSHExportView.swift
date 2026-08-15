import SwiftUI
import TerminatorCore

struct OpenSSHExportView: View {
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
                Section(FeatureL10n.text(.hostsOpenssh)) {
                    TextField(FeatureL10n.text(.uiField8), text: $alias)
                    TextField(FeatureL10n.text(.uiField9), text: $configPath)
                    TextField(FeatureL10n.text(.uiField10), text: $keyDirectory)
                }
                if hasExistingSelectedKeyFiles {
                    Section {
                        Toggle(FeatureL10n.text(.featureOpenSshexportReplaceExistingKeyFiles), isOn: $replaceKeyFiles)
                    } footer: {
                        Text(FeatureL10n.text(.featureOpenSshexportOneOrMoreSelectedKeyFilesAlready))
                    }
                }
                ForEach(credentials) { credential in
                    Section(FeatureL10n.text(.openSSHExportKeySection, credential.label)) {
                        Toggle(FeatureL10n.text(.hostsExportPublicKey), isOn: selectionBinding(credential.id, in: $publicKeyIDs))
                        if credential.accessKey?.backend == .secureEnclave {
                            LabeledContent(FeatureL10n.text(.keyExportAction)) {
                                Text(FeatureL10n.text(.featureOpenSshexportCanTBeExported))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Toggle(FeatureL10n.text(.keyExportAction), isOn: selectionBinding(credential.id, in: $privateKeyIDs))
                            if privateKeyIDs.contains(credential.id) {
                                Text(FeatureL10n.text(.featureOpenSshexportPrivateKeyExportRequiresSystemAuthentication))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if case .promptEveryConnection = credential.accessKey?.passphraseProtection {
                                    SecureField(FeatureL10n.text(.featureOpenSshexportPrivateKeyPassphrase),
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
                Section(FeatureL10n.text(.hostsProposedHostBlock)) {
                    Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let comparison {
                    Section(FeatureL10n.text(.hostsExistingHostBlock)) {
                        Text(comparison.existingBlock).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Toggle(FeatureL10n.text(.hostsReplaceThisHostBlock), isOn: $replaceHostBlock)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(FeatureL10n.text(.actionCancel)) { onClose() }
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
                        Text(didExport ? FeatureL10n.text(.openSSHExportCompleted, alias) : FeatureL10n.text(.openSSHExportAction))
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
            URL(fileURLWithPath: keyDirectory).appending(path: OpenSSHPathPolicy.safeFilename(credential.label))
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
            let base = directory.appending(path: OpenSSHPathPolicy.safeFilename(credential.label))
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
            let base = directory.appending(path: OpenSSHPathPolicy.safeFilename(credential.label))
            let hasPrivateConflict = privateKeyIDs.contains(credential.id)
                && credential.accessKey?.backend == .software
                && FileManager.default.fileExists(atPath: base.path)
            let hasPublicConflict = publicKeyIDs.contains(credential.id)
                && FileManager.default.fileExists(atPath: base.path + ".pub")
            return hasPrivateConflict || hasPublicConflict
        }
    }

}
