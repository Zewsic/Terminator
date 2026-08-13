# Architecture

## Goals

Terminator starts as a macOS application but treats macOS as a composition target, not as the home of business logic. Shared package APIs support macOS 26 and iOS 26. A future iOS target should compose the same domain, persistence, security, and feature modules with platform-specific capabilities.

The architecture optimizes for:

- explicit security boundaries;
- testable state transitions;
- append-only audit history;
- replaceable SSH, Docker, persistence, and terminal implementations;
- minimal conditional compilation outside the application target.

## Dependency rules

```text
TerminatorMac
  ├── TerminatorFeatures ──> TerminatorCore
  ├── TerminatorPersistence ──> TerminatorCore
  └── TerminatorSecurity ──> TerminatorCore

TerminatorTestSupport ──> TerminatorCore
```

`TerminatorCore` imports Foundation only. It owns domain values and async `Sendable` protocols, never platform frameworks or persistent model types.

`TerminatorPersistence` owns SwiftData records and mapping. `HostRecord`, `CredentialRecord`, `IdentityRecord`, and `ChangeRecord` are implementation details and never cross its public boundary.

`TerminatorSecurity` owns Keychain queries, software-key codecs, Secure Enclave key creation, system authorization, and authentication resolution. Callers address secrets by opaque `SecretID`; they do not know Keychain service/account details.

`TerminatorFeatures` owns SwiftUI views and the `@MainActor @Observable` application model. Views do not fetch SwiftData records or call Security APIs directly.

The app target constructs concrete actors and injects them through protocol existentials. There are no mutable global service singletons.

## Data flow

1. A SwiftUI editor produces a domain draft.
2. `TerminatorAppModel` validates intent and coordinates multi-store operations.
3. A repository actor validates the domain value again, writes the current record, appends a redacted history record, and saves one SwiftData context transaction.
4. The application model reloads domain values and Observation updates affected views.

Secret creation is a small compensating transaction:

1. Create a new immutable `SecretID` for access-key private material, a saved passphrase, or an embedded password.
2. Write secret bytes to Keychain; a saved key passphrase receives a separate `SecretID`.
3. Persist only typed access-key `CredentialMetadata`, public key data, fingerprints, and opaque identifiers. Identity and Host password methods contain only the opaque `SecretID`.
4. If any later write fails, purge every item created by the operation.

Existing secret items are never overwritten. Replacing a secret allocates new identifiers, allowing older Keychain items to remain available until manual cleanup. Multi-item purge first reads a compensating backup and restores removed items if any Keychain or metadata step fails.

## Authentication model

`IdentityProfile` owns a name, username, and a non-empty ordered list of authentication methods. `HostAuthentication` selects either a complete Identity or a manual username plus the same ordered method model; Identity mode has no host-level overrides. A method is either one embedded password reference or an access-key Credential reference. Validation permits at most one password and any number of unique access keys, so passwords never need labels or appear in the global Credentials catalog.

`AuthenticationResolver` turns a Host into an ordered list of safe handles. It resolves an embedded password directly by `SecretID`, reads saved key passphrases from their own Keychain items, and asks for unsaved passphrases once per resolution. The resolver has no cross-connection passphrase cache. Network SSH remains a separate transport adapter and must not advertise an authentication method until that adapter can sign with it.

## History semantics

- `ChangeRecord` is append-only from repository APIs.
- Every change contains a schema version and redacted before/after JSON snapshots.
- Revert applies the selected `beforeSnapshot` as a new current value and appends `.restored`.
- Reverting creation produces a soft-deleted current record rather than erasing it.
- Secret bytes are structurally impossible to serialize because authentication methods and credential metadata contain only `SecretID` and public metadata.
- `.purged` is not revertible because history cannot reconstruct deleted Keychain bytes.

Future schema changes must add version-aware snapshot decoders before changing the stored domain encoding.

## Distribution capabilities

Both editions use `TerminatorMac` and bundle ID `pro.zewsic.terminator`.

- Direct uses `Direct.xcconfig`, disables App Sandbox, and defines `TERMINATOR_DIRECT`.
- App Store uses `AppStore.xcconfig`, enables App Sandbox and outgoing network access, and defines `APP_STORE`.

The app converts compilation conditions into `AppCapabilities`. Feature navigation consumes capabilities rather than scattered `#if` statements. The future local PTY adapter belongs only in the app/platform layer and is never constructed for the App Store edition.

## Extension points

### SSH

Implement `SSHService` with SwiftNIO SSH. Authentication, host-key decisions, interactive channels, direct TCP forwarding, and remote forwarding should be separate collaborators behind that adapter. Session state must be actor-isolated.

### Terminal

`TerminalSession` exposes asynchronous output, input, resize, and close operations. A renderer consumes that protocol whether bytes originate from a local PTY, an SSH channel, or Docker exec.

### Docker

Implement `DockerService` against the versioned Docker Engine API. Transports are independent:

- Unix domain socket for local Docker;
- a stream forwarded over Terminator's SSH connection for remote Docker;
- mutually authenticated TLS for explicitly configured remote engines.

Do not shell out to the Docker CLI for core behavior and do not expose unauthenticated TCP.

### Sync

Sync must operate on encrypted domain events or exports, never directly expose a SwiftData file. Key material for sync requires a separate design and must not reuse raw SSH credentials.
