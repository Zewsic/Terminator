import SwiftUI
import TerminatorCore

struct TunnelsView: View {
    @Environment(TerminatorAppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            CatalogImportBanner(hint: .tunnelsImportBanner)
            if hasPendingTunnels {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.loadedExternalImportBundles, id: \.source.id) { bundle in
                            ForEach(bundle.tunnels) { tunnel in
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tunnel.label.isEmpty ? FeatureL10n.text(.sectionTunnels) : tunnel.label)
                                            .fontWeight(.medium)
                                        Text(tunnelDetail(tunnel, source: bundle.source.displayName))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView {
                    Label(FeatureL10n.text(.sectionTunnels), systemImage: "arrow.left.arrow.right")
                } description: {
                    Text(FeatureL10n.text(.plannedTunnels))
                } actions: {
                    Text(FeatureL10n.text(.plannedFeaturePlanned))
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
        .navigationTitle(FeatureL10n.text(.sectionTunnels))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ExternalImportMenu(hint: .tunnelsImportBanner)
            }
        }
    }

    private var hasPendingTunnels: Bool {
        model.loadedExternalImportBundles.contains { !$0.tunnels.isEmpty }
    }

    private func tunnelDetail(_ tunnel: ExternalImportTunnel, source: String) -> String {
        let endpoint: String
        switch tunnel.kind {
        case .local:
            endpoint = "\(tunnel.bindAddress):\(tunnel.localPort) → \(tunnel.targetHost):\(tunnel.targetPort)"
        case .remote:
            endpoint = "\(tunnel.targetHost):\(tunnel.targetPort) → \(tunnel.bindAddress):\(tunnel.localPort)"
        case .dynamic:
            endpoint = "\(tunnel.bindAddress):\(tunnel.localPort)"
        }
        return "\(endpoint) · \(source)"
    }
}
