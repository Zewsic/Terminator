import SwiftUI
import TerminatorCore
import TerminatorFeatures

struct SettingsView: View {
    let capabilities: AppCapabilities
    @State private var access = AccessPreferencesStore.load()
    private var dismissedHints = DismissedHintsStore.shared
    private var development = DevelopmentPreferences.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label(AppL10n.text(.settingsGeneral), systemImage: "gearshape") }
            if !capabilities.isAppStoreBuild {
                accessTab
                    .tabItem { Label(AppL10n.text(.settingsAccess), systemImage: "lock.rectangle.stack") }
            }
            if development.enabled {
                developmentTab
                    .tabItem { Label(AppL10n.text(.settingsDevelopment), systemImage: "hammer") }
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
            Section {
                Toggle(AppL10n.text(.settingsDevelopmentEnable), isOn: developmentEnabled)
                Text(AppL10n.text(.settingsDevelopmentCaption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var developmentTab: some View {
        Form {
            Section {
                Toggle(AppL10n.text(.settingsDevelopmentRestrictions), isOn: restrictionsRemoved)
            }
        }
        .formStyle(.grouped)
    }

    private var developmentEnabled: Binding<Bool> {
        Binding(get: { development.enabled }, set: { development.enabled = $0 })
    }

    private var restrictionsRemoved: Binding<Bool> {
        Binding(get: { development.restrictionsRemoved }, set: { development.restrictionsRemoved = $0 })
    }

    private var mcpCommand: String {
        #if !APP_STORE
        "\(MCPAccessSupport.serviceURL.path) mcp"
        #else
        "terminator-service mcp"
        #endif
    }
}
