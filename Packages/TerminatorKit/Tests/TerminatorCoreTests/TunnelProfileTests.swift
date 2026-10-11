import Foundation
import Testing
@testable import TerminatorCore

@Suite("Tunnel profiles")
struct TunnelProfileTests {
    @Test("Names the selected hosts in tags and clears automatic connect for a remote source")
    func derivedNamesAndAutomaticConnect() throws {
        let database = HostProfile(displayName: "Database", hostname: "10.0.0.8", port: 22, username: "root", group: "Production")
        let bastion = HostProfile(displayName: "Bastion", hostname: "bastion.example", port: 22, username: "admin")
        let tunnel = TunnelProfile(
            displayName: " SQL ",
            kind: .local,
            source: .saved(bastion.id),
            destination: .saved(database.id),
            connectAutomatically: true
        )
        let saved = try tunnel.validated()
        #expect(saved.displayName == "SQL")
        #expect(saved.connectAutomatically == false)
        #expect(saved.derivedTags(in: [database, bastion]) == ["Local", "Bastion", "Database"])
        #expect(saved.groupName(in: [database, bastion]) == "Production")
    }

    @Test("Rejects this Mac as host B")
    func rejectsLocalDestination() {
        let tunnel = TunnelProfile(displayName: "Loop", destination: .thisMac)
        #expect(throws: TunnelValidationError.destinationIsLocal) { try tunnel.validated() }
    }

    @Test("Plans a local listener on this Mac and a remote listener between two hosts")
    func forwardPlans() throws {
        let origin = HostProfile(displayName: "Origin", hostname: "10.0.0.2", username: "root")
        let edge = HostProfile(displayName: "Edge", hostname: "10.0.0.3", username: "root")
        let local = try TunnelForwardPlan.make(TunnelProfile(
            displayName: "DB", source: .thisMac, destination: .saved(edge.id), listenPort: 5432, targetPort: 5432
        ))
        guard case .listenLocally(let address, let port, let dial) = local else {
            Issue.record("Expected a local listener")
            return
        }
        #expect(address == "127.0.0.1")
        #expect(port == 5432)
        #expect(dial == .through(.saved(edge.id), address: "127.0.0.1", port: 5432))

        let bridged = try TunnelForwardPlan.make(TunnelProfile(
            displayName: "Bridge",
            source: .saved(origin.id),
            destination: .saved(edge.id)
        ))
        guard case .listenRemotely(let listener, _, _, _) = bridged else {
            Issue.record("Expected a remote listener")
            return
        }
        #expect(listener == .saved(origin.id))
        #expect(throws: TunnelValidationError.dynamicRequiresThisMac) {
            try TunnelForwardPlan.make(TunnelProfile(
                displayName: "SOCKS", kind: .dynamic, source: .saved(origin.id), destination: .saved(edge.id)
            ))
        }
    }

    @Test("Imports a Termius rule onto this Mac and a saved host")
    func importsTermiusRule() throws {
        let saved = HostProfile(displayName: "Office", hostname: "office.example", port: 22, username: "ada")
        let externalHost = ExternalImportHost(id: "host", label: "Office", hostname: "office.example", port: 22)
        let rule = ExternalImportTunnel(
            id: "rule", hostID: "host", label: "Database", kind: .local,
            bindAddress: "127.0.0.1", localPort: 5432, targetHost: "10.1.0.4", targetPort: 5432
        )
        let imported = try TunnelProfile.imported(from: rule, sshHost: externalHost, savedHosts: [saved]).validated()
        #expect(imported.source == .thisMac)
        #expect(imported.destination == .saved(saved.id))
        #expect(imported.listenPort == 5432)
        #expect(imported.targetAddress == "10.1.0.4")
        #expect(imported.connectAutomatically == false)
        #expect(imported.derivedTags(in: [saved]).contains("This Mac"))
        #expect(imported.derivedTags(in: [saved]).contains("Office"))
    }
}
