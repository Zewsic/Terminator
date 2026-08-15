import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
                        Text(FeatureL10n.text(.actionImport)).tag(AccessKeyDraftMode.importExisting)
                        Text(FeatureL10n.text(.credentialsGenerate)).tag(AccessKeyDraftMode.generateSoftware)
                        Text(FeatureL10n.text(.credentialsSecureEnclave)).tag(AccessKeyDraftMode.generateSecureEnclave)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                Form {
                Section {
                    TextField(FeatureL10n.text(.uiField6), text: $draft.label)
                    if draft.mode == .generateSoftware {
                        Picker(FeatureL10n.text(.rootAlgorithm), selection: $generationType) {
                            Text(FeatureL10n.text(.credentialsEd25519)).tag(0)
                            Text(FeatureL10n.text(.credentialsEcdsa)).tag(1)
                            Text(FeatureL10n.text(.credentialsRsa)).tag(2)
                        }
                        .onChange(of: generationType) { _, _ in updateGeneration() }
                        if generationType == 1 {
                            Picker(FeatureL10n.text(.credentialsCurve), selection: $curve) {
                                ForEach(ECDSACurve.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }.onChange(of: curve) { _, _ in updateGeneration() }
                        } else if generationType == 2 {
                            Picker(FeatureL10n.text(.credentialsBits), selection: $rsaBits) {
                                Text(FeatureL10n.text(.credentials2048)).tag(2_048)
                                Text(FeatureL10n.text(.credentials4096)).tag(4_096)
                            }.onChange(of: rsaBits) { _, _ in updateGeneration() }
                        }
                        TextField(FeatureL10n.text(.uiField2), text: $draft.comment)
                    }
                }
                if draft.mode == .importExisting {
                    Section {
                        if draft.privateKey.isEmpty, let credentialID = draft.credentialID {
                            HStack {
                                Text(FeatureL10n.text(.featureAccessKeyEditorPrivateKeyIsLocked))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(FeatureL10n.text(.featureAccessKeyEditorUnlock), systemImage: "lock.open") {
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
                            Button(FeatureL10n.text(.featureAccessKeyEditorUnlock), systemImage: "lock.open") {
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
                        Text(FeatureL10n.text(.credentialsPrivateKey))
                    }
                    Section {
                        TextEditor(text: $draft.publicKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                    } header: {
                        Text(FeatureL10n.text(.credentialsPublicKey))
                    }
                }
                if draft.mode == .generateSecureEnclave, !draft.publicKey.isEmpty {
                    Section {
                        Text(draft.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(FeatureL10n.text(.credentialsCopyPublicKey), systemImage: "doc.on.doc") {
                            copyToPasteboard(draft.publicKey)
                        }
                    } header: {
                        Text(FeatureL10n.text(.credentialsPublicKey))
                    }
                }
                if draft.mode != .generateSecureEnclave {
                    Section {
                        HStack {
                            Group {
                                if revealPassphrase {
                                    TextField(FeatureL10n.text(.uiField3), text: $draft.passphrase)
                                } else {
                                    SecureField(FeatureL10n.text(.uiField3), text: $draft.passphrase)
                                }
                            }
                            .disabled(isPrivateKeyLocked)
                            if isPrivateKeyLocked {
                                Text(FeatureL10n.text(.featureAccessKeyEditorUnlockPrivateKeyFirst))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(FeatureL10n.text(revealPassphrase ? .actionHide : .actionReveal), systemImage: revealPassphrase ? "eye.slash" : "eye") {
                                    revealPassphrase.toggle()
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                        if !isPrivateKeyLocked && !draft.passphrase.isEmpty {
                            Toggle(FeatureL10n.text(.credentialsRequireTouchIdForConnections), isOn: $draft.savePassphrase)
                        }
                    } header: {
                        Text(FeatureL10n.text(.featureAccessKeyEditorSecurity))
                    } footer: {
                        Text(isPrivateKeyLocked ? FeatureL10n.text(.featureAccessKeyEditorUnlockPrivateKeyFirst) : passphraseStorageDescription)
                    }
                } else {
                    Section {
                        Label(FeatureL10n.text(.credentialsEcdsaP256PrivateKeyCannotBe), systemImage: "touchid")
                    } header: {
                        Text(FeatureL10n.text(.featureAccessKeyEditorSecurity))
                    } footer: {
                        Text(FeatureL10n.text(.credentialsEachSignatureIsAuthorizedByTouchId))
                    }
                }
                Section {
                    TextField(FeatureL10n.text(.uiField5), text: .constant(""))
                        .disabled(true)
                } header: {
                    Text(FeatureL10n.text(.credentialsCertificate))
                } footer: {
                    Text(FeatureL10n.text(.credentialsAnSshCertificateIsAPublicCa))
                }
                }
                .formStyle(.grouped)
                if inline, draft.credentialID != nil, !explicitImport {
                    Divider()
                    HStack {
                        Spacer()
                        Button(FeatureL10n.text(.featureAccessKeyEditorExportToHost), systemImage: "server.rack") {
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
        .alert(FeatureL10n.text(.featureAccessKeyEditorUnableToSaveAccessKey), isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.dismissPresentedError() } }
        )) {
            Button(FeatureL10n.text(.actionOk)) { model.dismissPresentedError() }
        } message: {
            Text(model.presentedError?.message ?? "")
        }
        .sheet(isPresented: $isExportToHostPresented) {
            VStack(spacing: 18) {
                Image(systemName: "server.rack")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(FeatureL10n.text(.featureAccessKeyEditorExportToHost))
                    .font(.title2.weight(.semibold))
                Text(FeatureL10n.text(.featureAccessKeyEditorComingSoon))
                    .font(.headline)
                Text(FeatureL10n.text(.featureAccessKeyEditorExportingAnAccessKeyDirectlyToA))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(FeatureL10n.text(.actionOk)) { isExportToHostPresented = false }
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
        if draft.credentialID != nil { return FeatureL10n.text(.keyEditorEdit) }
        return switch draft.mode {
        case .importExisting: FeatureL10n.text(.keyEditorImport)
        case .generateSoftware: FeatureL10n.text(.keyEditorGenerate)
        case .generateSecureEnclave: FeatureL10n.text(.keyEditorSecureEnclave)
        }
    }

    private var isPrivateKeyLocked: Bool {
        draft.credentialID != nil && draft.mode == .importExisting && draft.privateKey.isEmpty
    }

    private var passphraseStorageDescription: String {
        if draft.passphrase.isEmpty {
            return FeatureL10n.text(.keyPassphrasePromptDescription)
        }
        if draft.savePassphrase {
            return FeatureL10n.text(.keyPassphraseSavedDescription)
        }
        return FeatureL10n.text(.keyPassphraseNoneDescription)
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
            model.present(error)
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
