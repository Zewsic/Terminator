import Foundation

struct CrontabDocument: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var marker: UUID?
        var task: ScheduledTask
    }

    var entries: [Entry]
    var preamble: [String]
    var environment: CrontabEnvironment
    var hash: String

    static func parse(hostID: UUID, text: String, hash: String, writable: Bool, salt: String = "") -> CrontabDocument {
        var environment = CrontabEnvironment()
        var preamble: [String] = []
        var entries: [Entry] = []
        var pendingMarker: UUID?
        var pendingName = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if entries.isEmpty { preamble.append(rawLine) }
                continue
            }
            if let marker = marker(in: line), job(from: line, hostID: hostID, marker: marker.id, name: marker.name, writable: writable, salt: salt) == nil {
                pendingMarker = marker.id
                pendingName = marker.name
                continue
            }
            if let assignment = environmentAssignment(line) {
                switch assignment.key {
                case "SHELL": environment.shell = assignment.value
                case "PATH": environment.path = assignment.value
                case "MAILTO": environment.mailto = assignment.value
                default: preamble.append(rawLine)
                }
                continue
            }
            if let task = job(from: line, hostID: hostID, marker: pendingMarker, name: pendingName, writable: writable, salt: salt) {
                entries.append(Entry(marker: task.id, task: task))
                pendingMarker = nil
                pendingName = ""
                continue
            }
            pendingMarker = nil
            pendingName = ""
            if entries.isEmpty {
                preamble.append(rawLine)
            }
        }
        return CrontabDocument(entries: entries, preamble: preamble, environment: environment, hash: hash)
    }

    func rendered() -> String {
        var lines: [String] = []
        if !environment.shell.isEmpty { lines.append("SHELL=\(environment.shell)") }
        if !environment.path.isEmpty { lines.append("PATH=\(environment.path)") }
        if !environment.mailto.isEmpty { lines.append("MAILTO=\(environment.mailto)") }
        lines.append(contentsOf: preamble.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        for entry in entries {
            let name = entry.task.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let suffix = name.isEmpty ? "" : " " + name
            lines.append("# terminator:\(entry.task.id.uuidString)\(suffix)")
            let expression = entry.task.schedule.expression
            let command = entry.task.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = expression + " " + command
            lines.append(entry.task.enabled ? body : "#" + body)
        }
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    func replacing(_ task: ScheduledTask, environment: CrontabEnvironment) -> CrontabDocument {
        var copy = self
        copy.environment = environment
        if let index = copy.entries.firstIndex(where: { $0.task.id == task.id }) {
            copy.entries[index].task = task
            copy.entries[index].marker = task.id
        } else {
            copy.entries.append(Entry(marker: task.id, task: task))
        }
        return copy
    }

    func removing(_ id: UUID, environment: CrontabEnvironment) -> CrontabDocument {
        var copy = self
        copy.environment = environment
        copy.entries.removeAll { $0.task.id == id }
        return copy
    }

    private static func marker(in line: String) -> (id: UUID, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard comment.hasPrefix("terminator:") else { return nil }
        let rest = comment.dropFirst("terminator:".count)
        let pieces = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let id = pieces.first.flatMap({ UUID(uuidString: String($0)) }) else { return nil }
        let name = pieces.count > 1 ? String(pieces[1]) : ""
        return (id, name)
    }

    private static func environmentAssignment(_ line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(of: "="), !line.hasPrefix("#") else { return nil }
        let key = String(line[..<separator])
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return nil }
        return (key, String(line[line.index(after: separator)...]))
    }

    private static func job(from line: String, hostID: UUID, marker: UUID?, name: String, writable: Bool, salt: String) -> ScheduledTask? {
        var text = line.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if text.hasPrefix("#") {
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            guard schedule(from: rest) != nil else { return nil }
            text = String(rest)
            enabled = false
        }
        guard let parsed = schedule(from: text) else { return nil }
        let identity = marker ?? TaskIdentity.stable(hostID: hostID, marker: salt + "\n" + text)
        return ScheduledTask(
            id: identity,
            hostID: hostID,
            backend: .cron,
            scope: .user,
            name: name,
            command: parsed.command,
            schedule: parsed.schedule,
            enabled: enabled,
            writable: writable
        )
    }

    private static func schedule(from line: String) -> (schedule: TaskSchedule, command: String)? {
        let nicknames: [(String, TaskSchedule.Preset)] = [
            ("@reboot", .reboot),
            ("@yearly", .custom),
            ("@annually", .custom),
            ("@monthly", .monthly),
            ("@weekly", .weekly),
            ("@daily", .daily),
            ("@midnight", .daily),
            ("@hourly", .hourly),
        ]
        for (name, preset) in nicknames where line.hasPrefix(name) {
            let command = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            var schedule = TaskSchedule()
            schedule.preset = preset
            if name == "@yearly" || name == "@annually" {
                schedule.cronMinute = "0"
                schedule.cronHour = "0"
                schedule.cronDayOfMonth = "1"
                schedule.cronMonth = "1"
                schedule.cronDayOfWeek = "*"
            }
            if preset == .monthly { schedule.dayOfMonth = 1; schedule.hour = 0; schedule.minute = 0 }
            if preset == .weekly { schedule.weekday = 0; schedule.hour = 0; schedule.minute = 0 }
            if preset == .daily || preset == .hourly { schedule.hour = 0; schedule.minute = 0 }
            return (schedule, String(command))
        }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 6 else { return nil }
        let fields = Array(parts.prefix(5))
        guard fields.allSatisfy({ $0.range(of: #"^[\d\*,/\-]+$"#, options: .regularExpression) != nil }) else { return nil }
        let command = parts.dropFirst(5).joined(separator: " ")
        guard !command.isEmpty else { return nil }
        return (interpreted(fields), command)
    }

    private static func interpreted(_ fields: [String]) -> TaskSchedule {
        var schedule = TaskSchedule()
        schedule.cronMinute = fields[0]
        schedule.cronHour = fields[1]
        schedule.cronDayOfMonth = fields[2]
        schedule.cronMonth = fields[3]
        schedule.cronDayOfWeek = fields[4]
        if let minute = Int(fields[0]), fields[1] == "*", fields[2] == "*", fields[3] == "*", fields[4] == "*" {
            schedule.preset = .hourly
            schedule.minute = minute
            return schedule
        }
        if let minute = Int(fields[0]), let hour = Int(fields[1]), fields[2] == "*", fields[3] == "*", fields[4] == "*" {
            schedule.preset = .daily
            schedule.minute = minute
            schedule.hour = hour
            return schedule
        }
        if let minute = Int(fields[0]), let hour = Int(fields[1]), fields[2] == "*", fields[3] == "*", let weekday = Int(fields[4]) {
            schedule.preset = .weekly
            schedule.minute = minute
            schedule.hour = hour
            schedule.weekday = weekday
            return schedule
        }
        if let minute = Int(fields[0]), let hour = Int(fields[1]), let day = Int(fields[2]), fields[3] == "*", fields[4] == "*" {
            schedule.preset = .monthly
            schedule.minute = minute
            schedule.hour = hour
            schedule.dayOfMonth = day
            return schedule
        }
        schedule.preset = .custom
        return schedule
    }
}

enum TaskExecutionParser {
    static func parse(_ lines: [String]) -> [TaskExecution] {
        lines.enumerated().map { index, line in
            let failed = line.range(of: "fail", options: .caseInsensitive) != nil
                || line.range(of: "error", options: .caseInsensitive) != nil
            return TaskExecution(
                id: "\(index)-\(line.hashValue)",
                recordedAt: date(in: line),
                result: failed ? "Failed" : "Ran",
                summary: line
            )
        }
    }

    private static func date(in line: String) -> Date? {
        let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: token) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: token)
    }
}
