import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct IdentityEditor: View {
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
                    TextField(FeatureL10n.text(.uiField6), text: $draft.name)
                }
                Section(FeatureL10n.text(.hostAuthentication)) {
                    TextField(FeatureL10n.text(.hostUsername), text: $draft.username)
                    if let index = passwordIndex {
                        HStack {
                            Group {
                                if revealPassword {
                                    TextField(FeatureL10n.text(.passwordField), text: passwordBinding(at: index))
                                } else {
                                    SecureField(FeatureL10n.text(.passwordField), text: passwordBinding(at: index))
                                }
                            }
                            .disabled(isLoadingStoredPassword)
                            if isLoadingStoredPassword {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(FeatureL10n.text(revealPassword ? .actionHide : .actionReveal), systemImage: revealPassword ? "eye.slash" : "eye") {
                                    revealPassword.toggle()
                                }
                            }
                        }
                    }
                    ForEach(accessKeyIndices, id: \.self) { index in
                        if case .accessKey(let id) = draft.authenticationMethods[index].kind {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(credential(id)?.label ?? FeatureL10n.text(.keyUnavailable))
                                    Text(credential(id)?.accessKey?.algorithm.displayName ?? FeatureL10n.text(.credentialsAccessKey))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let position = accessKeyIndices.firstIndex(of: index) ?? 0
                                Button(FeatureL10n.text(.hostsMoveUp), systemImage: "arrow.up") { moveAccessKey(index, by: -1) }
                                    .labelStyle(.iconOnly).disabled(position == 0)
                                Button(FeatureL10n.text(.hostsMoveDown), systemImage: "arrow.down") { moveAccessKey(index, by: 1) }
                                    .labelStyle(.iconOnly).disabled(position == accessKeyIndices.count - 1)
                                Button(FeatureL10n.text(.hostsRemove), systemImage: "minus.circle", role: .destructive) {
                                    draft.removeAuthenticationMethod(at: index)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                    if model.activeCredentials.isEmpty {
                        Text(FeatureL10n.text(.featureIdentityEditorNoAccessKeysYetCreateOneIn))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if availableAccessKeys.isEmpty {
                        Text(FeatureL10n.text(.featureIdentityEditorAllAvailableAccessKeysAreAlreadyAdded))
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
        .alert(FeatureL10n.text(.featureIdentityEditorUnableToLoadIdentityPassword), isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.dismissPresentedError() } }
        )) {
            Button(FeatureL10n.text(.actionOk)) { model.dismissPresentedError() }
        } message: {
            Text(model.presentedError?.message ?? "")
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
        draft.addAccessKey(id)
    }
    private func moveAccessKey(_ index: Int, by delta: Int) {
        draft.moveAccessKey(at: index, by: delta)
    }
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}
