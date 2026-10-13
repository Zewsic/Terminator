import SwiftUI

struct TaskEditorFields: View {
    let backend: TaskBackend
    @Binding var draft: TaskDraft
    var isEnabled = true
    var showsIdentity = true

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.sectionSpacing) {
            if showsIdentity {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.tasksName)) {
                        TextField(FeatureL10n.text(.tasksName), text: $draft.name)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                    if backend != .at {
                        InspectorGroupDivider()
                        InspectorFieldRow(FeatureL10n.text(.tasksEnableThis)) {
                            Toggle("", isOn: $draft.enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
            }
            InspectorFieldGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FeatureL10n.text(.tasksCommand))
                        .fontWeight(.medium)
                    TextField(FeatureL10n.text(.tasksCommand), text: $draft.command, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            InspectorFieldGroup {
                scheduleRow
                timingRow
            }
            if hasAdditional {
                TaskMoreSection {
                    extra
                }
            }
        }
        .disabled(!isEnabled)
    }

    private var hasAdditional: Bool {
        backend == .cron || backend == .systemd || backend == .at
    }

    @ViewBuilder
    private var scheduleRow: some View {
        switch backend {
        case .at:
            InspectorFieldRow(FeatureL10n.text(.tasksOnce)) {
                DatePicker("", selection: $draft.schedule.onceAt)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        case .anacron:
            InspectorFieldRow(FeatureL10n.text(.tasksPeriod)) {
                Stepper("\(draft.schedule.periodDays)", value: $draft.schedule.periodDays, in: 1...365)
            }
        case .cron, .systemd, .launchd:
            InspectorFieldRow(FeatureL10n.text(.tasksWhen)) {
                InspectorValueMenu(title: presetTitle) {
                    presetButton(.hourly, FeatureL10n.text(.tasksHourly))
                    presetButton(.daily, FeatureL10n.text(.tasksDaily))
                    presetButton(.weekly, FeatureL10n.text(.tasksWeekly))
                    presetButton(.monthly, FeatureL10n.text(.tasksMonthly))
                    if backend == .launchd {
                        presetButton(.interval, FeatureL10n.text(.tasksInterval))
                    }
                    presetButton(.reboot, FeatureL10n.text(.tasksStartup))
                    presetButton(.custom, FeatureL10n.text(.tasksCustom))
                }
            }
        }
    }

    @ViewBuilder
    private var timingRow: some View {
        switch backend {
        case .anacron:
            InspectorGroupDivider()
            InspectorFieldRow(FeatureL10n.text(.tasksDelay)) {
                Stepper("\(draft.schedule.anacronDelayMinutes)", value: $draft.schedule.anacronDelayMinutes, in: 0...240)
            }
        case .cron, .systemd, .launchd:
            switch draft.schedule.preset {
            case .hourly:
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksMinute)) {
                    Stepper(value: $draft.schedule.minute, in: 0...59) {
                        Text(":\(String(format: "%02d", draft.schedule.minute))")
                    }
                }
            case .daily, .weekly, .monthly:
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksTime)) {
                    DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                if draft.schedule.preset == .weekly {
                    InspectorGroupDivider()
                    weekdays
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                if draft.schedule.preset == .monthly {
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.tasksDay)) {
                        Stepper("\(draft.schedule.dayOfMonth)", value: $draft.schedule.dayOfMonth, in: 1...31)
                    }
                }
            case .interval:
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksInterval)) {
                    Stepper("\(draft.schedule.intervalMinutes) min", value: $draft.schedule.intervalMinutes, in: 1...10_080)
                }
            case .reboot:
                EmptyView()
            case .custom:
                customSchedule
            }
        case .at:
            EmptyView()
        }
    }

    private var presetTitle: String {
        switch draft.schedule.preset {
        case .hourly: FeatureL10n.text(.tasksHourly)
        case .daily: FeatureL10n.text(.tasksDaily)
        case .weekly: FeatureL10n.text(.tasksWeekly)
        case .monthly: FeatureL10n.text(.tasksMonthly)
        case .interval: FeatureL10n.text(.tasksInterval)
        case .reboot: FeatureL10n.text(.tasksStartup)
        case .custom: FeatureL10n.text(.tasksCustom)
        }
    }

    private func presetButton(_ preset: TaskSchedule.Preset, _ title: String) -> some View {
        Button(title) { draft.schedule.preset = preset }
    }



    private var weekdays: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let selected = draft.schedule.weekday == day
                Button(String(TaskScheduleText.weekday(day).prefix(2))) {
                    draft.schedule.weekday = day
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
            }
        }
    }

    private var customSchedule: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorGroupDivider()
            HStack(spacing: 8) {
                cronInput(FeatureL10n.text(.tasksMinute), $draft.schedule.cronMinute)
                cronInput(FeatureL10n.text(.tasksHour), $draft.schedule.cronHour)
                cronInput(FeatureL10n.text(.tasksDay), $draft.schedule.cronDayOfMonth)
                cronInput(FeatureL10n.text(.tasksMonth), $draft.schedule.cronMonth)
                cronInput(FeatureL10n.text(.tasksWeekday), $draft.schedule.cronDayOfWeek)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func cronInput(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.body.monospaced())
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var extra: some View {
        if backend == .cron {
            InspectorFieldGroup {
                plainRow(FeatureL10n.text(.tasksShell), $draft.shell)
                InspectorGroupDivider()
                plainRow(FeatureL10n.text(.tasksPath), $draft.path)
                InspectorGroupDivider()
                plainRow(FeatureL10n.text(.tasksMailto), $draft.mailto)
            }
        }
        if backend == .systemd {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.tasksCatchUp)) {
                    Toggle("", isOn: $draft.schedule.catchUp).labelsHidden().toggleStyle(.switch)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksBootDelay)) {
                    Stepper("\(draft.schedule.bootDelayMinutes)", value: $draft.schedule.bootDelayMinutes, in: 0...10_080)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksAfterPrevious)) {
                    Stepper("\(draft.schedule.afterPreviousMinutes)", value: $draft.schedule.afterPreviousMinutes, in: 0...10_080)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksRandomDelay)) {
                    Stepper("\(draft.schedule.randomDelayMinutes)", value: $draft.schedule.randomDelayMinutes, in: 0...1_440)
                }
            }
        }
        if backend == .at {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.tasksBatch)) {
                    Toggle("", isOn: $draft.schedule.batch).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private func plainRow(_ title: String, _ text: Binding<String>) -> some View {
        InspectorFieldRow(title) {
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                components.hour = draft.schedule.hour
                components.minute = draft.schedule.minute
                return Calendar.current.date(from: components) ?? .now
            },
            set: { date in
                draft.schedule.hour = Calendar.current.component(.hour, from: date)
                draft.schedule.minute = Calendar.current.component(.minute, from: date)
            }
        )
    }
}

private struct TaskMoreSection<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Text(FeatureL10n.text(.tasksAdditional))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TaskCreateSheet: View {
    let hostID: UUID
    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TaskDraft()
    @State private var isSaving = false
    @State private var explainedProgram: String?
    @State private var programID = TaskBackend.cron.rawValue
    private var development = DevelopmentPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                programs
                editor
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 920, height: 640)
        .onAppear(perform: selectInitialProgram)
    }

    private var header: some View {
        ZStack {
            Text(FeatureL10n.text(.tasksCreate))
                .font(.title2.bold())
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help(FeatureL10n.text(.actionClose))
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var programs: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorFieldGroup {
                InspectorFieldRow(FeatureL10n.text(.tasksName)) {
                    TextField(FeatureL10n.text(.tasksName), text: $draft.name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                InspectorGroupDivider()
                InspectorFieldRow(FeatureL10n.text(.tasksEnableThis)) {
                    Toggle("", isOn: $draft.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(FeatureL10n.text(.tasksProgram))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(TaskBackend.allCases) { backend in
                            programRow(
                                id: backend.id,
                                title: backend.title,
                                symbol: backend.symbol,
                                selected: programID == backend.id,
                                allowed: allows(backend),
                                reason: unavailableReason(backend)
                            ) {
                                programID = backend.id
                                draft.backend = backend
                            }
                            if backend == .cron {
                                let systemCron = model.serverTaskCapabilities[hostID]?.systemCron == true
                                programRow(
                                    id: "system-cron",
                                    title: FeatureL10n.text(.tasksSystemCron),
                                    symbol: "clock",
                                    selected: programID == "system-cron",
                                    allowed: systemCron,
                                    reason: FeatureL10n.text(.tasksUnavailableSystemCron)
                                ) {
                                    programID = "system-cron"
                                    draft.backend = .cron
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.quaternary, in: .rect(cornerRadius: InspectorMetrics.groupCornerRadius))
        }
        .padding(16)
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func programRow(
        id: String,
        title: String,
        symbol: String,
        selected: Bool,
        allowed: Bool,
        reason: String,
        select: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .frame(width: 22)
                    Text(title)
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!allowed)
            .opacity(allowed ? 1 : 0.38)
            if !allowed {
                Button {
                    explainedProgram = explainedProgram == id ? nil : id
                } label: {
                    Image(systemName: "questionmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help(reason)
                .popover(isPresented: Binding(
                    get: { explainedProgram == id },
                    set: { if !$0, explainedProgram == id { explainedProgram = nil } }
                )) {
                    Text(reason)
                        .font(.callout)
                        .padding(14)
                        .frame(width: 240, alignment: .leading)
                }
            }
        }
        .frame(height: 40)
        .foregroundStyle(selected && allowed ? Color.white : Color.primary)
        .background(
            selected && allowed ? Color.accentColor : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func unavailableReason(_ backend: TaskBackend) -> String {
        switch backend {
        case .cron: FeatureL10n.text(.tasksUnavailableCron)
        case .systemd: FeatureL10n.text(.tasksUnavailableSystemd)
        case .at: FeatureL10n.text(.tasksUnavailableAt)
        case .anacron: FeatureL10n.text(.tasksUnavailableAnacron)
        case .launchd: FeatureL10n.text(.tasksUnavailableLaunchd)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                TaskEditorFields(backend: draft.backend, draft: $draft, showsIdentity: false)
                    .padding(.trailing, 4)
            }
            InspectorProminentAction(
                title: FeatureL10n.text(.tasksCreate),
                disabled: isSaving || draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: save
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func allows(_ backend: TaskBackend) -> Bool {
        if development.previewsUnavailableFeatures { return true }
        return (model.serverTaskCapabilities[hostID] ?? TaskCapabilities()).allows(backend)
    }

    private func selectInitialProgram() {
        if allows(draft.backend) { return }
        if let backend = TaskBackend.allCases.first(where: allows) {
            draft.backend = backend
        }
    }

    private func save() {
        isSaving = true
        Task {
            if programID == "system-cron" {
                model.present(id: "task-save", message: FeatureL10n.text(.tasksSaveFailed))
                isSaving = false
                return
            }
            let saved = await model.saveServerTask(hostID: hostID, existing: nil, draft: draft)
            isSaving = false
            if saved { dismiss() }
        }
    }
}
