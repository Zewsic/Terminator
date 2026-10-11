import SwiftUI
import TerminatorCore

struct HostOSIcon: View {
    let osID: String?

    var body: some View {
        let descriptor = HostOSCatalog.descriptor(for: osID)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(descriptor.map { Color(hex: $0.colorHex) } ?? Color.secondary.opacity(0.85))
            if let descriptor {
                HostOSMark(id: descriptor.id, name: descriptor.name)
                    .foregroundStyle(markColor(for: descriptor.id))
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        .accessibilityHidden(true)
    }

    private func markColor(for id: String) -> Color {
        switch id {
        case "openbsd": .black.opacity(0.85)
        case "linux": .black.opacity(0.82)
        default: .white
        }
    }
}

private struct HostOSMark: View {
    let id: String
    let name: String

    var body: some View {
        switch id {
        case "macos", "ios":
            Image(systemName: "apple.logo")
                .font(.system(size: 14, weight: .semibold))
        case "windows":
            WindowsMark()
        case "ubuntu":
            UbuntuMark()
        case "debian":
            SpiralMark()
        case "fedora":
            InfinityMark()
        case "arch", "endeavour", "artix":
            TriangleMark()
        case "alpine":
            MountainMark()
        case "android":
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .bold))
        case "linux":
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .bold))
        case "nixos":
            SnowflakeMark()
        case "raspbian":
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 12, weight: .bold))
        case "freebsd", "openbsd", "netbsd", "dragonfly":
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .bold))
        case "proxmox", "esxi":
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 12, weight: .bold))
        case "opensuse", "suse":
            ChameleonMark()
        case "kali", "parrot":
            Image(systemName: "strikethrough")
                .font(.system(size: 13, weight: .heavy))
        default:
            Text(String(name.prefix(1)))
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
    }
}

private struct WindowsMark: View {
    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1.4
            let side = (min(size.width, size.height) - gap) / 2
            for row in 0..<2 {
                for column in 0..<2 {
                    let rect = CGRect(
                        x: CGFloat(column) * (side + gap),
                        y: CGFloat(row) * (side + gap),
                        width: side,
                        height: side
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.1), with: .color(.white))
                }
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct UbuntuMark: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = CGRect(x: 3, y: 3, width: size.width - 6, height: size.height - 6)
            context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 1.6)
            for index in 0..<3 {
                let angle = (Double(index) * 120 - 90) * Double.pi / 180
                let point = CGPoint(
                    x: center.x + cos(angle) * (size.width / 2 - 2.2),
                    y: center.y + sin(angle) * (size.height / 2 - 2.2)
                )
                let dot = CGRect(x: point.x - 2.1, y: point.y - 2.1, width: 4.2, height: 4.2)
                context.fill(Path(ellipseIn: dot), with: .color(.white))
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct SpiralMark: View {
    var body: some View {
        Image(systemName: "hurricane")
            .font(.system(size: 13, weight: .bold))
    }
}

private struct InfinityMark: View {
    var body: some View {
        Image(systemName: "infinity")
            .font(.system(size: 13, weight: .bold))
    }
}

private struct TriangleMark: View {
    var body: some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 13, weight: .bold))
    }
}

private struct MountainMark: View {
    var body: some View {
        Image(systemName: "mountain.2.fill")
            .font(.system(size: 12, weight: .bold))
    }
}

private struct SnowflakeMark: View {
    var body: some View {
        Image(systemName: "snowflake")
            .font(.system(size: 13, weight: .bold))
    }
}

private struct ChameleonMark: View {
    var body: some View {
        Image(systemName: "leaf.fill")
            .font(.system(size: 13, weight: .bold))
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
