import SwiftUI

enum ServerSettingsPane: Hashable {
    case tasks
    case services
    case firewall
}

enum ServerSettingsSort: Hashable {
    case name
    case lastRun
}

struct ServerSettingsChrome {
    var search: [ServerSettingsPane: String] = [:]
    var grouped: [ServerSettingsPane: Bool] = [:]
    var taskSort: ServerSettingsSort = .name
    var hideSystemTasks = true
}

/// Keeps Tasks, Services, and Firewall mounted so switching tabs does not reset them.
struct ServerSettingsPage: View {
    let hostID: UUID
    let pane: ServerSettingsPane
    @Binding var search: String
    var grouped: Bool
    var taskSort: ServerSettingsSort
    var hideSystemTasks: Bool
    @Binding var isCreatingTask: Bool

    var body: some View {
        ZStack {
            TasksPage(hostID: hostID, search: $search, grouped: grouped, taskSort: taskSort, hideSystemTasks: hideSystemTasks, isCreating: $isCreatingTask)
                .opacity(pane == .tasks ? 1 : 0)
                .allowsHitTesting(pane == .tasks)
                .accessibilityHidden(pane != .tasks)
            if pane != .tasks {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
