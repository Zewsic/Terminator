import SwiftUI
import TerminatorCore

struct ConnectionStatusView: View {
    let phase: SSHConnectionPhase

    var body: some View {
        if case .failed(let message) = phase {
            ConnectionForm(
                title: FeatureL10n.text(.connectionFailedTitle),
                subtitle: FeatureL10n.text(.connectionFailedDescription)
            ) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .connectionInput(border: .red)
            }
        } else if case .connected = phase {
            ConnectionForm(
                title: FeatureL10n.text(.connectionConnectedTitle),
                subtitle: FeatureL10n.text(.connectionConnectedDescription)
            ) { EmptyView() }
        } else {
            ConnectionForm(
                title: FeatureL10n.text(.connectionConnectingTitle),
                subtitle: phase.description
            ) { EmptyView() }
        }
    }
}
