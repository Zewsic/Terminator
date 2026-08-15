import SwiftUI
import TerminatorCore

struct ContainersView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedContainerID: String?

    var body: some View {
        Group {
            if model.containers.isEmpty {
                ContentUnavailableView(FeatureL10n.text(.containersEmpty),
                    systemImage: "shippingbox",
                    description: Text(FeatureL10n.text(.containersDockerDiscoveryIsPlannedForALater))
                )
            } else {
                InspectorLayout {
                    List(model.containers, selection: $selectedContainerID) { container in
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
                            Text(FeatureL10n.text(.containerSummary, container.image, container.endpointName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(container.id)
                    }
                } inspector: {
                    if let container = model.containers.first(where: { $0.id == selectedContainerID }) {
                        ContainerInspector(container: container) { selectedContainerID = nil }
                    }
                } onContentInteraction: { selectedContainerID = nil }
            }
        }
        .navigationTitle(FeatureL10n.text(.containersContainersDemo))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(FeatureL10n.text(.featureHistoryCloseInspector), systemImage: "arrow.left.to.line") { selectedContainerID = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(FeatureL10n.text(.featureHistoryCloseInspector))
                    .disabled(selectedContainerID == nil)
                    .opacity(selectedContainerID == nil ? 0 : 1)
            }
        }
        .safeAreaInset(edge: .top) {
            Label(FeatureL10n.text(.containersDemoDataNoDockerDaemonIsContacted), systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .padding(.top, 8)
        }
    }
}

private struct ContainerInspector: View {
    let container: ContainerSummary
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(container.name).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                LabeledContent(FeatureL10n.text(.featureContainersImage), value: container.image)
                LabeledContent(FeatureL10n.text(.featureContainersState), value: container.state)
                LabeledContent(FeatureL10n.text(.connectionEndpoint), value: container.endpointName)
            }
            .formStyle(.grouped)
        }
    }
}
