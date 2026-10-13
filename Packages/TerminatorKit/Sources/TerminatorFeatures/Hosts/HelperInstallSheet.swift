import SwiftUI
import TerminatorCore

struct HelperInstallSheet: View {
    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    var reinstall = false
    @State private var isInstalling = false
    @State private var phase = ""
    @State private var progress = 0.0
    @State private var ceiling = 0.0
    @State private var installTask: Task<Void, Never>?
    @State private var failure: String?

    private var dockerMissing: Bool { model.isDockerMissing(host) }

    private var actionTitle: String {
        if dockerMissing { return FeatureL10n.text(.helperInstallDockerFirst) }
        if isInstalling { return phase }
        return FeatureL10n.text(reinstall ? .helperReinstall : .helperInstall)
    }

    private var hostTitle: String {
        let name = host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? host.hostname : name
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(FeatureL10n.text(reinstall ? .helperReinstall : .helperInstallTitle))
                    .font(.title2.bold())
                HStack {
                    Button {
                        installTask?.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 18) {
                benefit(symbol: "server.rack", title: .helperBenefitControl, detail: .helperBenefitControlDetail)
                benefit(symbol: "slider.horizontal.3", title: .helperBenefitSettings, detail: .helperBenefitSettingsDetail)
                benefit(symbol: "lock.shield", title: .helperBenefitEncrypted, detail: .helperBenefitEncryptedDetail)
                HStack(spacing: 12) {
                    Text(hostTitle)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(host.hostname):\(host.port)")
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                installButton
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: ceiling) { await creepProgress() }
    }

    @ViewBuilder
    private var installButton: some View {
        if isInstalling {
            ZStack {
                Capsule().fill(Color.blue.opacity(0.22))
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: max(8, geo.size.width * progress))
                }
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
            }
            .frame(height: 44)
            .clipShape(Capsule())
            .accessibilityLabel(actionTitle)
        } else {
            InspectorProminentAction(
                title: actionTitle,
                disabled: dockerMissing,
                action: install
            )
        }
    }

    private func benefit(symbol: String, title: FeatureString, detail: FeatureString) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(FeatureL10n.text(title))
                    .fontWeight(.semibold)
                Text(FeatureL10n.text(detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func install() {
        guard !dockerMissing else { return }
        isInstalling = true
        failure = nil
        progress = 0.04
        ceiling = 0.18
        phase = FeatureL10n.text(.helperInstallConnecting)
        installTask = Task {
            do {
                try await model.installHelper(on: host) { title, fraction in
                    phase = title
                    ceiling = min(0.97, fraction + 0.16)
                    if progress < fraction { progress = fraction }
                }
                if !Task.isCancelled {
                    progress = 1
                    dismiss()
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                    isInstalling = false
                    progress = 0
                    ceiling = 0
                }
            }
        }
    }

    private func creepProgress() async {
        while !Task.isCancelled, progress + 0.008 < ceiling {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            progress = min(ceiling, progress + 0.012)
        }
    }
}
