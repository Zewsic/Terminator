import SwiftUI
import TerminatorCore

struct TunnelEditor: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var draft: TunnelDraft
    @State private var originalDraft: TunnelDraft
    let onSave: @MainActor (TunnelDraft) async -> Bool
    let onStart: @MainActor () -> Void
    let onStop: @MainActor () -> Void

    init(
        tunnel: TunnelProfile,
        onSave: @escaping @MainActor (TunnelDraft) async -> Bool,
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void
    ) {
        let initial = TunnelDraft(tunnel: tunnel)
        _draft = State(initialValue: initial)
        _originalDraft = State(initialValue: initial)
        self.onSave = onSave
        self.onStart = onStart
        self.onStop = onStop
    }

    var body: some View {
        InspectorScreen(title: FeatureL10n.text(.tunnelEdit)) {
            TunnelKindSelector(kind: $draft.kind)
            TunnelSettingsGroup(draft: $draft)
            TunnelEndpointStack(draft: $draft)
        } actions: {
            InspectorActionArea {
                if hasChanges {
                    InspectorTextAction(title: FeatureL10n.text(.identityEditorCancelChanges)) {
                        draft = originalDraft
                    }
                }
                InspectorProminentAction(title: primaryTitle) {
                    performPrimary()
                }
            }
        }
        .onDisappear {
            let value = normalized(draft)
            guard value != normalized(originalDraft) else { return }
            Task { await onSave(value) }
        }
    }

    private var hasChanges: Bool { normalized(draft) != normalized(originalDraft) }

    private var primaryTitle: String {
        isRunning ? FeatureL10n.text(.tunnelStop) : FeatureL10n.text(.tunnelStart)
    }

    private var isRunning: Bool {
        guard let id = draft.id else { return false }
        if case .connected = model.tunnelPhase(for: id) { return true }
        return model.tunnelPhase(for: id).isWorking
    }

    private func performPrimary() {
        Task {
            if isRunning {
                onStop()
                return
            }
            let value = normalized(draft)
            if value != normalized(originalDraft) {
                guard await onSave(value) else { return }
                originalDraft = draft
            }
            onStart()
        }
    }

    private func normalized(_ draft: TunnelDraft) -> TunnelDraft {
        var copy = draft
        if !copy.allowsAutomaticConnect { copy.connectAutomatically = false }
        return copy
    }
}
