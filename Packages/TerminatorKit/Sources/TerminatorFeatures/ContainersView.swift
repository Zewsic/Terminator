import SwiftUI

struct ContainersView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        Group {
            if model.containers.isEmpty {
                ContentUnavailableView(
                    "No demo containers",
                    systemImage: "shippingbox",
                    description: Text("Docker discovery is planned for a later milestone.")
                )
            } else {
                List(model.containers) { container in
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(container.state == "running" || container.state == "healthy" ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(container.name).fontWeight(.medium)
                                Text(container.state.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Text(FeatureL10n.text("container.summary", container.image, container.endpointName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Containers · Demo")
        .safeAreaInset(edge: .top) {
            Label("Demo data — no Docker daemon is contacted", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .padding(.top, 8)
        }
    }
}
