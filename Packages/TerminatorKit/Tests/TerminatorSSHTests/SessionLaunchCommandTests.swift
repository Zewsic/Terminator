import Foundation
import Testing
import TerminatorCore
@testable import TerminatorSSH

@Test func noPersistenceAndNoCommandsUsesAPlainShell() {
    let command = SessionLaunchCommand.remoteCommand(
        sessionID: UUID(), persistence: .none, connectCommands: "  \n"
    )
    #expect(command == nil)
}

@Test func noPersistenceRunsCommandsThenALoginShell() throws {
    let command = SessionLaunchCommand.remoteCommand(
        sessionID: UUID(), persistence: .none, connectCommands: "export FOO=1\ncd /srv"
    )
    let value = try #require(command)
    #expect(value.contains("export FOO=1"))
    #expect(value.contains("cd /srv"))
    #expect(value.contains("exec \"${SHELL:-/bin/sh}\" -l"))
    #expect(!value.contains("tmux"))
    #expect(!value.contains("screen"))
}

@Test func tmuxAttachesExistingSessionWithoutRerunningStartupCommands() throws {
    let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let command = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: sessionID, persistence: .tmux, connectCommands: "unique_boot_marker"
    ))
    let name = SessionLaunchCommand.multiplexerName(sessionID: sessionID)
    #expect(command.contains("tmux has-session"))
    #expect(command.contains("tmux attach-session -t '\(name)'"))
    #expect(command.contains("tmux new-session -s '\(name)'"))
    #expect(command.contains("unique_boot_marker"))
    let attachIndex = try #require(command.range(of: "attach-session")?.lowerBound)
    let newIndex = try #require(command.range(of: "new-session")?.lowerBound)
    #expect(attachIndex < newIndex)
    let attachSlice = command[..<newIndex]
    #expect(!attachSlice.contains("unique_boot_marker"))
}

@Test func screenReusesTheSameSessionNameOnReconnect() throws {
    let sessionID = UUID()
    let first = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: sessionID, persistence: .screen, connectCommands: ""
    ))
    let second = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: sessionID, persistence: .screen, connectCommands: ""
    ))
    #expect(first == second)
    #expect(first.contains("screen -d -rr"))
    #expect(first.contains("screen -S"))
    #expect(SessionLaunchCommand.multiplexerName(sessionID: sessionID).hasPrefix("t"))
}

@Test func requestedShellIsUsedForNewSessions() throws {
    let zsh = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: UUID(),
        persistence: .none,
        connectCommands: "",
        shell: RemoteShell(preset: .zsh)
    ))
    #expect(zsh.contains("command -v zsh"))
    #expect(zsh.contains("exec \"$_terminator_shell\" -l"))

    let custom = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: UUID(),
        persistence: .none,
        connectCommands: "cd /tmp",
        shell: RemoteShell(preset: .custom, customPath: "/opt/homebrew/bin/fish")
    ))
    #expect(custom.contains("cd /tmp"))
    #expect(custom.contains("/opt/homebrew/bin/fish"))
    #expect(custom.contains("exec "))
}

@Test func missingMultiplexerFallsBackToARegularShell() throws {
    let tmux = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: UUID(), persistence: .tmux, connectCommands: ""
    ))
    #expect(tmux.contains("tmux is not installed"))
    let screen = try #require(SessionLaunchCommand.remoteCommand(
        sessionID: UUID(), persistence: .screen, connectCommands: ""
    ))
    #expect(screen.contains("screen is not installed"))
}
