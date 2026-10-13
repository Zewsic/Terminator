import SwiftUI
import TerminatorCore

struct HostsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var selectedHostID: UUID?
    @State private var editorDraft: HostDraft?
    @State private var isImportingOpenSSHHost = false
    @State private var editorSessionID = UUID()
    @State private var pendingDelete: HostProfile?
    @State private var exportHost: HostProfile?
    @State private var helperHost: HostProfile?
    @State private var hostListPreferences = HostListPreferences.shared
    @State private var collapsedHostGroups: Set<String> = []
    @State private var tray: CatalogTray?
    @State private var traySelection: Set<String> = []
    @State private var isImportingTray = false

    private struct HostListGroup: Identifiable {
        let id: String
        let title: String
        let hosts: [HostProfile]
    }

    private var filteredHosts: [HostProfile] {
        let terms = HostCatalogSearch.terms(in: search)
        guard !terms.isEmpty else { return model.hosts }
        return model.hosts.filter { HostCatalogSearch.matches($0, terms: terms, identities: model.identities) }
    }

    private var selectedHost: HostProfile? { model.hosts.first { $0.id == selectedHostID } }

    private var hostGroups: [HostListGroup] {
        let ordered = hostListPreferences.sorted(filteredHosts, logs: model.sessionLogs)
        if !hostListPreferences.groupsEnabled {
            return [.init(id: "__flat", title: "", hosts: ordered)]
        }
        let grouped = Dictionary(grouping: ordered) { host -> String? in
            let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return group.isEmpty ? nil : group
        }
        var result: [HostListGroup] = []
        if let ungrouped = grouped[nil], !ungrouped.isEmpty {
            result.append(.init(id: "__catalog", title: FeatureL10n.text(.hostsCatalog), hosts: ungrouped))
        }
        result.append(contentsOf: grouped.compactMap { name, hosts -> HostListGroup? in
            guard let name else { return nil }
            return .init(id: "group:\(name)", title: name, hosts: hosts)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        return result
    }

    var body: some View {
        InspectorLayout(content: {
            VStack(spacing: 0) {
                CatalogImportBanner(hint: .hostsImportBanner) { openTray(.source($0.id)) }
                if model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label(FeatureL10n.text(.hostsNoHosts), systemImage: "server.rack")
                    } description: {
                        Text(FeatureL10n.text(.hostsAddAnSshHostToStartBuilding))
                    } actions: {
                        Button(FeatureL10n.text(.hostsAddHost), systemImage: "plus") { openEditor(HostDraft()) }
                            .emptyCatalogAddStyle()
                            .accessibilityIdentifier("add-host-empty")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    hostList
                }
            }
        }, inspector: {
            if let tray {
                hostPicker(tray)
            } else if let editorDraft {
                HostEditor(draft: editorDraft, explicitImport: isImportingOpenSSHHost) { savedDraft in
                    await model.saveHost(savedDraft)
                } onClose: {
                    closeInspector()
                }
                .id(editorSessionID)
            } else if let exportHost {
                OpenSSHExportView(host: exportHost) {
                    closeInspector()
                }
                .id(exportHost.id)
            }
        }, inspectorWidth: tray == nil ? 540 : InspectorMetrics.compactWidth,
           isInspectorPresented: tray != nil || editorDraft != nil || exportHost != nil, onContentInteraction: {
            closeInspector()
        })
        .navigationTitle(FeatureL10n.text(.overviewHosts))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Menu {
                    Picker(FeatureL10n.text(.hostsSort), selection: hostSortBinding) {
                        Text(FeatureL10n.text(.hostsSortName)).tag(HostListSort.name)
                        Text(FeatureL10n.text(.hostsSortConnected)).tag(HostListSort.connected)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Toggle(FeatureL10n.text(.hostsGroupHosts), isOn: hostGroupsBinding)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(FeatureL10n.text(.hostsSort))
            }
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.hostsSearchHosts))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(FeatureL10n.text(.hostsAddHost), systemImage: "plus") { openEditor(HostDraft()) }
                    .accessibilityIdentifier("add-host")
                ExternalImportMenu { openTray($0) }
                    .accessibilityIdentifier("import-hosts")
            }
        }
        .alert(FeatureL10n.text(.hostsOpenssh), isPresented: Binding(
            get: { model.openSSHResultMessage != nil },
            set: { if !$0 { model.openSSHResultMessage = nil } }
        )) {
            Button(FeatureL10n.text(.rootOk)) { model.openSSHResultMessage = nil }
        } message: {
            Text(model.openSSHResultMessage ?? "")
        }
        .confirmationDialog(FeatureL10n.text(.featureHostsArchiveThisHost),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.hostsArchive), role: .destructive) {
                if let pendingDelete { Task { await model.deleteHost(id: pendingDelete.id) } }
                pendingDelete = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(FeatureL10n.text(.hostsTheHostCanBeRestoredFromHistory))
        }
        .onChange(of: selectedHostID) { _, id in
            if let host = id.flatMap({ hostID in model.hosts.first { $0.id == hostID } }) {
                tray = nil
                openEditor(HostDraft(host: host))
            } else {
                editorDraft = nil
            }
        }
        .sheet(item: $helperHost) { host in
            HelperInstallSheet(host: host, reinstall: model.helperIsInstalled(host.id))
        }
    }

    private var hostSortBinding: Binding<HostListSort> {
        Binding(get: { hostListPreferences.sort }, set: { hostListPreferences.sort = $0 })
    }

    private var hostGroupsBinding: Binding<Bool> {
        Binding(get: { hostListPreferences.groupsEnabled }, set: { hostListPreferences.groupsEnabled = $0 })
    }

    private var hostGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hostGroups) { group in
                    if !group.title.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if collapsedHostGroups.contains(group.id) {
                                    collapsedHostGroups.remove(group.id)
                                } else {
                                    collapsedHostGroups.insert(group.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsedHostGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                Text(group.title)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }

                    if !collapsedHostGroups.contains(group.id) {
                        LazyVGrid(columns: hostGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                            ForEach(group.hosts) { host in
                                hostCard(host)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("hosts-list")
    }

    private func hostCard(_ host: HostProfile) -> some View {
        HostCard(
            host: host,
            username: resolvedUsername(for: host),
            phase: model.connectionPhase(for: host.id),
            isSelected: selectedHostID == host.id
        )
        .tag(host.id)
        .onTapGesture { selectedHostID = host.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard model.capabilities.externalTerminal else { return }
            Task { await model.connect(host, with: .terminal) }
        })
        .contextMenu {
            if model.helperIsInstalled(host.id), !model.isHelperOnline(host.id) {
                Button(FeatureL10n.text(.helperReinstall), systemImage: "arrow.clockwise") {
                    helperHost = host
                }
            }
            if model.helperIsInstalled(host.id) {
                Button(FeatureL10n.text(.serverSettingsOpen), systemImage: "slider.horizontal.3") {
                    model.presentServerSettings(host)
                }
            } else {
                Button(FeatureL10n.text(.helperInstall), systemImage: "shippingbox") {
                    helperHost = host
                }
            }
            Divider()
            if model.capabilities.externalTerminal {
                Menu(FeatureL10n.text(.hostsConnectWith)) {
                    ForEach(model.terminalApplications) { terminal in
                        Button(terminal.displayName) { Task { await model.connect(host, with: terminal) } }
                    }
                }
                if !model.connectionPhase(for: host.id).isDisconnected {
                    Button(FeatureL10n.text(.featureHostEditorDisconnect), systemImage: "xmark.circle") {
                        Task { await model.disconnect(host) }
                    }
                }
                Divider()
            }
            Button(FeatureL10n.text(.hostsEdit)) { openEditor(HostDraft(host: host)) }
            if model.capabilities.externalFileAccess {
                Button(FeatureL10n.text(.hostsExportToOpenssh)) { openExporter(host) }
            }
            Button(FeatureL10n.text(.hostsArchive), role: .destructive) { pendingDelete = host }
        }
    }

    private func closeInspector() {
        selectedHostID = nil
        editorDraft = nil
        exportHost = nil
        isImportingOpenSSHHost = false
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

    private func openEditor(_ draft: HostDraft, importingFromOpenSSH: Bool = false) {
        tray = nil
        editorSessionID = UUID()
        exportHost = nil
        isImportingOpenSSHHost = importingFromOpenSSH
        editorDraft = draft
    }

    private func openExporter(_ host: HostProfile) {
        closeInspector()
        DispatchQueue.main.async {
            exportHost = host
        }
    }

    private func hostPicker(_ tray: CatalogTray) -> some View {
        let archive = tray == .archive
        return CatalogPickerPanel(
            title: archive ? FeatureL10n.text(.actionArchive) : sourceTitle(tray),
            subtitle: FeatureL10n.text(archive ? .catalogChooseArchive : .catalogChooseImport),
            records: hostPicks(tray),
            isLoading: isLoading(tray),
            primaryTitle: FeatureL10n.text(archive ? .catalogRestore : .actionImport),
            destructiveTitle: archive ? FeatureL10n.text(.catalogDelete) : nil,
            emptyTitle: FeatureL10n.text(archive ? .featureArchiveArchiveIsEmpty : .catalogNothingToImport),
            selection: $traySelection,
            isWorking: isImportingTray,
            onPrimary: { Task { await applyHostTray(tray, purge: false) } },
            onDestructive: { Task { await applyHostTray(tray, purge: true) } },
            onClose: closeInspector
        )
    }

    private func sourceTitle(_ tray: CatalogTray) -> String {
        guard case .source(let id) = tray else { return FeatureL10n.text(.actionImport) }
        return model.importSources.first { $0.id == id }?.displayName ?? FeatureL10n.text(.actionImport)
    }

    private func isLoading(_ tray: CatalogTray) -> Bool {
        guard case .source(let id) = tray else { return false }
        return model.loadingImportSourceIDs.contains(id) || (id == ExternalImportSourceKind.openSSH.rawValue && model.isScanningOpenSSH)
    }

    private func hostPicks(_ tray: CatalogTray) -> [CatalogPick] {
        switch tray {
        case .archive:
            return model.archivedHosts.map { host in
                CatalogPick(
                    id: host.id.uuidString,
                    title: host.displayName,
                    subtitle: "\(resolvedUsername(for: host))@\(host.hostname):\(host.port)",
                    symbol: "server.rack"
                )
            }
        case .source(let id):
            guard let source = model.importSources.first(where: { $0.id == id }) else { return [] }
            if source.kind == .openSSH {
                return model.openSSH.hosts.filter { $0.status == .available }.map { host in
                    CatalogPick(
                        id: "openssh|\(host.id)",
                        title: host.alias,
                        subtitle: "\(host.username)@\(host.hostname):\(host.port)",
                        symbol: "server.rack"
                    )
                }
            }
            return (model.externalImportBundles[id]?.hosts ?? []).map { host in
                CatalogPick(
                    id: "bundle|\(host.id)",
                    title: host.label,
                    subtitle: "\(host.hostname):\(host.port)",
                    symbol: "server.rack"
                )
            }
        }
    }

    private func applyHostTray(_ tray: CatalogTray, purge: Bool) async {
        guard !isImportingTray else { return }
        isImportingTray = true
        defer { isImportingTray = false }
        let chosen = traySelection
        switch tray {
        case .archive:
            for id in chosen {
                guard let uuid = UUID(uuidString: id) else { continue }
                let saved = purge ? await model.purgeHost(id: uuid) : await model.restoreHost(id: uuid)
                if saved { traySelection.remove(id) }
            }
        case .source(let sourceID):
            guard let source = model.importSources.first(where: { $0.id == sourceID }) else { return }
            model.suppressesImportAnnouncements = true
            defer { model.suppressesImportAnnouncements = false }
            if source.kind == .openSSH {
                for host in model.openSSH.hosts where chosen.contains("openssh|\(host.id)") {
                    if await model.importHost(host, credentialIDs: []) { traySelection.remove("openssh|\(host.id)") }
                }
            } else if let bundle = model.externalImportBundles[sourceID] {
                for host in bundle.hosts where chosen.contains("bundle|\(host.id)") {
                    let draft = model.externalHostDraft(host, in: bundle)
                    if await model.importExternalHost(host, from: bundle, editedDraft: draft) {
                        traySelection.remove("bundle|\(host.id)")
                    }
                }
            }
        }
    }

    private func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return FeatureL10n.text(.identityUnavailable) }
        return model.identities.first { $0.id == id }?.username ?? "Unavailable identity"
    }

}
