import SwiftUI
import TerminatorCore

struct TunnelsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var selectedTunnelID: UUID?
    @State private var editorTunnel: TunnelProfile?
    @State private var isCreating = false
    @State private var pendingDelete: TunnelProfile?
    @State private var collapsedGroups: Set<String> = []

    private struct TunnelListGroup: Identifiable {
        let id: String
        let title: String
        let tunnels: [TunnelProfile]
    }

    var body: some View {
        Group {
            if model.tunnels.isEmpty && !hasPendingImports {
                ContentUnavailableView {
                    Label(FeatureL10n.text(.tunnelEmpty), systemImage: "arrow.left.arrow.right")
                } description: {
                    Text(FeatureL10n.text(.tunnelEmptyDescription))
                } actions: {
                    Button(FeatureL10n.text(.tunnelAdd), systemImage: "plus") { isCreating = true }
                        .buttonStyle(.glassProminent).tint(.blue)
                        .accessibilityIdentifier("add-tunnel-empty")
                }
            } else {
                InspectorLayout(content: {
                    VStack(spacing: 0) {
                        CatalogImportBanner(hint: .tunnelsImportBanner)
                        tunnelList
                    }
                }, inspector: {
                    if let editorTunnel {
                        TunnelEditor(tunnel: editorTunnel) { draft in
                            await model.saveTunnel(draft)
                        } onStart: {
                            Task { await model.startTunnel(id: editorTunnel.id) }
                        } onStop: {
                            Task { await model.stopTunnel(id: editorTunnel.id) }
                        }
                        .id(editorTunnel.id)
                    }
                }, isInspectorPresented: editorTunnel != nil, onContentInteraction: {
                    closeInspector()
                })
            }
        }
        .navigationTitle(FeatureL10n.text(.sectionTunnels))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.tunnelSearch))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(FeatureL10n.text(.tunnelAdd), systemImage: "plus") { isCreating = true }
                    .accessibilityIdentifier("add-tunnel")
                ExternalImportMenu(hint: .tunnelsImportBanner)
            }
        }
        .sheet(isPresented: $isCreating) { TunnelCreateSheet() }
        .confirmationDialog(
            FeatureL10n.text(.tunnelArchive),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.tunnelArchive), role: .destructive) {
                if let pendingDelete { Task { await model.deleteTunnel(id: pendingDelete.id) } }
                pendingDelete = nil
                closeInspector()
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(FeatureL10n.text(.tunnelArchiveMessage))
        }
        .onChange(of: selectedTunnelID) { _, id in
            editorTunnel = id.flatMap { tunnelID in model.tunnels.first { $0.id == tunnelID } }
        }
        .onChange(of: model.tunnels) { _, _ in
            if let id = selectedTunnelID {
                editorTunnel = model.tunnels.first { $0.id == id }
            }
        }
    }

    private var tunnelGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private var tunnelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if collapsedGroups.contains(group.id) { collapsedGroups.remove(group.id) }
                            else { collapsedGroups.insert(group.id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                            Text(group.title)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if !collapsedGroups.contains(group.id) {
                        LazyVGrid(columns: tunnelGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                            ForEach(group.tunnels) { tunnel in
                                tunnelCard(tunnel)
                            }
                        }
                    }
                }
                if hasPendingImports {
                    Text(FeatureL10n.text(.actionImport))
                        .font(.headline)
                        .padding(.top, 8)
                    LazyVGrid(columns: tunnelGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                        ForEach(model.loadedExternalImportBundles, id: \.source.id) { bundle in
                            ForEach(bundle.tunnels.filter { matchesImport($0) }) { tunnel in
                                Button {
                                    Task { await model.importExternalTunnel(tunnel, from: bundle) }
                                } label: {
                                    importCard(tunnel, source: bundle.source.displayName)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("tunnels-list")
    }

    private func tunnelCard(_ tunnel: TunnelProfile) -> some View {
        let phase = model.tunnelPhase(for: tunnel.id)
        return TunnelCard(
            tunnel: tunnel,
            tags: tunnel.derivedTags(in: model.hosts),
            subtitle: cardSubtitle(tunnel),
            phase: phase,
            isSelected: selectedTunnelID == tunnel.id
        )
        .onTapGesture { selectedTunnelID = tunnel.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !phase.isWorking else { return }
            if case .connected = phase { return }
            Task { await model.startTunnel(id: tunnel.id) }
        })
        .contextMenu {
            if case .connected = phase {
                Button(FeatureL10n.text(.tunnelStop), systemImage: "stop.fill") {
                    Task { await model.stopTunnel(id: tunnel.id) }
                }
            } else {
                Button(FeatureL10n.text(.tunnelStart), systemImage: "play.fill") {
                    Task { await model.startTunnel(id: tunnel.id) }
                }
            }
            Button(FeatureL10n.text(.tunnelArchive), role: .destructive) { pendingDelete = tunnel }
        }
    }

    private func importCard(_ tunnel: ExternalImportTunnel, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tunnel.label.isEmpty ? tunnel.kind.rawValue.capitalized : tunnel.label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(tunnel.bindAddress):\(tunnel.localPort) · \(source)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(HostCardMetrics.iconInset)
        .frame(width: HostCardMetrics.width, height: HostCardMetrics.height, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
    }

    private func cardSubtitle(_ tunnel: TunnelProfile) -> String {
        let source = model.endpointName(tunnel.source, fallback: FeatureL10n.text(.tunnelHostA))
        let destination = model.endpointName(tunnel.destination, fallback: FeatureL10n.text(.tunnelHostB))
        switch tunnel.kind {
        case .dynamic: return "\(source) → \(destination)"
        case .local: return "\(source) \(tunnel.listenPort) → \(destination) \(tunnel.targetPort)"
        case .remote: return "\(destination) \(tunnel.targetPort) → \(source) \(tunnel.listenPort)"
        }
    }

    private var groups: [TunnelListGroup] {
        let filtered = model.tunnels.filter(matches)
        let grouped = Dictionary(grouping: filtered) { tunnel -> String? in
            tunnel.groupName(in: model.hosts)
        }
        var result: [TunnelListGroup] = []
        if let ungrouped = grouped[nil], !ungrouped.isEmpty {
            result.append(.init(id: "__catalog", title: FeatureL10n.text(.hostsCatalog), tunnels: ungrouped))
        }
        result.append(contentsOf: grouped.compactMap { name, tunnels -> TunnelListGroup? in
            guard let name else { return nil }
            return .init(id: "group:\(name)", title: name, tunnels: tunnels)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        return result
    }

    private var hasPendingImports: Bool {
        model.loadedExternalImportBundles.contains { !$0.tunnels.isEmpty }
    }

    private func matches(_ tunnel: TunnelProfile) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = ([tunnel.displayName, tunnel.kind.displayName] + tunnel.derivedTags(in: model.hosts)).joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func matchesImport(_ tunnel: ExternalImportTunnel) -> Bool {
        guard !search.isEmpty else { return true }
        return tunnel.label.localizedCaseInsensitiveContains(search)
            || tunnel.targetHost.localizedCaseInsensitiveContains(search)
    }

    private func closeInspector() {
        selectedTunnelID = nil
        editorTunnel = nil
    }
}

struct TunnelCard: View {
    let tunnel: TunnelProfile
    let tags: [String]
    let subtitle: String
    let phase: SSHConnectionPhase
    var isSelected = false

    var body: some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    OverflowingTagLine(tags: tags)
                    Spacer(minLength: 0)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(HostCardMetrics.iconInset)
        .frame(width: HostCardMetrics.width, height: HostCardMetrics.height, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: HostCardMetrics.cornerRadius, style: .continuous)
            ZStack {
                if let statusColor {
                    shape.inset(by: 1).stroke(statusColor.opacity(0.85), lineWidth: 1.25)
                }
                if isSelected { shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5) }
            }
        }
    }

    private var symbol: String {
        switch tunnel.kind {
        case .local: "arrow.down"
        case .remote: "arrow.up"
        case .dynamic: "arrow.triangle.branch"
        }
    }

    private var statusColor: Color? {
        switch phase {
        case .connected: .green
        case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: .yellow
        case .failed: .red
        case .disconnected: nil
        }
    }
}
