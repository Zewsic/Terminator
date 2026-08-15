import TerminatorCore

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case hosts
    case tunnels
    case containers
    case credentials
    case snippets
    case history
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: FeatureL10n.text(.sectionOverview)
        case .hosts: FeatureL10n.text(.sectionHosts)
        case .tunnels: FeatureL10n.text(.sectionTunnels)
        case .containers: FeatureL10n.text(.sectionContainers)
        case .credentials: FeatureL10n.text(.sectionCredentials)
        case .snippets: FeatureL10n.text(.sectionSnippets)
        case .history: FeatureL10n.text(.sectionHistory)
        case .logs: FeatureL10n.text(.sectionLogs)
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .hosts: "server.rack"
        case .tunnels: "arrow.left.arrow.right"
        case .containers: "shippingbox"
        case .credentials: "key"
        case .snippets: "chevron.left.forwardslash.chevron.right"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .logs: "text.document"
        }
    }

    public static func available(for capabilities: AppCapabilities) -> [AppSection] { allCases }
}
