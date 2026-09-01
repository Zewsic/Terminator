import TerminatorCore

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case hosts
    case tunnels
    case services
    case credentials
    case snippets
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hosts: FeatureL10n.text(.sectionHosts)
        case .tunnels: FeatureL10n.text(.sectionTunnels)
        case .services: "Services"
        case .credentials: FeatureL10n.text(.sectionCredentials)
        case .snippets: FeatureL10n.text(.sectionSnippets)
        case .logs: FeatureL10n.text(.sectionLogs)
        }
    }

    public var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .tunnels: "arrow.left.arrow.right"
        case .services: "point.3.connected.trianglepath.dotted"
        case .credentials: "key"
        case .snippets: "curlybraces"
        case .logs: "text.document"
        }
    }

    public static func available(for capabilities: AppCapabilities) -> [AppSection] { allCases }
}
