import SwiftUI

struct HostKeyPromptView: View {
    let endpoint: String
    let algorithm: String
    let fingerprints: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent(FeatureL10n.text(.connectionEndpoint), value: endpoint)
            LabeledContent(FeatureL10n.text(.connectionAlgorithm), value: algorithm)
            ForEach(Array(fingerprints.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .connectionInput()
    }
}
