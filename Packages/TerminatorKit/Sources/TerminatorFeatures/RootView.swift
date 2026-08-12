import SwiftUI
import TerminatorCore

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Group {
                #if os(macOS)
                List(selection: $model.selection) {
                    sidebarSections(buttons: false)
                }
                #else
                List {
                    sidebarSections(buttons: true)
                }
                #endif
            }
            .navigationTitle("Terminator")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .accessibilityIdentifier("main-sidebar")
        } detail: {
            content
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    @ViewBuilder
    private func selectableSidebarRow(_ section: AppSection, buttons: Bool) -> some View {
        if buttons {
            Button {
                model.selection = section
            } label: {
                Label(section.title, systemImage: section.systemImage)
            }
        } else {
            sidebarRow(section)
        }
    }

    @ViewBuilder
    private func sidebarSections(buttons: Bool) -> some View {
        Section("Workspace") {
            selectableSidebarRow(.overview, buttons: buttons)
            selectableSidebarRow(.hosts, buttons: buttons)
            if model.capabilities.localShell {
                selectableSidebarRow(.localTerminal, buttons: buttons)
            }
            selectableSidebarRow(.tunnels, buttons: buttons)
        }

        Section("Infrastructure") {
            selectableSidebarRow(.containers, buttons: buttons)
        }

        Section("Library") {
            selectableSidebarRow(.credentials, buttons: buttons)
            selectableSidebarRow(.snippets, buttons: buttons)
            selectableSidebarRow(.history, buttons: buttons)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .overview:
            OverviewView()
        case .hosts:
            HostsView()
        case .credentials:
            CredentialsView()
        case .history:
            HistoryView()
        case .containers:
            ContainersView()
        case .localTerminal:
            PlannedFeatureView(
                title: "Local Terminal",
                systemImage: "terminal",
                description: "A native PTY-backed terminal will be available in the Direct edition."
            )
        case .tunnels:
            PlannedFeatureView(
                title: "Tunnels",
                systemImage: "arrow.left.arrow.right",
                description: "Saved local, remote, and dynamic SSH port forwards are on the roadmap."
            )
        case .snippets:
            PlannedFeatureView(
                title: "Snippets",
                systemImage: "chevron.left.forwardslash.chevron.right",
                description: "Reusable commands and parameterized snippets are planned."
            )
        }
    }
}
