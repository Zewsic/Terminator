import SwiftUI
import Observation

enum CatalogTray: Equatable {
    case source(String)
    case archive
}

struct CatalogPick: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var isEnabled = true
}

@MainActor
@Observable
final class ArchiveHintStore {
    static let shared = ArchiveHintStore()

    private(set) var isVisible = false

    /// Shows the archive hint again. It lasts only for this launch.
    func arm() {
        isVisible = true
    }

    func dismiss() {
        isVisible = false
    }
}

struct CatalogPickerPanel: View {
    let title: String
    let subtitle: String
    let records: [CatalogPick]
    var isLoading = false
    let primaryTitle: String
    var destructiveTitle: String?
    let emptyTitle: String
    @Binding var selection: Set<String>
    var isWorking = false
    let onPrimary: () -> Void
    var onDestructive: () -> Void = {}
    let onClose: () -> Void

    @State private var query = ""
    @State private var isConfirmingDelete = false

    private var visibleRecords: [CatalogPick] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            terms.allSatisfy { term in
                record.title.localizedCaseInsensitiveContains(term)
                    || record.subtitle.localizedCaseInsensitiveContains(term)
            }
        }
    }

    private var enabledVisibleIDs: Set<String> {
        Set(visibleRecords.filter(\.isEnabled).map(\.id))
    }

    private var selectedCount: Int {
        selection.intersection(Set(records.filter(\.isEnabled).map(\.id))).count
    }

    var body: some View {
        InspectorScreen(heading: heading) {
            searchField
            if isLoading && records.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if visibleRecords.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                list
            }
        } actions: {
            InspectorActionArea {
                if destructiveTitle != nil {
                    HStack(spacing: 8) {
                        InspectorProminentAction(
                            title: primaryTitle,
                            disabled: isWorking || selectedCount == 0,
                            action: onPrimary
                        )
                        InspectorCircleButton(
                            systemImage: "trash",
                            foreground: Color.red.opacity(0.72),
                            help: destructiveTitle ?? ""
                        ) {
                            isConfirmingDelete = true
                        }
                        .disabled(isWorking || selectedCount == 0)
                    }
                } else {
                    InspectorProminentAction(
                        title: primaryTitle,
                        disabled: isWorking || selectedCount == 0,
                        action: onPrimary
                    )
                }
            }
        }
        .confirmationDialog(
            FeatureL10n.text(.catalogDeleteConfirm),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.catalogDelete), role: .destructive) { onDestructive() }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) {}
        } message: {
            Text(FeatureL10n.text(.catalogDeleteMessage))
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(FeatureL10n.text(.catalogSearch), text: $query)
                .textFieldStyle(.plain)
            if !enabledVisibleIDs.isEmpty {
                Button(FeatureL10n.text(.catalogSelectAll)) { toggleAll() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }

    private var list: some View {
        InspectorFieldGroup {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                if index > 0 { InspectorGroupDivider() }
                row(record)
            }
        }
    }

    private func row(_ record: CatalogPick) -> some View {
        let selected = selection.contains(record.id)
        return Button {
            guard record.isEnabled else { return }
            if selected { selection.remove(record.id) } else { selection.insert(record.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(record.isEnabled ? (selected ? Color.blue : Color.secondary) : Color.secondary.opacity(0.45))
                    .frame(width: 24)
                Image(systemName: record.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(record.isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(record.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!record.isEnabled)
    }

    private func toggleAll() {
        if enabledVisibleIDs.isSubset(of: selection) {
            selection.subtract(enabledVisibleIDs)
        } else {
            selection.formUnion(enabledVisibleIDs)
        }
    }
}
