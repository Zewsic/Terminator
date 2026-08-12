import SwiftUI
import TerminatorCore

struct CredentialsView: View {
    @Environment(TerminatorAppModel.self) private var model
    @State private var isAdding = false
    @State private var pendingArchive: CredentialMetadata?
    @State private var pendingPurge: CredentialMetadata?

    private var available: [CredentialMetadata] {
        model.credentials.filter { !$0.isDeleted && $0.isSecretAvailable }
    }

    private var archived: [CredentialMetadata] {
        model.credentials.filter(\.isDeleted)
    }

    var body: some View {
        Group {
            if model.credentials.isEmpty {
                ContentUnavailableView {
                    Label("No credentials", systemImage: "key")
                } description: {
                    Text("Secrets are stored in the device-only Keychain, never in the catalog database.")
                } actions: {
                    addButton
                        .buttonStyle(.glassProminent)
                        .tint(.clear)
                }
            } else {
                List {
                    Section("Available") {
                        ForEach(available) { credential in
                            credentialRow(credential)
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived and retained") {
                            ForEach(archived) { credential in
                                credentialRow(credential)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("credentials-list")
            }
        }
        .navigationTitle("Credentials")
        .toolbar { addButton }
        .sheet(isPresented: $isAdding) {
            CredentialEditor { draft in
                let saved = await model.saveCredential(draft)
                if saved { isAdding = false }
            }
        }
        .confirmationDialog(
            "Archive this credential?",
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                if let pendingArchive {
                    Task { await model.deleteCredential(id: pendingArchive.id) }
                }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("The Keychain item remains available until you purge it manually.")
        }
        .confirmationDialog(
            "Permanently purge this secret?",
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Purge Secret", role: .destructive) {
                if let pendingPurge {
                    Task { await model.purgeCredential(id: pendingPurge.id) }
                }
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("This removes the Keychain item and cannot be undone from History.")
        }
    }

    private var addButton: some View {
        Button("Add Credential", systemImage: "plus") { isAdding = true }
            .accessibilityIdentifier("add-credential")
    }

    private func credentialRow(_ credential: CredentialMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: credential.kind == .privateKey ? "key.horizontal" : "key")
                .foregroundStyle(credential.isSecretAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label)
                    .fontWeight(.medium)
                Text(status(for: credential))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") {
                if !credential.isDeleted {
                    Button("Archive", role: .destructive) { pendingArchive = credential }
                        .disabled(model.credentialUsageCount(id: credential.id) > 0)
                }
                if credential.isSecretAvailable, model.credentialUsageCount(id: credential.id) == 0 {
                    Button("Purge Secret", role: .destructive) { pendingPurge = credential }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private func status(for credential: CredentialMetadata) -> String {
        if !credential.isSecretAvailable { return "Secret purged · metadata only" }
        let usage = model.credentialUsageCount(id: credential.id)
        if credential.isDeleted { return "Archived · secret retained" }
        if usage == 0 { return "Unused · \(credential.kind.displayName)" }
        return "Used by \(usage) host\(usage == 1 ? "" : "s") · \(credential.kind.displayName)"
    }
}

private struct CredentialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CredentialDraft()
    let onSave: @MainActor (CredentialDraft) async -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Metadata") {
                    TextField("Label", text: $draft.label)
                        .accessibilityIdentifier("credential-label")
                    Picker("Type", selection: $draft.kind) {
                        ForEach(CredentialKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Public fingerprint (optional)", text: $draft.fingerprint)
                }
                Section {
                    if draft.kind == .privateKey {
                        TextEditor(text: $draft.secret)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                            .accessibilityIdentifier("credential-secret")
                    } else {
                        SecureField("Secret value", text: $draft.secret)
                            .accessibilityIdentifier("credential-secret")
                    }
                } header: {
                    Text("Secret")
                } footer: {
                    Text("The secret is written directly to Keychain and is never loaded into the editor again.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await onSave(draft) } }
                    .buttonStyle(.glassProminent)
                    .tint(.clear)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-credential")
            }
            .padding()
        }
        .frame(width: 520, height: 520)
    }
}
