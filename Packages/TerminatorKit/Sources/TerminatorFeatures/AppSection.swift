import TerminatorCore

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case hosts
    case tunnels
    case containers
    case tasks
    case credentials
    case snippets
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hosts: FeatureL10n.text(.sectionHosts)
        case .tunnels: FeatureL10n.text(.sectionTunnels)
        case .containers: FeatureL10n.text(.sectionServices)
        case .credentials: FeatureL10n.text(.sectionCredentials)
        case .snippets: FeatureL10n.text(.sectionSnippets)
        case .logs: FeatureL10n.text(.sectionLogs)
        case .tasks: FeatureL10n.text(.sectionTasks)
        }
    }

    public var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .tunnels: "arrow.left.arrow.right"
        case .containers: "shippingbox"
        case .credentials: "key"
        case .snippets: "curlybraces"
        case .logs: "text.document"
        case .tasks: "checklist"
        }
    }
    public static func available(for capabilities: AppCapabilities) -> [AppSection] { allCases }

    public static let showServicesTabKey = "sidebar.showServicesTab"
    public static let showTasksTabKey = "sidebar.showTasksTab"
}
