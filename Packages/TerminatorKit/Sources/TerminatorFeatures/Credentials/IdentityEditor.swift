import SwiftUI
import TerminatorCore

struct IdentityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: IdentityDraft
    @State private var originalDraft: IdentityDraft
    @State private var hasTriggeredSave = false
    @State private var revealPassword = false
    @State private var isLoadingStoredPassword: Bool
    @State private var isAuthorizationExpanded = true
    let onSave: @MainActor (IdentityDraft) async -> Bool
    let inline: Bool
    let explicitImport: Bool
    let onDraftChange: ((IdentityDraft) -> Void)?
    let isDiscarding: () -> Bool
    let onClose: (() -> Void)?

    init(
        draft: IdentityDraft,
        inline: Bool = false,
        explicitImport: Bool = false,
        onDraftChange: ((IdentityDraft) -> Void)? = nil,
        isDiscarding: @escaping () -> Bool = { false },
        onSave: @escaping @MainActor (IdentityDraft) async -> Bool,
        onClose: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)
        _originalDraft = State(initialValue: draft)
        _isLoadingStoredPassword = State(initialValue: draft.authenticationMethods.contains { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        })
        self.onSave = onSave
        self.inline = inline
        self.explicitImport = explicitImport
        self.onDraftChange = onDraftChange
        self.isDiscarding = isDiscarding
        self.onClose = onClose
    }

    var body: some View {
        InspectorScreen(title: FeatureL10n.text(draft.id == nil ? .identityEditorAdd : .identityEditorEdit)) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.uiField6)) {
                    TextField(FeatureL10n.text(.uiField6), text: $draft.name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }

            InspectorCollapsibleSection(
                FeatureL10n.text(.identityEditorAuthorization),
                isExpanded: $isAuthorizationExpanded
            ) {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.hostUsername)) {
                        TextField(FeatureL10n.text(.hostUsername), text: $draft.username)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }

                    if let index = passwordIndex {
                        InspectorGroupDivider()
                        InspectorFieldRow(FeatureL10n.text(.passwordField)) {
                            HStack(spacing: 8) {
                                Group {
                                    if revealPassword {
                                        TextField(
                                            FeatureL10n.text(.passwordField),
                                            text: passwordBinding(at: index)
                                        )
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)
                                        .disabled(isLoadingStoredPassword)
                                    } else {
                                        SecureField(
                                            FeatureL10n.text(.passwordField),
                                            text: passwordBinding(at: index)
                                        )
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)
                                        .disabled(isLoadingStoredPassword)
                                    }
                                }

                                if isLoadingStoredPassword {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button(
                                        FeatureL10n.text(revealPassword ? .actionHide : .actionReveal),
                                        systemImage: revealPassword ? "eye.slash" : "eye"
                                    ) {
                                        revealPassword.toggle()
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    ForEach(accessKeyIndices, id: \.self) { index in
                        if case .accessKey(let id) = draft.authenticationMethods[index].kind {
                            InspectorGroupDivider()
                            accessKeyRow(id: id, at: index)
                        }
                    }

                    InspectorGroupDivider()
                    accessKeyPicker
                }
            }
        } actions: {
            if explicitImport {
                importActions
            } else if isCreatingIdentity {
                createActions
            } else if hasChanges {
                editActions
            }
        }
        .frame(width: inline ? nil : 420, height: inline ? nil : 600)
        .onDisappear {
            guard inline && !explicitImport && !isCreatingIdentity && hasChanges,
                  !hasTriggeredSave && !isDiscarding() else { return }
            Task { await onSave(draft) }
        }
        .onChange(of: draft) { _, value in onDraftChange?(value) }
        .task {
            guard isLoadingStoredPassword else { return }
            let loaded = await model.loadIdentityPassword(into: draft)
            draft = loaded
            originalDraft = loaded
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

    private func accessKeyRow(id: UUID, at index: Int) -> some View {
        let value = credential(id)

        return HStack(spacing: 11) {
            Text(value?.label ?? FeatureL10n.text(.keyUnavailable))
                .fontWeight(.medium)
                .lineLimit(1)

            Text(accessKeyDescription(value))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(FeatureL10n.text(.hostsRemove), systemImage: "xmark.circle.fill", role: .destructive) {
                draft.removeAuthenticationMethod(at: index)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .contentShape(.rect)
        .draggable(id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let source = values.first.flatMap(UUID.init(uuidString:)) else { return false }
            return reorderAccessKey(source, to: id)
        }
    }

    @ViewBuilder
    private var accessKeyPicker: some View {
        if !availableAccessKeys.isEmpty {
            Menu {
                ForEach(availableAccessKeys) { credential in
                    Button {
                        addAccessKey(credential.id)
                    } label: {
                        Label(
                            "\(credential.label) · \(accessKeyDescription(credential))",
                            systemImage: credential.accessKey?.backend == .secureEnclave
                                ? "touchid"
                                : "key.horizontal"
                        )
                    }
                }
            } label: {
                Label(FeatureL10n.text(.credentialsAccessKey), systemImage: "plus")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 42)
        } else {
            Button {} label: {
                Label(FeatureL10n.text(.credentialsAccessKey), systemImage: "plus")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .frame(minHeight: 42)
        }
    }

    private var importActions: some View {
        InspectorActionArea {
            Button(FeatureL10n.text(.historyCancel)) {
                hasTriggeredSave = true
                close()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.cancelAction)

            Button {
                hasTriggeredSave = true
                Task { await onSave(draft) }
            } label: {
                Text(FeatureL10n.text(.externalImportIdentityAction))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .controlSize(.large)
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.blue)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var createActions: some View {
        InspectorActionArea {
            InspectorProminentAction(title: FeatureL10n.text(.identityEditorAdd)) {
                hasTriggeredSave = true
                Task { await onSave(draft) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var editActions: some View {
        InspectorActionArea {
            HStack(spacing: 8) {
                InspectorProminentAction(title: FeatureL10n.text(.actionSave)) {
                    Task {
                        if await onSave(draft) { originalDraft = draft }
                    }
                }
                .keyboardShortcut(.defaultAction)
                InspectorRevertButton {
                    draft = originalDraft
                    revealPassword = false
                }
            }
        }
    }

    private var isCreatingIdentity: Bool { originalDraft.id == nil }
    private var hasChanges: Bool { draft != originalDraft }

    private func accessKeyDescription(_ credential: CredentialMetadata?) -> String {
        let algorithm = credential?.accessKey?.algorithm.displayName ?? FeatureL10n.text(.credentialsAccessKey)
        guard credential?.accessKey?.backend == .secureEnclave else { return algorithm }
        return "\(algorithm) / \(FeatureL10n.text(.credentialsSecureEnclave))"
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

    private func reorderAccessKey(_ sourceID: UUID, to targetID: UUID) -> Bool {
        guard sourceID != targetID else { return false }
        withAnimation(.smooth(duration: 0.2)) {
            draft.reorderAccessKey(sourceID, to: targetID)
        }
        return true
    }
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}
