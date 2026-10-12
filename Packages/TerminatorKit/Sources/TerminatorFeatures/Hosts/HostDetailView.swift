import SwiftUI
import TerminatorCore

struct HostDetailView: View {
    @Environment(TerminatorAppModel.self) private var model
    let host: HostProfile
    let identity: IdentityProfile?
    let credentials: [CredentialMetadata]

    var body: some View {
        Form {
            Section(FeatureL10n.text(.hostsConnection)) {
                LabeledContent(FeatureL10n.text(.hostsAddress)) {
                    Text(host.hostname)
                }
                LabeledContent(FeatureL10n.text(.hostsPort), value: String(host.port))
                if let identity {
                    LabeledContent(FeatureL10n.text(.hostsIdentity), value: identity.name)
                    LabeledContent(FeatureL10n.text(.hostsUsername), value: identity.username)
                    LabeledContent(FeatureL10n.text(.hostsMethods), value: "\(identity.authenticationMethods.count)")
                } else if case .manual(let username, _) = host.authentication {
                    LabeledContent(FeatureL10n.text(.hostsAuthentication), value: FeatureL10n.text(.hostAuthenticationManual))
                    LabeledContent(FeatureL10n.text(.hostsUsername), value: username)
                    LabeledContent(FeatureL10n.text(.hostsMethods), value: "\(host.authentication.authenticationMethods.count)")
                }
            }
            if let group = host.group {
                Section(FeatureL10n.text(.hostsOrganization)) {
                    LabeledContent(FeatureL10n.text(.hostsGroup), value: group)
                    if !host.tags.isEmpty { LabeledContent(FeatureL10n.text(.hostsTags), value: host.tags.joined(separator: ", ")) }
                }
            }
            if !host.notes.isEmpty { Section(FeatureL10n.text(.hostsNotes)) { Text(host.notes).textSelection(.enabled) } }
            Section {
                if model.capabilities.externalTerminal {
                    Menu(FeatureL10n.text(.hostsConnectWith), systemImage: "bolt.horizontal") {
                        ForEach(model.terminalApplications) { terminal in
                            Button(terminal.displayName) { Task { await model.connect(host, with: terminal) } }
                        }
                    }
                }
            } footer: {
                Text(model.capabilities.externalTerminal
                    ? "Terminator owns the SSH connection; the selected terminal renders it through a protected local attach socket."
                    : "External terminal connections are available in the Direct macOS edition.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.displayName)
    }
}
