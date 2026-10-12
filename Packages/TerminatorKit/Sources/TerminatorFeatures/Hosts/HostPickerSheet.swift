import SwiftUI
import TerminatorCore

struct HostPickerSheet: View {
    let title: String
    let actionTitle: String
    let work: (HostProfile) async -> HostActionResult

    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: Set<UUID> = []
    @State private var phase: Phase = .picking
    @State private var rows: [UUID: RowState] = [:]

    private enum Phase { case picking, running, finished }

    private enum RowState {
        case running
        case success(String)
        case failure(String)
    }

    private var hosts: [HostProfile] {
        model.hosts
            .filter { !$0.isDeleted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var visibleHosts: [HostProfile] {
        let base: [HostProfile]
        if phase == .picking {
            let terms = HostCatalogSearch.terms(in: search)
            base = hosts.filter { HostCatalogSearch.matches($0, terms: terms, identities: model.identities) }
        } else {
            base = hosts.filter { selected.contains($0.id) }
        }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                if phase == .picking {
                    searchField
                }
                if visibleHosts.isEmpty {
                    ContentUnavailableView(FeatureL10n.text(.hostPickerNoHosts), systemImage: "server.rack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(visibleHosts.enumerated()), id: \.element.id) { index, host in
                                if index > 0 { Divider() }
                                hostRow(host)
                            }
                        }
                    }
                }
                if phase == .picking {
                    InspectorProminentAction(
                        title: actionTitle,
                        disabled: selected.isEmpty,
                        action: run
                    )
                    .keyboardShortcut(.defaultAction)
                } else {
                    Text(FeatureL10n.text(.hostPickerFullHistory))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 640)
        .presentationBackground(.ultraThinMaterial)
    }

    private var header: some View {
        ZStack {
            Text(title)
                .font(.title2.bold())
                .lineLimit(1)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .running)
                .help(FeatureL10n.text(.actionClose))
                .accessibilityLabel(FeatureL10n.text(.actionClose))
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(FeatureL10n.text(.hostsSearchHosts), text: $search)
                .textFieldStyle(.plain)
            if !visibleHosts.isEmpty {
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

    private func hostRow(_ host: HostProfile) -> some View {
        Button {
            guard phase == .picking else { return }
            if selected.contains(host.id) { selected.remove(host.id) } else { selected.insert(host.id) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(subtitle(host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let detail = detail(for: host.id) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                marker(for: host.id)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase != .picking)
    }

    @ViewBuilder
    private func marker(for id: UUID) -> some View {
        switch rows[id] {
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        case nil:
            Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(id) ? Color.blue : Color.secondary)
        }
    }

    private func detail(for id: UUID) -> String? {
        switch rows[id] {
        case .success(let message), .failure(let message): return message
        default: return nil
        }
    }

    private func subtitle(_ host: HostProfile) -> String {
        let username = host.authentication.manualUsername
            ?? host.authentication.identityID.flatMap { id in model.identities.first { $0.id == id }?.username }
            ?? ""
        if username.isEmpty { return host.hostname }
        return "\(username)@\(host.hostname)"
    }

    private func toggleAll() {
        let ids = Set(visibleHosts.map(\.id))
        if ids.isSubset(of: selected) {
            selected.subtract(ids)
        } else {
            selected.formUnion(ids)
        }
    }

    private func run() {
        let chosen = hosts.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        phase = .running
        for host in chosen { rows[host.id] = .running }
        Task {
            for host in chosen {
                let result = await work(host)
                rows[host.id] = result.succeeded ? .success(result.message) : .failure(result.message)
            }
            await model.load()
            phase = .finished
        }
    }
}
