import Foundation

public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(message: String)
}

public protocol SSHService: Sendable {
    func connect(to host: HostProfile) async throws
    func disconnect(hostID: UUID) async
    func state(for hostID: UUID) async -> SSHConnectionState
}

public struct ContainerSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var endpointName: String

    public init(id: String, name: String, image: String, state: String, endpointName: String) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.endpointName = endpointName
    }
}

public protocol DockerService: Sendable {
    func listContainers() async throws -> [ContainerSummary]
    func start(containerID: String) async throws
    func stop(containerID: String) async throws
}

public struct TerminalSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public protocol TerminalSession: Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(to size: TerminalSize) async throws
    func close() async
}
