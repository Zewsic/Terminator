# Terminator Servers for Raycast

This local Raycast extension lists servers saved in Terminator and opens the selected one in the default macOS Terminal.

1. Launch Terminator once; it writes a non-secret server catalog to `~/Library/Application Support/Terminator/Integrations/Raycast/servers.json`.
2. In this directory, run `npm install && npm run dev`.
3. Search Raycast for **Search Terminator Servers**.

The catalog includes only display name, hostname, port, group, and tags. Credentials, usernames, and SSH keys never leave Terminator.
