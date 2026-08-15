import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CredentialInspector: View {
    let credential: CredentialMetadata
    let onReplace: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(FeatureL10n.text(.actionClose), systemImage: "arrow.left.to.line") { onClose() }
                    .labelStyle(.iconOnly)
                Image(systemName: "key.horizontal").foregroundStyle(.tint)
                Text(credential.label).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()
            Form {
                if let key = credential.accessKey {
                    Section(FeatureL10n.text(.credentialsAccessKey)) {
                        LabeledContent(FeatureL10n.text(.connectionAlgorithm), value: key.algorithm.displayName)
                        LabeledContent(FeatureL10n.text(.keyStorage), value: key.backend.displayName)
                        LabeledContent(FeatureL10n.text(.keyFingerprint), value: key.fingerprint)
                    }
                    Section(FeatureL10n.text(.credentialsPublicKey)) {
                        Text(key.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button(FeatureL10n.text(.featureCredentialInspectorReplacePrivateKey), systemImage: "arrow.triangle.2.circlepath") {
                        onReplace()
                    }
                } footer: {
                    Text(FeatureL10n.text(.featureCredentialInspectorPrivateKeyMaterialIsNeverReadUntil))
                }
            }
            .formStyle(.grouped)
        }
    }
}
