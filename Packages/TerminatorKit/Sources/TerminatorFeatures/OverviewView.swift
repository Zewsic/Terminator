import SwiftUI

struct OverviewView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FeatureL10n.text("ui.overview.view.1"))
                        .font(.largeTitle.bold())
                    Text(FeatureL10n.text("ui.overview.view.2"))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    metric(title: FeatureL10n.text("ui.overview.view.8"), value: model.hosts.count, image: "server.rack")
                    metric(title: FeatureL10n.text("ui.overview.view.9"), value: model.activeCredentials.count, image: "key")
                    metric(title: FeatureL10n.text("ui.overview.view.10"), value: model.history.count, image: "clock")
                    metric(title: FeatureL10n.text("ui.overview.view.11"), value: model.containers.count, image: "shippingbox")
                }

                GroupBox(FeatureL10n.text("ui.overview.view.3")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(FeatureL10n.text("ui.overview.view.4"), systemImage: "checkmark.shield")
                        Label(FeatureL10n.text("ui.overview.view.5"), systemImage: "checkmark.shield")
                        Label(FeatureL10n.text("ui.overview.view.6"), systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(FeatureL10n.text("ui.overview.view.7"))
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
