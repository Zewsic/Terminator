import SwiftUI
import TerminatorCore

struct ServicesView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedServiceID: String?
    @State private var search = ""

    private var filteredServices: [ContainerSummary] {
        guard !search.isEmpty else { return model.containers }
        return model.containers.filter { service in
            service.name.localizedCaseInsensitiveContains(search)
                || service.image.localizedCaseInsensitiveContains(search)
                || service.endpointName.localizedCaseInsensitiveContains(search)
                || service.state.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.containers.isEmpty {
                ContentUnavailableView(
                    "No services",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Discovered services will appear here.")
                )
            } else {
                InspectorLayout {
                    List(filteredServices, selection: $selectedServiceID) { service in
                        HStack(spacing: 12) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(isAvailable(service) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(service.name).fontWeight(.medium)
                                    Text(service.state.uppercased())
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                }
                                Text(FeatureL10n.text(.containerSummary, service.image, service.endpointName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .tag(service.id)
                    }
                } inspector: {
                    if let service = model.containers.first(where: { $0.id == selectedServiceID }) {
                        ServiceInspector(service: service)
                    }
                } onContentInteraction: {
                    selectedServiceID = nil
                }
            }
        }
        .navigationTitle("Services")
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button(FeatureL10n.text(.featureHistoryCloseInspector), systemImage: "arrow.left.to.line") {
                    selectedServiceID = nil
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(FeatureL10n.text(.featureHistoryCloseInspector))
                .disabled(selectedServiceID == nil)
                .opacity(selectedServiceID == nil ? 0 : 1)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: "Search services")
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private func isAvailable(_ service: ContainerSummary) -> Bool {
        service.state == "running" || service.state == "healthy"
    }
}

private struct ServiceInspector: View {
    let service: ContainerSummary

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(service.name).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                LabeledContent(FeatureL10n.text(.featureContainersImage), value: service.image)
                LabeledContent(FeatureL10n.text(.featureContainersState), value: service.state)
                LabeledContent(FeatureL10n.text(.connectionEndpoint), value: service.endpointName)
            }
            .formStyle(.grouped)
        }
    }
}
