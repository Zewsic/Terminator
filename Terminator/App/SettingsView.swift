import SwiftUI
import TerminatorCore

struct SettingsView: View {
    let capabilities: AppCapabilities
    @AppStorage("sessionLogRetentionDays") private var retentionDays = 90

    var body: some View {
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
            Section(AppL10n.text(.settingsLicensing)) {
                Text(AppL10n.text(.settingsPolyformNoncommercial100))
                if let supportURL = URL(string: "mailto:terminator@zewsic.pro") {
                    Link(AppL10n.text(.settingsCommercialLicensing), destination: supportURL)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 390)
        .navigationTitle(AppL10n.text(.settingsSettings))
    }
}
