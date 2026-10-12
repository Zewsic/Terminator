import SwiftUI
import TerminatorCore

struct HelperInstallSheet: View {
    @Environment(TerminatorAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    @State private var isInstalling = false
    @State private var phase = ""
    @State private var installTask: Task<Void, Never>?
    @State private var failure: String?

    private var dockerMissing: Bool { model.isDockerMissing(host) }

    private var actionTitle: String {
        if dockerMissing { return FeatureL10n.text(.helperInstallDockerFirst) }
        if isInstalling { return phase }
        return FeatureL10n.text(.helperInstall)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(FeatureL10n.text(.helperInstallTitle))
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
                benefit(symbol: "waveform.path.ecg", title: .helperBenefitRealtime, detail: .helperBenefitRealtimeDetail)
                benefit(symbol: "bolt", title: .helperBenefitFaster, detail: .helperBenefitFasterDetail)
                benefit(symbol: "lock.shield", title: .helperBenefitEncrypted, detail: .helperBenefitEncryptedDetail)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .lineLimit(1)
                    Text("\(host.hostname):\(String(HelperSnapshot.port))")
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InspectorProminentAction(
                    title: actionTitle,
                    disabled: isInstalling || dockerMissing,
                    action: install
                )
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
        phase = FeatureL10n.text(.helperInstallPreparing)
        installTask = Task {
            do {
                try await model.installHelper(on: host) { phase = $0 }
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                    isInstalling = false
                }
            }
        }
    }
}
