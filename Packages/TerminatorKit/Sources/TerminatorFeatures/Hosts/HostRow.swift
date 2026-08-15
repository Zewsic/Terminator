import SwiftUI
import TerminatorCore

struct HostRow: View {
    let host: HostProfile
    let username: String
    let phase: SSHConnectionPhase
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).fontWeight(.medium)
                Text("\(username)@\(host.hostname):\(host.port)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !host.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(host.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if host.tags.count > 3 {
                        Text("+\(host.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch phase {
        case .connected: .green
        case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}
