# Planned features

These surfaces intentionally remain placeholders during the architecture refactor.

| Feature | Current status | Backend required |
| --- | --- | --- |
| Tunnels | Navigation placeholder only; no behavior changed. | Tunnel lifecycle service, port-forwarding model, persistence, and SSH channel integration. |
| Snippets | Navigation placeholder only; no behavior changed. | Snippet repository, execution policy, variable substitution, and terminal dispatch. |
| Docker | Demo container catalog only; no Docker daemon is contacted. | Docker socket/CLI discovery, container lifecycle service, streaming logs, and permissions UX. |
| Export to Host | Access-key editor placeholder only; no remote mutation is performed. | Authorized-keys reader/writer, conflict handling, remote permission validation, and audit history. |
