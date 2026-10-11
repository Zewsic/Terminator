import SwiftUI
import TerminatorCore

enum TunnelPortFormat {
    static var style: IntegerFormatStyle<Int> {
        IntegerFormatStyle<Int>.number.grouping(.never)
    }
}

extension TunnelKind {
    var detail: String {
        switch self {
        case .local: FeatureL10n.text(.tunnelKindLocalDetail)
        case .remote: FeatureL10n.text(.tunnelKindRemoteDetail)
        case .dynamic: FeatureL10n.text(.tunnelKindDynamicDetail)
        }
    }

    var directionSymbol: String {
        switch self {
        case .local: "arrow.down"
        case .remote: "arrow.up"
        case .dynamic: "arrow.triangle.branch"
        }
    }
}

private enum TunnelHostChoice: Hashable {
    case unset
    case thisMac
    case manual
    case saved(UUID)

    init(_ endpoint: TunnelEndpoint?) {
        switch endpoint {
        case .thisMac: self = .thisMac
        case .saved(let id): self = .saved(id)
        case .manual: self = .manual
        case nil: self = .unset
        }
    }

    func endpoint(replacing current: TunnelEndpoint?) -> TunnelEndpoint? {
        switch self {
        case .unset:
            return nil
        case .thisMac:
            return .thisMac
        case .saved(let id):
            return .saved(id)
        case .manual:
            if case .manual = current { return current }
            return .manual(id: UUID(), hostname: "", port: 22)
        }
    }
}

struct TunnelKindSelector: View {
    @Binding var kind: TunnelKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorSegmentedSelector(
                selection: $kind,
                options: TunnelKind.allCases.map {
                    InspectorSelectorOption(value: $0, title: $0.displayName)
                },
                fillsWidth: true
            )
            Text(kind.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TunnelSettingsGroup: View {
    @Binding var draft: TunnelDraft

    var body: some View {
        InspectorFieldGroup {
            InspectorFieldRow(FeatureL10n.text(.tunnelDisplayName)) {
                TextField(FeatureL10n.text(.tunnelDisplayName), text: $draft.displayName)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("tunnel-display-name")
            }
            if draft.allowsAutomaticConnect {
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tunnelConnectAutomatically)) {
                    Toggle(FeatureL10n.text(.tunnelConnectAutomatically), isOn: $draft.connectAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .fixedSize()
                }
            }
        }
        .onChange(of: draft.source) { _, _ in
            if !draft.allowsAutomaticConnect { draft.connectAutomatically = false }
        }
    }
}

struct TunnelUseExamples: View {
    let kind: TunnelKind
    let sourceName: String
    let destinationName: String
    let onApply: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FeatureL10n.text(.tunnelUseCases))
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        onApply(item.listenPort, item.targetPort)
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.accentColor.gradient, in: Circle())
                            Text(item.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(.rect(cornerRadius: 18))
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var items: [TunnelUseCase] {
        let lines = keys.map { FeatureL10n.text($0, sourceName, destinationName) }
        return zip(symbols, zip(lines, presets)).enumerated().map { index, pair in
            TunnelUseCase(
                id: index,
                symbol: pair.0,
                text: pair.1.0,
                listenPort: pair.1.1.listen,
                targetPort: pair.1.1.target
            )
        }
    }

    private var presets: [(listen: Int, target: Int)] {
        switch kind {
        case .local: [(8080, 8080), (5432, 5432), (8088, 80)]
        case .remote: [(8080, 8080), (5432, 5432), (3000, 3000)]
        case .dynamic: [(1080, 1080), (9050, 9050), (8888, 8888)]
        }
    }

    private var keys: [FeatureString] {
        switch kind {
        case .local: [.tunnelUseLocal1, .tunnelUseLocal2, .tunnelUseLocal3]
        case .remote: [.tunnelUseRemote1, .tunnelUseRemote2, .tunnelUseRemote3]
        case .dynamic: [.tunnelUseDynamic1, .tunnelUseDynamic2, .tunnelUseDynamic3]
        }
    }

    private var symbols: [String] {
        switch kind {
        case .local: ["arrow.down.forward", "cylinder", "globe"]
        case .remote: ["arrow.up.forward", "cylinder", "macwindow"]
        case .dynamic: ["network", "safari", "point.3.connected.trianglepath.dotted"]
        }
    }
}

private struct TunnelUseCase: Identifiable {
    let id: Int
    let symbol: String
    let text: String
    let listenPort: Int
    let targetPort: Int
}

struct TunnelEndpointStack: View {
    @Binding var draft: TunnelDraft
    var sideBySide = false

    var body: some View {
        if sideBySide {
            HStack(alignment: .center, spacing: 16) {
                sourceGroup
                directionMark
                destinationGroup
            }
        } else {
            VStack(spacing: 14) {
                sourceGroup
                directionMark
                destinationGroup
            }
        }
    }

    private var directionMark: some View {
        Image(systemName: draft.kind.directionSymbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .frame(maxWidth: sideBySide ? 28 : .infinity)
            .accessibilityHidden(true)
    }

    private var sourceGroup: some View {
        TunnelEndpointGroup(
            title: FeatureL10n.text(.tunnelHostA),
            endpoint: draft.source,
            allowsThisMac: true,
            address: $draft.listenAddress,
            port: $draft.listenPort,
            onSelect: { draft.source = $0 ?? .thisMac }
        )
    }

    private var destinationGroup: some View {
        TunnelEndpointGroup(
            title: FeatureL10n.text(.tunnelHostB),
            endpoint: draft.destination,
            allowsEmpty: true,
            showsSocket: draft.kind != .dynamic,
            address: $draft.targetAddress,
            port: $draft.targetPort,
            onSelect: { draft.destination = $0 }
        )
    }
}

struct TunnelEndpointGroup: View {
    let title: String
    let endpoint: TunnelEndpoint?
    var allowsThisMac = false
    var allowsEmpty = false
    var showsSocket = true
    @Binding var address: String
    @Binding var port: Int
    let onSelect: (TunnelEndpoint?) -> Void

    var body: some View {
        InspectorFieldGroup {
            InspectorFieldRow(title) {
                TunnelHostPicker(
                    endpoint: endpoint,
                    allowsThisMac: allowsThisMac,
                    allowsEmpty: allowsEmpty,
                    onSelect: onSelect
                )
                .fixedSize()
            }
            if isManual {
                TunnelManualRows(hostname: manualHostname, port: manualPort)
            }
            if showsSocket {
                TunnelSocketRows(address: $address, port: $port)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var isManual: Bool {
        if case .manual = endpoint { return true }
        return false
    }

    private var manualHostname: Binding<String> {
        Binding(
            get: {
                if case .manual(_, let hostname, _) = endpoint { return hostname }
                return ""
            },
            set: { value in
                guard case .manual(let id, _, let port) = endpoint else { return }
                onSelect(.manual(id: id, hostname: value, port: port))
            }
        )
    }

    private var manualPort: Binding<Int> {
        Binding(
            get: {
                if case .manual(_, _, let port) = endpoint { return port }
                return 22
            },
            set: { value in
                guard case .manual(let id, let hostname, _) = endpoint else { return }
                onSelect(.manual(id: id, hostname: hostname, port: value))
            }
        )
    }
}

private struct TunnelManualRows: View {
    @Binding var hostname: String
    @Binding var port: Int

    var body: some View {
        VStack(spacing: 0) {
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.tunnelSshHost)) {
                TextField(FeatureL10n.text(.tunnelSshHost), text: $hostname)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.tunnelSshPort)) {
                TunnelPortField(title: FeatureL10n.text(.tunnelSshPort), value: $port)
            }
        }
    }
}

private struct TunnelSocketRows: View {
    @Binding var address: String
    @Binding var port: Int

    var body: some View {
        VStack(spacing: 0) {
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.tunnelAddress)) {
                TextField(FeatureL10n.text(.tunnelAddress), text: $address, prompt: Text("127.0.0.1"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.tunnelPort)) {
                TunnelPortField(title: FeatureL10n.text(.tunnelPort), value: $port)
            }
        }
    }
}

private struct TunnelPortField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        TextField(title, value: $value, format: TunnelPortFormat.style)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }
}

struct TunnelHostPicker: View {
    @Environment(TerminatorAppModel.self) private var model
    let endpoint: TunnelEndpoint?
    var allowsThisMac = false
    var allowsEmpty = false
    let onSelect: (TunnelEndpoint?) -> Void

    var body: some View {
        InspectorValueMenu(title: currentTitle) {
            if allowsEmpty {
                Button(FeatureL10n.text(.tunnelChooseHost)) { onSelect(nil) }
            }
            if allowsThisMac {
                Button(FeatureL10n.text(.tunnelThisMac)) { onSelect(.thisMac) }
            }
            Button(FeatureL10n.text(.tunnelManual)) {
                onSelect(TunnelHostChoice.manual.endpoint(replacing: endpoint))
            }
            if !model.activeHosts.isEmpty { Divider() }
            ForEach(model.activeHosts) { host in
                Button(host.displayName) { onSelect(.saved(host.id)) }
            }
        }
        .accessibilityLabel(FeatureL10n.text(.tunnelChooseHost))
    }

    private var currentTitle: String {
        switch endpoint {
        case .thisMac:
            FeatureL10n.text(.tunnelThisMac)
        case .saved(let id):
            model.activeHosts.first { $0.id == id }?.displayName ?? FeatureL10n.text(.tunnelChooseHost)
        case .manual:
            FeatureL10n.text(.tunnelManual)
        case nil:
            FeatureL10n.text(.tunnelChooseHost)
        }
    }
}

extension TerminatorAppModel {
    func endpointName(_ endpoint: TunnelEndpoint, fallback: String) -> String {
        switch endpoint {
        case .thisMac: FeatureL10n.text(.tunnelThisMac)
        case .saved(let id): hosts.first { $0.id == id }?.displayName ?? fallback
        case .manual(_, let hostname, _): hostname.isEmpty ? fallback : hostname
        }
    }
}
