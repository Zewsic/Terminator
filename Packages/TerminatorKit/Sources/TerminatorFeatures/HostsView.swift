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
    @State private var collapsedHostGroups: Set<String> = []
    private var dismissedHints = DismissedHintsStore.shared
    @State private var pendingExternalHost: ExternalImportHost?
    @State private var pendingExternalBundle: ExternalImportBundle?

    private struct HostListGroup: Identifiable {
        let id: String
        let title: String
        let hosts: [HostProfile]
    }

    private var filteredHosts: [HostProfile] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return model.hosts }

        return model.hosts.filter { host in
            var searchableValues = [
                host.displayName,
                host.hostname,
                resolvedUsername(for: host),
                host.group ?? "",
                host.notes,
            ]
            searchableValues.append(contentsOf: host.tags)

            if let identityID = host.authentication.identityID,
               let identity = model.identities.first(where: { $0.id == identityID }) {
                searchableValues.append(identity.name)
                searchableValues.append(identity.username)
            }

            return terms.allSatisfy { term in
                searchableValues.contains { $0.localizedCaseInsensitiveContains(term) }
            }
        }
    }

    private var selectedHost: HostProfile? { model.hosts.first { $0.id == selectedHostID } }

    private var hostGroups: [HostListGroup] {
        let grouped = Dictionary(grouping: filteredHosts) { host -> String? in
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
        Group {
            if model.hosts.isEmpty && !hasAvailableImports {
                ContentUnavailableView {
                    Label(FeatureL10n.text(.hostsNoHosts), systemImage: "server.rack")
                } description: {
                    Text(FeatureL10n.text(.hostsAddAnSshHostToStartBuilding))
                } actions: {
                    Button(FeatureL10n.text(.hostsAddHost), systemImage: "plus") { openEditor(HostDraft()) }
                        .buttonStyle(.glassProminent).tint(.blue)
                        .accessibilityIdentifier("add-host-empty")
                }
            } else {
                InspectorLayout(content: {
                    VStack(spacing: 0) {
                        CatalogImportBanner(hint: .hostsImportBanner)
                        hostList
                    }
                }, inspector: {
                    if let editorDraft {
                        HostEditor(draft: editorDraft, explicitImport: isImportingOpenSSHHost) { savedDraft in
                            if let host = pendingExternalHost, let bundle = pendingExternalBundle {
                                return await model.importExternalHost(host, from: bundle, editedDraft: savedDraft)
                            }
                            return await model.saveHost(savedDraft)
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
                }, isInspectorPresented: editorDraft != nil || exportHost != nil, onContentInteraction: {
                    closeInspector()
                })
            }
        }
        .navigationTitle(FeatureL10n.text(.overviewHosts))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.hostsSearchHosts))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(FeatureL10n.text(.hostsAddHost), systemImage: "plus") { openEditor(HostDraft()) }
                    .accessibilityIdentifier("add-host")
                ExternalImportMenu(hint: .hostsImportBanner)
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
                openEditor(HostDraft(host: host))
            } else {
                editorDraft = nil
            }
        }
    }

    private var hostGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hostGroups) { group in
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

                    if !collapsedHostGroups.contains(group.id) {
                        LazyVGrid(columns: hostGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                            ForEach(group.hosts) { host in
                                hostCard(host)
                            }
                        }
                    }
                }
                if model.capabilities.externalFileAccess {
                    LazyVGrid(columns: hostGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                        ForEach(availableOpenSSHHosts) { host in
                            importHostCard(
                                title: host.alias,
                                subtitle: "\(host.username)@\(host.hostname):\(host.port)",
                                caption: FeatureL10n.text(.hostsOpenssh)
                            )
                            .onTapGesture { openDiscoveredHost(host) }
                            .contextMenu {
                                Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                    openDiscoveredHost(host)
                                }
                            }
                        }
                        ForEach(model.loadedExternalImportBundles, id: \.source.id) { bundle in
                            ForEach(bundle.hosts.filter(matchesSearch)) { host in
                                externalHostRow(host, bundle: bundle)
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
            Task { await model.connectInBackground(host, with: .terminal) }
        })
        .contextMenu {
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
        pendingExternalHost = nil
        pendingExternalBundle = nil
    }

    private func openEditor(_ draft: HostDraft, importingFromOpenSSH: Bool = false) {
        editorSessionID = UUID()
        exportHost = nil
        isImportingOpenSSHHost = importingFromOpenSSH
        editorDraft = draft
    }

    private var availableOpenSSHHosts: [DiscoveredSSHHost] {
        model.openSSH.hosts.filter { host in
            host.status == .available && (
                search.isEmpty
                    || host.alias.localizedCaseInsensitiveContains(search)
                    || host.hostname.localizedCaseInsensitiveContains(search)
                    || host.username.localizedCaseInsensitiveContains(search)
            )
        }
    }

    private func openExporter(_ host: HostProfile) {
        closeInspector()
        DispatchQueue.main.async {
            exportHost = host
        }
    }

    private func openDiscoveredHost(_ discovered: DiscoveredSSHHost) {
        let existing = model.matchingHost(for: discovered)
        var draft = HostDraft(host: existing)
        draft.displayName = discovered.alias
        draft.hostname = discovered.hostname
        draft.port = discovered.port
        if existing == nil || !draft.usesIdentity {
            draft.usesIdentity = false
            draft.identityID = nil
            draft.username = discovered.username
        }
        closeInspector()
        DispatchQueue.main.async {
            if let existing {
                selectedHostID = existing.id
            }
            openEditor(draft, importingFromOpenSSH: true)
        }
    }

    private var showsImportBanner: Bool {
        !dismissedHints.isDismissed(.hostsImportBanner)
            && model.capabilities.externalFileAccess
            && !model.importSources.isEmpty
    }

    private var hasAvailableImports: Bool {
        showsImportBanner || !availableOpenSSHHosts.isEmpty
            || model.loadedExternalImportBundles.contains { !$0.hosts.filter(matchesSearch).isEmpty }
    }

    private func matchesSearch(_ host: ExternalImportHost) -> Bool {
        search.isEmpty || host.label.localizedCaseInsensitiveContains(search)
            || host.hostname.localizedCaseInsensitiveContains(search)
            || host.group.localizedCaseInsensitiveContains(search)
    }

    private func externalHostRow(_ host: ExternalImportHost, bundle: ExternalImportBundle) -> some View {
        Button {
            var draft = model.externalHostDraft(host, in: bundle)
            if let existing = model.hosts.first(where: { $0.hostname == host.hostname && $0.port == host.port }) {
                draft.id = existing.id
            }
            closeInspector()
            pendingExternalHost = host
            pendingExternalBundle = bundle
            isImportingOpenSSHHost = true
            editorSessionID = UUID()
            editorDraft = draft
        } label: {
            importHostCard(
                title: host.label,
                subtitle: "\(host.hostname):\(host.port)",
                caption: bundle.source.displayName
            )
        }
        .buttonStyle(.plain)
    }

    private func importHostCard(title: String, subtitle: String, caption: String) -> some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(HostCardMetrics.iconInset)
        .frame(width: HostCardMetrics.width, height: HostCardMetrics.height, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
    }

    private func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return FeatureL10n.text(.identityUnavailable) }
        return model.identities.first { $0.id == id }?.username ?? "Unavailable identity"
    }

}
