import SwiftUI
import TerminatorCore

struct HostEditor: View {
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
                    TextField(FeatureL10n.text(.featureHostEditorDisplayName), text: $draft.displayName)
                        .accessibilityIdentifier("host-display-name")
                }
                Section(FeatureL10n.text(.hostsHost)) {
                    TextField(FeatureL10n.text(.featureHostEditorHostnameOrIpAddress), text: $draft.hostname, prompt: Text("127.0.0.1"))
                        .accessibilityIdentifier("host-hostname")
                    TextField(FeatureL10n.text(.hostPort), value: $draft.port, format: .number)
                        .accessibilityIdentifier("host-port")
                    if !model.activeIdentities.isEmpty {
                        Picker(FeatureL10n.text(.hostAuthentication), selection: authenticationChoice) {
                            Text(FeatureL10n.text(.hostAuthenticationManual)).tag(AuthenticationChoice.manual)
                            Divider()
                            ForEach(model.activeIdentities) { identity in
                                Text(FeatureL10n.text(.identityNameAndUsername, identity.name, identity.username))
                                    .tag(AuthenticationChoice.identity(identity.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if model.activeIdentities.isEmpty || !draft.usesIdentity {
                        manualAuthenticationFields
                    }
                }
                Section {
                    Picker(FeatureL10n.text(.hostSessionPersistence), selection: $draft.sessionPersistence) {
                        Text(FeatureL10n.text(.hostSessionPersistenceNone)).tag(SessionPersistence.none)
                        Text(FeatureL10n.text(.hostSessionPersistenceTmux)).tag(SessionPersistence.tmux)
                        Text(FeatureL10n.text(.hostSessionPersistenceScreen)).tag(SessionPersistence.screen)
                    }
                    if draft.sessionPersistence != .none {
                        Text(FeatureL10n.text(.hostSessionPersistenceHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker(FeatureL10n.text(.hostRemoteShell), selection: $draft.remoteShell.preset) {
                        Text(FeatureL10n.text(.hostRemoteShellLogin)).tag(RemoteShellPreset.loginShell)
                        Text(FeatureL10n.text(.hostRemoteShellZsh)).tag(RemoteShellPreset.zsh)
                        Text(FeatureL10n.text(.hostRemoteShellBash)).tag(RemoteShellPreset.bash)
                        Text(FeatureL10n.text(.hostRemoteShellSh)).tag(RemoteShellPreset.sh)
                        Text(FeatureL10n.text(.hostRemoteShellFish)).tag(RemoteShellPreset.fish)
                        Text(FeatureL10n.text(.hostRemoteShellCustom)).tag(RemoteShellPreset.custom)
                    }
                    if draft.remoteShell.preset == .custom {
                        TextField(
                            FeatureL10n.text(.hostRemoteShellCustomPath),
                            text: $draft.remoteShell.customPath,
                            prompt: Text("/usr/local/bin/zsh")
                        )
                        .font(.body.monospaced())
                    }
                    TextField(
                        FeatureL10n.text(.hostConnectCommands),
                        text: $draft.connectCommands,
                        prompt: Text(FeatureL10n.text(.hostConnectCommandsPrompt)),
                        axis: .vertical
                    )
                    .lineLimit(3...12)
                    .font(.body.monospaced())
                } header: {
                    Text(FeatureL10n.text(.hostConnection))
                }

                Section(FeatureL10n.text(.hostsOrganization)) {
                    AutocompleteTextField(
                        title: "Group",
                        text: $draft.group,
                        suggestions: existingGroups
                    )
                    TagEditor(tags: tagsBinding, suggestions: existingTags)
                    TextField(FeatureL10n.text(.hostsNotes), text: $draft.notes, prompt: Text(FeatureL10n.text(.featureHostEditorEmpty)), axis: .vertical)
                        .lineLimit(3...8)
                }
            }.formStyle(.grouped)
            if explicitImport {
                Divider()
                HStack {
                    Spacer()
                    Button(FeatureL10n.text(.actionCancel)) {
                        hasTriggeredSave = true
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(FeatureL10n.text(.featureHostEditorImportHost)) {
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
                        Button(FeatureL10n.text(.featureHostEditorDisconnect), systemImage: "xmark.circle") {
                            Task { await model.disconnect(host) }
                        }
                    }
                    Menu {
                        connectionDestinations
                    } label: {
                        Label(FeatureL10n.text(.featureHostEditorConnect), systemImage: "bolt.horizontal.fill")
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
                model.dismissPresentedError()
                return
            }
            Task {
                let saved = await onSave(closingDraft)
                if !saved, closingDraft.id == nil { model.dismissPresentedError() }
            }
        }
        .toolbar {
            if !explicitImport {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button(FeatureL10n.text(.actionCancel), systemImage: "xmark") {
                            hasTriggeredSave = true
                            onClose()
                        }
                        Button(FeatureL10n.text(.featureHostEditorSaveAndClose), systemImage: "checkmark") {
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
        TextField(FeatureL10n.text(.hostUsername), text: $draft.username)
            .accessibilityIdentifier("host-username")
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential(id)?.label ?? FeatureL10n.text(.keyUnavailable))
                        Text(credential(id)?.accessKey?.algorithm.displayName ?? FeatureL10n.text(.credentialsAccessKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let position = accessKeyIndices.firstIndex(of: index) ?? 0
                    Button(FeatureL10n.text(.hostsMoveUp), systemImage: "arrow.up") { moveAccessKey(index, by: -1) }
                        .labelStyle(.iconOnly)
                        .disabled(position == 0)
                    Button(FeatureL10n.text(.hostsMoveDown), systemImage: "arrow.down") { moveAccessKey(index, by: 1) }
                        .labelStyle(.iconOnly)
                        .disabled(position == accessKeyIndices.count - 1)
                    Button(FeatureL10n.text(.hostsRemove), systemImage: "minus.circle", role: .destructive) {
                        draft.removeAuthenticationMethod(at: index)
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        if model.activeCredentials.isEmpty {
            Text(FeatureL10n.text(.featureIdentityEditorNoAccessKeysYetCreateOneIn))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if availableAccessKeys.isEmpty {
            Text(FeatureL10n.text(.featureIdentityEditorAllAvailableAccessKeysAreAlreadyAdded))
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
        Section(FeatureL10n.text(.hostsConnectWith)) {
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
        draft.addAccessKey(id)
    }

    private func moveAccessKey(_ index: Int, by delta: Int) {
        draft.moveAccessKey(at: index, by: delta)
    }
}
