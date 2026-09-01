import SwiftUI
import TerminatorCore

struct SettingsView: View {
    let capabilities: AppCapabilities
    @AppStorage("sessionLogRetentionDays") private var retentionDays = 90
    @State private var access = AccessPreferencesStore.load()
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
            Section(AppL10n.text(.settingsEdition)) {
                LabeledContent(AppL10n.text(.settingsDistribution), value: capabilities.isAppStoreBuild ? AppL10n.text(.settingsDistributionAppStore) : AppL10n.text(.settingsDistributionDirect))
                LabeledContent(AppL10n.text(.settingsLocalShell), value: capabilities.localShell ? AppL10n.text(.settingsLocalShellFuture) : AppL10n.text(.settingsLocalShellUnavailable))
                LabeledContent(AppL10n.text(.settingsExternalFiles), value: capabilities.externalFileAccess ? AppL10n.text(.settingsExternalFilesUserControlled) : AppL10n.text(.settingsExternalFilesSandboxed))
            }
            Section(AppL10n.text(.settingsStorage)) {
                LabeledContent(AppL10n.text(.settingsCatalog), value: AppL10n.text(.settingsCatalogValue))
                LabeledContent(AppL10n.text(.settingsSecrets), value: AppL10n.text(.settingsSecretsValue))
                LabeledContent(AppL10n.text(.settingsCloudSync), value: AppL10n.text(.settingsCloudSyncDisabled))
                Stepper(AppL10n.text(.settingsRetention, retentionDays), value: $retentionDays, in: 1...3650)
                Text(AppL10n.text(.settingsPinnedAndActiveSessionsAreNeverRemoved)).font(.caption).foregroundStyle(.secondary)
            }
            Section(AppL10n.text(.settingsInterface)) {
                Button(AppL10n.text(.settingsRestoreHiddenBanners)) {
                    dismissedHints.restoreAll()
                }
                .disabled(!dismissedHints.hasDismissedHints)
                Text(AppL10n.text(.settingsRestoreHiddenBannersCaption))
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

    private var mcpCommand: String {
        #if !APP_STORE
        "\(MCPAccessSupport.serviceURL.path) mcp"
        #else
        "terminator-service mcp"
        #endif
    }
}
