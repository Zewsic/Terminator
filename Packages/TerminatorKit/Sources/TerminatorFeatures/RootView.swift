import SwiftUI
import TerminatorCore

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model

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
            .navigationTitle("Terminator")
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
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(item: Binding(
            get: { model.connectionHost },
            set: { if $0 == nil { model.dismissConnection() } }
        )) { _ in ConnectionSheet() }
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
        Section("Workspace") {
            selectableSidebarRow(.overview, buttons: buttons)
            selectableSidebarRow(.hosts, buttons: buttons)
            if model.capabilities.localShell {
                selectableSidebarRow(.localTerminal, buttons: buttons)
            }
            selectableSidebarRow(.tunnels, buttons: buttons)
        }

        Section("Infrastructure") {
            selectableSidebarRow(.containers, buttons: buttons)
        }

        Section("Library") {
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
            CredentialsView()
        case .history:
            HistoryView()
        case .logs:
            SessionLogsView()
        case .containers:
            ContainersView()
        case .localTerminal:
            PlannedFeatureView(
                title: "Local Terminal",
                systemImage: "terminal",
                description: "A native PTY-backed terminal will be available in the Direct edition."
            )
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

private struct ConnectionSheet: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var passphrase = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34)).foregroundStyle(isWarning ? Color.orange : model.connectionPhase.isFailure ? Color.red : Color.accentColor)
            Text(model.connectionHost?.displayName ?? "SSH Connection").font(.title2).fontWeight(.semibold)
            if let prompt = model.connectionPrompts.request {
                promptContent(prompt)
            } else {
                Text(model.connectionPhase.description).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.connectionPhase.isWorking { ProgressView().controlSize(.small) }
                Button("Close") { model.dismissConnection() }.disabled(model.connectionPhase.isWorking)
            }
        }
        .padding(28).frame(width: 500).frame(minHeight: 300)
        .onChange(of: model.connectionPrompts.request?.id) { _, _ in passphrase = "" }
    }

    @ViewBuilder
    private func promptContent(_ prompt: ConnectionPromptRequest) -> some View {
        switch prompt.kind {
        case .passphrase(let credential):
            Text(FeatureL10n.text("connection.unlock", credential.label))
                .font(.headline)
            Text("Enter the private-key passphrase. It is used only for this connection and is not logged.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Private key passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassphrase() }
            promptButtons(primaryTitle: "Continue", primaryDisabled: passphrase.isEmpty) {
                submitPassphrase()
            }
        case .trustNewHost(let key):
            Text("Trust this SSH host?").font(.headline)
            hostKeyDetails(endpoint: key.endpoint, algorithm: key.algorithm, fingerprints: [("Fingerprint", key.fingerprint)])
            Text("Verify this fingerprint with the server administrator before connecting.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            promptButtons(primaryTitle: "Trust & Connect") { model.connectionPrompts.submit() }
        case .replaceHostKey(let previous, let presented):
            Text("SSH host key changed").font(.headline).foregroundStyle(.red)
            hostKeyDetails(
                endpoint: presented.endpoint,
                algorithm: presented.algorithm,
                fingerprints: [("Previous", previous.fingerprint), ("Presented", presented.fingerprint)]
            )
            Text("This can indicate a server rebuild or a man-in-the-middle attack. The connection remains blocked unless you explicitly replace the stored key.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            promptButtons(primaryTitle: "Replace Key & Connect", destructive: true) {
                model.connectionPrompts.submit()
            }
        }
    }

    private func hostKeyDetails(endpoint: String, algorithm: String, fingerprints: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Endpoint", value: endpoint)
            LabeledContent("Algorithm", value: algorithm)
            ForEach(Array(fingerprints.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func promptButtons(
        primaryTitle: String,
        primaryDisabled: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Button("Cancel", role: .cancel) { model.dismissConnection() }
            Spacer()
            Button(primaryTitle, role: destructive ? .destructive : nil, action: action)
                .buttonStyle(.glassProminent)
                .disabled(primaryDisabled)
        }
    }

    private func submitPassphrase() {
        guard !passphrase.isEmpty else { return }
        model.connectionPrompts.submit(text: passphrase)
        passphrase = ""
    }

    private var isWarning: Bool {
        guard let request = model.connectionPrompts.request else { return false }
        return switch request.kind {
        case .trustNewHost, .replaceHostKey: true
        case .passphrase: false
        }
    }

    private var icon: String {
        guard let request = model.connectionPrompts.request else {
            return model.connectionPhase.isFailure ? "exclamationmark.triangle" : "network"
        }
        return switch request.kind {
        case .passphrase: "lock"
        case .trustNewHost: "checkmark.shield"
        case .replaceHostKey: "exclamationmark.shield"
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
