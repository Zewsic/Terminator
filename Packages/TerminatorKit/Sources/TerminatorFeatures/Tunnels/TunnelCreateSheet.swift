import SwiftUI
import TerminatorCore

struct TunnelCreateSheet: View {
    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TunnelDraft()
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                detailsColumn
                endpointsColumn
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .frame(width: 920, height: 640)
    }

    private var header: some View {
        ZStack {
            Text(FeatureL10n.text(.tunnelCreate))
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
                .accessibilityLabel(FeatureL10n.text(.actionClose))
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            TunnelKindSelector(kind: $draft.kind)
            TunnelSettingsGroup(draft: $draft)
            Spacer(minLength: 16)
            TunnelUseExamples(kind: draft.kind, sourceName: sourceName, destinationName: destinationName) { listenPort, targetPort in
                draft.listenAddress = "127.0.0.1"
                draft.listenPort = listenPort
                draft.targetAddress = "127.0.0.1"
                draft.targetPort = targetPort
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var endpointsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            TunnelEndpointStack(draft: $draft)
            Spacer(minLength: 12)
            InspectorProminentAction(
                title: FeatureL10n.text(.tunnelCreate),
                disabled: !canCreate || isSaving,
                action: save
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("create-tunnel")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var sourceName: String {
        model.endpointName(draft.source, fallback: FeatureL10n.text(.tunnelHostA))
    }

    private var destinationName: String {
        guard let destination = draft.destination else { return FeatureL10n.text(.tunnelHostB) }
        return model.endpointName(destination, fallback: FeatureL10n.text(.tunnelHostB))
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await model.saveTunnel(draftForSave())
            isSaving = false
            if saved { dismiss() }
        }
    }

    private func normalized(_ draft: TunnelDraft) -> TunnelDraft {
        var copy = draft
        if !copy.allowsAutomaticConnect { copy.connectAutomatically = false }
        return copy
    }

    private func draftForSave() -> TunnelDraft {
        var copy = normalized(draft)
        if copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.displayName = generatedName(for: copy)
        }
        return copy
    }

    private func generatedName(for draft: TunnelDraft) -> String {
        switch draft.kind {
        case .local:
            FeatureL10n.text(.tunnelDefaultNameLocal, draft.listenPort, destinationName)
        case .remote:
            FeatureL10n.text(.tunnelDefaultNameRemote, draft.targetPort, destinationName)
        case .dynamic:
            FeatureL10n.text(.tunnelDefaultNameDynamic, draft.listenPort, destinationName)
        }
    }

    private var canCreate: Bool {
        let draft = normalized(self.draft)
        guard draft.destination != nil,
              !draft.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(draft.listenPort) else { return false }
        if case .thisMac = draft.destination { return false }
        if draft.kind != .dynamic {
            guard !draft.targetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65_535).contains(draft.targetPort) else { return false }
        }
        if case .manual(_, let hostname, let port) = draft.source {
            guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65_535).contains(port) else { return false }
        }
        if case .manual(_, let hostname, let port) = draft.destination {
            guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65_535).contains(port) else { return false }
        }
        return true
    }
}
