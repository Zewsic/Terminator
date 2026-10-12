import SwiftUI
import TerminatorCore

enum HostEditorPane: String, Hashable {
    case status
    case edit
}

struct HostHelperState: Equatable {
    var installed: Bool
    var version: String?
    var online: Bool
    var canInstall: Bool
    var dockerMissing: Bool
    var updating: Bool = false
}

struct HostStatusPane: View {
    let name: String
    let snapshot: HostStatusSnapshot?
    let helper: HostHelperState
    let onInstall: () -> Void
    @State private var processSort = ProcessColumn.cpu
    @State private var sortDescending = true
    @State private var showsAllProcesses = false

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.featureHostEditorDisplayName)) {
                    InspectorReadOnlyValue(value: name)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.hostStatusUptime)) {
                    VStack(alignment: .trailing, spacing: 2) {
                        InspectorReadOnlyValue(value: snapshot.map { uptime($0.uptime) } ?? "—")
                        if let snapshot {
                            Text(String(format: "%.2f  %.2f  %.2f", snapshot.load1, snapshot.load5, snapshot.load15))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.hostStatusHelper)) {
                    HStack(spacing: 10) {
                        Text(helperValue)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if helper.canInstall {
                            Button(FeatureL10n.text(.helperInstall), action: onInstall)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.blue)
                                .fixedSize()
                        } else if helper.dockerMissing {
                            Button(action: onInstall) {
                                Image(systemName: "questionmark")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .controlSize(.small)
                            .accessibilityLabel(FeatureL10n.text(.helperInstallTitle))
                        }
                    }
                }
            }
            cpuGrid
            InspectorFieldGroup {
                ForEach(Array(memoryRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { InspectorGroupDivider() }
                    InspectorFieldRow(row.title) {
                        InspectorReadOnlyValue(value: row.cells.first ?? "—")
                    }
                }
            }
            metricTable(
                FeatureL10n.text(.hostStatusDisks),
                columns: [
                    Column(FeatureL10n.text(.hostStatusVolume), width: 88),
                    Column(FeatureL10n.text(.hostStatusUsed), width: 88),
                    Column("%", width: 52),
                ],
                rows: diskRows
            )
            metricTable(
                FeatureL10n.text(.hostStatusNetwork),
                columns: [
                    Column(FeatureL10n.text(.hostStatusReceive), width: 80),
                    Column(FeatureL10n.text(.hostStatusTransmit), width: 80),
                ],
                rows: networkRows
            )
            metricTable(
                FeatureL10n.text(.hostStatusProcesses),
                columns: [
                    Column(FeatureL10n.text(.hostStatusCPU), width: 56, sort: .cpu),
                    Column(FeatureL10n.text(.hostStatusMemory), width: 72, sort: .memory),
                    Column(FeatureL10n.text(.hostStatusDiskIO), width: 72, sort: .disk),
                    Column(FeatureL10n.text(.hostStatusNetwork), width: 72, sort: .network),
                ],
                rows: visibleProcessRows,
                footer: processListFooter
            )
        }
    }

    private var cpuGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(coreRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.cells.first ?? "—")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: .rect(cornerRadius: InspectorMetrics.groupCornerRadius))
            }
        }
    }

    private var coreRows: [StatusRow] {
        guard let snapshot else { return [] }
        let cores = snapshot.cores.filter { $0.name != "cpu" }
        let rows = (cores.isEmpty ? snapshot.cores : cores).sorted { coreNumber($0.name) < coreNumber($1.name) }
        return rows.map { StatusRow(id: $0.id, title: $0.name, cells: [percent($0.usage)]) }
    }

    private func coreNumber(_ name: String) -> Int {
        Int(name.filter(\.isNumber)) ?? 0
    }

    private var memoryRows: [StatusRow] {
        guard let snapshot else {
            return [
                StatusRow(id: "memory", title: FeatureL10n.text(.hostStatusMemory), cells: ["—"]),
                StatusRow(id: "swap", title: FeatureL10n.text(.hostStatusSwap), cells: ["—"]),
            ]
        }
        return [
            StatusRow(
                id: "memory",
                title: FeatureL10n.text(.hostStatusMemory),
                cells: ["\(bytes(snapshot.memory.used)) / \(bytes(snapshot.memory.total))"]
            ),
            StatusRow(
                id: "swap",
                title: FeatureL10n.text(.hostStatusSwap),
                cells: ["\(bytes(snapshot.memory.swapUsed)) / \(bytes(snapshot.memory.swapTotal))"]
            ),
        ]
    }

    private var diskRows: [StatusRow] {
        guard let snapshot else { return [] }
        return snapshot.disks.enumerated().map { index, disk in
            let fraction = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
            return StatusRow(
                id: "\(index)-\(disk.mount)",
                title: disk.mount,
                cells: [bytes(disk.total), bytes(disk.used), percent(fraction)]
            )
        }
    }

    private var networkRows: [StatusRow] {
        guard let snapshot else { return [] }
        let interfaces = snapshot.network.interfaces.filter { !isVirtualInterface($0.name) }
        if interfaces.isEmpty {
            return [
                StatusRow(
                    id: "total",
                    title: FeatureL10n.text(.hostStatusNetwork),
                    cells: [
                        rate(snapshot.network.receiveBytesPerSecond),
                        rate(snapshot.network.transmitBytesPerSecond),
                    ]
                )
            ]
        }
        return interfaces.map { interface in
            StatusRow(
                id: interface.id,
                title: interface.name,
                cells: [rate(interface.receiveBytesPerSecond), rate(interface.transmitBytesPerSecond)]
            )
        }
    }

    private func isVirtualInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "lo" || lower.hasPrefix("lo") { return true }
        let prefixes = ["veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "dummy", "ifb", "kube", "nodelocal", "vxlan", "vboxnet", "tunl", "erspan"]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private var visibleProcessRows: [StatusRow] {
        showsAllProcesses ? processRows : Array(processRows.prefix(10))
    }

    @ViewBuilder
    private var processListFooter: some View {
        if processRows.count > 10 {
            Button(FeatureL10n.text(showsAllProcesses ? .hostStatusShowTopProcesses : .hostStatusShowAllProcesses)) {
                showsAllProcesses.toggle()
            }
            .buttonStyle(.plain)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight)
        }
    }

    private var processRows: [StatusRow] {
        processes.map { process in
            StatusRow(
                id: "\(process.pid)-\(process.name)",
                title: process.name,
                cells: [
                    percent(process.cpu),
                    bytes(process.memory),
                    rate(process.readBytesPerSecond + process.writeBytesPerSecond),
                    "—",
                ]
            )
        }
    }

    private var processes: [HostProcessStatus] {
        let items = snapshot?.processes ?? []
        return items.sorted { lhs, rhs in
            let order: ComparisonResult
            switch processSort {
            case .cpu:
                order = compare(lhs.cpu, rhs.cpu)
            case .memory:
                order = compare(Double(lhs.memory), Double(rhs.memory))
            case .disk:
                order = compare(
                    lhs.readBytesPerSecond + lhs.writeBytesPerSecond,
                    rhs.readBytesPerSecond + rhs.writeBytesPerSecond
                )
            case .network:
                return lhs.pid < rhs.pid
            }
            if order == .orderedSame { return lhs.pid < rhs.pid }
            let descending = order == .orderedDescending
            return sortDescending ? descending : !descending
        }
    }

    private var helperValue: String {
        if helper.updating { return FeatureL10n.text(.hostStatusHelperUpdating) }
        if helper.dockerMissing, !helper.installed {
            return FeatureL10n.text(.hostStatusHelperUnavailable)
        }
        guard helper.installed, let version = helper.version else {
            return FeatureL10n.text(.hostStatusHelperMissing)
        }
        let label = FeatureL10n.text(.hostStatusHelperVersion, version)
        guard helper.online else { return "\(FeatureL10n.text(.hostStatusHelperOffline)) · \(label)" }
        return label
    }

    private func metricTable(_ title: String, columns: [Column], rows: [StatusRow], footer: (any View)? = nil) -> some View {
        InspectorFieldGroup {
            HStack(spacing: 8) {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    columnHeader(column)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: InspectorMetrics.rowHeight)
            if rows.isEmpty {
                InspectorGroupDivider()
                Text("—")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(minHeight: InspectorMetrics.rowHeight)
            } else {
                ForEach(rows) { row in
                    InspectorGroupDivider()
                    HStack(spacing: 8) {
                        Text(row.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: columns.indices.contains(index) ? columns[index].width : 72, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: InspectorMetrics.rowHeight)
                }
            }
            if let footer {
                InspectorGroupDivider()
                AnyView(footer)
            }
        }
    }

    @ViewBuilder
    private func columnHeader(_ column: Column) -> some View {
        if let sort = column.sort {
            Button {
                if processSort == sort {
                    sortDescending.toggle()
                } else {
                    processSort = sort
                    sortDescending = true
                }
            } label: {
                HStack(spacing: 2) {
                    Text(column.title)
                    if processSort == sort {
                        Image(systemName: sortDescending ? "chevron.down" : "chevron.up")
                            .font(.caption2.weight(.bold))
                    }
                }
                .frame(width: column.width, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(processSort == sort ? Color.primary : Color.secondary)
        } else {
            Text(column.title)
                .foregroundStyle(.secondary)
                .frame(width: column.width, alignment: .trailing)
        }
    }

    private func compare(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs > rhs ? .orderedDescending : .orderedAscending
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", max(value, 0) * 100)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func rate(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
    }

    private func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        return "\(minutes)m \(seconds)s"
    }

    private struct Column {
        var title: String
        var width: CGFloat
        var sort: ProcessColumn?

        init(_ title: String, width: CGFloat, sort: ProcessColumn? = nil) {
            self.title = title
            self.width = width
            self.sort = sort
        }
    }

    private struct StatusRow: Identifiable {
        var id: String
        var title: String
        var cells: [String]
    }

    private enum ProcessColumn: Hashable {
        case cpu, memory, disk, network
    }
}

struct DockerOutputSheet: View {
    let output: DockerCommandOutput
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(output.title)
                    .font(.headline)
                Spacer()
                Button(FeatureL10n.text(.actionClose), action: onClose)
            }
            ScrollView {
                Text(output.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
    }
}

struct TunnelStatusPane: View {
    let traffic: TunnelTrafficSnapshot
    let phase: SSHConnectionPhase

    var body: some View {
        HStack {
            metric("↓", ByteCountFormatter.string(fromByteCount: Int64(clamping: traffic.received), countStyle: .binary))
            metric("↑", ByteCountFormatter.string(fromByteCount: Int64(clamping: traffic.sent), countStyle: .binary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(phase.isDisconnected ? 0.45 : 1)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
