import SwiftUI
import TerminatorCore

struct SettingsView: View {
    let capabilities: AppCapabilities

    var body: some View {
        Form {
            Section("Edition") {
                LabeledContent("Distribution", value: capabilities.isAppStoreBuild ? "Mac App Store" : "Direct")
                LabeledContent("Local shell", value: capabilities.localShell ? "Available in a future milestone" : "Unavailable")
                LabeledContent("External files", value: capabilities.externalFileAccess ? "User-controlled" : "Sandboxed")
            }
            Section("Storage") {
                LabeledContent("Catalog", value: "Local SwiftData store")
                LabeledContent("Secrets", value: "Device-only Keychain")
                LabeledContent("Cloud sync", value: "Disabled")
            }
            Section("Licensing") {
                Text("PolyForm Noncommercial 1.0.0")
                Link("Commercial licensing", destination: URL(string: "mailto:terminator@zewsic.pro")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 390)
        .navigationTitle("Settings")
    }
}
