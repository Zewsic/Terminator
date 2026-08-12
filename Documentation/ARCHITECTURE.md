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

`TerminatorPersistence` owns SwiftData records and mapping. `HostRecord`, `CredentialRecord`, and `ChangeRecord` are implementation details and never cross its public boundary.

`TerminatorSecurity` owns Keychain queries. Callers address secrets by opaque `SecretID`; they do not know Keychain service/account details.

`TerminatorFeatures` owns SwiftUI views and the `@MainActor @Observable` application model. Views do not fetch SwiftData records or call Security APIs directly.

The app target constructs concrete actors and injects them through protocol existentials. There are no mutable global service singletons.

## Data flow

1. A SwiftUI editor produces a domain draft.
2. `TerminatorAppModel` validates intent and coordinates multi-store operations.
3. A repository actor validates the domain value again, writes the current record, appends a redacted history record, and saves one SwiftData context transaction.
4. The application model reloads domain values and Observation updates affected views.

Credential creation is a small compensating transaction:

1. Create a new immutable `SecretID`.
2. Write secret bytes to Keychain.
3. Persist only `CredentialMetadata` and its `SecretID`.
4. If metadata persistence fails, purge the just-created Keychain item.

Existing secret items are never overwritten. Replacing a secret creates a new credential version, allowing older Keychain items to remain available until manual cleanup.

## History semantics

- `ChangeRecord` is append-only from repository APIs.
- Every change contains a schema version and redacted before/after JSON snapshots.
- Revert applies the selected `beforeSnapshot` as a new current value and appends `.restored`.
- Reverting creation produces a soft-deleted current record rather than erasing it.
- Secret bytes are structurally impossible to serialize because domain credential metadata contains only `SecretID` and public metadata.
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
