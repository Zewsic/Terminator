import SwiftUI
import TerminatorCore

public struct RootView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var isArchivePresented = false

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
            .navigationTitle(FeatureL10n.text(.rootTerminator))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .accessibilityIdentifier("main-sidebar")
        } detail: {
            content
        }
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
        Section(FeatureL10n.text(.rootWorkspace)) {
            selectableSidebarRow(.overview, buttons: buttons)
            selectableSidebarRow(.hosts, buttons: buttons)
            selectableSidebarRow(.tunnels, buttons: buttons)
        }

        Section(FeatureL10n.text(.rootInfrastructure)) {
            selectableSidebarRow(.containers, buttons: buttons)
        }

        Section(FeatureL10n.text(.rootLibrary)) {
            selectableSidebarRow(.credentials, buttons: buttons)
            selectableSidebarRow(.snippets, buttons: buttons)
            selectableSidebarRow(.history, buttons: buttons)
            selectableSidebarRow(.logs, buttons: buttons)
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
            CredentialsView(isArchivePresented: $isArchivePresented)
        case .history:
            HistoryView()
        case .logs:
            SessionLogsView()
        case .containers:
            ContainersView()
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
