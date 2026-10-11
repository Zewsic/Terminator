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
    @State private var collapsedCredentialGroups: Set<String> = []
    private var dismissedHints = DismissedHintsStore.shared
    @State private var pendingExternalKey: ExternalImportAccessKey?
    @State private var pendingExternalIdentity: ExternalImportIdentity?
    @State private var pendingExternalBundle: ExternalImportBundle?

    init(isArchivePresented: Binding<Bool>) {
        _isArchivePresented = isArchivePresented
    }

    var body: some View {
        InspectorLayout(content: {
            VStack(spacing: 0) {
                CatalogImportBanner(hint: .credentialsImportBanner)
                credentialsContent
            }
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
                    if saved != nil, let key = pendingExternalKey, let bundle = pendingExternalBundle {
                        model.consumeExternalAccessKey(key, sourceID: bundle.source.id)
                    }
                    if (isExplicitAccessKeyImport || value.credentialID == nil), saved != nil { closeInspector() }
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
                IdentityEditor(
                    draft: identityDraft,
                    inline: true,
                    explicitImport: pendingExternalIdentity != nil,
                    onDraftChange: updateIdentityDraft,
                    isDiscarding: isDiscarding
                ) { value in
                    if let identity = pendingExternalIdentity, let bundle = pendingExternalBundle {
                        if await model.importExternalIdentity(identity, from: bundle, editedDraft: value) != nil {
                            closeInspector()
                        }
                    } else {
                        let saved = await model.saveIdentity(value)
                        if value.id == nil, saved { closeInspector() }
                    }
                } onClose: {
                    closeInspector()
                }
                .id(inspectorSessionID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            .animation(.easeInOut(duration: 0.22), value: inspectorSessionID))
        }, inspectorWidth: InspectorMetrics.compactWidth,
           isInspectorPresented: hasInspector,
           onContentInteraction: { closeInspector() })
        .navigationTitle(FeatureL10n.text(.overviewCredentials))
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
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox") { isArchivePresented = true }
                .accessibilityIdentifier("archive-button")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            ToolbarSearchField(text: $searchText, prompt: "Search identities and credentials")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            addMenu
            ExternalImportMenu(hint: .credentialsImportBanner)
        }
    }

    private func identityRow(_ identity: IdentityProfile) -> some View {
        credentialCardLabel(
            title: identityDisplayName(identity),
            subtitle: FeatureL10n.text(identity.authenticationMethods.count == 1 ? "identity.summary.one" : "identity.summary.many", identity.username, identity.authenticationMethods.count),
            icon: "person.badge.key",
            isSelected: identityDraft?.id == identity.id
        )
        .onTapGesture { if !identity.isDeleted { openIdentity(IdentityDraft(identity: identity)) } }
        .contextMenu {
            if !identity.isDeleted {
                Button(FeatureL10n.text(.hostsEdit), systemImage: "pencil") { openIdentity(IdentityDraft(identity: identity)) }
                Button(FeatureL10n.text(.actionArchive), systemImage: "archivebox", role: .destructive) { pendingIdentityArchive = identity }
                    .disabled(model.identityUsageCount(id: identity.id) > 0)
            }
        }
    }

    private var credentialGridColumns: [GridItem] {
        [GridItem(.adaptive(
            minimum: CredentialCardMetrics.minimumWidth
        ), spacing: CredentialCardMetrics.spacing, alignment: .leading)]
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
        if activeIdentities.isEmpty && activeCredentials.isEmpty && !hasAvailableImports {
            ContentUnavailableView {
                Label(FeatureL10n.text(.featureCredentialsNoIdentitiesOrCredentials), systemImage: "key")
            } description: {
                Text(FeatureL10n.text(.featureCredentialsCreateAnIdentityOrAddACredential))
            } actions: { addMenu.buttonStyle(.glassProminent).tint(.blue) }
        } else if identities.isEmpty && available.isEmpty && !hasAvailableImports {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !identities.isEmpty {
                        sectionHeader(FeatureL10n.text(.credentialsIdentity), id: "identities")
                            .padding(.top, 4)
                        if !collapsedCredentialGroups.contains("identities") {
                            LazyVGrid(columns: credentialGridColumns, alignment: .leading, spacing: CredentialCardMetrics.spacing) {
                                ForEach(identities) { identity in
                                    identityRow(identity)
                                }
                            }
                        }
                    }
                    if !available.isEmpty {
                        sectionHeader(FeatureL10n.text(.sectionCredentials), id: "credentials")
                            .padding(.top, 4)
                        if !collapsedCredentialGroups.contains("credentials") {
                            LazyVGrid(columns: credentialGridColumns, alignment: .leading, spacing: CredentialCardMetrics.spacing) {
                                ForEach(available) { credential in
                                    credentialRow(credential)
                                }
                            }
                        }
                    }
                    if model.capabilities.externalFileAccess {
                        LazyVGrid(columns: credentialGridColumns, alignment: .leading, spacing: CredentialCardMetrics.spacing) {
                            ForEach(openSSHKeys) { key in
                                credentialCardLabel(
                                    title: key.label,
                                    subtitle: key.importError ?? key.fingerprint ?? (key.isEncrypted ? FeatureL10n.text(.opensshEncryptedKey) : key.privateKeyURL.path),
                                    icon: key.importError == nil ? "key.horizontal" : "exclamationmark.triangle.fill",
                                    iconColor: key.importError == nil ? .secondary : .red
                                )
                                .onTapGesture {
                                    if key.importError == nil { openDiscoveredKey(key) }
                                }
                                .contextMenu {
                                    if key.importError == nil {
                                        Button(FeatureL10n.text(.actionImport), systemImage: "square.and.arrow.down") {
                                            openDiscoveredKey(key)
                                        }
                                    }
                                }
                                .help(key.importError ?? key.privateKeyURL.path)
                            }
                            ForEach(model.loadedExternalImportBundles, id: \.source.id) { bundle in
                                ForEach(bundle.identities.filter(matchesSearch)) { identity in
                                    externalIdentityRow(identity, bundle: bundle)
                                }
                                ForEach(bundle.accessKeys.filter(matchesSearch)) { key in
                                    externalKeyRow(key, bundle: bundle)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("credentials-list")
        }
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
        credentialCardLabel(
            title: credential.label,
            subtitle: status(for: credential),
            icon: credentialIcon(for: credential),
            iconColor: credential.isSecretAvailable ? .accentColor : .secondary,
            isSelected: selectedCredential?.id == credential.id
        )
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
        pendingExternalKey = nil
        pendingExternalIdentity = nil
        pendingExternalBundle = nil
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

    private var showsImportBanner: Bool {
        !dismissedHints.isDismissed(.credentialsImportBanner)
            && model.capabilities.externalFileAccess
            && !model.importSources.isEmpty
    }

    private var hasAvailableImports: Bool {
        showsImportBanner || !availableOpenSSHKeys.isEmpty
            || model.loadedExternalImportBundles.contains { bundle in
                !bundle.identities.filter(matchesSearch).isEmpty || !bundle.accessKeys.filter(matchesSearch).isEmpty
            }
    }

    private func matchesSearch(_ identity: ExternalImportIdentity) -> Bool {
        matchesSearch(identity.label) || matchesSearch(identity.username)
    }

    private func matchesSearch(_ key: ExternalImportAccessKey) -> Bool { matchesSearch(key.label) }

    private func sectionHeader(_ title: String, id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsedCredentialGroups.contains(id) { collapsedCredentialGroups.remove(id) }
                else { collapsedCredentialGroups.insert(id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedCredentialGroups.contains(id) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Text(title)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func externalKeyRow(_ key: ExternalImportAccessKey, bundle: ExternalImportBundle) -> some View {
        Button {
            closeInspector()
            pendingExternalKey = key
            pendingExternalBundle = bundle
            openAccessKey(model.externalAccessKeyDraft(key), importingFromOpenSSH: true)
        } label: {
            credentialCardLabel(
                title: key.label.isEmpty ? FeatureL10n.text(.credentialsAccessKey) : key.label,
                subtitle: FeatureL10n.text(.externalImportAccessKeyDetail, bundle.source.displayName),
                icon: "key.horizontal"
            )
        }.buttonStyle(.plain)
    }

    private func externalIdentityRow(_ identity: ExternalImportIdentity, bundle: ExternalImportBundle) -> some View {
        Button {
            closeInspector()
            pendingExternalIdentity = identity
            pendingExternalBundle = bundle
            isDiscardingInspector = false
            inspectorSessionID = UUID()
            identityDraft = model.externalIdentityDraft(identity)
        } label: {
            credentialCardLabel(
                title: identity.label.isEmpty ? identity.username : identity.label,
                subtitle: FeatureL10n.text(.externalImportIdentityDetail, bundle.source.displayName),
                icon: "person.badge.key"
            )
        }.buttonStyle(.plain)
    }

    private func credentialCardLabel(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color = .secondary,
        isSelected: Bool = false
    ) -> some View {
        HStack(spacing: CredentialCardMetrics.iconInset) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: CredentialCardMetrics.iconSize, height: CredentialCardMetrics.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CredentialCardMetrics.iconInset)
        .frame(maxWidth: .infinity, minHeight: CredentialCardMetrics.height, maxHeight: CredentialCardMetrics.height, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CredentialCardMetrics.cornerRadius))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CredentialCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
            }
        }
    }

}

private enum CredentialCardMetrics {
    static let minimumWidth: CGFloat = 250
    static let iconSize: CGFloat = 28
    static let iconInset: CGFloat = 12
    static let height: CGFloat = iconSize + iconInset * 2
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 20
}
