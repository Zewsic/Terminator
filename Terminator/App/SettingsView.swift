import SwiftUI
import TerminatorCore
import TerminatorFeatures

struct SettingsView: View {
    let capabilities: AppCapabilities
    @State private var access = AccessPreferencesStore.load()
    @AppStorage(AppSection.showServicesTabKey) private var showServicesTab = true
    @AppStorage(AppSection.showTasksTabKey) private var showTasksTab = true
    private var dismissedHints = DismissedHintsStore.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label(AppL10n.text(.settingsGeneral), systemImage: "gearshape") }
            if !capabilities.isAppStoreBuild {
                accessTab
                    .tabItem { Label(AppL10n.text(.settingsAccess), systemImage: "lock.rectangle.stack") }
            }
        }
        .frame(width: 560, height: 420)
        .navigationTitle(AppL10n.text(.settingsSettings))
    }

    private var general: some View {
        Form {
            Section(AppL10n.text(.settingsInterface)) {
                Button(AppL10n.text(.settingsRestoreHiddenBanners)) {
                    dismissedHints.restoreAll()
                }
                .disabled(!dismissedHints.hasDismissedHints)
            }
            Section(AppL10n.text(.settingsSidebar)) {
                Toggle(AppL10n.text(.settingsShowServicesTab), isOn: $showServicesTab)
                Toggle(AppL10n.text(.settingsShowTasksTab), isOn: $showTasksTab)
            }
            Section(AppL10n.text(.settingsLicensing)) {
                Text(AppL10n.text(.settingsPolyformNoncommercial100))
                if let supportURL = URL(string: "mailto:terminator@zewsic.pro") {
                    Link(AppL10n.text(.settingsCommercialLicensing), destination: supportURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var accessTab: some View {
        Form {
            Section {
                Toggle(AppL10n.text(.settingsAccessCLI), isOn: $access.cliEnabled)
                Text(AppL10n.text(.settingsAccessCLICaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(AppL10n.text(.settingsAccessMCP), isOn: $access.mcpEnabled)
                Text(AppL10n.text(.settingsAccessMCPCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if access.mcpEnabled {
                    Text(mcpCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: access) { _, value in
            let previous = AccessPreferencesStore.load()
            AccessPreferencesStore.save(value)
            #if !APP_STORE
            if previous.mcpEnabled != value.mcpEnabled {
                MCPAccessSupport.apply(enabled: value.mcpEnabled)
            }
            #endif
        }
    }

    private var mcpCommand: String {
        #if !APP_STORE
        "\(MCPAccessSupport.serviceURL.path) mcp"
        #else
        "terminator-service mcp"
        #endif
    }
}
