import TerminatorCore

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case hosts
    case localTerminal
    case tunnels
    case containers
    case credentials
    case snippets
    case history
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .hosts: "Hosts"
        case .localTerminal: "Local Terminal"
        case .tunnels: "Tunnels"
        case .containers: "Containers"
        case .credentials: "Credentials"
        case .snippets: "Snippets"
        case .history: "History"
        case .logs: "Logs"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .hosts: "server.rack"
        case .localTerminal: "terminal"
        case .tunnels: "arrow.left.arrow.right"
        case .containers: "shippingbox"
        case .credentials: "key"
        case .snippets: "chevron.left.forwardslash.chevron.right"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .logs: "text.document"
        }
    }

    public static func available(for capabilities: AppCapabilities) -> [AppSection] {
        allCases.filter { $0 != .localTerminal || capabilities.localShell }
    }
}
