import SwiftUI
import TerminatorCore

struct SettingsView: View {
    let capabilities: AppCapabilities
    @AppStorage("sessionLogRetentionDays") private var retentionDays = 90

    var body: some View {
        Form {
            Section(AppL10n.text("ui.settings.view.1")) {
                LabeledContent(AppL10n.text("ui.settings.view.2"), value: capabilities.isAppStoreBuild ? "Mac App Store" : "Direct")
                LabeledContent(AppL10n.text("ui.settings.view.3"), value: capabilities.localShell ? "Available in a future milestone" : "Unavailable")
                LabeledContent(AppL10n.text("ui.settings.view.4"), value: capabilities.externalFileAccess ? "User-controlled" : "Sandboxed")
            }
            Section(AppL10n.text("ui.settings.view.5")) {
                LabeledContent(AppL10n.text("ui.settings.view.6"), value: "Local SwiftData store")
                LabeledContent(AppL10n.text("ui.settings.view.7"), value: "Device-only Keychain")
                LabeledContent(AppL10n.text("ui.settings.view.8"), value: "Disabled")
                Stepper(AppL10n.text("settings.retention", retentionDays), value: $retentionDays, in: 1...3650)
                Text(AppL10n.text("ui.settings.view.9")).font(.caption).foregroundStyle(.secondary)
            }
            Section(AppL10n.text("ui.settings.view.10")) {
                Text(AppL10n.text("ui.settings.view.11"))
                Link(AppL10n.text("ui.settings.view.12"), destination: URL(string: "mailto:terminator@zewsic.pro")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 390)
        .navigationTitle(AppL10n.text("ui.settings.view.13"))
    }
}
