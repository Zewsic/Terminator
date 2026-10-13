import SwiftUI
import TerminatorCore

enum LogsPane: String, Hashable {
    case shell
    case events
}

struct SessionLogsView: View {
    @Binding var pane: LogsPane
    @Environment(TerminatorAppModel.self) private var model
    @State private var selectedLogID: UUID?
    @State private var selectedEventID: UUID?
    @State private var search = ""
    @State private var tray: CatalogTray?
    @State private var traySelection: Set<String> = []
    @State private var isWorkingTray = false
    @State private var isConfirmingRevert = false
    private var archiveHint = ArchiveHintStore.shared

    var body: some View {
        InspectorLayout(content: {
            switch pane {
            case .shell: shellList
            case .events: eventList
            }
        }, inspector: {
            if tray != nil {
                logArchive
            } else if pane == .shell, let log = model.visibleSessionLogs.first(where: { $0.id == selectedLogID }) {
                SessionLogInspector(log: log) { selectedLogID = nil }
            } else if pane == .events, let entry = model.history.first(where: { $0.id == selectedEventID }) {
                HistoryEventInspector(entry: entry, isConfirmingRevert: $isConfirmingRevert) {
                    selectedEventID = nil
                }
            }
        }, inspectorWidth: InspectorMetrics.compactWidth,
           isInspectorPresented: tray != nil || selectedLogID != nil || selectedEventID != nil,
           onContentInteraction: { closeInspector() })
        .navigationTitle(FeatureL10n.text(.sessionLogsLogs))
        .toolbar { toolbar }
        .task(id: pane) {
            guard pane == .shell else { return }
            while !Task.isCancelled {
                await model.reloadSessionLogs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: pane) { _, next in
            closeInspector()
            guard next == .events else { return }
            Task { await model.reloadHistory() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button(FeatureL10n.text(.actionRefresh), systemImage: "arrow.clockwise") {
                Task {
                    if pane == .shell {
                        await model.reloadSessionLogs()
                    } else {
                        await model.reloadHistory()
                    }
                }
            }
            .help(FeatureL10n.text(.actionRefresh))
        }
        ToolbarItem {
            ToolbarSearchField(text: $search, prompt: FeatureL10n.text(.logsSearch))
        }
        .sharedBackgroundVisibility(.hidden)
        if pane == .shell {
            ToolbarSpacer(.fixed)
            ToolbarItem { archiveButton }
        }
    }

    private var archiveButton: some View {
        Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox") {
            closeInspector()
            traySelection = []
            tray = .archive
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(FeatureL10n.text(.actionArchive))
        .help(archiveHint.isVisible ? FeatureL10n.text(.catalogArchiveHint) : FeatureL10n.text(.actionArchive))
        .popover(isPresented: hintPresented, arrowEdge: .bottom) {
            Text(FeatureL10n.text(.catalogArchiveHint))
                .font(.callout)
                .padding(14)
                .frame(width: 240)
        }
    }

    private var hintPresented: Binding<Bool> {
        Binding(get: { archiveHint.isVisible }, set: { if !$0 { archiveHint.dismiss() } })
    }

    @ViewBuilder
    private var shellList: some View {
        if model.visibleSessionLogs.isEmpty {
            ContentUnavailableView(
                FeatureL10n.text(.sessionLogsNoSessionLogs),
                systemImage: "text.document",
                description: Text(FeatureL10n.text(.sessionLogsRemoteTerminalOutputWillBeEncryptedAnd))
            )
        } else if filteredLogs.isEmpty {
            ContentUnavailableView.search
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLogs) { log in
                        logRow(log)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func logRow(_ log: SessionLogMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: log.isPinned ? "pin.fill" : "terminal")
            VStack(alignment: .leading) {
                Text(log.hostDisplayName).fontWeight(.medium)
                Text(FeatureL10n.text(
                    .sessionlogSummary,
                    log.terminal.displayName,
                    log.startedAt.formatted(),
                    ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file)
                ))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(log.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selectedLogID == log.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            tray = nil
            selectedLogID = log.id
        }
        .contextMenu {
            Button(FeatureL10n.text(log.isPinned ? .actionUnpin : .actionPin)) {
                Task { await model.setLogPinned(log.id, pinned: !log.isPinned) }
            }
            Button(FeatureL10n.text(.actionArchive)) {
                Task { await model.archiveLog(log) }
            }
            .disabled(log.state == .active)
            Button(FeatureL10n.text(.sessionLogsExport)) {
                Task { await model.exportLog(log) }
            }
            .disabled(log.state == .active)
        }
    }

    @ViewBuilder
    private var eventList: some View {
        if model.history.isEmpty {
            ContentUnavailableView(
                FeatureL10n.text(.logsEventsEmpty),
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                description: Text(FeatureL10n.text(.logsEventsEmptyDescription))
            )
        } else if filteredEvents.isEmpty {
            ContentUnavailableView.search
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEvents) { entry in
                        eventRow(entry)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func eventRow(_ entry: HistoryEntry) -> some View {
        let detail = HistoryEventSummary.detail(for: entry)
        return HStack(spacing: 12) {
            Image(systemName: detail.symbol)
            VStack(alignment: .leading) {
                Text(detail.name).fontWeight(.medium)
                Text("\(entry.title) · \(entry.timestamp.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selectedEventID == entry.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            tray = nil
            selectedEventID = entry.id
        }
    }

    private var filteredLogs: [SessionLogMetadata] {
        let terms = LogSearch.terms(in: search)
        guard !terms.isEmpty else { return model.visibleSessionLogs }
        return model.visibleSessionLogs.filter { log in
            LogSearch.matches(log, terms: terms)
        }
    }

    private var filteredEvents: [HistoryEntry] {
        let terms = LogSearch.terms(in: search)
        guard !terms.isEmpty else { return model.history }
        return model.history.filter { entry in
            LogSearch.matches(entry, terms: terms)
        }
    }

    private var logArchive: some View {
        CatalogPickerPanel(
            title: FeatureL10n.text(.actionArchive),
            subtitle: FeatureL10n.text(.catalogChooseArchive),
            records: model.archivedSessionLogs.map { log in
                CatalogPick(
                    id: log.id.uuidString,
                    title: log.hostDisplayName,
                    subtitle: "\(log.terminal.displayName) · \(log.startedAt.formatted())",
                    symbol: "terminal",
                    isEnabled: log.state != .active
                )
            },
            primaryTitle: FeatureL10n.text(.catalogRestore),
            destructiveTitle: FeatureL10n.text(.catalogDelete),
            emptyTitle: FeatureL10n.text(.featureArchiveArchiveIsEmpty),
            selection: $traySelection,
            isWorking: isWorkingTray,
            onPrimary: { applyArchive(restore: true) },
            onDestructive: { applyArchive(restore: false) },
            onClose: { tray = nil; traySelection = [] }
        )
    }

    private func applyArchive(restore: Bool) {
        let ids = traySelection
        Task {
            isWorkingTray = true
            defer { isWorkingTray = false }
            for id in ids {
                guard let log = model.archivedSessionLogs.first(where: { $0.id.uuidString == id }) else { continue }
                if restore {
                    _ = await model.restoreLog(log)
                } else {
                    await model.deleteLog(log)
                }
            }
            traySelection = []
        }
    }

    private func closeInspector() {
        selectedLogID = nil
        selectedEventID = nil
        tray = nil
        traySelection = []
    }
}

private enum LogSearch {
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ log: SessionLogMetadata, terms: [String]) -> Bool {
        let day = log.startedAt.formatted(.iso8601.year().month().day())
        let started = log.startedAt.formatted()
        return terms.allSatisfy { term in
            log.hostDisplayName.localizedCaseInsensitiveContains(term)
                || log.terminal.displayName.localizedCaseInsensitiveContains(term)
                || started.localizedCaseInsensitiveContains(term)
                || day.localizedCaseInsensitiveContains(term)
        }
    }

    static func matches(_ entry: HistoryEntry, terms: [String]) -> Bool {
        let detail = HistoryEventSummary.detail(for: entry)
        let day = entry.timestamp.formatted(.iso8601.year().month().day())
        let stamp = entry.timestamp.formatted()
        return terms.allSatisfy { term in
            detail.name.localizedCaseInsensitiveContains(term)
                || entry.title.localizedCaseInsensitiveContains(term)
                || entry.entity.rawValue.localizedCaseInsensitiveContains(term)
                || entry.operation.rawValue.localizedCaseInsensitiveContains(term)
                || stamp.localizedCaseInsensitiveContains(term)
                || day.localizedCaseInsensitiveContains(term)
        }
    }
}

private struct SessionLogInspector: View {
    let log: SessionLogMetadata
    let onClose: () -> Void
    @Environment(TerminatorAppModel.self) private var model
    @State private var isDetailsExpanded = true
    @State private var transcript: String?

    var body: some View {
        InspectorScreen(heading: heading) {
            InspectorCollapsibleSection(
                FeatureL10n.text(.inspectorSessionDetails),
                isExpanded: $isDetailsExpanded
            ) {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.featureSessionLogsTerminal)) {
                        InspectorReadOnlyValue(value: log.terminal.displayName)
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.featureContainersState)) {
                        InspectorReadOnlyValue(value: log.state.rawValue.capitalized)
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.featureSessionLogsStarted)) {
                        InspectorReadOnlyValue(value: log.startedAt.formatted())
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.featureSessionLogsSize)) {
                        InspectorReadOnlyValue(
                            value: ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file)
                        )
                    }
                }
            }
        } actions: {
            InspectorActionArea {
                HStack(spacing: 8) {
                    InspectorProminentAction(
                        title: FeatureL10n.text(.logsViewLog),
                        disabled: log.state == .active
                    ) {
                        Task { transcript = await model.sessionLogTranscript(log) }
                    }
                    Button {
                        Task { await model.exportLog(log) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(.blue)
                    .disabled(log.state == .active)
                    .help(FeatureL10n.text(.sessionLogsExport))
                    .accessibilityLabel(FeatureL10n.text(.sessionLogsExport))
                }
            }
        }
        .sheet(isPresented: Binding(get: { transcript != nil }, set: { if !$0 { transcript = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(transcript ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .navigationTitle(log.hostDisplayName)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(FeatureL10n.text(.actionClose)) { transcript = nil }
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(log.hostDisplayName)
                .font(.title2.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(FeatureL10n.text(.actionClose))
            .accessibilityLabel(FeatureL10n.text(.actionClose))
        }
    }
}

private struct HistoryEventInspector: View {
    let entry: HistoryEntry
    @Binding var isConfirmingRevert: Bool
    let onClose: () -> Void
    @Environment(TerminatorAppModel.self) private var model
    @State private var isDetailsExpanded = true

    private var detail: HistoryEventDetail { HistoryEventSummary.detail(for: entry) }
    private var canRevert: Bool {
        entry.entity != .task && !(entry.entity == .credential && entry.operation == .purged)
    }

    var body: some View {
        InspectorScreen(heading: heading) {
            InspectorCollapsibleSection(entry.title, isExpanded: $isDetailsExpanded) {
                InspectorFieldGroup {
                    InspectorFieldRow(FeatureL10n.text(.logsFieldName)) {
                        InspectorReadOnlyValue(value: detail.name)
                    }
                    InspectorGroupDivider()
                    InspectorFieldRow(FeatureL10n.text(.featureSessionLogsStarted)) {
                        InspectorReadOnlyValue(value: entry.timestamp.formatted())
                    }
                }
                if detail.changes.isEmpty {
                    Text(FeatureL10n.text(.logsEventsNoChanges))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(detail.changes) { change in
                            HistoryChangeRow(change: change)
                        }
                    }
                }
            }
            if detail.touchesPassword {
                Text(FeatureL10n.text(.logsEventsPasswordNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            if entry.entity != .task {
                InspectorActionArea {
                    InspectorProminentAction(title: FeatureL10n.text(.historyRevert), disabled: !canRevert) {
                        isConfirmingRevert = true
                    }
                }
            }
        }
        .confirmationDialog(
            FeatureL10n.text(.historyRevertConfirmationTitle),
            isPresented: $isConfirmingRevert,
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.historyRevert)) {
                Task { await model.revert(historyEntryID: entry.id) }
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) {}
        } message: {
            Text(FeatureL10n.text(.historyRevertingCreatesANewHistoryEntryExisting))
        }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: detail.symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 28, height: 28)
            Text(detail.name)
                .font(.title2.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(FeatureL10n.text(.actionClose))
            .accessibilityLabel(FeatureL10n.text(.actionClose))
        }
    }
}

struct HistoryChangeRow: View {
    let change: HistoryFieldChange

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(change.label)
                    .font(.caption.weight(.semibold))
            }
            if change.isHidden {
                Text(FeatureL10n.text(.logsChangeHidden))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let before = change.before, change.kind != .added {
                    Text(before)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .strikethrough(change.kind == .changed || change.kind == .removed)
                }
                if let after = change.after, change.kind != .removed {
                    Text(after)
                        .font(.caption.monospaced())
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch change.kind {
        case .added: "plus"
        case .removed: "minus"
        case .changed: "pencil"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added: .green
        case .removed: .red
        case .changed: .primary
        }
    }
}
