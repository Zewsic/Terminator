import SwiftUI

struct OverviewView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FeatureL10n.text(.overviewInfrastructureAtAGlance))
                        .font(.largeTitle.bold())
                    Text(FeatureL10n.text(.overviewYourLocalCatalogIsReadyLiveSsh))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    metric(title: FeatureL10n.text(.overviewHosts), value: model.hosts.count, image: "server.rack")
                    metric(title: FeatureL10n.text(.overviewCredentials), value: model.activeCredentials.count, image: "key")
                    metric(title: FeatureL10n.text(.overviewHistoryEntries), value: model.history.count, image: "clock")
                    metric(title: FeatureL10n.text(.overviewDemoContainers), value: model.containers.count, image: "shippingbox")
                }

                GroupBox(FeatureL10n.text(.overviewSecurityBaseline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(FeatureL10n.text(.overviewSecretsAreStoredInTheDeviceOnly), systemImage: "checkmark.shield")
                        Label(FeatureL10n.text(.overviewHistorySnapshotsContainMetadataOnly), systemImage: "checkmark.shield")
                        Label(FeatureL10n.text(.overviewHostKeyVerificationWillDefaultToStrict), systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(FeatureL10n.text(.overviewOverview))
    }

    private func metric(title: String, value: Int, image: String) -> some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: image)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(value, format: .number)
                        .font(.title.bold())
                    Text(title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
}
