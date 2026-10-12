import SwiftUI
import TerminatorCore

@MainActor
@Observable
final class ContainerSectionStore {
    static let shared = ContainerSectionStore()
    private let key = "containers.collapsedSections"
    private let defaults: UserDefaults
    var collapsed: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        defaults.set(Array(collapsed), forKey: key)
    }
}

struct ContainersView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var sections = ContainerSectionStore.shared
    @State private var search = ""
    @State private var pendingDelete: DockerContainer?
    @State private var selectedID: String?
    @State private var visibility = ContainerVisibilityStore.shared
    @State private var managingSectionID: String?
    @State private var showsGroupSettings = false
    @State private var tunnelRequest: TunnelCreateRequest?

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private var browser: [DockerBrowserGroup] {
        DockerInventory.browserGroups(model.dockerContainers, macTitle: FeatureL10n.text(.containersThisMac))
    }

    private func matchesSearch(_ container: DockerContainer) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [container.name, container.image, shortID(container), container.state].joined(separator: " ")
        return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func displayed(in section: DockerBrowserSection) -> [DockerContainer] {
        section.containers.filter { visibility.shows($0) && matchesSearch($0) }
    }

    private func listedSections(_ group: DockerBrowserGroup) -> [DockerBrowserSection] {
        group.sections.filter { section in
            guard visibility.sectionVisible(section.id) else { return false }
            if !search.isEmpty { return !displayed(in: section).isEmpty }
            return !section.containers.isEmpty
        }
    }

    private var placeholders: [DockerEndpoint] {
        let present = Set(model.dockerContainers.map(\.endpoint.cacheKey))
        return model.dockerUpdating.filter { endpoint in
            guard !present.contains(endpoint.cacheKey) else { return false }
            guard !search.isEmpty else { return true }
            return endpointTitle(endpoint).localizedCaseInsensitiveContains(search)
        }
    }

    private var showsLoading: Bool {
        model.dockerContainers.isEmpty && (!model.dockerInventoryReady || !model.dockerUpdating.isEmpty)
    }

    private var showsEmpty: Bool {
        search.isEmpty && !browser.contains { !listedSections($0).isEmpty } && placeholders.isEmpty && !showsLoading
    }

    private var selectedContainer: DockerContainer? {
        guard let selectedID else { return nil }
        return model.dockerContainers.first { $0.id == selectedID }
    }

    private var managedSection: (group: DockerBrowserGroup, section: DockerBrowserSection)? {
        guard let managingSectionID else { return nil }
        for group in browser {
            if let section = group.sections.first(where: { $0.id == managingSectionID }) {
                return (group, section)
            }
        }
        return nil
    }

    var body: some View {
        InspectorLayout(content: {
        Group {
            if showsLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsEmpty {
                ContentUnavailableView(
                    FeatureL10n.text(.containersEmpty),
                    systemImage: "shippingbox",
                    description: Text(FeatureL10n.text(.containersEmptyDescription))
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(browser) { group in
                            let sections = listedSections(group)
                            if !sections.isEmpty {
                                groupHeader(id: group.id, title: group.title, updating: isUpdating(group))
                                if !self.sections.collapsed.contains(group.id) {
                                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                        if index > 0 {
                                            Divider().padding(.vertical, 4)
                                        }
                                        if let title = section.title {
                                            Text(title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                                            ForEach(displayed(in: section)) { container in
                                                ContainerCard(container: container, subtitle: shortID(container))
                                                    .onTapGesture {
                                                        managingSectionID = nil
                                                        selectedID = container.id
                                                    }
                                                    .contextMenu { containerMenu(container) }
                                            }
                                            if search.isEmpty {
                                                ManageContainersCard(
                                                    kind: ContainerSectionKind(sectionID: section.id),
                                                    hiddenCount: visibility.hiddenCount(in: section.containers)
                                                ) {
                                                    selectedID = nil
                                                    managingSectionID = section.id
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(placeholders, id: \.cacheKey) { endpoint in
                            groupHeader(id: placeholderID(endpoint), title: endpointTitle(endpoint), updating: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("containers-list")
            }
        }
        }, inspector: {
            if let managed = managedSection {
                ContainerStackPanel(group: managed.group, section: managed.section) { draft in
                    tunnelRequest = TunnelCreateRequest(draft: draft)
                }
            } else if let container = selectedContainer {
                ContainerInspector(container: container, onDelete: { pendingDelete = container }) { draft in
                    tunnelRequest = TunnelCreateRequest(draft: draft)
                }
            }
        }, isInspectorPresented: managedSection != nil || selectedContainer != nil, onContentInteraction: {
            selectedID = nil
            managingSectionID = nil
        })
        .navigationTitle(FeatureL10n.text(.containersTitle))
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button(FeatureL10n.text(.containersGroups), systemImage: "shippingbox") {
                    showsGroupSettings = true
                }
            }
            ToolbarItem {
                ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.containersSearch))
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showsGroupSettings) {
            ContainerGroupSettingsSheet(groups: browser)
        }
        .sheet(item: $tunnelRequest) { request in
            TunnelCreateSheet(draft: request.draft)
        }
        .confirmationDialog(
            FeatureL10n.text(.containersDeleteConfirm),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.containersDelete), role: .destructive) {
                guard let container = pendingDelete else { return }
                pendingDelete = nil
                Task { await model.runDocker(container, action: .remove) }
            }
        }
        .sheet(item: Bindable(model).dockerOutput) { output in
            DockerOutputSheet(output: output) { model.dockerOutput = nil }
        }
    }

    @ViewBuilder
    private func containerMenu(_ container: DockerContainer) -> some View {
        if container.state == "created" || container.state == "exited" || container.state == "dead" {
            Button(FeatureL10n.text(.containersStart), systemImage: "play.fill") {
                Task { await model.runDocker(container, action: .start) }
            }
        }
        if container.state == "running" {
            Button(FeatureL10n.text(.containersPause), systemImage: "pause.fill") {
                Task { await model.runDocker(container, action: .pause) }
            }
        }
        if container.state == "paused" {
            Button(FeatureL10n.text(.containersResume), systemImage: "play.fill") {
                Task { await model.runDocker(container, action: .unpause) }
            }
        }
        if container.state == "running" || container.state == "paused" || container.state == "restarting" {
            Button(FeatureL10n.text(.containersStop), systemImage: "stop.fill") {
                Task { await model.runDocker(container, action: .stop) }
            }
        }
        if container.state == "running" || container.state == "paused" {
            Button(FeatureL10n.text(.containersRestart), systemImage: "arrow.clockwise") {
                Task { await model.runDocker(container, action: .restart) }
            }
        }
        if container.state != "running" && container.state != "restarting" && container.state != "paused" {
            Button(FeatureL10n.text(.containersDelete), systemImage: "trash", role: .destructive) {
                pendingDelete = container
            }
        }
    }

    private func isUpdating(_ group: DockerBrowserGroup) -> Bool {
        let keys = Set(model.dockerUpdating.map(\.cacheKey))
        if group.sections.contains(where: { $0.containers.contains { keys.contains($0.endpoint.cacheKey) } }) { return true }
        if group.id == "mac" { return keys.contains(DockerEndpoint.mac.cacheKey) }
        if group.id.hasPrefix("host:") { return keys.contains(String(group.id.dropFirst("host:".count))) }
        return false
    }


    private func groupHeader(id: String, title: String, updating: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                sections.toggle(id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sections.collapsed.contains(id) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Text(title)
                if updating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }


    private func endpointTitle(_ endpoint: DockerEndpoint) -> String {
        switch endpoint {
        case .mac: FeatureL10n.text(.containersThisMac)
        case .host(_, let name): name
        }
    }

    private func placeholderID(_ endpoint: DockerEndpoint) -> String {
        switch endpoint {
        case .mac: "mac"
        case .host(let id, _): "host:\(id.uuidString)"
        }
    }

    private func shortID(_ container: DockerContainer) -> String {
        var id = container.id
        if id.hasPrefix("sha256:") { id.removeFirst("sha256:".count) }
        return String(id.prefix(12))
    }
}

struct TunnelCreateRequest: Identifiable {
    let id = UUID()
    var draft: TunnelDraft
}

enum ContainerTunnel {
    static func draft(container: DockerContainer, port: DockerPublishedPort) -> TunnelDraft {
        var draft = TunnelDraft()
        draft.kind = .local
        draft.displayName = "\(container.name) · \(port.containerPort)"
        draft.listenAddress = "127.0.0.1"
        draft.listenPort = port.hostPort
        draft.targetAddress = port.tunnelTargetAddress
        draft.targetPort = port.hostPort
        draft.source = .thisMac
        if case .host(let id, _) = container.endpoint {
            draft.destination = .saved(id)
        }
        return draft
    }
}

private struct ContainerInspector: View {
    @Environment(TerminatorAppModel.self) private var model
    let container: DockerContainer
    let onDelete: () -> Void
    let onCreateTunnel: (TunnelDraft) -> Void
    @State private var runtime: DockerRuntimeStatus?
    @State private var isLoadingRuntime = false

    private var ports: [DockerPublishedPort] {
        if let published = runtime?.published, !published.isEmpty { return published }
        return container.ports
    }

    var body: some View {
        InspectorScreen(heading: heading) {
            metricGrid
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.featureContainersState)) {
                    InspectorReadOnlyValue(value: container.state)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.containersHealth)) {
                    InspectorReadOnlyValue(value: container.health ?? "—")
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.containersID)) {
                    InspectorReadOnlyValue(value: String(container.id.prefix(12)))
                }
                if let base = container.baseImage, !base.isEmpty {
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.containersBaseImage)) {
                        InspectorReadOnlyValue(value: base)
                    }
                }
                if let runtime {
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.hostStatusUptime)) {
                        InspectorReadOnlyValue(value: started(runtime.startedAt))
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.containersRestarts)) {
                        InspectorReadOnlyValue(value: "\(runtime.restartCount)")
                    }
                }
            }
            if !ports.isEmpty {
                InspectorFieldGroup {
                    ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                        if index > 0 { InspectorGroupDivider() }
                        PublishedPortRow(
                            title: "\(port.containerPort)/\(port.proto)",
                            subtitle: port.binding
                        ) {
                            onCreateTunnel(ContainerTunnel.draft(container: container, port: port))
                        }
                    }
                }
            }
            if let mounts = runtime?.mounts, !mounts.isEmpty {
                InspectorFieldGroup {
                    HStack {
                        Text(FeatureL10n.text(.containersMounts)).fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: InspectorMetrics.rowHeight)
                    ForEach(Array(mounts.prefix(6).enumerated()), id: \.offset) { _, mount in
                        InspectorGroupDivider()
                        Text(mount)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
        } actions: {
            InspectorActionArea {
                HStack(spacing: 8) {
                    InspectorCircleButton(
                        systemImage: "apple.terminal",
                        disabled: container.state != "running"
                    ) {
                        Task { await model.openContainerShell(container) }
                    }
                    InspectorProminentAction(
                        title: primaryTitle,
                        disabled: container.state == "removing"
                    ) {
                        Task {
                            await model.runDocker(container, action: showsStart ? .start : .logs)
                        }
                    }
                    InspectorCircleMenu {
                        Button(FeatureL10n.text(.containersPause)) {
                            Task { await model.runDocker(container, action: .pause) }
                        }
                        .disabled(container.state != "running")
                        Button(FeatureL10n.text(.containersResume)) {
                            Task { await model.runDocker(container, action: .unpause) }
                        }
                        .disabled(container.state != "paused")
                        Button(FeatureL10n.text(.containersStop)) {
                            Task { await model.runDocker(container, action: .stop) }
                        }
                        .disabled(!canStop)
                        Button(FeatureL10n.text(.containersRestart)) {
                            Task { await model.runDocker(container, action: .restart) }
                        }
                        .disabled(container.state != "running" && container.state != "paused")
                        if showsStart {
                            Button(FeatureL10n.text(.containersOpenLogs)) {
                                Task { await model.runDocker(container, action: .logs) }
                            }
                        }
                        Divider()
                        Button(FeatureL10n.text(.containersDelete), role: .destructive) { onDelete() }
                            .disabled(container.state == "running" || container.state == "restarting" || container.state == "paused")
                    }
                }
            }
        }
        .task(id: container.id) {
            isLoadingRuntime = true
            runtime = await model.dockerRuntime(container)
            isLoadingRuntime = false
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            ContainerLogo(imageName: container.image, baseImage: container.baseImage, side: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(container.image.isEmpty ? "—" : container.image)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var metricGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            metric(FeatureL10n.text(.hostStatusCPU), percent(runtime?.cpu))
            metric(FeatureL10n.text(.hostStatusMemory), bytes(runtime?.memoryUsed))
            metric(FeatureL10n.text(.hostStatusNetwork), bytes(runtime?.networkReceive))
            metric(FeatureL10n.text(.hostStatusDiskIO), bytes(runtime?.diskUsed))
        }
        .opacity(isLoadingRuntime && runtime == nil ? 0.45 : 1)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: .rect(cornerRadius: InspectorMetrics.groupCornerRadius))
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", max(value, 0) * 100)
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func started(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = max(0, Date().timeIntervalSince(date))
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var showsStart: Bool {
        container.state == "created" || container.state == "exited" || container.state == "dead"
    }

    private var canStop: Bool {
        container.state == "running" || container.state == "paused" || container.state == "restarting"
    }

    private var primaryTitle: String {
        FeatureL10n.text(showsStart ? .containersStart : .containersOpenLogs)
    }
}

private struct ContainerCard: View {
    let container: DockerContainer
    let subtitle: String

    var body: some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            ContainerLogo(imageName: container.image, baseImage: container.baseImage)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    OverflowingTagLine(tags: container.image.isEmpty ? [] : [container.image])
                    Spacer(minLength: 0)
                }
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
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: HostCardMetrics.cornerRadius))
        .overlay(alignment: .leading) {
            if let statusColor {
                Capsule()
                    .fill(statusColor)
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 5)
            }
        }
    }

    private var statusColor: Color? {
        if container.health == "unhealthy" { return .red }
        switch container.state {
        case "running": return .green
        case "restarting", "paused", "created": return .yellow
        case "dead": return .red
        default: return nil
        }
    }
}

private struct InspectorCircleButton: View {
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(disabled)
    }
}
