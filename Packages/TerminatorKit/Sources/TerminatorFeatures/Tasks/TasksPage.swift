import SwiftUI

struct TasksPage: View {
    let hostID: UUID
    @Binding var search: String
    var grouped: Bool
    var taskSort: ServerSettingsSort
    var hideSystemTasks: Bool
    @Binding var isCreating: Bool
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedID: UUID?
    @State private var executionLimit = 10
    @State private var collapsedGroups: Set<String> = []
    @State private var pendingDelete: ScheduledTask?

    private var tasks: [ScheduledTask] {
        let source = model.serverTasks[hostID] ?? []
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = source.filter { task in
            if hideSystemTasks, task.scope == .system { return false }
            guard !terms.isEmpty else { return true }
            let haystack = [
                task.listTitle,
                task.command,
                TaskScheduleText.summary(task.schedule, backend: task.backend),
                task.backend.title,
            ].joined(separator: " ")
            return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
        return filtered.sorted { lhs, rhs in
            switch taskSort {
            case .name:
                return lhs.listTitle.localizedCaseInsensitiveCompare(rhs.listTitle) == .orderedAscending
            case .lastRun:
                let left = model.taskLastRuns[hostID]?[lhs.id]
                let right = model.taskLastRuns[hostID]?[rhs.id]
                switch (left, right) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.listTitle.localizedCaseInsensitiveCompare(rhs.listTitle) == .orderedAscending
            }
        }
    }

    private var selected: ScheduledTask? {
        tasks.first { $0.id == selectedID } ?? model.serverTasks[hostID]?.first { task in
            task.id == selectedID && !(hideSystemTasks && task.scope == .system)
        }
    }

    private struct TaskListGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [ScheduledTask]
    }

    private var taskGroups: [TaskListGroup] {
        if !grouped {
            return [TaskListGroup(id: "__flat", title: "", tasks: tasks)]
        }
        let groupedTasks = Dictionary(grouping: tasks, by: { programKey($0) })
        return groupedTasks.map { key, rows in
            TaskListGroup(id: key, title: programLabel(rows[0]), tasks: rows)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var taskGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: HostCardMetrics.width, maximum: HostCardMetrics.width), spacing: HostCardMetrics.spacing, alignment: .leading)]
    }

    private func programKey(_ task: ScheduledTask) -> String {
        task.backend == .cron && task.scope == .system ? "system-cron" : task.backend.rawValue
    }

    private func programLabel(_ task: ScheduledTask) -> String {
        if task.backend == .cron, task.scope == .system {
            return FeatureL10n.text(.tasksSystemCron)
        }
        return task.backend.title
    }

    var body: some View {
        InspectorLayout(content: {
            list
        }, inspector: {
            if let selected {
                TaskInspector(hostID: hostID, task: selected, executionLimit: $executionLimit) {
                    selectedID = nil
                }
            }
        }, inspectorWidth: InspectorMetrics.compactWidth, isInspectorPresented: selected != nil, onContentInteraction: {
            selectedID = nil
        })
        .task(id: hostID) {
            await model.loadServerTasks(hostID: hostID)
            await model.loadTaskLastRuns(hostID: hostID)
        }
        .sheet(isPresented: $isCreating) {
            TaskCreateSheet(hostID: hostID)
        }
        .confirmationDialog(
            FeatureL10n.text(.tasksDeleteConfirm),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.tasksDelete), role: .destructive) {
                guard let task = pendingDelete else { return }
                pendingDelete = nil
                let environment = model.serverCrontabs[hostID]?.environment ?? CrontabEnvironment()
                Task {
                    if await model.deleteServerTask(hostID: hostID, task: task, draft: TaskDraft(task: task, environment: environment)),
                       selectedID == task.id {
                        selectedID = nil
                    }
                }
            }
            Button(FeatureL10n.text(.actionCancel), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.serverTasksLoading.contains(hostID), tasks.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.serverTasksOffline.contains(hostID), tasks.isEmpty {
            ContentUnavailableView(FeatureL10n.text(.tasksHelperOffline), systemImage: "wifi.slash")
        } else if tasks.isEmpty {
            ContentUnavailableView(FeatureL10n.text(.tasksEmpty), systemImage: "calendar.badge.clock")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(taskGroups) { group in
                        if !group.title.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if collapsedGroups.contains(group.id) {
                                        collapsedGroups.remove(group.id)
                                    } else {
                                        collapsedGroups.insert(group.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                    Text(group.title)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }

                        if !collapsedGroups.contains(group.id) {
                            LazyVGrid(columns: taskGridColumns, alignment: .leading, spacing: HostCardMetrics.spacing) {
                                ForEach(group.tasks) { task in
                                    TaskCard(
                                        title: task.listTitle,
                                        program: programLabel(task),
                                        subtitle: TaskScheduleText.summary(task.schedule, backend: task.backend),
                                        enabled: task.enabled,
                                        isSelected: selectedID == task.id
                                    )
                                    .onTapGesture { selectedID = task.id }
                                    .contextMenu {
                                        Button(FeatureL10n.text(.tasksRunNow), systemImage: "play.fill") {}
                                        if task.writable {
                                            Divider()
                                            Button(FeatureL10n.text(.tasksDelete), systemImage: "trash", role: .destructive) {
                                                pendingDelete = task
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TaskCard: View {
    let title: String
    let program: String
    let subtitle: String
    let enabled: Bool
    var isSelected = false

    var body: some View {
        HStack(spacing: HostCardMetrics.iconInset) {
            Circle()
                .fill(enabled ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .frame(width: HostCardMetrics.iconSize, height: HostCardMetrics.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(program)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
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
        .overlay {
            let shape = RoundedRectangle(cornerRadius: HostCardMetrics.cornerRadius, style: .continuous)
            if isSelected {
                shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
            }
        }
    }
}

private struct TaskInspector: View {
    let hostID: UUID
    let task: ScheduledTask
    @Binding var executionLimit: Int
    let onClose: () -> Void
    @Environment(TerminatorAppModel.self) private var model
    @State private var pane = Pane.status
    @State private var draft: TaskDraft
    @State private var isSaving = false

    init(hostID: UUID, task: ScheduledTask, executionLimit: Binding<Int>, onClose: @escaping () -> Void) {
        self.hostID = hostID
        self.task = task
        _executionLimit = executionLimit
        self.onClose = onClose
        _draft = State(initialValue: TaskDraft(task: task, environment: CrontabEnvironment()))
    }

    private enum Pane: Hashable { case status, task }

    private var baseline: TaskDraft {
        TaskDraft(task: task, environment: model.serverCrontabs[hostID]?.environment ?? CrontabEnvironment())
    }

    private var hasChanges: Bool { draft != baseline }

    var body: some View {
        InspectorScreen(heading: heading) {
            if pane == .status {
                status
            } else {
                TaskEditorFields(backend: task.backend, draft: $draft, isEnabled: task.writable)
            }
        } actions: {
            InspectorActionArea {
                if pane == .task, task.writable, hasChanges {
                    HStack(spacing: 8) {
                        InspectorProminentAction(
                            title: FeatureL10n.text(.actionSave),
                            disabled: isSaving,
                            action: save
                        )
                        InspectorRevertButton {
                            draft = baseline
                        }
                        .disabled(isSaving)
                    }
                } else {
                    InspectorProminentAction(
                        title: FeatureL10n.text(.tasksRunNow),
                        action: {}
                    )
                }
            }
        }
        .task(id: task.id) {
            await model.loadTaskExecutions(hostID: hostID, limit: executionLimit)
            await model.reloadHistory()
        }
        .onChange(of: task) { _, next in
            draft = TaskDraft(task: next, environment: model.serverCrontabs[hostID]?.environment ?? CrontabEnvironment())
        }
        .onAppear {
            if let environment = model.serverCrontabs[hostID]?.environment {
                draft.shell = environment.shell
                draft.path = environment.path
                draft.mailto = environment.mailto
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 0) {
            InspectorSegmentedSelector(
                selection: $pane,
                options: [
                    InspectorSelectorOption(value: Pane.status, title: FeatureL10n.text(.tasksStatus)),
                    InspectorSelectorOption(value: Pane.task, title: FeatureL10n.text(.tasksTask)),
                ],
                style: .joined
            )
            Spacer(minLength: 0)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.tasksName)) {
                    InspectorReadOnlyValue(value: task.listTitle)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksEnabled)) {
                    InspectorReadOnlyValue(value: task.enabled ? "On" : "Off")
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksProgram)) {
                    InspectorReadOnlyValue(value: programTitle)
                }
            }
            let executions = model.serverTaskExecutions[hostID] ?? []
            InspectorFieldGroup {
                HStack {
                    Text(FeatureL10n.text(.tasksExecutions)).fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: InspectorMetrics.rowHeight)
                if executions.isEmpty {
                    InspectorGroupDivider()
                    Text(FeatureL10n.text(.tasksNoExecutions))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: InspectorMetrics.rowHeight)
                } else {
                    ForEach(executions) { execution in
                        InspectorGroupDivider()
                        HStack(spacing: 12) {
                            Text(executionDate(execution))
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .foregroundStyle(execution.result == "Failed" ? Color.red : Color.primary)
                            Spacer(minLength: 8)
                            Button(FeatureL10n.text(.tasksOpenLog)) {}
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.blue)
                                .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
                if executions.count >= executionLimit {
                    InspectorGroupDivider()
                    Button(FeatureL10n.text(.tasksLoadMoreExecutions)) {
                        executionLimit += 30
                        Task { await model.loadTaskExecutions(hostID: hostID, limit: executionLimit) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight)
                }
            }
        }
    }

    private var programTitle: String {
        if task.backend == .cron, task.scope == .system {
            return FeatureL10n.text(.tasksSystemCron)
        }
        return task.backend.title
    }

    private func executionDate(_ execution: TaskExecution) -> String {
        if let recordedAt = execution.recordedAt {
            return recordedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return execution.summary
    }

    private func save() {
        isSaving = true
        Task {
            _ = await model.saveServerTask(hostID: hostID, existing: task, draft: draft)
            isSaving = false
        }
    }
}


