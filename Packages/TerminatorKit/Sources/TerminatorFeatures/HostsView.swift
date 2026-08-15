import SwiftUI
import TerminatorCore

struct HostsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedHostID: UUID?
    @State private var editorDraft: HostDraft?
    @State private var isImportingOpenSSHHost = false
    @State private var editorSessionID = UUID()
    @State private var pendingDelete: HostProfile?
    @State private var exportHost: HostProfile?
    @State private var collapsedHostGroups: Set<String> = []

    private struct HostListGroup: Identifiable {
        let id: String
        let title: String
        let hosts: [HostProfile]
    }

    private var filteredHosts: [HostProfile] {
        guard !search.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.hostname.localizedCaseInsensitiveContains(search)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
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
            if model.hosts.isEmpty && availableOpenSSHHosts.isEmpty {
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
                    hostList
                }, inspector: {
                    if let editorDraft {
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
                }, isInspectorPresented: editorDraft != nil || exportHost != nil, onContentInteraction: {
                    closeInspector()
                })
            }
        }
        .navigationTitle(FeatureL10n.text(.overviewHosts))
        .searchable(text: $search, prompt: FeatureL10n.text(.hostsSearchHosts))
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItemGroup {
                Button(FeatureL10n.text(.hostsAddHost), systemImage: "plus") { openEditor(HostDraft()) }
                    .accessibilityIdentifier("add-host")
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
        .onChange(of: isSearchFocused) { _, isFocused in
            if isFocused { closeInspector() }
        }
    }

    private var hostList: some View {
        List(selection: $selectedHostID) {
            ForEach(hostGroups) { group in
                Section {
                    if !collapsedHostGroups.contains(group.id) {
                        ForEach(group.hosts) { host in
                            hostRow(host)
                        }
                    }
                } header: {
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
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.capabilities.externalFileAccess, !availableOpenSSHHosts.isEmpty {
                Section {
                    ForEach(availableOpenSSHHosts) { host in
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(host.alias).fontWeight(.medium)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                openDiscoveredHost(host)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                openDiscoveredHost(host)
                            }
                        }
                    }
                } header: {
                    Text(FeatureL10n.text(.hostsAvailableFromOpenssh))
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 360)
        .accessibilityIdentifier("hosts-list")
    }

    private func hostRow(_ host: HostProfile) -> some View {
        HostRow(host: host, username: resolvedUsername(for: host), phase: model.connectionPhase(for: host.id))
            .tag(host.id)
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

    private func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return FeatureL10n.text(.identityUnavailable) }
        return model.identities.first { $0.id == id }?.username ?? "Unavailable identity"
    }

}
