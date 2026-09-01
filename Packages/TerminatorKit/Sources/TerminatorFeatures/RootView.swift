import SwiftUI
import TerminatorCore

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var isArchivePresented = false
    @State private var isSidebarCollapsed = false
    @State private var isSidebarOverlayPresented = false
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
        .modifier(RootPresentations(isArchivePresented: $isArchivePresented))
        #else
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle(FeatureL10n.text(.rootTerminator))
            .accessibilityIdentifier("main-sidebar")
        } detail: {
            content
        }
        .modifier(RootPresentations(isArchivePresented: $isArchivePresented))
        #endif
    }

    #if os(macOS)
    private func floatingSidebar(
        selection: Binding<AppSection>
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AppSection.allCases) { section in
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
        }
        .frame(width: 214)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
            PlannedFeatureView(
                title: "Tunnels",
                systemImage: "arrow.left.arrow.right",
                description: "Saved local, remote, and dynamic SSH port forwards are on the roadmap."
            )
        case .services:
            ServicesView()
        case .credentials:
            CredentialsView(isArchivePresented: $isArchivePresented)
        case .snippets:
            PlannedFeatureView(
                title: "Snippets",
                systemImage: "chevron.left.forwardslash.chevron.right",
                description: "Reusable commands and parameterized snippets are planned."
            )
        case .logs:
            SessionLogsView()
        }
    }
}

private struct RootPresentations: ViewModifier {
    @Environment(TerminatorAppModel.self) private var model
    @Binding var isArchivePresented: Bool

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
            .sheet(isPresented: $isArchivePresented) { ArchiveView() }
    }
}
