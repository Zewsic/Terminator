import SwiftUI
import TerminatorCore
#if os(macOS)
import AppKit
#endif

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var isSidebarCollapsed = false
    @State private var isSidebarOverlayPresented = false
    @State private var logsPane = LogsPane.shell
    @State private var sectionShown: AppSection = .hosts
    @State private var serverPanes: [UUID: ServerSettingsPane] = [:]
    @State private var serverChrome: [UUID: ServerSettingsChrome] = [:]
    @State private var taskCreateHost: UUID?
    @Namespace private var sidebarSelectionNamespace

    public init() {}

    public var body: some View {
        @Bindable var model = model

        #if os(macOS)
        ZStack(alignment: .leading) {
            HStack(spacing: isSidebarCollapsed ? 0 : 12) {
                if !isSidebarCollapsed {
                    floatingSidebar()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                NavigationStack {
                    content
                }
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: toggleSidebar) {
                            Image(systemName: "sidebar.leading")
                                .imageScale(.medium)
                        }
                        .help(isSidebarCollapsed ? "Keep Sidebar Open" : "Hide Sidebar")
                        .accessibilityIdentifier("sidebar-toggle")
                    }

                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 8) {
                            Text("Terminator")
                                .font(.system(size: 15, weight: .regular))
                            if let serverSettingsID {
                                serverSettingsSwitcher(serverSettingsID)
                            }
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    if model.selection == .section(.logs) {
                        ToolbarItem(placement: .principal) {
                            sectionSwitcher
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    if let serverSettingsID {
                        let pane = serverPanes[serverSettingsID] ?? .tasks
                        ToolbarSpacer(.flexible)
                        if pane == .tasks {
                            ToolbarItem {
                                Button(FeatureL10n.text(.actionRefresh), systemImage: "arrow.clockwise") {
                                    Task { await model.loadServerTasks(hostID: serverSettingsID) }
                                }
                                .disabled(model.serverTasksLoading.contains(serverSettingsID))
                                .help(FeatureL10n.text(.actionRefresh))
                            }
                            ToolbarSpacer(.fixed)
                        }
                        ToolbarItem {
                            serverSettingsSortMenu(serverSettingsID, pane)
                        }
                        ToolbarItem {
                            ToolbarSearchField(
                                text: serverSearchBinding(serverSettingsID, pane),
                                prompt: FeatureL10n.text(serverSearchPrompt(pane))
                            )
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed)
                        ToolbarItem {
                            Button(FeatureL10n.text(serverAddTitle(pane)), systemImage: "plus") {
                                if pane == .tasks { taskCreateHost = serverSettingsID }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            if isSidebarCollapsed {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .onHover { hovering in
                        guard hovering else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            isSidebarOverlayPresented = true
                        }
                }

                if isSidebarOverlayPresented {
                    floatingSidebar()
                        .padding(.leading, 10)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .onHover { hovering in
                            guard !hovering else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                isSidebarOverlayPresented = false
                            }
                        }
                        .zIndex(1)
                }
            }
        }
        .background(WindowBackgroundShapeStyle.windowBackground)
        .animation(.snappy(duration: 0.24), value: isSidebarCollapsed)
        .modifier(RootPresentations())
        .onChange(of: model.hosts.map(\.id)) { _, _ in
            model.pruneServerSettings()
        }
        #else
        NavigationSplitView {
            List(sidebarSections, selection: sectionSelection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle(FeatureL10n.text(.rootTerminator))
            .accessibilityIdentifier("main-sidebar")
        } detail: {
            content
        }
        .modifier(RootPresentations())
        #endif
    }

    #if os(macOS)
    private func floatingSidebar() -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sidebarSections) { section in
                        sidebarRow(
                            title: section.title,
                            systemImage: section.systemImage,
                            isSelected: model.selection == .section(section)
                        ) {
                            sectionShown = section
                            model.selection = .section(section)
                        }
                    }
                    if !model.openServerSettings.isEmpty {
                        Text(FeatureL10n.text(.serverSettingsTitle))
                            .padding(.top, 10)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                        ForEach(model.openServerSettings, id: \.self) { id in
                            serverSettingsRow(id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("main-sidebar")

            Button(action: openLocalTerminal) {
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer")
                    Text(FeatureL10n.text(.sectionLocalTerminal))
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.blue)
            .controlSize(.large)
            .help(FeatureL10n.text(.sectionLocalTerminal))
            .accessibilityIdentifier("local-terminal")
            .accessibilityLabel(FeatureL10n.text(.sectionLocalTerminal))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
        .frame(width: 214)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func sidebarRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        sidebarChrome(title: title, isSelected: isSelected, action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20)
        } trailing: {
            EmptyView()
        }
    }

    private func serverSettingsRow(_ id: UUID) -> some View {
        let selected = model.selection == .serverSettings(id)
        return sidebarChrome(title: serverSettingsName(id), isSelected: selected) {
            model.selection = .serverSettings(id)
        } icon: {
            HostOSIcon(osID: model.hosts.first { $0.id == id }?.detectedOS?.id, side: 18)
                .frame(width: 20)
        } trailing: {
            Button {
                let wasSelected = model.selection == .serverSettings(id)
                model.closeServerSettings(id)
                if wasSelected { sectionShown = .hosts }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(selected ? Color.white.opacity(0.92) : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(FeatureL10n.text(.actionClose))
            .accessibilityLabel(FeatureL10n.text(.actionClose))
        }
    }

    private func sidebarChrome<Icon: View, Trailing: View>(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.26, extraBounce: 0.08)) {
                    action()
                }
            } label: {
                HStack(spacing: 10) {
                    icon()
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.96),
                                Color.accentColor.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                    }
                    .shadow(color: Color.accentColor.opacity(0.22), radius: 5, y: 2)
                    .matchedGeometryEffect(id: "sidebar-selection", in: sidebarSelectionNamespace)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func serverSettingsName(_ id: UUID) -> String {
        guard let host = model.hosts.first(where: { $0.id == id }) else { return "" }
        let name = host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? host.hostname : name
    }

    private func openLocalTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        Task {
            try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            isSidebarCollapsed.toggle()
            isSidebarOverlayPresented = false
        }
    }
    #endif

    private var sectionSelection: Binding<AppSection?> {
        Binding(
            get: {
                if case .section(let section) = model.selection { return section }
                return nil
            },
            set: { section in
                guard let section else { return }
                sectionShown = section
                model.selection = .section(section)
            }
        )
    }

    private var showsSection: Bool {
        if case .section = model.selection { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if showsSection {
                sectionPage(sectionShown)
            }
            ForEach(model.openServerSettings, id: \.self) { id in
                let shown = model.selection == .serverSettings(id)
                ServerSettingsPage(
                    hostID: id,
                    pane: serverPanes[id] ?? .tasks,
                    search: serverSearchBinding(id, .tasks),
                    grouped: serverChrome[id]?.grouped[.tasks] ?? true,
                    taskSort: serverChrome[id]?.taskSort ?? .name,
                    hideSystemTasks: serverChrome[id]?.hideSystemTasks ?? true,
                    isCreatingTask: Binding(
                        get: { taskCreateHost == id },
                        set: { shown in
                            if shown { taskCreateHost = id }
                            else if taskCreateHost == id { taskCreateHost = nil }
                        }
                    )
                )
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: AppSection) -> some View {
        switch section {
        case .hosts:
            HostsView()
        case .tunnels:
            TunnelsView()
        case .containers:
            ContainersView()
        case .credentials:
            CredentialsView()
        case .snippets:
            SnippetsView()
        case .logs:
            SessionLogsView(pane: $logsPane)
        }
    }

    private var sidebarSections: [AppSection] { AppSection.allCases }

    @ViewBuilder
    private var sectionSwitcher: some View {
        InspectorSegmentedSelector(
            selection: $logsPane,
            options: [
                InspectorSelectorOption(value: LogsPane.shell, title: FeatureL10n.text(.logsModeShell)),
                InspectorSelectorOption(value: LogsPane.events, title: FeatureL10n.text(.logsModeEvents)),
            ]
        )
    }

    private var serverSettingsID: UUID? {
        if case .serverSettings(let id) = model.selection { return id }
        return nil
    }

    private func serverSearchPrompt(_ pane: ServerSettingsPane) -> FeatureString {
        switch pane {
        case .tasks: .serverSettingsSearchTasks
        case .services: .serverSettingsSearchServices
        case .firewall: .serverSettingsSearchFirewall
        }
    }

    private func serverAddTitle(_ pane: ServerSettingsPane) -> FeatureString {
        switch pane {
        case .tasks: .serverSettingsAddTask
        case .services: .serverSettingsAddService
        case .firewall: .serverSettingsAddRule
        }
    }

    private func serverGroupTitle(_ pane: ServerSettingsPane) -> FeatureString {
        switch pane {
        case .tasks: .serverSettingsGroupTasks
        case .services: .serverSettingsGroupServices
        case .firewall: .serverSettingsGroupRules
        }
    }

    private func serverSearchBinding(_ id: UUID, _ pane: ServerSettingsPane) -> Binding<String> {
        Binding(
            get: { serverChrome[id]?.search[pane] ?? "" },
            set: { value in
                var chrome = serverChrome[id] ?? ServerSettingsChrome()
                chrome.search[pane] = value
                serverChrome[id] = chrome
            }
        )
    }

    private func serverTaskSortBinding(_ id: UUID) -> Binding<ServerSettingsSort> {
        Binding(
            get: { serverChrome[id]?.taskSort ?? .name },
            set: { value in
                var chrome = serverChrome[id] ?? ServerSettingsChrome()
                chrome.taskSort = value
                serverChrome[id] = chrome
                if value == .lastRun {
                    Task { await model.loadTaskLastRuns(hostID: id) }
                }
            }
        )
    }

    private func hideSystemTasksBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { serverChrome[id]?.hideSystemTasks ?? true },
            set: { value in
                var chrome = serverChrome[id] ?? ServerSettingsChrome()
                chrome.hideSystemTasks = value
                serverChrome[id] = chrome
            }
        )
    }

    private func serverGroupedBinding(_ id: UUID, _ pane: ServerSettingsPane) -> Binding<Bool> {
        Binding(
            get: { serverChrome[id]?.grouped[pane] ?? (pane == .tasks) },
            set: { value in
                var chrome = serverChrome[id] ?? ServerSettingsChrome()
                chrome.grouped[pane] = value
                serverChrome[id] = chrome
            }
        )
    }

    private func serverSettingsSortMenu(_ id: UUID, _ pane: ServerSettingsPane) -> some View {
        Menu {
            Picker(FeatureL10n.text(.hostsSort), selection: serverTaskSortBinding(id)) {
                Text(FeatureL10n.text(.hostsSortName)).tag(ServerSettingsSort.name)
                if pane == .tasks {
                    Text(FeatureL10n.text(.tasksSortLastRun)).tag(ServerSettingsSort.lastRun)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle(FeatureL10n.text(serverGroupTitle(pane)), isOn: serverGroupedBinding(id, pane))
            if pane == .tasks {
                Toggle(FeatureL10n.text(.tasksHideSystem), isOn: hideSystemTasksBinding(id))
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(FeatureL10n.text(.hostsSort))
    }

    private func serverSettingsSwitcher(_ id: UUID) -> some View {
        InspectorSegmentedSelector(
            selection: Binding(
                get: { serverPanes[id] ?? .tasks },
                set: { serverPanes[id] = $0 }
            ),
            options: [
                InspectorSelectorOption(value: ServerSettingsPane.tasks, title: FeatureL10n.text(.serverSettingsTasks)),
                InspectorSelectorOption(value: ServerSettingsPane.services, title: FeatureL10n.text(.serverSettingsServices)),
                InspectorSelectorOption(value: ServerSettingsPane.firewall, title: FeatureL10n.text(.serverSettingsFirewall)),
            ]
        )
    }
}

private struct RootPresentations: ViewModifier {
    @Environment(TerminatorAppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.presentedError != nil },
                    set: { if !$0 { model.dismissPresentedError() } }
                )
            ) {
                Button(FeatureL10n.text(.rootOk)) { model.dismissPresentedError() }
            } message: {
                Text(model.presentedError?.message ?? FeatureL10n.text(.errorUnknown))
            }
            .sheet(item: Binding(
                get: { model.connectionHost },
                set: { if $0 == nil { Task { await model.cancelConnectionPresentation() } } }
            )) { _ in ConnectionSheet() }
    }
}
