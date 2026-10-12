import SwiftUI
import TerminatorCore

enum HostCardMetrics {
    static let width: CGFloat = 250
    static let iconSize: CGFloat = 28
    static let iconInset: CGFloat = 12
    static let height: CGFloat = iconSize + iconInset * 2
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 20
}

struct HostCard: View {
    let host: HostProfile
    let username: String
    let phase: SSHConnectionPhase
    var isSelected = false

    var body: some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            HostOSIcon(osID: host.detectedOS?.id)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    OverflowingTagLine(tags: host.tags)
                    Spacer(minLength: 0)
                }
                Text("\(username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(HostCardMetrics.iconInset)
        .frame(width: HostCardMetrics.width, height: HostCardMetrics.height, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: HostCardMetrics.cornerRadius, style: .continuous)
            ZStack {
                if let statusColor {
                    shape
                        .inset(by: 1)
                        .stroke(statusColor.opacity(0.85), lineWidth: 1.25)
                }
                if isSelected {
                    shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
                }
            }
        }
    }

    private var statusColor: Color? {
        switch phase {
        case .connected: .green
        case .agent: .blue
        case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: .yellow
        case .failed: .red
        case .disconnected: nil
        }
    }
}

struct OverflowingTagLine: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: tags.count, through: 1, by: -1)), id: \.self) { visibleCount in
                    Text(summary(visibleCount: visibleCount))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text("+\(tags.count)")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
        }
    }

    private func summary(visibleCount: Int) -> String {
        let shown = tags.prefix(visibleCount)
        let hidden = tags.count - visibleCount
        if hidden == 0 {
            return shown.joined(separator: ", ")
        }
        return shown.joined(separator: ", ") + ", +\(hidden)"
    }
}
