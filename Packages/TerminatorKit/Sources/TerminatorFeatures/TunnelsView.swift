import SwiftUI
import TerminatorCore

struct TunnelsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var selectedTunnelID: UUID?
    @State private var editorTunnel: TunnelProfile?
    @State private var isCreating = false
    @State private var pendingDelete: TunnelProfile?
    @State private var tray: CatalogTray?
    @State private var traySelection: Set<String> = []
    @State private var isImportingTray = false

    var body: some View {
        InspectorLayout(content: {
            VStack(spacing: 0) {
                CatalogImportBanner(hint: .tunnelsImportBanner) { openTray(.source($0.id)) }
                if model.tunnels.isEmpty {
                    ContentUnavailableView {
                        Label(FeatureL10n.text(.tunnelEmpty), systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text(FeatureL10n.text(.tunnelEmptyDescription))
                    } actions: {
                        Button(FeatureL10n.text(.tunnelAdd), systemImage: "plus") {
                        tray = nil
                        isCreating = true
                    }
                            .emptyCatalogAddStyle()
                            .accessibilityIdentifier("add-tunnel-empty")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    tunnelList
                }
            }
        }, inspector: {
            if let tray {
                tunnelPicker(tray)
            } else if let editorTunnel {
                TunnelEditor(tunnel: editorTunnel) { draft in
                    await model.saveTunnel(draft)
                } onStart: {
                    Task { await model.startTunnel(id: editorTunnel.id) }
                } onStop: {
                    Task { await model.stopTunnel(id: editorTunnel.id) }
                }
                .id(editorTunnel.id)
            }
        }, inspectorWidth: tray == nil ? 540 : InspectorMetrics.compactWidth,
           isInspectorPresented: tray != nil || editorTunnel != nil, onContentInteraction: {
            closeInspector()
        })
        .navigationTitle(FeatureL10n.text(.sectionTunnels))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.tunnelSearch))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(FeatureL10n.text(.tunnelAdd), systemImage: "plus") {
                    tray = nil
                    isCreating = true
                }
                    .accessibilityIdentifier("add-tunnel")
                ExternalImportMenu { openTray($0) }
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
            if id != nil { tray = nil }
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
                if !visibleTunnels.isEmpty {
                    LazyVGrid(columns: tunnelGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                        ForEach(visibleTunnels) { tunnel in
                            tunnelCard(tunnel)
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
            subtitle: tunnelSubtitle(tunnel),
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

    private func tunnelSubtitle(_ tunnel: TunnelProfile) -> String {
        let base = cardSubtitle(tunnel)
        guard case .connected = model.tunnelPhase(for: tunnel.id),
              let traffic = model.tunnelTraffic[tunnel.id] else { return base }
        let received = ByteCountFormatter.string(fromByteCount: Int64(clamping: traffic.received), countStyle: .binary)
        let sent = ByteCountFormatter.string(fromByteCount: Int64(clamping: traffic.sent), countStyle: .binary)
        return "\(base) · ↓\(received) ↑\(sent)"
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

    private var visibleTunnels: [TunnelProfile] {
        model.tunnels.filter(matches).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func matches(_ tunnel: TunnelProfile) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = ([tunnel.displayName, tunnel.kind.displayName] + tunnel.derivedTags(in: model.hosts)).joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func closeInspector() {
        selectedTunnelID = nil
        editorTunnel = nil
        tray = nil
        traySelection = []
    }

    private func openTray(_ next: CatalogTray) {
        closeInspector()
        traySelection = []
        tray = next
        guard case .source(let id) = next,
              let source = model.importSources.first(where: { $0.id == id }) else { return }
        Task { await model.loadImportSource(source) }
    }

    private func tunnelPicker(_ tray: CatalogTray) -> some View {
        let archive = tray == .archive
        return CatalogPickerPanel(
            title: archive ? FeatureL10n.text(.actionArchive) : sourceTitle(tray),
            subtitle: FeatureL10n.text(archive ? .catalogChooseArchive : .catalogChooseImport),
            records: tunnelPicks(tray),
            isLoading: isLoading(tray),
            primaryTitle: FeatureL10n.text(archive ? .catalogRestore : .actionImport),
            destructiveTitle: archive ? FeatureL10n.text(.catalogDelete) : nil,
            emptyTitle: FeatureL10n.text(archive ? .featureArchiveArchiveIsEmpty : .catalogNothingToImport),
            selection: $traySelection,
            isWorking: isImportingTray,
            onPrimary: { Task { await applyTunnelTray(tray, purge: false) } },
            onDestructive: { Task { await applyTunnelTray(tray, purge: true) } },
            onClose: closeInspector
        )
    }

    private func sourceTitle(_ tray: CatalogTray) -> String {
        guard case .source(let id) = tray else { return FeatureL10n.text(.actionImport) }
        return model.importSources.first { $0.id == id }?.displayName ?? FeatureL10n.text(.actionImport)
    }

    private func isLoading(_ tray: CatalogTray) -> Bool {
        guard case .source(let id) = tray else { return false }
        return model.loadingImportSourceIDs.contains(id)
    }

    private func tunnelPicks(_ tray: CatalogTray) -> [CatalogPick] {
        switch tray {
        case .archive:
            return model.archivedTunnels.map { tunnel in
                CatalogPick(id: tunnel.id.uuidString, title: tunnel.displayName, subtitle: cardSubtitle(tunnel), symbol: "arrow.left.arrow.right")
            }
        case .source(let id):
            return (model.externalImportBundles[id]?.tunnels ?? []).map { tunnel in
                let title = tunnel.label.isEmpty ? tunnel.kind.rawValue.capitalized : tunnel.label
                return CatalogPick(
                    id: "bundle|\(tunnel.id)",
                    title: title,
                    subtitle: "\(tunnel.bindAddress):\(tunnel.localPort)",
                    symbol: "arrow.left.arrow.right"
                )
            }
        }
    }

    private func applyTunnelTray(_ tray: CatalogTray, purge: Bool) async {
        guard !isImportingTray else { return }
        isImportingTray = true
        defer { isImportingTray = false }
        let chosen = traySelection
        switch tray {
        case .archive:
            for id in chosen {
                guard let uuid = UUID(uuidString: id) else { continue }
                let saved = purge ? await model.purgeTunnel(id: uuid) : await model.restoreTunnel(id: uuid)
                if saved { traySelection.remove(id) }
            }
        case .source(let sourceID):
            guard let bundle = model.externalImportBundles[sourceID] else { return }
            for tunnel in bundle.tunnels where chosen.contains("bundle|\(tunnel.id)") {
                if await model.importExternalTunnel(tunnel, from: bundle) {
                    traySelection.remove("bundle|\(tunnel.id)")
                }
            }
        }
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
        case .connected, .agent: .green
        case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: .yellow
        case .failed: .red
        case .disconnected: nil
        }
    }
}
