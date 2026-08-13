# Security

Terminator is an infrastructure client. A compromise can expose remote systems, so security boundaries are product requirements rather than implementation details.

## Current threat model

The first milestone protects against:

- credentials being written to the catalog database or its history;
- secrets syncing through iCloud Keychain unintentionally;
- a metadata delete silently destroying a credential;
- a UI/history operation claiming to restore secret bytes after permanent deletion;
- accidental secret disclosure through previews or logs.

It does not protect an already-unlocked user account from a malicious process with equivalent privileges, a compromised operating system, or a user deliberately exporting secret material.

## Storage policy

### Metadata

Host profiles, identity profiles, access-key labels, public keys, fingerprints, opaque secret references, and history snapshots use a local SwiftData store. There is no CloudKit entitlement in this milestone. Password bytes are never Credential metadata: Identity and Manual Host authentication store only their password's opaque `SecretID` and allow at most one password each.

History is append-only through repository APIs. It contains `Codable` domain metadata, never arbitrary view state or secret input.

### Secrets

`KeychainSecretStore` stores generic password items using:

- an application-specific service namespace;
- a random opaque account identifier (`SecretID`);
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`;
- `kSecAttrSynchronizable = false`.

Embedded password and software-key items follow the unlocked-device Keychain policy. Exporting a software private key additionally requires system authentication. A Secure Enclave key is fixed to ECDSA P-256 and is created with `privateKeyUsage + userPresence`, so every private-key operation requires Touch ID or the system password and its private key is never exportable.

Software private material and a saved passphrase use separate immutable Keychain items. If a passphrase is not saved, it exists only for the current operation and must be entered again for each connection attempt. Generated passphrase-protected keys are encrypted before storage; public key material and fingerprints are not secret.

Secret replacement must allocate a new `SecretID`; it must not update an old Keychain item in place. Previous versions remain available to history rather than being overwritten. Legacy password Credentials are converted to embedded password methods when old records are read; their existing Keychain `SecretID` is preserved.

Manual purge is irreversible. The UI requires confirmation and removes private material plus any saved passphrase as one compensating operation. If a Keychain or metadata write fails, already-removed items are restored. History records only that a purge occurred and cannot restore the bytes after a successful purge.

Access-key metadata cannot be archived or purged while a Host or Identity references it. An Identity cannot be archived while a Host references it.

### Import compatibility

The in-process codec generates OpenSSH private keys for Ed25519, ECDSA P-256/P-384/P-521, and RSA-2048/RSA-4096. It reads and writes standard `openssh-key-v1` protection using attributed OpenBSD `bcrypt_pbkdf` plus AES-256-CTR, and imports unencrypted EC SEC1/PKCS#8, Ed25519 PKCS#8, and RSA PKCS#1/PKCS#8 before normalizing them to OpenSSH. Encrypted legacy PEM/PKCS#8 is rejected without saving partial data.

Viewing or exporting software private material requires system authentication. Editing a key creates new immutable private-material and saved-passphrase items; old identifiers remain addressable by metadata history until explicit purge. Secure Enclave material can never enter this editor as private text.

## Logging and diagnostics

- Never log password, passphrase, private-key, terminal-input, clipboard, or file-transfer payload bytes.
- Do not interpolate full domain values into errors because future fields may become sensitive.
- Prefer structured identifiers and redacted endpoint descriptions.
- Crash and analytics tooling must be reviewed before adoption and must default to no terminal/session capture.

## Future SSH policy

- Use SwiftNIO SSH behind `SSHService`.
- New hosts require an explicit trust-on-first-use decision displaying a fingerprint.
- Known host-key matches proceed without prompting.
- Host-key changes block connection and present a high-severity warning; there is no silent fallback.
- Prefer modern algorithms and reject library-deprecated choices unless a user explicitly enables a scoped compatibility override.
- Keep agent forwarding disabled by default.
- Never reuse credentials for a different host without an explicit user association.

## Future Docker policy

Access to a Docker daemon is effectively privileged infrastructure access.

- Local access uses the configured Unix domain socket.
- Remote access uses SSH forwarding or mutually authenticated TLS.
- Plain unauthenticated TCP is unsupported.
- Destructive lifecycle actions require clear target and endpoint context.
- Logs and exec share terminal redaction rules.
- API version negotiation must tolerate additional response fields and reject unsupported destructive requests safely.

## Distribution

The Direct edition is outside App Sandbox so a future local PTY can run a user shell. It must use Hardened Runtime, Developer ID signing, and notarization for distribution.

The Mac App Store edition is sandboxed and has outgoing network access. It does not expose the Local Terminal feature. User-selected file access remains read-only until a concrete transfer workflow justifies broader access.

## Reporting a vulnerability

Do not disclose a vulnerability in a public issue. A dedicated security mailbox has not been designated. Contact the maintainer privately through the repository owner profile and include a minimal reproduction without real credentials or production host details.

The commercial licensing address `terminator@zewsic.pro` is not designated as the security-reporting address.
