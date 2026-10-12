import SwiftUI
import TerminatorCore

extension View {
    func connectionInput(border: Color? = nil) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.quaternary, in: .rect(cornerRadius: 14))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(border.opacity(0.75), lineWidth: 1.5)
                }
            }
    }
}

struct ConnectionForm<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) { content() }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConnectionPrimaryButton: View {
    let title: String
    var loading = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.blue)
        .disabled(disabled || loading)
    }
}

extension SSHConnectionPhase {
    var isWorking: Bool {
        switch self { case .resolving, .verifyingHost, .authenticating, .reconnecting, .waitingForUser: true; default: false }
    }
    var isFailure: Bool { if case .failed = self { true } else { false } }
    var description: String {
        switch self {
        case .disconnected: FeatureL10n.text(.connectionPhaseDisconnected)
        case .resolving: FeatureL10n.text(.connectionPhaseResolving)
        case .verifyingHost(let fingerprint): FeatureL10n.text(.connectionPhaseVerifyingHost, fingerprint)
        case .authenticating: FeatureL10n.text(.connectionPhaseAuthenticating)
        case .connected: FeatureL10n.text(.connectionPhaseConnected)
        case .agent: FeatureL10n.text(.connectionPhaseAgent)
        case .reconnecting(let attempt): FeatureL10n.text(.connectionPhaseReconnecting, attempt)
        case .waitingForUser(let message): message
        case .failed(let message): message
        }
    }
}
