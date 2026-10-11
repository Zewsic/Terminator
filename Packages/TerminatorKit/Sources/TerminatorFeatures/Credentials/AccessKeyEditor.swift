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
    @State private var originalDraft: AccessKeyDraft
    @State private var generationType = 0
    @State private var curve: ECDSACurve = .p256
    @State private var rsaBits = 2_048
    @State private var revealPassphrase = false
    @State private var isImportingPrivateKey = false
    @State private var isImportingPublicKey = false
    @State private var hasTriggeredSave = false
    @State private var isExportToHostPresented = false
    @State private var isConfigurationExpanded = true
    @State private var isPrivateKeyExpanded = true
    @State private var isPublicKeyExpanded = true
    @State private var isSecurityExpanded = true
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
        _originalDraft = State(initialValue: draft)
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
        _originalDraft = State(initialValue: value)
        self.onSave = onSave
        self.inline = inline
        self.explicitImport = explicitImport
        self.onDraftChange = onDraftChange
        self.isDiscarding = isDiscarding
        self.onClose = onClose
    }

    var body: some View {
        InspectorScreen(title: title) {
            if isCreatingAccessKey {
                InspectorSegmentedSelector(
                    selection: $draft.mode,
                    options: [
                        .init(value: .importExisting, title: FeatureL10n.text(.actionImport)),
                        .init(value: .generateSoftware, title: FeatureL10n.text(.credentialsGenerate)),
                        .init(value: .generateSecureEnclave, title: FeatureL10n.text(.credentialsSecureEnclave)),
                    ],
                    fillsWidth: true
                )
            }

            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.uiField6)) {
                    TextField(FeatureL10n.text(.uiField6), text: $draft.label)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }

            if draft.mode == .generateSoftware {
                InspectorCollapsibleSection(
                    FeatureL10n.text(.keyEditorConfiguration),
                    isExpanded: $isConfigurationExpanded
                ) {
                    InspectorFieldGroup {
                        InspectorFieldRow(FeatureL10n.text(.rootAlgorithm)) {
                            InspectorSegmentedSelector(
                                selection: $generationType,
                                options: [
                                    .init(value: 0, title: FeatureL10n.text(.credentialsEd25519)),
                                    .init(value: 1, title: FeatureL10n.text(.credentialsEcdsa)),
                                    .init(value: 2, title: FeatureL10n.text(.credentialsRsa)),
                                ],
                                style: .chips
                            )
                            .onChange(of: generationType) { _, _ in updateGeneration() }
                        }
                        if generationType == 1 {
                            InspectorGroupDivider()
                            InspectorFieldRow(FeatureL10n.text(.credentialsCurve)) {
                                InspectorSegmentedSelector(
                                    selection: $curve,
                                    options: ECDSACurve.allCases.map {
                                        .init(value: $0, title: $0.displayName)
                                    },
                                    style: .chips
                                )
                                .onChange(of: curve) { _, _ in updateGeneration() }
                            }
                        } else if generationType == 2 {
                            InspectorGroupDivider()
                            InspectorFieldRow(FeatureL10n.text(.credentialsBits)) {
                                InspectorSegmentedSelector(
                                    selection: $rsaBits,
                                    options: [
                                        .init(value: 2_048, title: FeatureL10n.text(.credentials2048)),
                                        .init(value: 4_096, title: FeatureL10n.text(.credentials4096)),
                                    ],
                                    style: .chips
                                )
                                .onChange(of: rsaBits) { _, _ in updateGeneration() }
                            }
                        }
                        InspectorGroupDivider()
                        InspectorFieldRow(FeatureL10n.text(.uiField2)) {
                            TextField(FeatureL10n.text(.uiField2), text: $draft.comment)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            if draft.mode == .importExisting {
                InspectorCollapsibleSection(
                    FeatureL10n.text(.credentialsPrivateKey),
                    isExpanded: $isPrivateKeyExpanded
                ) {
                    InspectorFieldGroup {
                        if draft.privateKey.isEmpty, let credentialID = draft.credentialID {
                            Button {
                                Task { await loadStoredDraft(id: credentialID) }
                            } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: "lock.fill")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text(FeatureL10n.text(.featureAccessKeyEditorPrivateKeyLocked))
                                        .font(.headline)
                                    Text(FeatureL10n.text(.featureAccessKeyEditorClickToUnblock))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 126)
                            }
                            .buttonStyle(.plain)
                        } else {
                            TextEditor(text: $draft.privateKey)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .frame(height: 170)
                        }
                        if draft.requiresUnlock {
                            InspectorGroupDivider()
                            Button(FeatureL10n.text(.featureAccessKeyEditorUnlock), systemImage: "lock.open") {
                                Task { await unlockStoredDraft() }
                            }
                            .disabled(draft.passphrase.isEmpty)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                        }
                    }
                }

                InspectorCollapsibleSection(
                    FeatureL10n.text(.credentialsPublicKey),
                    isExpanded: $isPublicKeyExpanded
                ) {
                    InspectorFieldGroup {
                        TextEditor(text: $draft.publicKey)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(height: 68)
                    }
                }
            }

            if draft.mode == .generateSecureEnclave, !draft.publicKey.isEmpty {
                InspectorCollapsibleSection(
                    FeatureL10n.text(.credentialsPublicKey),
                    isExpanded: $isPublicKeyExpanded
                ) {
                    InspectorFieldGroup {
                        HStack(spacing: 12) {
                            Text(draft.publicKey)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(
                                FeatureL10n.text(.credentialsCopyPublicKey),
                                systemImage: "doc.on.doc"
                            ) {
                                copyToPasteboard(draft.publicKey)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help(FeatureL10n.text(.credentialsCopyPublicKey))
                        }
                        .padding(12)
                        .frame(minHeight: 64)
                    }
                }
            }

            if draft.mode == .generateSecureEnclave {
                VStack(spacing: 9) {
                    Image(systemName: "touchid")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(FeatureL10n.text(.keySecureEnclaveTitle))
                        .font(.title3.weight(.semibold))
                    Text(FeatureL10n.text(.keySecureEnclaveDescription))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            } else {
                InspectorCollapsibleSection(
                    FeatureL10n.text(.featureAccessKeyEditorSecurity),
                    isExpanded: $isSecurityExpanded
                ) {
                    VStack(spacing: 8) {
                        InspectorFieldGroup {
                            InspectorFieldRow(FeatureL10n.text(.uiField3)) {
                                HStack(spacing: 8) {
                                    if isPassphraseLocked {
                                        Spacer(minLength: 0)
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Group {
                                            if revealPassphrase {
                                                TextField(FeatureL10n.text(.uiField3), text: $draft.passphrase)
                                            } else {
                                                SecureField(FeatureL10n.text(.uiField3), text: $draft.passphrase)
                                            }
                                        }
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)

                                        Button(
                                            FeatureL10n.text(revealPassphrase ? .actionHide : .actionReveal),
                                            systemImage: revealPassphrase ? "eye.slash" : "eye"
                                        ) {
                                            revealPassphrase.toggle()
                                        }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if !isPassphraseLocked && !draft.passphrase.isEmpty {
                                InspectorGroupDivider()
                                InspectorFieldRow(FeatureL10n.text(.credentialsRequireTouchIdForConnections)) {
                                    Toggle("", isOn: $draft.savePassphrase)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .tint(.blue)
                                        .fixedSize()
                                }
                            }
                        }
                        Text(securityDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        } actions: {
            editorActions
        }
        .frame(width: inline ? nil : InspectorMetrics.compactWidth, height: inline ? nil : 680)
        .onDisappear {
            guard inline && !explicitImport && !isCreatingAccessKey && hasChanges,
                  !hasTriggeredSave && !isDiscarding() else { return }
            saveDraft()
        }
        .onChange(of: draft) { _, value in onDraftChange?(value) }
        .onAppear { syncGenerationControls(with: draft.generation) }
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

    private var isPassphraseLocked: Bool { isPrivateKeyLocked && !draft.requiresUnlock }

    private var isCreatingAccessKey: Bool { originalDraft.credentialID == nil }
    private var hasChanges: Bool { draft != originalDraft }

    @ViewBuilder
    private var editorActions: some View {
        if explicitImport {
            InspectorActionArea {
                InspectorProminentAction(title: FeatureL10n.text(.keyEditorImport)) {
                    submitDraft()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if isCreatingAccessKey {
            InspectorActionArea {
                InspectorProminentAction(title: title) {
                    submitDraft()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if inline, draft.credentialID != nil {
            InspectorActionArea {
                if hasChanges {
                    InspectorTextAction(title: FeatureL10n.text(.identityEditorCancelChanges)) {
                        draft = originalDraft
                        revealPassphrase = false
                        syncGenerationControls(with: originalDraft.generation)
                    }
                }
                InspectorProminentAction(title: FeatureL10n.text(.featureAccessKeyEditorExportToHost)) {
                    isExportToHostPresented = true
                }
            }
        }
    }

    private var securityDescription: String {
        if draft.mode == .generateSecureEnclave {
            return FeatureL10n.text(.credentialsEachSignatureIsAuthorizedByTouchId)
        }
        return isPrivateKeyLocked
            ? FeatureL10n.text(.featureAccessKeyEditorUnlockPrivateKeyFirst)
            : passphraseStorageDescription
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

    private func syncGenerationControls(with generation: SoftwareKeyGeneration) {
        switch generation {
        case .ed25519:
            generationType = 0
        case .ecdsa(let value):
            generationType = 1
            curve = value
        case .rsa(let bitCount):
            generationType = 2
            rsaBits = bitCount
        }
    }

    private func submitDraft() {
        hasTriggeredSave = true
        saveDraft()
    }

    private func saveDraft() {
        var value = draft
        value.passphraseConfirmation = value.passphrase
        Task { await onSave(value) }
    }

    private func loadStoredDraft(id: UUID) async {
        guard let value = await model.accessKeyDraft(id: id) else { return }
        draft = value
        originalDraft = value
        syncGenerationControls(with: value.generation)
    }

    private func unlockStoredDraft() async {
        guard let value = await model.accessKeyDraft(
            id: draft.credentialID ?? UUID(),
            unlockingWith: draft.passphrase
        ) else { return }
        draft = value
        originalDraft = value
        syncGenerationControls(with: value.generation)
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
