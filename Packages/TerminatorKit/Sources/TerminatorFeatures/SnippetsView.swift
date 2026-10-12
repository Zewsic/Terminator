import SwiftUI
import TerminatorCore

struct SnippetsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var search = ""
    @State private var editorDraft: SnippetDraft?
    @State private var editorSessionID = UUID()
    @State private var preferences = SnippetListPreferences.shared
    @State private var collapsedGroups: Set<String> = []
    @State private var tray: CatalogTray?
    @State private var traySelection: Set<String> = []
    @State private var isImportingTray = false
    @State private var pendingArchive: SnippetProfile?
    @State private var executeSnippet: SnippetProfile?

    private struct SnippetListGroup: Identifiable {
        let id: String
        let title: String
        let snippets: [SnippetProfile]
    }

    private var filtered: [SnippetProfile] {
        let terms = HostCatalogSearch.terms(in: search)
        guard !terms.isEmpty else { return model.snippets }
        return model.snippets.filter { snippet in
            let values = [snippet.name, snippet.notes, snippet.group ?? "", snippet.script] + snippet.tags
            return terms.allSatisfy { term in
                values.contains { $0.localizedCaseInsensitiveContains(term) }
            }
        }
    }

    private var groups: [SnippetListGroup] {
        let ordered = preferences.sorted(filtered)
        if !preferences.groupsEnabled {
            return [.init(id: "__flat", title: "", snippets: ordered)]
        }
        let grouped = Dictionary(grouping: ordered) { snippet -> String? in
            let group = snippet.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return group.isEmpty ? nil : group
        }
        var result: [SnippetListGroup] = []
        if let ungrouped = grouped[nil], !ungrouped.isEmpty {
            result.append(.init(id: "__catalog", title: FeatureL10n.text(.hostsCatalog), snippets: ungrouped))
        }
        result.append(contentsOf: grouped.compactMap { name, snippets -> SnippetListGroup? in
            guard let name else { return nil }
            return .init(id: "group:\(name)", title: name, snippets: snippets)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        return result
    }

    var body: some View {
        InspectorLayout(content: {
            VStack(spacing: 0) {
                CatalogImportBanner(hint: .snippetsImportBanner, allowsOpenSSH: false) { openTray(.source($0.id)) }
                if model.snippets.isEmpty {
                    ContentUnavailableView {
                        Label(FeatureL10n.text(.snippetEmpty), systemImage: "curlybraces")
                    } description: {
                        Text(FeatureL10n.text(.snippetEmptyDescription))
                    } actions: {
                        Button(FeatureL10n.text(.snippetAdd), systemImage: "plus") { openEditor(SnippetDraft()) }
                            .emptyCatalogAddStyle()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    snippetList
                }
            }
        }, inspector: {
            if let tray {
                snippetPicker(tray)
            } else if let editorDraft {
                SnippetEditor(draft: editorDraft, onSave: saveDraft)
                    .id(editorSessionID)
            }
        }, inspectorWidth: tray == nil ? 540 : InspectorMetrics.compactWidth,
           isInspectorPresented: tray != nil || editorDraft != nil,
           onContentInteraction: { closeInspector() })
        .navigationTitle(FeatureL10n.text(.sectionSnippets))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Menu {
                    Picker(FeatureL10n.text(.hostsSort), selection: sortBinding) {
                        Text(FeatureL10n.text(.hostsSortName)).tag(SnippetListSort.name)
                        Text(FeatureL10n.text(.snippetSortLastUsage)).tag(SnippetListSort.lastUsage)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Toggle(FeatureL10n.text(.snippetGroup), isOn: groupsBinding)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(FeatureL10n.text(.hostsSort))
            }
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.snippetSearch))
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(FeatureL10n.text(.snippetAdd), systemImage: "plus") { openEditor(SnippetDraft()) }
                    .accessibilityIdentifier("add-snippet")
                ExternalImportMenu(allowsOpenSSH: false) { openTray($0) }
                    .accessibilityIdentifier("import-snippets")
            }
        }
        .confirmationDialog(
            FeatureL10n.text(.snippetArchiveConfirm),
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.hostsArchive), role: .destructive) {
                if let pendingArchive { Task { await model.deleteSnippet(id: pendingArchive.id) } }
                pendingArchive = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingArchive = nil }
        } message: {
            Text(FeatureL10n.text(.snippetArchiveMessage))
        }
        .sheet(item: $executeSnippet) { snippet in
            HostPickerSheet(title: snippet.name, actionTitle: FeatureL10n.text(.snippetExecute)) { host in
                await model.executeSnippet(snippet, on: host)
            }
        }
    }

    private var sortBinding: Binding<SnippetListSort> {
        Binding(get: { preferences.sort }, set: { preferences.sort = $0 })
    }

    private var groupsBinding: Binding<Bool> {
        Binding(get: { preferences.groupsEnabled }, set: { preferences.groupsEnabled = $0 })
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private var snippetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    if !group.title.isEmpty {
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
                    }
                    if !collapsedGroups.contains(group.id) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                            ForEach(group.snippets) { snippet in
                                snippetCard(snippet)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func snippetCard(_ snippet: SnippetProfile) -> some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            Image(systemName: "curlybraces")
                .font(.system(size: 14, weight: .bold))
                .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    OverflowingTagLine(tags: snippet.tags)
                    Spacer(minLength: 0)
                }
                Text(snippet.script.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
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
            if editorDraft?.id == snippet.id {
                RoundedRectangle(cornerRadius: HostCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
            }
        }
        .onTapGesture { openEditor(SnippetDraft(snippet: snippet)) }
        .contextMenu {
            Button(FeatureL10n.text(.snippetExecute), systemImage: "play") { executeSnippet = snippet }
            Button(FeatureL10n.text(.hostsEdit), systemImage: "pencil") { openEditor(SnippetDraft(snippet: snippet)) }
            Button(FeatureL10n.text(.snippetDuplicate), systemImage: "plus.square.on.square") {
                openEditor(SnippetDraft(snippet: snippet).duplicate())
            }
            Button(FeatureL10n.text(.snippetCopy), systemImage: "doc.on.doc") { copyToPasteboard(snippet.script) }
            Button(FeatureL10n.text(.hostsArchive), systemImage: "archivebox", role: .destructive) { pendingArchive = snippet }
        }
    }

    private func saveDraft(_ draft: SnippetDraft) async -> SnippetProfile? {
        let saved = await model.saveSnippet(draft)
        if let saved { editorDraft = SnippetDraft(snippet: saved) }
        return saved
    }

    private func closeInspector() {
        editorDraft = nil
        tray = nil
        traySelection = []
    }

    private func openEditor(_ draft: SnippetDraft) {
        tray = nil
        editorSessionID = UUID()
        editorDraft = draft
    }

    private func openTray(_ next: CatalogTray) {
        closeInspector()
        traySelection = []
        tray = next
        guard case .source(let id) = next,
              let source = model.importSources.first(where: { $0.id == id }) else { return }
        Task { await model.loadImportSource(source) }
    }

    private func snippetPicker(_ tray: CatalogTray) -> some View {
        let archive = tray == .archive
        return CatalogPickerPanel(
            title: archive ? FeatureL10n.text(.actionArchive) : sourceTitle(tray),
            subtitle: FeatureL10n.text(archive ? .catalogChooseArchive : .catalogChooseImport),
            records: picks(tray),
            isLoading: isLoading(tray),
            primaryTitle: FeatureL10n.text(archive ? .catalogRestore : .actionImport),
            destructiveTitle: archive ? FeatureL10n.text(.catalogDelete) : nil,
            emptyTitle: FeatureL10n.text(archive ? .featureArchiveArchiveIsEmpty : .catalogNothingToImport),
            selection: $traySelection,
            isWorking: isImportingTray,
            onPrimary: { Task { await apply(tray, purge: false) } },
            onDestructive: { Task { await apply(tray, purge: true) } },
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

    private func picks(_ tray: CatalogTray) -> [CatalogPick] {
        switch tray {
        case .archive:
            return model.archivedSnippets.map { snippet in
                CatalogPick(id: snippet.id.uuidString, title: snippet.name, subtitle: snippet.group ?? "", symbol: "curlybraces")
            }
        case .source(let id):
            return (model.externalImportBundles[id]?.snippets ?? []).map { snippet in
                CatalogPick(id: "bundle|\(snippet.id)", title: snippet.label, subtitle: snippet.group, symbol: "curlybraces")
            }
        }
    }

    private func apply(_ tray: CatalogTray, purge: Bool) async {
        guard !isImportingTray else { return }
        isImportingTray = true
        defer { isImportingTray = false }
        let chosen = traySelection
        switch tray {
        case .archive:
            for id in chosen {
                guard let uuid = UUID(uuidString: id) else { continue }
                let saved = purge ? await model.purgeSnippet(id: uuid) : await model.restoreSnippet(id: uuid)
                if saved { traySelection.remove(id) }
            }
        case .source(let sourceID):
            guard let source = model.importSources.first(where: { $0.id == sourceID }),
                  let bundle = model.externalImportBundles[sourceID] else { return }
            model.suppressesImportAnnouncements = true
            defer { model.suppressesImportAnnouncements = false }
            for snippet in bundle.snippets where chosen.contains("bundle|\(snippet.id)") {
                if await model.importExternalSnippet(snippet, source: source) {
                    traySelection.remove("bundle|\(snippet.id)")
                }
            }
        }
    }
}
