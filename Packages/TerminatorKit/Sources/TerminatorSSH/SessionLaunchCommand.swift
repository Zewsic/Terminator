import Foundation
import TerminatorCore

enum SessionLaunchCommand {
    static func remoteCommand(
        sessionID: UUID,
        persistence: SessionPersistence,
        connectCommands: String,
        shell: RemoteShell = .login
    ) -> String? {
        let inner = innerShell(connectCommands: connectCommands, shell: shell)
        switch persistence {
        case .none:
            let trimmed = connectCommands.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, shell.preset == .loginShell { return nil }
            return "/bin/sh -lc \(quote(inner))"
        case .tmux:
            return multiplexerScript(sessionID: sessionID, tool: .tmux, inner: inner)
        case .screen:
            return multiplexerScript(sessionID: sessionID, tool: .screen, inner: inner)
        }
    }

    static func multiplexerName(sessionID: UUID) -> String {
        "t" + sessionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    private enum Tool { case tmux, screen }

    private static func innerShell(connectCommands: String, shell: RemoteShell) -> String {
        let trimmed = connectCommands.trimmingCharacters(in: .whitespacesAndNewlines)
        let execLine = execShell(shell)
        if trimmed.isEmpty { return execLine }
        return trimmed + "\n" + execLine
    }

    private static func execShell(_ shell: RemoteShell) -> String {
        switch shell.preset {
        case .loginShell:
            return "exec \"${SHELL:-/bin/sh}\" -l"
        case .custom:
            let path = shell.customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { return "exec \"${SHELL:-/bin/sh}\" -l" }
            return "exec \(quote(path)) -l"
        case .zsh, .bash, .sh, .fish:
            let name = shell.preset.rawValue
            return """
            _terminator_shell=$(command -v \(name) 2>/dev/null || true)
            if [ -z "$_terminator_shell" ]; then
              printf '\\r\\n[Terminator: \(name) is not installed on this host. Using the login shell.]\\r\\n'
              exec "${SHELL:-/bin/sh}" -l
            fi
            exec "$_terminator_shell" -l
            """
        }
    }

    private static func multiplexerScript(sessionID: UUID, tool: Tool, inner: String) -> String {
        let name = multiplexerName(sessionID: sessionID)
        let quotedInner = quote(inner)
        let quotedName = quote(name)
        switch tool {
        case .tmux:
            return """
            if command -v tmux >/dev/null 2>&1; then \
              if tmux has-session -t \(quotedName) 2>/dev/null; then \
                exec tmux attach-session -t \(quotedName); \
              fi; \
              exec tmux new-session -s \(quotedName) -- /bin/sh -lc \(quotedInner); \
            fi; \
            printf '\\r\\n[Terminator: tmux is not installed on this host. Starting a regular shell.]\\r\\n'; \
            exec /bin/sh -lc \(quotedInner)
            """
        case .screen:
            return """
            if command -v screen >/dev/null 2>&1; then \
              if screen -ls 2>/dev/null | grep -q "[.]\(name)[[:space:]]"; then \
                exec screen -d -rr \(quotedName); \
              fi; \
              exec screen -S \(quotedName) /bin/sh -lc \(quotedInner); \
            fi; \
            printf '\\r\\n[Terminator: screen is not installed on this host. Starting a regular shell.]\\r\\n'; \
            exec /bin/sh -lc \(quotedInner)
            """
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
