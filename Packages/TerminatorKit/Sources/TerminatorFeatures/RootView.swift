import SwiftUI
import TerminatorCore
#if os(macOS)
import AppKit
#endif

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var isArchivePresented = false

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Group {
                #if os(macOS)
                List(selection: $model.selection) {
                    sidebarSections(buttons: false)
                }
                #else
                List {
                    sidebarSections(buttons: true)
                }
                #endif
            }
            .navigationTitle(FeatureL10n.text("ui.root.view.14"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .accessibilityIdentifier("main-sidebar")
        } detail: {
            content
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(FeatureL10n.text("ui.root.view.1")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(item: Binding(
            get: { model.connectionHost },
            set: { if $0 == nil { Task { await model.cancelConnectionPresentation() } } }
        )) { _ in ConnectionSheet() }
        .sheet(isPresented: $isArchivePresented) { ArchiveView() }
    }

    @ViewBuilder
    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    @ViewBuilder
    private func selectableSidebarRow(_ section: AppSection, buttons: Bool) -> some View {
        if buttons {
            Button {
                model.selection = section
            } label: {
                Label(section.title, systemImage: section.systemImage)
            }
        } else {
            sidebarRow(section)
        }
    }

    @ViewBuilder
    private func sidebarSections(buttons: Bool) -> some View {
        Section(FeatureL10n.text("ui.root.view.2")) {
            selectableSidebarRow(.overview, buttons: buttons)
            selectableSidebarRow(.hosts, buttons: buttons)
            selectableSidebarRow(.tunnels, buttons: buttons)
        }

        Section(FeatureL10n.text("ui.root.view.3")) {
            selectableSidebarRow(.containers, buttons: buttons)
        }

        Section(FeatureL10n.text("ui.root.view.4")) {
            selectableSidebarRow(.credentials, buttons: buttons)
            selectableSidebarRow(.snippets, buttons: buttons)
            selectableSidebarRow(.history, buttons: buttons)
            selectableSidebarRow(.logs, buttons: buttons)
        }

    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .overview:
            OverviewView()
        case .hosts:
            HostsView()
        case .credentials:
            CredentialsView(isArchivePresented: $isArchivePresented)
        case .history:
            HistoryView()
        case .logs:
            SessionLogsView()
        case .containers:
            ContainersView()
        case .tunnels:
            PlannedFeatureView(
                title: "Tunnels",
                systemImage: "arrow.left.arrow.right",
                description: "Saved local, remote, and dynamic SSH port forwards are on the roadmap."
            )
        case .snippets:
            PlannedFeatureView(
                title: "Snippets",
                systemImage: "chevron.left.forwardslash.chevron.right",
                description: "Reusable commands and parameterized snippets are planned."
            )
        }
    }
}

private struct ArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model

    private var archivedIdentities: [IdentityProfile] { model.identities.filter(\.isDeleted) }
    private var archivedCredentials: [CredentialMetadata] {
        model.credentials.filter { $0.isDeleted && $0.isSecretAvailable }
    }
    private var purgedCredentials: [CredentialMetadata] {
        model.credentials.filter { !$0.isSecretAvailable }
    }

    var body: some View {
        NavigationStack {
            Group {
                if archivedIdentities.isEmpty && archivedCredentials.isEmpty && purgedCredentials.isEmpty {
                    ContentUnavailableView("Archive is empty", systemImage: "archivebox")
                } else {
                    List {
                        if !archivedIdentities.isEmpty || !archivedCredentials.isEmpty {
                            Section("Archived") {
                                ForEach(archivedIdentities) { identity in
                                    Label(identity.name, systemImage: "person.badge.key")
                                }
                                ForEach(archivedCredentials) { credential in
                                    Label(credential.label, systemImage: "key")
                                }
                            }
                        }
                        if !purgedCredentials.isEmpty {
                            Section("Purged") {
                                ForEach(purgedCredentials) { credential in
                                    Label(credential.label, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Archive")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

private struct ConnectionSheet: View {
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
                .help("Cancel connection")
                Spacer()
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func promptContent(_ prompt: ConnectionPromptRequest) -> some View {
        switch prompt.kind {
        case .username(let host):
            verticalForm(
                title: "Your username",
                subtitle: "Enter the account name used on \(host.hostname)."
            ) {
                TextField("Username", text: $username)
                    .textFieldStyle(.plain)
                    .connectionInput()
                    .focused($focusedField, equals: .username)
                    .onSubmit { submitUsername() }
            }
        case .password(let host, let account):
            verticalForm(
                title: "Welcome back",
                subtitle: "Enter the password for \(account)@\(host.hostname)."
            ) {
                passwordField(placeholder: "Password")
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
            verticalForm(
                title: "Unlock \(credential.label)",
                subtitle: "Enter the passphrase for this private key. It is used only for this connection."
            ) {
                SecureField("Key passphrase", text: $passphrase)
                    .textFieldStyle(.plain)
                    .connectionInput()
                    .focused($focusedField, equals: .passphrase)
                    .onSubmit { submitPassphrase() }
            }
        case .trustNewHost(let key):
            verticalForm(
                title: "Verify this host",
                subtitle: "This is the first connection to this server. Check its fingerprint before continuing."
            ) {
                hostKeyDetails(endpoint: key.endpoint, algorithm: key.algorithm, fingerprints: [("Fingerprint", key.fingerprint)])
            }
        case .replaceHostKey(let previous, let presented):
            verticalForm(
                title: "Host key changed",
                subtitle: "The server presented a different key. Continue only if you expected this change."
            ) {
                hostKeyDetails(
                    endpoint: presented.endpoint,
                    algorithm: presented.algorithm,
                    fingerprints: [("Previous", previous.fingerprint), ("Presented", presented.fingerprint)]
                )
            }
        }
    }

    private func authenticationForm(
        host: HostProfile,
        storedUsername: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) -> some View {
        verticalForm(
            title: "Sign in to \(host.displayName)",
            subtitle: "Use a password, an access key, or one of your saved identities."
        ) {
            HStack(spacing: 10) {
                TextField("Username", text: usernameBinding(identities: availableIdentities))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .username)
                if !availableIdentities.isEmpty {
                    Menu {
                        Button("Manual") {
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
                    .help("Choose an identity")
                }
            }
            .connectionInput()

            if let identity = availableIdentities.first(where: { $0.id == selectedIdentityID }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.name).fontWeight(.medium)
                        Text("Saved identity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") {
                        withAnimation(.smooth(duration: 0.3)) { selectedIdentityID = nil }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
                .connectionInput()
                .transition(.blurReplace)
            } else {
                passwordField(placeholder: "Password")
                    .onSubmit { submitAuthentication() }

                if showsAccessKey, !availableAccessKeys.isEmpty {
                    Menu {
                        Button("No Access Key") { selectedAccessKeyID = nil }
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
                    Button("Add Access Key", systemImage: "key.horizontal") {
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

    private var connectionStateContent: some View {
        Group {
            if case .failed(let message) = model.connectionPhase {
                verticalForm(
                    title: "Couldn’t connect",
                    subtitle: "The SSH login did not complete. Check the details and try again."
                ) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .connectionInput(border: .red)
                }
            } else if case .connected = model.connectionPhase {
                verticalForm(
                    title: "Connected",
                    subtitle: "The SSH session is ready and has been handed to the selected terminal."
                ) { EmptyView() }
            } else {
                verticalForm(
                    title: "Connecting…",
                    subtitle: model.connectionPhase.description
                ) { EmptyView() }
            }
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        if let request = model.connectionPrompts.request {
            switch request.kind {
            case .username:
                primaryButton(
                    "Continue",
                    disabled: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submitUsername
                )
            case .password:
                primaryButton("Connect", disabled: password.isEmpty, action: submitPassword)
            case .authentication:
                primaryButton("Connect", disabled: !canSubmitAuthentication, action: submitAuthentication)
            case .passphrase:
                primaryButton("Unlock & Continue", disabled: passphrase.isEmpty, action: submitPassphrase)
            case .trustNewHost:
                primaryButton("Trust & Connect") { model.connectionPrompts.submit() }
            case .replaceHostKey:
                Button("Replace Key & Connect", role: .destructive) {
                    model.connectionPrompts.submit()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        } else if case .failed = model.connectionPhase {
            VStack(spacing: 12) {
                Button("Close") { Task { await model.cancelConnectionPresentation() } }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                primaryButton("Retry") { Task { await model.retryConnection() } }
            }
        } else if case .connected = model.connectionPhase {
            VStack(spacing: 12) {
                Button(connectionCommandButtonTitle) {
                    copyConnectionCommand()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isPreparingConnectionCommand)
                primaryButton("Done") { model.dismissConnection() }
            }
        } else {
            primaryButton("Connecting…", loading: true, disabled: true) {}
        }
    }

    private func verticalForm<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) { content() }
        }
        .frame(maxWidth: .infinity)
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
            Button(revealsPassword ? "Hide password" : "Show password", systemImage: revealsPassword ? "eye.slash" : "eye") {
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
            return "Select an access key"
        }
        return credential.label
    }

    private var connectionCommandButtonTitle: String {
        if isPreparingConnectionCommand { return "Preparing command…" }
        if didCopyConnectionCommand { return "Paste it into any terminal" }
        return "Copy connection command"
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
        model.connectionHost?.displayName ?? "SSH Connection"
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
        case .trustNewHost, .replaceHostKey:
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

    private func hostKeyDetails(endpoint: String, algorithm: String, fingerprints: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent(FeatureL10n.text("ui.root.view.11"), value: endpoint)
            LabeledContent(FeatureL10n.text("ui.root.view.12"), value: algorithm)
            ForEach(Array(fingerprints.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .connectionInput()
    }
}

private extension View {
    func connectionInput(border: Color? = nil) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.quaternary, in: .rect(cornerRadius: 14))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(border.opacity(0.75), lineWidth: 1.5)
                }
            }
    }
}

private extension SSHConnectionPhase {
    var isWorking: Bool {
        switch self { case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: true; default: false }
    }
    var isFailure: Bool { if case .failed = self { true } else { false } }
    var description: String {
        switch self {
        case .disconnected: "Connection cancelled"
        case .resolving: "Resolving host and preparing authentication…"
        case .verifyingHost(let fingerprint): FeatureL10n.text("connection.phase.verifyingHost", fingerprint)
        case .authenticating: "Authenticating…"
        case .connected: "Ready. The terminal can now attach to this connection."
        case .reconnecting(let attempt): FeatureL10n.text("connection.phase.reconnecting", attempt)
        case .waitingForUser(let message): message
        case .failed(let message): message
        }
    }
}
