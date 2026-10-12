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
    @State private var servicesPane = ServicesPane.containers
    @AppStorage(AppSection.showServicesTabKey) private var showServicesTab = true
    @AppStorage(AppSection.showTasksTabKey) private var showTasksTab = true
    @Namespace private var sidebarSelectionNamespace

    public init() {}

    public var body: some View {
        @Bindable var model = model

        #if os(macOS)
        ZStack(alignment: .leading) {
            HStack(spacing: isSidebarCollapsed ? 0 : 12) {
                if !isSidebarCollapsed {
                    floatingSidebar(selection: $model.selection)
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
                        Text("Terminator")
                            .font(.system(size: 15, weight: .regular))
                    }
                    .sharedBackgroundVisibility(.hidden)
                    if model.selection == .logs || model.selection == .containers {
                        ToolbarItem(placement: .principal) {
                            sectionSwitcher
                        }
                        .sharedBackgroundVisibility(.hidden)
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
                    floatingSidebar(selection: $model.selection)
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
        .onChange(of: showServicesTab) { _, shown in
            if !shown, model.selection == .containers { model.selection = .hosts }
        }
        .onChange(of: showTasksTab) { _, shown in
            if !shown, model.selection == .tasks { model.selection = .hosts }
        }
        #else
        NavigationSplitView {
            List(sidebarSections, selection: $model.selection) { section in
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
    private func floatingSidebar(
        selection: Binding<AppSection>
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sidebarSections) { section in
                        let isSelected = selection.wrappedValue == section

                        Button {
                            withAnimation(.snappy(duration: 0.26, extraBounce: 0.08)) {
                                selection.wrappedValue = section
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.systemImage)
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 20)

                                Text(section.title)
                                    .font(.body.weight(.medium))

                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .contentShape(.rect(cornerRadius: 14))
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
                                        .matchedGeometryEffect(
                                            id: "sidebar-selection",
                                            in: sidebarSelectionNamespace
                                        )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .hosts:
            HostsView()
        case .tunnels:
            TunnelsView()
        case .containers:
            switch servicesPane {
            case .containers:
                ContainersView()
            case .services:
                PlannedFeatureView(
                    title: FeatureL10n.text(.sectionServices),
                    systemImage: "cylinder.split.1x2",
                    description: FeatureL10n.text(.servicesEmptyDescription)
                )
            }
        case .credentials:
            CredentialsView()
        case .snippets:
            SnippetsView()
        case .logs:
            SessionLogsView(pane: $logsPane)
        case .tasks:
            PlannedFeatureView(
                title: FeatureL10n.text(.sectionTasks),
                systemImage: "checklist",
                description: FeatureL10n.text(.tasksEmptyDescription)
            )
        }
    }

    private var sidebarSections: [AppSection] {
        AppSection.allCases.filter { section in
            switch section {
            case .containers: showServicesTab
            case .tasks: showTasksTab
            default: true
            }
        }
    }

    @ViewBuilder
    private var sectionSwitcher: some View {
        switch model.selection {
        case .logs:
            InspectorSegmentedSelector(
                selection: $logsPane,
                options: [
                    InspectorSelectorOption(value: LogsPane.shell, title: FeatureL10n.text(.logsModeShell)),
                    InspectorSelectorOption(value: LogsPane.events, title: FeatureL10n.text(.logsModeEvents)),
                ]
            )
        case .containers:
            InspectorSegmentedSelector(
                selection: $servicesPane,
                options: [
                    InspectorSelectorOption(value: ServicesPane.containers, title: FeatureL10n.text(.sectionContainers)),
                    InspectorSelectorOption(value: ServicesPane.services, title: FeatureL10n.text(.sectionServices)),
                ]
            )
        default:
            EmptyView()
        }
    }
}

private enum ServicesPane: Hashable {
    case containers
    case services
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
