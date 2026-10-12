import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CredentialDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminatorAppModel.self) private var model
    let credential: CredentialMetadata
    @State private var passphrase = ""
    @State private var document: PrivateKeyDocument?
    @State private var isExporting = false
    @State private var isConfirmingPurge = false

    var body: some View {
        editorShell(title: credential.label, width: 620, height: 560, saveTitle: "Done") {
            Form {
                if let key = credential.accessKey {
                    Section(FeatureL10n.text(.credentialsAccessKey)) {
                        LabeledContent(FeatureL10n.text(.rootAlgorithm), value: key.algorithm.displayName)
                        LabeledContent(FeatureL10n.text(.credentialsStorage), value: key.backend.displayName)
                        LabeledContent(FeatureL10n.text(.credentialsPassphrase), value: key.passphraseProtection.displayName)
                        LabeledContent(FeatureL10n.text(.credentialsFingerprint), value: key.fingerprint)
                        if let warning = key.compatibility.warning {
                            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    Section(FeatureL10n.text(.credentialsPublicKey)) {
                        Text(key.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(FeatureL10n.text(.credentialsCopyPublicKey), systemImage: "doc.on.doc") { copyToPasteboard(key.publicKey) }
                    }
                    if key.backend == .software {
                        Section {
                            if key.passphraseProtection == .promptEveryConnection {
                                SecureField(FeatureL10n.text(.uiField7), text: $passphrase)
                            }
                            Button(FeatureL10n.text(.credentialsExportPrivateKey), systemImage: "square.and.arrow.up") {
                                Task {
                                    if let data = await model.exportPrivateKey(id: credential.id, passphrase: passphrase) {
                                        document = PrivateKeyDocument(data: data)
                                        isExporting = true
                                    }
                                }
                            }
                        } header: {
                            Text(FeatureL10n.text(.credentialsPrivateKeyExport))
                        } footer: {
                            Text(FeatureL10n.text(.credentialsExportRequiresSystemAuthenticationKeepTheResulting))
                        }
                    }
                    Section {
                        if !credential.isDeleted {
                            Button(FeatureL10n.text(.credentialsArchiveKey), systemImage: "archivebox") {
                                Task {
                                    model.dismissPresentedError()
                                    await model.deleteCredential(id: credential.id)
                                    if model.presentedError == nil { dismiss() }
                                }
                            }
                            .disabled(model.credentialUsageCount(id: credential.id) > 0)
                        }
                        Button(FeatureL10n.text(.credentialsPurgePrivateMaterial), systemImage: "trash", role: .destructive) {
                            isConfirmingPurge = true
                        }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0 || !credential.isSecretAvailable)
                    } header: {
                        Text(FeatureL10n.text(.credentialsManagement))
                    } footer: {
                        if model.credentialUsageCount(id: credential.id) > 0 {
                            Text(FeatureL10n.text(.credentialsDetachThisKeyFromEveryHostAnd))
                        } else {
                            Text(FeatureL10n.text(.credentialsPurgePermanentlyRemovesPrivateMaterialAndAny))
                        }
                    }
                }
            }.formStyle(.grouped)
        } save: { dismiss() } cancel: { dismiss() }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .plainText,
            defaultFilename: credential.label.replacingOccurrences(of: " ", with: "-")
        ) { _ in document = nil }
        .alert(FeatureL10n.text(.credentialsPermanentlyPurgeThisKey), isPresented: $isConfirmingPurge) {
            Button(FeatureL10n.text(.credentialsPurge), role: .destructive) {
                Task {
                    model.dismissPresentedError()
                    await model.purgeCredential(id: credential.id)
                    if model.presentedError == nil { dismiss() }
                }
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) {}
        } message: {
            Text(FeatureL10n.text(.credentialsThePrivateKeyAndSavedPassphraseCannot))
        }
    }
}
