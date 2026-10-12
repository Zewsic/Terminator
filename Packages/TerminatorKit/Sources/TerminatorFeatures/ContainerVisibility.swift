import SwiftUI
import TerminatorCore

@MainActor
@Observable
final class ContainerVisibilityStore {
    static let shared = ContainerVisibilityStore()

    private let defaults: UserDefaults
    private let hiddenKey = "containers.hidden"
    private let sectionsKey = "containers.hiddenSections"
    var hiddenContainers: Set<String>
    var hiddenSections: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenContainers = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
        hiddenSections = Set(defaults.stringArray(forKey: sectionsKey) ?? [])
    }

    func key(_ container: DockerContainer) -> String {
        "\(container.endpoint.cacheKey)|\(container.name)"
    }

    func isContainerHidden(_ container: DockerContainer) -> Bool {
        hiddenContainers.contains(key(container))
    }

    func shows(_ container: DockerContainer) -> Bool {
        !isContainerHidden(container)
    }

    func hiddenCount(in containers: [DockerContainer]) -> Int {
        containers.filter(isContainerHidden).count
    }

    func toggleContainer(_ container: DockerContainer) {
        let id = key(container)
        if hiddenContainers.contains(id) { hiddenContainers.remove(id) } else { hiddenContainers.insert(id) }
        defaults.set(Array(hiddenContainers), forKey: hiddenKey)
    }

    func sectionVisible(_ id: String) -> Bool {
        !hiddenSections.contains(id)
    }

    func setSection(_ id: String, visible: Bool) {
        if visible { hiddenSections.remove(id) } else { hiddenSections.insert(id) }
        defaults.set(Array(hiddenSections), forKey: sectionsKey)
    }

    func setSections(_ ids: [String], visible: Bool) {
        for id in ids { if visible { hiddenSections.remove(id) } else { hiddenSections.insert(id) } }
        defaults.set(Array(hiddenSections), forKey: sectionsKey)
    }
}

enum ContainerSectionKind: Equatable {
    case compose
    case swarm
    case containers

    init(sectionID: String) {
        if sectionID.hasPrefix("compose:") {
            self = .compose
        } else if sectionID.hasPrefix("swarm:") {
            self = .swarm
        } else {
            self = .containers
        }
    }

    var manageTitle: String {
        switch self {
        case .compose: FeatureL10n.text(.containersManageCompose)
        case .swarm: FeatureL10n.text(.containersManageSwarm)
        case .containers: FeatureL10n.text(.containersManageContainers)
        }
    }

    var label: String {
        switch self {
        case .compose: FeatureL10n.text(.containersKindCompose)
        case .swarm: FeatureL10n.text(.containersKindSwarm)
        case .containers: FeatureL10n.text(.containersKindContainers)
        }
    }

    var symbol: String {
        switch self {
        case .compose: "square.stack.3d.up"
        case .swarm: "network"
        case .containers: "shippingbox"
        }
    }
}

struct ManageContainersCard: View {
    let kind: ContainerSectionKind
    let hiddenCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HostCardMetrics.iconInset) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.manageTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(HostCardMetrics.iconInset)
            .frame(width: HostCardMetrics.width, height: HostCardMetrics.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
    }

    private var subtitle: String {
        FeatureL10n.text(.containersManageHidden, hiddenCount)
    }
}

enum DockerGroup {
    static func applies(_ action: DockerControlAction, to container: DockerContainer) -> Bool {
        switch action {
        case .start:
            return ["created", "exited", "dead"].contains(container.state)
        case .stop:
            return ["running", "paused", "restarting"].contains(container.state)
        case .pause:
            return container.state == "running"
        case .unpause:
            return container.state == "paused"
        case .restart:
            return container.state == "running" || container.state == "paused"
        case .logs:
            return true
        case .remove, .stats:
            return false
        }
    }
}

struct PublishedPortRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(FeatureL10n.text(.containersTunnel), action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ContainerStackPanel: View {
    @Environment(TerminatorAppModel.self) private var model
    let group: DockerBrowserGroup
    let section: DockerBrowserSection
    let onCreateTunnel: (TunnelDraft) -> Void
    @State private var visibility = ContainerVisibilityStore.shared
    @State private var runningAction: DockerControlAction?

    private var kind: ContainerSectionKind { ContainerSectionKind(sectionID: section.id) }

    private var containers: [DockerContainer] {
        section.containers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var primaryAction: DockerControlAction {
        if containers.contains(where: { DockerGroup.applies(.start, to: $0) }) { return .start }
        if containers.contains(where: { DockerGroup.applies(.stop, to: $0) }) { return .stop }
        return .logs
    }

    private var menuActions: [DockerControlAction] {
        [.start, .stop, .restart, .pause, .unpause, .logs].filter { $0 != primaryAction }
    }

    var body: some View {
        InspectorScreen(heading: heading) {
            metricGrid
            if let host = hostLine {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.containersStackHost)) {
                        InspectorReadOnlyValue(value: host)
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.containersStackImages)) {
                        InspectorReadOnlyValue(value: "\(imageCount)")
                    }
                }
            }
            if !published.isEmpty {
                InspectorFieldGroup {
                    ForEach(Array(published.enumerated()), id: \.offset) { index, item in
                        if index > 0 { InspectorGroupDivider() }
                        PublishedPortRow(title: item.port.binding, subtitle: item.container.name) {
                            onCreateTunnel(ContainerTunnel.draft(container: item.container, port: item.port))
                        }
                    }
                }
            }
            InspectorFieldGroup {
                HStack(spacing: 8) {
                    Text(FeatureL10n.text(.containersVisible))
                        .fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text("\(visibleCount)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: InspectorMetrics.rowHeight)
                ForEach(containers) { container in
                    InspectorGroupDivider()
                    visibilityRow(container)
                }
            }
        } actions: {
            InspectorActionArea {
                HStack(spacing: 10) {
                    InspectorProminentAction(
                        title: runningAction == nil ? actionTitle(primaryAction) : actionTitle(runningAction ?? primaryAction),
                        disabled: runningAction != nil
                    ) {
                        perform(primaryAction)
                    }
                    InspectorCircleMenu {
                        ForEach(menuActions, id: \.self) { action in
                            Button(actionTitle(action), systemImage: actionSymbol(action)) {
                                perform(action)
                            }
                            .disabled(runningAction != nil || !containers.contains { DockerGroup.applies(action, to: $0) })
                        }
                    }
                    .disabled(runningAction != nil)
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metricGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            metric(FeatureL10n.text(.containersStackRunning), containers.filter { $0.state == "running" }.count)
            metric(FeatureL10n.text(.containersStackPaused), containers.filter { $0.state == "paused" }.count)
            metric(FeatureL10n.text(.containersStackStopped), containers.filter { !["running", "paused"].contains($0.state) }.count)
            metric(FeatureL10n.text(.containersVisible), visibleCount)
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: .rect(cornerRadius: InspectorMetrics.groupCornerRadius))
    }

    private func visibilityRow(_ container: DockerContainer) -> some View {
        let shown = visibility.shows(container)
        return Button {
            visibility.toggleContainer(container)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: shown ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(shown ? Color.blue : Color.secondary)
                    .frame(width: 24)
                ContainerLogo(imageName: container.image, baseImage: container.baseImage, side: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(stateLabel(container))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if let name = section.title, !name.isEmpty { return name }
        if case .swarm(let name) = containers.first?.placement { return name }
        return group.title
    }

    private var subtitle: String {
        if let host = hostLine, kind != .containers {
            return "\(kind.label) · \(host)"
        }
        return kind.label
    }

    private var hostLine: String? {
        let hosts = hostNames
        guard !hosts.isEmpty else { return nil }
        if kind == .containers, hosts.count == 1, hosts[0] == title { return nil }
        return hosts.joined(separator: ", ")
    }

    private var imageCount: Int {
        Set(containers.map(\.image).filter { !$0.isEmpty }).count
    }

    private var published: [(container: DockerContainer, port: DockerPublishedPort)] {
        containers.flatMap { container in container.ports.map { (container, $0) } }
    }

    private var visibleCount: Int {
        containers.filter(visibility.shows).count
    }

    private var hostNames: [String] {
        var seen: [String] = []
        for container in containers {
            let name: String
            switch container.endpoint {
            case .mac:
                name = FeatureL10n.text(.containersThisMac)
            case .host(_, let hostName):
                name = hostName.isEmpty ? group.title : hostName
            }
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private func stateLabel(_ container: DockerContainer) -> String {
        if container.health == "unhealthy" { return container.health ?? container.state }
        return container.state
    }

    private func actionTitle(_ action: DockerControlAction) -> String {
        switch action {
        case .start: FeatureL10n.text(.containersStart)
        case .stop: FeatureL10n.text(.containersStop)
        case .pause: FeatureL10n.text(.containersPause)
        case .unpause: FeatureL10n.text(.containersResume)
        case .restart: FeatureL10n.text(.containersRestart)
        case .logs: FeatureL10n.text(.containersLogs)
        case .remove: FeatureL10n.text(.containersDelete)
        case .stats: FeatureL10n.text(.containersStats)
        }
    }

    private func actionSymbol(_ action: DockerControlAction) -> String {
        switch action {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .pause: "pause.fill"
        case .unpause: "play.fill"
        case .restart: "arrow.clockwise"
        case .logs: "text.alignleft"
        case .remove: "trash"
        case .stats: "chart.bar"
        }
    }

    private func perform(_ action: DockerControlAction) {
        guard runningAction == nil else { return }
        let targets = containers
        let name = title
        runningAction = action
        Task {
            await model.runDocker(targets, action: action, title: name)
            runningAction = nil
        }
    }
}

struct ContainerGroupSettingsSheet: View {
    let groups: [DockerBrowserGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var visibility = ContainerVisibilityStore.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 2) {
                    Text(FeatureL10n.text(.containersGroups))
                        .font(.title2.bold())
                    Text(FeatureL10n.text(.containersGroupsDetail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 52)
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .help(FeatureL10n.text(.actionClose))
                    .accessibilityLabel(FeatureL10n.text(.actionClose))
                    Spacer()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups) { group in
                        groupCard(group)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 560)
    }

    private func groupCard(_ group: DockerBrowserGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if isSimple(group) {
                    Text(group.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded.contains(group.id) ? 90 : 0))
                            Text(group.title)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                }
                Toggle("", isOn: isSimple(group) ? sectionBinding(group.sections[0].id) : hostBinding(group))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.blue)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            if !isSimple(group), expanded.contains(group.id) {
                ForEach(group.sections) { section in
                    Divider().padding(.leading, 14)
                    switchRow(
                        section.title ?? FeatureL10n.text(.containersGroupsOther),
                        isOn: sectionBinding(section.id)
                    )
                }
            }
        }
        .background(.quaternary, in: .rect(cornerRadius: 16))
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.blue)
        }
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .frame(minHeight: 44)
    }

    private func isSimple(_ group: DockerBrowserGroup) -> Bool {
        group.sections.count == 1 && group.sections[0].title == nil
    }

    private func sectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { visibility.sectionVisible(id) },
            set: { visibility.setSection(id, visible: $0) }
        )
    }

    private func hostBinding(_ group: DockerBrowserGroup) -> Binding<Bool> {
        Binding(
            get: { group.sections.contains { visibility.sectionVisible($0.id) } },
            set: { visibility.setSections(group.sections.map(\.id), visible: $0) }
        )
    }
}
