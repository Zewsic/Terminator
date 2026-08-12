import SwiftData

public enum TerminatorSchema {
    public static let version1 = Schema([
        HostRecord.self,
        CredentialRecord.self,
        ChangeRecord.self,
    ])

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Terminator",
            schema: version1,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )
        return try ModelContainer(for: version1, configurations: [configuration])
    }
}
