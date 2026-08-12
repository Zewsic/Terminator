import SwiftUI

struct OverviewView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Infrastructure at a glance")
                        .font(.largeTitle.bold())
                    Text("Your local catalog is ready. Live SSH and Docker status arrives in the next milestones.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    metric(title: "Hosts", value: model.hosts.count, image: "server.rack")
                    metric(title: "Credentials", value: model.activeCredentials.count, image: "key")
                    metric(title: "History entries", value: model.history.count, image: "clock")
                    metric(title: "Demo containers", value: model.containers.count, image: "shippingbox")
                }

                GroupBox("Security baseline") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Secrets are stored in the device-only Keychain", systemImage: "checkmark.shield")
                        Label("History snapshots contain metadata only", systemImage: "checkmark.shield")
                        Label("Host-key verification will default to strict trust-on-first-use", systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Overview")
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
