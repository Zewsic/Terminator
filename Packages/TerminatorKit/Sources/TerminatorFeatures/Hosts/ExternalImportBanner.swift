import SwiftUI
import TerminatorCore

struct CatalogImportBanner: View {
    let hint: DismissedHintsStore.Hint
    @Environment(TerminatorAppModel.self) private var model
    private var dismissedHints = DismissedHintsStore.shared

    var body: some View {
        if showsBanner {
            ExternalImportBanner(
                sources: model.availableImportSources,
                loadingIDs: model.loadingImportSourceIDs,
                onImport: { source in
                    Task { await model.loadImportSource(source) }
                },
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        dismissedHints.dismiss(hint)
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
        }
    }

    private var showsBanner: Bool {
        !dismissedHints.isDismissed(hint)
            && model.capabilities.externalFileAccess
            && !model.importSources.isEmpty
    }
}

struct ExternalImportMenu: View {
    @Environment(TerminatorAppModel.self) private var model
    let hint: DismissedHintsStore.Hint
    private var dismissedHints = DismissedHintsStore.shared

    var body: some View {
        if showsMenu {
            Menu {
                ForEach(model.importSources) { source in
                    Button(source.displayName) {
                        Task { await model.loadImportSource(source) }
                    }
                    .disabled(model.loadingImportSourceIDs.contains(source.id))
                }
            } label: {
                Label(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down")
            }
            .help(FeatureL10n.text(.externalImportBannerTitle))
        }
    }

    private var showsMenu: Bool {
        dismissedHints.isDismissed(hint)
            && model.capabilities.externalFileAccess
            && !model.importSources.isEmpty
    }
}

struct ExternalImportBanner: View {
    let sources: [ExternalImportSource]
    let loadingIDs: Set<String>
    let onImport: (ExternalImportSource) -> Void
    let onDismiss: () -> Void
    @State private var isConfirmingDismiss = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(FeatureL10n.text(.externalImportBannerTitle))
                        .font(.headline)
                    Text(FeatureL10n.text(.externalImportBannerSubtitle))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                HStack(spacing: 10) {
                    ForEach(sources) { source in
                        importButton(source)
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            Button(action: handleDismissTap) {
                if isConfirmingDismiss {
                    Text(FeatureL10n.text(.actionClose))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(isConfirmingDismiss ? .capsule : .circle)
            .controlSize(.mini)
            .offset(x: 7, y: -7)
            .accessibilityLabel(
                isConfirmingDismiss
                    ? FeatureL10n.text(.actionClose)
                    : FeatureL10n.text(.externalImportBannerDismiss)
            )
        }
        .padding(.top, 7)
        .padding(.trailing, 7)
        .animation(.easeInOut(duration: 0.18), value: isConfirmingDismiss)
        .task(id: isConfirmingDismiss) {
            guard isConfirmingDismiss else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isConfirmingDismiss = false
            }
        }
    }

    private func handleDismissTap() {
        if isConfirmingDismiss {
            onDismiss()
        } else {
            isConfirmingDismiss = true
        }
    }

    private func importButton(_ source: ExternalImportSource) -> some View {
        let isLoading = loadingIDs.contains(source.id)
        return Button {
            onImport(source)
        } label: {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(FeatureL10n.text(.externalImportFrom, source.displayName))
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .controlSize(.regular)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.blue)
        .disabled(isLoading)
    }
}
