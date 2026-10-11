import SwiftUI
import TerminatorCore

struct HostEditor: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: HostDraft
    @State private var originalDraft: HostDraft
    @State private var hasTriggeredSave = false
    @State private var revealPassword = false
    @State private var isConnectionExpanded = true
    @State private var isOrganizationExpanded = true
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
        _originalDraft = State(initialValue: draft)
        _isLoadingStoredPassword = State(initialValue: draft.authenticationMethods.contains { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        })
        self.explicitImport = explicitImport
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        InspectorScreen(title: editorTitle) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.featureHostEditorDisplayName)) {
                    TextField(FeatureL10n.text(.featureHostEditorDisplayName), text: $draft.displayName)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("host-display-name")
                }
            }

            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.featureHostEditorHostnameOrIpAddress)) {
                    TextField(FeatureL10n.text(.featureHostEditorHostnameOrIpAddress), text: $draft.hostname, prompt: Text("127.0.0.1"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("host-hostname")
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.hostPort)) {
                    TextField(FeatureL10n.text(.hostPort), value: $draft.port, format: IntegerFormatStyle<Int>.number.grouping(.never))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("host-port")
                }
                if !model.activeIdentities.isEmpty {
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.hostAuthentication)) {
                        InspectorValueMenu(title: authenticationTitle) {
                            Button(FeatureL10n.text(.hostAuthenticationManual)) {
                                authenticationChoice.wrappedValue = .manual
                            }
                            Divider()
                            ForEach(model.activeIdentities) { identity in
                                Button(FeatureL10n.text(.identityNameAndUsername, identity.name, identity.username)) {
                                    authenticationChoice.wrappedValue = .identity(identity.id)
                                }
                            }
                        }
                    }
                }
                if model.activeIdentities.isEmpty || !draft.usesIdentity {
                    manualAuthenticationFields
                }
            }

            InspectorCollapsibleSection(FeatureL10n.text(.hostConnection), isExpanded: $isConnectionExpanded) {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.hostSessionPersistence)) {
                        InspectorValueMenu(title: sessionTitle) {
                            Button(FeatureL10n.text(.hostSessionPersistenceNone)) { draft.sessionPersistence = .none }
                            Button(FeatureL10n.text(.hostSessionPersistenceTmux)) { draft.sessionPersistence = .tmux }
                            Button(FeatureL10n.text(.hostSessionPersistenceScreen)) { draft.sessionPersistence = .screen }
                        }
                    }
                    if draft.sessionPersistence != .none {
                        Text(FeatureL10n.text(.hostSessionPersistenceHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.hostRemoteShell)) {
                        InspectorValueMenu(title: shellTitle) {
                            Button(FeatureL10n.text(.hostRemoteShellLogin)) { draft.remoteShell.preset = .loginShell }
                            Button(FeatureL10n.text(.hostRemoteShellZsh)) { draft.remoteShell.preset = .zsh }
                            Button(FeatureL10n.text(.hostRemoteShellBash)) { draft.remoteShell.preset = .bash }
                            Button(FeatureL10n.text(.hostRemoteShellSh)) { draft.remoteShell.preset = .sh }
                            Button(FeatureL10n.text(.hostRemoteShellFish)) { draft.remoteShell.preset = .fish }
                            Button(FeatureL10n.text(.hostRemoteShellCustom)) { draft.remoteShell.preset = .custom }
                        }
                    }
                    if draft.remoteShell.preset == .custom {
                        InspectorGroupDivider()
                        InspectorFieldRow(FeatureL10n.text(.hostRemoteShellCustomPath)) {
                            TextField(FeatureL10n.text(.hostRemoteShellCustomPath), text: $draft.remoteShell.customPath, prompt: Text("/usr/local/bin/zsh"))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospaced())
                        }
                    }
                    InspectorGroupDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostConnectCommands))
                            .fontWeight(.medium)
                        TextField(
                            FeatureL10n.text(.hostConnectCommands),
                            text: $draft.connectCommands,
                            prompt: Text(FeatureL10n.text(.hostConnectCommandsPrompt)),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .lineLimit(3...12)
                        .font(.body.monospaced())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            InspectorCollapsibleSection(FeatureL10n.text(.hostsOrganization), isExpanded: $isOrganizationExpanded) {
                InspectorFieldGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsGroup))
                            .fontWeight(.medium)
                        AutocompleteTextField(
                            title: FeatureL10n.text(.hostsGroup),
                            text: $draft.group,
                            suggestions: existingGroups
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    InspectorGroupDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsTags))
                            .fontWeight(.medium)
                        TagEditor(tags: tagsBinding, suggestions: existingTags)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    InspectorGroupDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureL10n.text(.hostsNotes))
                            .fontWeight(.medium)
                        TextField(FeatureL10n.text(.hostsNotes), text: $draft.notes, prompt: Text(FeatureL10n.text(.featureHostEditorEmpty)), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        } actions: {
            editorActions
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
        .task {
            if model.activeIdentities.isEmpty, draft.usesIdentity {
                draft.usesIdentity = false
                draft.identityID = nil
                originalDraft.usesIdentity = false
                originalDraft.identityID = nil
            }
            guard isLoadingStoredPassword else { return }
            draft = await model.loadHostPassword(into: draft)
            originalDraft = draft
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

    private var manualAuthenticationFields: some View {
        VStack(spacing: 0) {
        InspectorGroupDivider()
        InspectorFieldRow(FeatureL10n.text(.hostUsername)) {
            TextField(FeatureL10n.text(.hostUsername), text: $draft.username)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("host-username")
        }
        if let index = passwordIndex {
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.passwordField)) {
                HStack(spacing: 8) {
                    Group {
                        if revealPassword {
                            TextField(FeatureL10n.text(.passwordField), text: passwordBinding(at: index))
                        } else {
                            SecureField(FeatureL10n.text(.passwordField), text: passwordBinding(at: index))
                        }
                    }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .disabled(isLoadingStoredPassword)
                    if isLoadingStoredPassword {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(FeatureL10n.text(revealPassword ? .actionHide : .actionReveal), systemImage: revealPassword ? "eye.slash" : "eye") {
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

    private func accessKeyRow(id: UUID, at index: Int) -> some View {
        let position = accessKeyIndices.firstIndex(of: index) ?? 0
        return HStack(spacing: 8) {
            Text(credential(id)?.label ?? FeatureL10n.text(.keyUnavailable))
                .fontWeight(.medium)
                .lineLimit(1)
            Text(credential(id)?.accessKey?.algorithm.displayName ?? FeatureL10n.text(.credentialsAccessKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(FeatureL10n.text(.hostsMoveUp), systemImage: "arrow.up") { moveAccessKey(index, by: -1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(position == 0)
            Button(FeatureL10n.text(.hostsMoveDown), systemImage: "arrow.down") { moveAccessKey(index, by: 1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(position == accessKeyIndices.count - 1)
            Button(FeatureL10n.text(.hostsRemove), systemImage: "xmark.circle.fill", role: .destructive) {
                draft.removeAuthenticationMethod(at: index)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: InspectorMetrics.rowHeight)
    }

    @ViewBuilder
    private var accessKeyPicker: some View {
        if model.activeCredentials.isEmpty {
            Text(FeatureL10n.text(.featureIdentityEditorNoAccessKeysYetCreateOneIn))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else if availableAccessKeys.isEmpty {
            Text(FeatureL10n.text(.featureIdentityEditorAllAvailableAccessKeysAreAlreadyAdded))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            Menu {
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
            } label: {
                Label(FeatureL10n.text(.hostsAddAccessKey), systemImage: "plus")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 42)
        }
    }

    @ViewBuilder
    private var editorActions: some View {
        if explicitImport {
            InspectorActionArea {
                InspectorTextAction(title: FeatureL10n.text(.actionCancel)) {
                    hasTriggeredSave = true
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                InspectorProminentAction(title: FeatureL10n.text(.featureHostEditorImportHost)) {
                    Task {
                        if await onSave(draft) {
                            hasTriggeredSave = true
                            onClose()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if hasChanges || canConnect {
            InspectorActionArea {
                if hasChanges {
                    InspectorTextAction(title: FeatureL10n.text(.identityEditorCancelChanges)) {
                        draft = originalDraft
                        revealPassword = false
                    }
                }
                if canConnect {
                    HStack(spacing: 8) {
                        InspectorProminentAction(title: connectTitle, disabled: !canConnectNow) {
                            connect(using: .terminal)
                        }
                        .keyboardShortcut(.defaultAction)
                        InspectorCircleMenu(disabled: !canConnectNow) {
                            if let host = persistedHost, !model.connectionPhase(for: host.id).isDisconnected {
                                Button(FeatureL10n.text(.featureHostEditorDisconnect), systemImage: "xmark.circle") {
                                    Task { await model.disconnect(host) }
                                }
                                Divider()
                            }
                            connectionDestinations
                        }
                        .accessibilityLabel(FeatureL10n.text(.hostsConnectWith))
                    }
                }
            }
        }
    }

    private var editorTitle: String {
        draft.id == nil ? FeatureL10n.text(.hostsAddHost) : FeatureL10n.text(.featureHostEditorEdit)
    }

    private var connectTitle: String {
        hasChanges ? FeatureL10n.text(.featureHostEditorSaveAndConnect) : FeatureL10n.text(.featureHostEditorConnect)
    }

    private var authenticationTitle: String {
        if draft.usesIdentity, let id = draft.identityID,
           let identity = model.activeIdentities.first(where: { $0.id == id }) {
            return identity.name
        }
        return FeatureL10n.text(.hostAuthenticationManual)
    }

    private var sessionTitle: String {
        switch draft.sessionPersistence {
        case .none: FeatureL10n.text(.hostSessionPersistenceNone)
        case .tmux: FeatureL10n.text(.hostSessionPersistenceTmux)
        case .screen: FeatureL10n.text(.hostSessionPersistenceScreen)
        }
    }

    private var shellTitle: String {
        switch draft.remoteShell.preset {
        case .loginShell: FeatureL10n.text(.hostRemoteShellLogin)
        case .zsh: FeatureL10n.text(.hostRemoteShellZsh)
        case .bash: FeatureL10n.text(.hostRemoteShellBash)
        case .sh: FeatureL10n.text(.hostRemoteShellSh)
        case .fish: FeatureL10n.text(.hostRemoteShellFish)
        case .custom: FeatureL10n.text(.hostRemoteShellCustom)
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

    private var hasChanges: Bool { draft != originalDraft }

    private var canConnect: Bool { draft.id != nil && model.capabilities.externalTerminal }

    private var canConnectNow: Bool {
        !draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect(using terminal: TerminalApplication) {
        Task {
            guard await onSave(draft),
                  let hostID = draft.id,
                  let host = model.hosts.first(where: { $0.id == hostID }) else { return }
            originalDraft = draft
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
