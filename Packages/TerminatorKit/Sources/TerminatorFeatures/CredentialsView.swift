import SwiftUI
import TerminatorCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CredentialsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @Binding private var isArchivePresented: Bool
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var accessKeyDraft: AccessKeyDraft?
    @State private var identityDraft: IdentityDraft?
    @State private var selectedCredential: CredentialMetadata?
    @State private var isImportingOpenSSHKey = false
    @State private var inspectorSessionID = UUID()
    @State private var isDiscardingInspector = false
    @State private var pendingArchive: CredentialMetadata?
    @State private var pendingPurge: CredentialMetadata?
    @State private var pendingIdentityArchive: IdentityProfile?
    @State private var exportDocument: PrivateKeyDocument?
    @State private var exportingCredential: CredentialMetadata?
    @State private var isExportingCredential = false

    init(isArchivePresented: Binding<Bool>) {
        _isArchivePresented = isArchivePresented
    }

    var body: some View {
        InspectorLayout(content: {
            credentialsContent
        }, inspector: {
            AnyView(ZStack {
            if let accessKeyDraft {
                AccessKeyEditor(
                    draft: accessKeyDraft,
                    inline: true,
                    explicitImport: isExplicitAccessKeyImport,
                    onDraftChange: updateAccessKeyDraft,
                    isDiscarding: isDiscarding
                ) { value in
                    let saved = await model.saveAccessKey(value)
                    if isExplicitAccessKeyImport, saved != nil { closeInspector() }
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let selectedCredential {
                AccessKeyEditor(credential: selectedCredential, inline: true, isDiscarding: isDiscarding) { value in
                    _ = await model.replaceAccessKey(value)
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let identityDraft {
                IdentityEditor(draft: identityDraft, inline: true, onDraftChange: updateIdentityDraft, isDiscarding: isDiscarding) { value in
                    _ = await model.saveIdentity(value)
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            .animation(.easeInOut(duration: 0.22), value: inspectorSessionID))
        }, isInspectorPresented: hasInspector, onContentInteraction: { closeInspector() })
        .navigationTitle(FeatureL10n.text(.overviewCredentials))
        .searchable(text: $searchText, prompt: "Search identities and credentials")
        .searchFocused($isSearchFocused)
        .toolbar {
            credentialsToolbar
        }
        .fileExporter(
            isPresented: $isExportingCredential,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportingCredential?.label.replacingOccurrences(of: " ", with: "-") ?? "access-key"
        ) { _ in
            exportDocument = nil
            exportingCredential = nil
        }
        .confirmationDialog(FeatureL10n.text(.credentialsArchiveCredentialTitle),
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.hostsArchive), role: .destructive) {
                if let pendingArchive { Task { await model.deleteCredential(id: pendingArchive.id) } }
                pendingArchive = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingArchive = nil }
        } message: {
            Text(FeatureL10n.text(.credentialsItsKeychainMaterialRemainsAvailableUntilYou))
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            if isFocused { closeInspector() }
        }
        .confirmationDialog(FeatureL10n.text(.credentialsPurgeSecretTitle),
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.credentialsPurgeSecret), role: .destructive) {
                if let pendingPurge { Task { await model.purgeCredential(id: pendingPurge.id) } }
                pendingPurge = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingPurge = nil }
        } message: {
            Text(FeatureL10n.text(.credentialsAllAssociatedPrivateMaterialAndAnySaved))
        }
        .confirmationDialog(FeatureL10n.text(.credentialsArchiveIdentityTitle),
            isPresented: Binding(get: { pendingIdentityArchive != nil }, set: { if !$0 { pendingIdentityArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button(FeatureL10n.text(.hostsArchive), role: .destructive) {
                if let pendingIdentityArchive { Task { await model.deleteIdentity(id: pendingIdentityArchive.id) } }
                pendingIdentityArchive = nil
            }
            Button(FeatureL10n.text(.historyCancel), role: .cancel) { pendingIdentityArchive = nil }
        }
    }

    private var addMenu: some View {
        Menu(FeatureL10n.text(.credentialsAdd), systemImage: "plus") {
            Button(FeatureL10n.text(.hostsIdentity), systemImage: "person.badge.key") {
                openIdentity(IdentityDraft())
            }
            Button(FeatureL10n.text(.credentialsAccessKey), systemImage: "key.horizontal") {
                var draft = AccessKeyDraft()
                draft.suggestedOrdinal = model.activeCredentials.count + 1
                openAccessKey(draft)
            }
        }
        .accessibilityIdentifier("add-credential")
    }

    @ToolbarContentBuilder
    private var credentialsToolbar: some ToolbarContent {
        ToolbarItemGroup {
            addMenu
            Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox") { isArchivePresented = true }
                .accessibilityIdentifier("archive-button")
        }
        if hasInspector && !isExplicitAccessKeyImport {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(FeatureL10n.text(.actionCancel), systemImage: "xmark") { discardInspector() }
                    Button(FeatureL10n.text(.featureHostEditorSaveAndClose), systemImage: "checkmark") {
                        Task { await saveInspectorAndClose() }
                    }
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private func identityRow(_ identity: IdentityProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(identityDisplayName(identity)).fontWeight(.medium)
                Text(FeatureL10n.text(identity.authenticationMethods.count == 1 ? "identity.summary.one" : "identity.summary.many", identity.username, identity.authenticationMethods.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if !identity.isDeleted { openIdentity(IdentityDraft(identity: identity)) } }
        .contextMenu {
            if !identity.isDeleted {
                Button(FeatureL10n.text(.hostsEdit), systemImage: "pencil") { openIdentity(IdentityDraft(identity: identity)) }
                Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox", role: .destructive) { pendingIdentityArchive = identity }
                    .disabled(model.identityUsageCount(id: identity.id) > 0)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var credentialsContent: some View {
        let activeIdentities = model.identities.filter { !$0.isDeleted }
        let activeCredentials = model.credentials.filter { !$0.isDeleted && $0.isSecretAvailable }
        let identities = activeIdentities
            .filter { matchesSearch($0.name) || matchesSearch($0.username) }
        let available = activeCredentials
            .filter { matchesSearch($0.label) }
        let openSSHKeys = availableOpenSSHKeys
        if activeIdentities.isEmpty && activeCredentials.isEmpty && openSSHKeys.isEmpty {
            ContentUnavailableView {
                Label(FeatureL10n.text(.featureCredentialsNoIdentitiesOrCredentials), systemImage: "key")
            } description: {
                Text(FeatureL10n.text(.featureCredentialsCreateAnIdentityOrAddACredential))
            } actions: { addMenu.buttonStyle(.glassProminent).tint(.blue) }
        } else if identities.isEmpty && available.isEmpty && openSSHKeys.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if !identities.isEmpty {
                    Section(FeatureL10n.text(.credentialsIdentity)) { ForEach(identities) { identity in identityRow(identity) } }
                }
                if !available.isEmpty {
                    Section(FeatureL10n.text(.sectionCredentials)) { ForEach(available) { credential in credentialRow(credential) } }
                }
                if model.capabilities.externalFileAccess, !openSSHKeys.isEmpty {
                    Section {
                        ForEach(openSSHKeys) { key in
                            HStack {
                                if let importError = key.importError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .help(importError)
                                } else {
                                    Image(systemName: "key.horizontal")
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.label).fontWeight(.medium)
                                    Text(key.importError ?? key.fingerprint ?? (key.isEncrypted ? FeatureL10n.text(.opensshEncryptedKey) : key.privateKeyURL.path))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if key.importError == nil {
                                    Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                        openDiscoveredKey(key)
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }
                            .help(key.importError ?? key.privateKeyURL.path)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                    openDiscoveredKey(key)
                                }
                                .disabled(key.importError != nil)
                            }
                        }
                    } header: {
                        Text(FeatureL10n.text(.hostsAvailableFromOpenssh))
                    }
                }
            }
            .accessibilityIdentifier("credentials-list")
        }
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: credentialIcon(for: credential))
                .foregroundStyle(credential.isSecretAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label).fontWeight(.medium)
                Text(status(for: credential)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if credential.kind == .accessKey { openCredential(credential) } }
        .contextMenu {
            if credential.kind == .accessKey {
                Button(FeatureL10n.text(.hostsEdit), systemImage: "pencil") { openCredential(credential) }
                Button(FeatureL10n.text(.hostsExportToOpenssh), systemImage: "square.and.arrow.up") { exportToOpenSSH(credential) }
                    .disabled(credential.accessKey?.backend == .secureEnclave || !credential.isSecretAvailable)
                Divider()
            }
                if !credential.isDeleted {
                    Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox", role: .destructive) { pendingArchive = credential }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0)
                }
                if credential.isSecretAvailable, model.credentialUsageCount(id: credential.id) == 0 {
                    Button(FeatureL10n.text(.credentialsPurge), systemImage: "trash", role: .destructive) { pendingPurge = credential }
                }
        }
        .padding(.vertical, 3)
    }

    private var availableOpenSSHKeys: [DiscoveredAccessKey] {
        model.openSSH.accessKeys.filter { $0.status != .existing && matchesSearch($0.label) }
    }

    private func exportToOpenSSH(_ credential: CredentialMetadata) {
        Task {
            guard let data = await model.exportPrivateKey(id: credential.id) else { return }
            exportingCredential = credential
            exportDocument = PrivateKeyDocument(data: data)
            isExportingCredential = true
        }
    }

    private func status(for credential: CredentialMetadata) -> String {
        if !credential.isSecretAvailable { return FeatureL10n.text(.credentialStatusPurged) }
        if credential.kind == .legacyPassphrase { return FeatureL10n.text(.credentialStatusLegacy) }
        let usage = model.credentialUsageCount(id: credential.id)
        let detail = credential.accessKey?.algorithm.displayName ?? credential.kind.displayName
        if credential.isDeleted { return FeatureL10n.text(.credentialStatusArchived) }
        if usage == 0 { return FeatureL10n.text(.credentialStatusUnused, detail) }
        return FeatureL10n.text(usage == 1 ? "credential.status.used.one" : "credential.status.used.many", usage, detail)
    }

    private func credentialIcon(for credential: CredentialMetadata) -> String {
        if credential.accessKey?.backend == .secureEnclave { return "touchid" }
        return credential.kind == .accessKey ? "key.horizontal" : "key"
    }

    private func matchesSearch(_ value: String) -> Bool {
        searchText.isEmpty || value.localizedCaseInsensitiveContains(searchText)
    }

    private func identityDisplayName(_ identity: IdentityProfile) -> String {
        let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "Identity" : username
    }

    private func closeInspector() {
        accessKeyDraft = nil
        selectedCredential = nil
        identityDraft = nil
        isImportingOpenSSHKey = false
    }

    private func updateAccessKeyDraft(_ draft: AccessKeyDraft) { accessKeyDraft = draft }
    private func updateIdentityDraft(_ draft: IdentityDraft) { identityDraft = draft }
    private func isDiscarding() -> Bool { isDiscardingInspector }

    private var hasInspector: Bool {
        accessKeyDraft != nil || selectedCredential != nil || identityDraft != nil
    }

    private var isExplicitAccessKeyImport: Bool {
        isImportingOpenSSHKey
            || (accessKeyDraft?.credentialID == nil && accessKeyDraft?.mode == .importExisting)
    }

    private func discardInspector() {
        isDiscardingInspector = true
        closeInspector()
    }

    private func saveInspectorAndClose() async {
        isDiscardingInspector = true
        if let accessKeyDraft {
            _ = await model.saveAccessKey(accessKeyDraft)
        } else if let selectedCredential {
            var draft = AccessKeyDraft()
            draft.credentialID = selectedCredential.id
            draft.label = selectedCredential.label
            _ = await model.replaceAccessKey(draft)
        } else if let identityDraft {
            _ = await model.saveIdentity(identityDraft)
        }
        closeInspector()
    }

    private func openAccessKey(_ draft: AccessKeyDraft, importingFromOpenSSH: Bool = false) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = importingFromOpenSSH
        accessKeyDraft = draft
        selectedCredential = nil
        identityDraft = nil
    }

    private func openDiscoveredKey(_ key: DiscoveredAccessKey) {
        let draft = model.draft(for: key)
        closeInspector()
        DispatchQueue.main.async {
            openAccessKey(draft, importingFromOpenSSH: true)
        }
    }

    private func openCredential(_ credential: CredentialMetadata) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = false
        selectedCredential = credential
        accessKeyDraft = nil
        identityDraft = nil
    }

    private func openIdentity(_ draft: IdentityDraft) {
        isDiscardingInspector = false
        inspectorSessionID = UUID()
        isImportingOpenSSHKey = false
        identityDraft = draft
        accessKeyDraft = nil
        selectedCredential = nil
    }

}
