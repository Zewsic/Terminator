import SwiftUI
import TerminatorCore
#if os(macOS)
import AppKit
#endif

struct ConnectionSheet: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var passphrase = ""
    @State private var username = ""
    @State private var password = ""
    @State private var selectedAccessKeyID: UUID?
    @State private var selectedIdentityID: UUID?
    @State private var showsAccessKey = false
    @State private var revealsPassword = false
    @State private var isPreparingConnectionCommand = false
    @State private var didCopyConnectionCommand = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password, passphrase }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .frame(height: 52)
            Spacer(minLength: 24)
            ZStack {
                Group {
                    if let prompt = model.connectionPrompts.request {
                        promptContent(prompt)
                    } else {
                        connectionStateContent
                    }
                }
                .id(stepID)
                .transition(.blurReplace)
            }
            .frame(maxHeight: .infinity)
            .animation(.smooth(duration: 0.45), value: stepID)
            Spacer(minLength: 24)
            ZStack(alignment: .bottom) {
                connectionActions
                    .id("actions-\(stepID)")
                    .transition(.blurReplace)
            }
            .frame(height: 96, alignment: .bottom)
            .animation(.smooth(duration: 0.45), value: stepID)
        }
        .padding(32)
        .frame(width: 460)
        .frame(height: 560)
        .onChange(of: model.connectionPrompts.request?.id) { _, _ in
            resetFieldsForCurrentPrompt()
        }
        .task { resetFieldsForCurrentPrompt() }
    }

    private var sheetHeader: some View {
        ZStack(alignment: .center) {
            VStack(spacing: 5) {
                Text(headerTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let host = model.connectionHost {
                    Text("\(host.hostname):\(host.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 52)

            HStack {
                Button {
                    Task { await model.cancelConnectionPresentation() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(FeatureL10n.text(.connectionCancelHelp))
                Spacer()
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func promptContent(_ prompt: ConnectionPromptRequest) -> some View {
        switch prompt.kind {
        case .username(let host):
            ConnectionForm(
                title: FeatureL10n.text(.connectionUsernameTitle),
                subtitle: FeatureL10n.text(.connectionUsernameDescription, host.hostname)
            ) {
                TextField(FeatureL10n.text(.hostUsername), text: $username)
                    .textFieldStyle(.plain)
                    .connectionInput()
                    .focused($focusedField, equals: .username)
                    .onSubmit { submitUsername() }
            }
        case .password(let host, let account):
            ConnectionForm(
                title: FeatureL10n.text(.connectionPasswordTitle),
                subtitle: FeatureL10n.text(.connectionPasswordDescription, account, host.hostname)
            ) {
                passwordField(placeholder: FeatureL10n.text(.passwordField))
                    .onSubmit { submitPassword() }
            }
        case .authentication(let host, let storedUsername, let availableAccessKeys, let availableIdentities):
            authenticationForm(
                host: host,
                storedUsername: storedUsername,
                availableAccessKeys: availableAccessKeys,
                availableIdentities: availableIdentities
            )
        case .passphrase(let credential):
            ConnectionForm(
                title: FeatureL10n.text(.connectionUnlock, credential.label),
                subtitle: FeatureL10n.text(.connectionPassphraseDescription)
            ) {
                SecureField(FeatureL10n.text(.uiField7), text: $passphrase)
                    .textFieldStyle(.plain)
                    .connectionInput()
                    .focused($focusedField, equals: .passphrase)
                    .onSubmit { submitPassphrase() }
            }
        case .trustNewHost(let key):
            ConnectionForm(
                title: FeatureL10n.text(.connectionTrustHost),
                subtitle: FeatureL10n.text(.connectionVerifyFingerprint)
            ) {
                HostKeyPromptView(endpoint: key.endpoint, algorithm: key.algorithm, fingerprints: [(FeatureL10n.text(.connectionFingerprint), key.fingerprint)])
            }
        case .replaceHostKey(let previous, let presented):
            ConnectionForm(
                title: FeatureL10n.text(.connectionHostKeyChanged),
                subtitle: FeatureL10n.text(.connectionHostKeyChangedDescription)
            ) {
                HostKeyPromptView(
                    endpoint: presented.endpoint,
                    algorithm: presented.algorithm,
                    fingerprints: [(FeatureL10n.text(.hostkeyPrevious), previous.fingerprint), (FeatureL10n.text(.hostkeyPresented), presented.fingerprint)]
                )
            }
        case .keychain(let reason):
            ConnectionForm(
                title: FeatureL10n.text(.connectionUnlockKeychain),
                subtitle: reason
            ) {
                EmptyView()
            }
        }
    }

    private func authenticationForm(
        host: HostProfile,
        storedUsername: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) -> some View {
        ConnectionForm(
            title: FeatureL10n.text(.connectionSignInTitle, host.displayName),
            subtitle: FeatureL10n.text(.connectionSignInDescription)
        ) {
            HStack(spacing: 10) {
                TextField(FeatureL10n.text(.hostUsername), text: usernameBinding(identities: availableIdentities))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .username)
                if !availableIdentities.isEmpty {
                    Menu {
                        Button(FeatureL10n.text(.hostAuthenticationManual)) {
                            withAnimation(.smooth(duration: 0.3)) { selectedIdentityID = nil }
                        }
                        Divider()
                        ForEach(availableIdentities) { identity in
                            Button {
                                withAnimation(.smooth(duration: 0.3)) {
                                    selectedIdentityID = identity.id
                                    username = identity.username
                                    password = ""
                                    selectedAccessKeyID = nil
                                    showsAccessKey = false
                                }
                            } label: {
                                if selectedIdentityID == identity.id {
                                    Label(identity.name, systemImage: "checkmark")
                                } else {
                                    Text(identity.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .help(FeatureL10n.text(.connectionChooseIdentity))
                }
            }
            .connectionInput()

            if let identity = availableIdentities.first(where: { $0.id == selectedIdentityID }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.name).fontWeight(.medium)
                        Text(FeatureL10n.text(.featureConnectionSheetSavedIdentity))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(FeatureL10n.text(.hostsRemove), systemImage: "xmark.circle") {
                        withAnimation(.smooth(duration: 0.3)) { selectedIdentityID = nil }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
                .connectionInput()
                .transition(.blurReplace)
            } else {
                passwordField(placeholder: FeatureL10n.text(.passwordField))
                    .onSubmit { submitAuthentication() }

                if showsAccessKey, !availableAccessKeys.isEmpty {
                    Menu {
                        Button(FeatureL10n.text(.featureConnectionSheetNoAccessKey)) { selectedAccessKeyID = nil }
                        Divider()
                        ForEach(availableAccessKeys) { credential in
                            Button {
                                selectedAccessKeyID = credential.id
                            } label: {
                                if selectedAccessKeyID == credential.id {
                                    Label(credential.label, systemImage: "checkmark")
                                } else {
                                    Text(credential.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key.horizontal")
                                .foregroundStyle(.secondary)
                            Text(selectedAccessKeyLabel(in: availableAccessKeys))
                                .foregroundStyle(selectedAccessKeyID == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .connectionInput()
                    .transition(.blurReplace)
                } else if !availableAccessKeys.isEmpty {
                    Button(FeatureL10n.text(.hostsAddAccessKey), systemImage: "key.horizontal") {
                        withAnimation(.smooth(duration: 0.3)) { showsAccessKey = true }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.blurReplace)
                }
            }

        }
        .onAppear {
            if username.isEmpty { username = storedUsername }
        }
    }

    private var connectionStateContent: some View { ConnectionStatusView(phase: model.connectionPhase) }

    @ViewBuilder
    private var connectionActions: some View {
        if let request = model.connectionPrompts.request {
            switch request.kind {
            case .username:
                primaryButton(FeatureL10n.text(.actionContinue),
                    disabled: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submitUsername
                )
            case .password:
                primaryButton(FeatureL10n.text(.featureHostEditorConnect), disabled: password.isEmpty, action: submitPassword)
            case .authentication:
                primaryButton(FeatureL10n.text(.featureHostEditorConnect), disabled: !canSubmitAuthentication, action: submitAuthentication)
            case .passphrase:
                primaryButton(FeatureL10n.text(.featureConnectionSheetUnlockContinue), disabled: passphrase.isEmpty, action: submitPassphrase)
            case .trustNewHost:
                primaryButton(FeatureL10n.text(.connectionTrustAndConnect)) { model.connectionPrompts.submit() }
            case .replaceHostKey:
                Button(FeatureL10n.text(.connectionReplaceKeyAndConnect), role: .destructive) {
                    model.connectionPrompts.submit()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            case .keychain:
                primaryButton(FeatureL10n.text(.actionContinue)) { model.connectionPrompts.submit() }
            }
        } else if case .failed = model.connectionPhase {
            VStack(spacing: 12) {
                Button(FeatureL10n.text(.actionClose)) { Task { await model.cancelConnectionPresentation() } }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                primaryButton(FeatureL10n.text(.featureConnectionSheetRetry)) { Task { await model.retryConnection() } }
            }
        } else if case .connected = model.connectionPhase {
            VStack(spacing: 12) {
                Button(connectionCommandButtonTitle) {
                    copyConnectionCommand()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isPreparingConnectionCommand)
                primaryButton(FeatureL10n.text(.actionDone)) { model.dismissConnection() }
            }
        } else {
            primaryButton(FeatureL10n.text(.featureConnectionSheetConnecting), loading: true, disabled: true) {}
        }
    }

    private func passwordField(placeholder: String) -> some View {
        HStack(spacing: 10) {
            Group {
                if revealsPassword {
                    TextField(placeholder, text: $password)
                } else {
                    SecureField(placeholder, text: $password)
                }
            }
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .password)
            Button(revealsPassword ? FeatureL10n.text(.actionHide) : FeatureL10n.text(.actionReveal), systemImage: revealsPassword ? "eye.slash" : "eye") {
                revealsPassword.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .connectionInput()
    }

    private func primaryButton(
        _ title: String,
        loading: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.blue)
        .disabled(disabled || loading)
    }

    private func submitUsername() {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.connectionPrompts.submit(text: value)
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        model.connectionPrompts.submit(text: password)
        password = ""
    }

    private func usernameBinding(identities: [IdentityProfile]) -> Binding<String> {
        Binding(
            get: { username },
            set: { value in
                username = value
                if let selectedIdentityID,
                   identities.first(where: { $0.id == selectedIdentityID })?.username != value {
                    self.selectedIdentityID = nil
                }
            }
        )
    }

    private var canSubmitAuthentication: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selectedIdentityID != nil || !password.isEmpty || selectedAccessKeyID != nil)
    }

    private func selectedAccessKeyLabel(in credentials: [CredentialMetadata]) -> String {
        guard let selectedAccessKeyID,
              let credential = credentials.first(where: { $0.id == selectedAccessKeyID }) else {
            return FeatureL10n.text(.connectionSelectAccessKey)
        }
        return credential.label
    }

    private var connectionCommandButtonTitle: String {
        if isPreparingConnectionCommand { return FeatureL10n.text(.connectionPreparingCommand) }
        if didCopyConnectionCommand { return FeatureL10n.text(.connectionPasteCommand) }
        return FeatureL10n.text(.connectionCopyCommand)
    }

    private func copyConnectionCommand() {
        guard !isPreparingConnectionCommand else { return }
        isPreparingConnectionCommand = true
        Task {
            guard let command = await model.makeConnectionCommand() else {
                isPreparingConnectionCommand = false
                return
            }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            #endif
            withAnimation(.smooth(duration: 0.2)) {
                isPreparingConnectionCommand = false
                didCopyConnectionCommand = true
            }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.smooth(duration: 0.2)) {
                didCopyConnectionCommand = false
            }
        }
    }

    private var headerTitle: String {
        model.connectionHost?.displayName ?? FeatureL10n.text(.connectionTitle)
    }

    private var stepID: String {
        if let id = model.connectionPrompts.request?.id { return "prompt-\(id)" }
        switch model.connectionPhase {
        case .failed: return "failed"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        default: return "working"
        }
    }

    private func resetFieldsForCurrentPrompt() {
        passphrase = ""
        username = ""
        password = ""
        selectedAccessKeyID = nil
        selectedIdentityID = nil
        showsAccessKey = false
        revealsPassword = false
        isPreparingConnectionCommand = false
        didCopyConnectionCommand = false
        guard let request = model.connectionPrompts.request else {
            focusedField = nil
            return
        }
        switch request.kind {
        case .authentication(_, let storedUsername, _, _):
            username = storedUsername
            focusedField = storedUsername.isEmpty ? .username : .password
        case .username:
            focusedField = .username
        case .password:
            focusedField = .password
        case .passphrase:
            focusedField = .passphrase
        case .trustNewHost, .replaceHostKey, .keychain:
            focusedField = nil
        }
    }

    private func submitPassphrase() {
        guard !passphrase.isEmpty else { return }
        model.connectionPrompts.submit(text: passphrase)
        passphrase = ""
    }

    private func submitAuthentication() {
        guard canSubmitAuthentication else { return }
        model.connectionPrompts.submit(authentication: .init(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            identityID: selectedIdentityID,
            password: password.isEmpty ? nil : password,
            credentialID: selectedAccessKeyID
        ))
        password = ""
        selectedAccessKeyID = nil
    }

}
