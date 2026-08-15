import SwiftUI
import TerminatorCore

struct ArchiveView: View {
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
                    ContentUnavailableView(FeatureL10n.text(.featureArchiveArchiveIsEmpty), systemImage: "archivebox")
                } else {
                    List {
                        if !archivedIdentities.isEmpty || !archivedCredentials.isEmpty {
                            Section(FeatureL10n.text(.commonArchived)) {
                                ForEach(archivedIdentities) { identity in
                                    Label(identity.name, systemImage: "person.badge.key")
                                }
                                ForEach(archivedCredentials) { credential in
                                    Label(credential.label, systemImage: "key")
                                }
                            }
                        }
                        if !purgedCredentials.isEmpty {
                            Section(FeatureL10n.text(.featureArchivePurged)) {
                                ForEach(purgedCredentials) { credential in
                                    Label(credential.label, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(FeatureL10n.text(.actionArchive))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FeatureL10n.text(.actionClose)) { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
