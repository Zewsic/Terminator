import Foundation

enum TaskBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case cron
    case systemd
    case at
    case anacron
    case launchd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cron: "Cron"
        case .systemd: "systemd"
        case .at: "at"
        case .anacron: "anacron"
        case .launchd: "launchd"
        }
    }

    var symbol: String {
        switch self {
        case .cron: "clock"
        case .systemd: "gearshape.2"
        case .at: "timer"
        case .anacron: "calendar"
        case .launchd: "apple.logo"
        }
    }
}

enum TaskScope: String, Codable, Sendable {
    case user
    case system
}

struct TaskSchedule: Codable, Equatable, Hashable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case hourly
        case daily
        case weekly
        case monthly
        case custom
        case reboot
        case interval
    }

    var preset: Preset = .daily
    var minute: Int = 0
    var hour: Int = 3
    var dayOfMonth: Int = 1
    var weekday: Int = 1
    var cronMinute: String = "*"
    var cronHour: String = "*"
    var cronDayOfMonth: String = "*"
    var cronMonth: String = "*"
    var cronDayOfWeek: String = "*"
    var intervalMinutes: Int = 30
    var onceAt: Date = .now
    var bootDelayMinutes: Int = 0
    var afterPreviousMinutes: Int = 0
    var catchUp: Bool = false
    var randomDelayMinutes: Int = 0
    var periodDays: Int = 1
    var anacronDelayMinutes: Int = 5
    var batch: Bool = false

    var expression: String {
        switch preset {
        case .hourly: "\(minute) * * * *"
        case .daily: "\(minute) \(hour) * * *"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .monthly: "\(minute) \(hour) \(dayOfMonth) * *"
        case .reboot: "@reboot"
        case .interval: "\(max(intervalMinutes, 1))m"
        case .custom:
            [cronMinute, cronHour, cronDayOfMonth, cronMonth, cronDayOfWeek]
                .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : $0 }
                .joined(separator: " ")
        }
    }
}

struct TaskCapabilities: Equatable, Sendable {
    var cron = false
    var systemd = false
    var at = false
    var anacron = false
    var launchd = false
    var isRoot = false
    var systemCron = false

    func allows(_ backend: TaskBackend) -> Bool {
        switch backend {
        case .cron: cron
        case .systemd: systemd
        case .at: at
        case .anacron: anacron
        case .launchd: launchd
        }
    }
}

struct ScheduledTask: Identifiable, Equatable, Sendable {
    var id: UUID
    var hostID: UUID
    var backend: TaskBackend
    var scope: TaskScope
    var name: String
    var command: String
    var schedule: TaskSchedule
    var enabled: Bool
    var writable: Bool
    var listTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? backend.title : command
    }
}

struct TaskDraft: Equatable, Sendable {
    var backend: TaskBackend = .cron
    var name = ""
    var command = ""
    var schedule = TaskSchedule()
    var enabled = true
    var shell = ""
    var path = ""
    var mailto = ""

    init() {}

    init(task: ScheduledTask, environment: CrontabEnvironment) {
        backend = task.backend
        name = task.name
        command = task.command
        schedule = task.schedule
        enabled = task.enabled
        shell = environment.shell
        path = environment.path
        mailto = environment.mailto
    }
}

struct TaskHistorySnapshot: Codable, Equatable, Sendable {
    var name: String
    var command: String
    var schedule: String
    var backend: String
    var enabled: Bool
    var host: String
}

struct TaskExecution: Identifiable, Equatable, Sendable {
    var id: String
    var recordedAt: Date?
    var result: String
    var summary: String
}

struct CrontabEnvironment: Equatable, Sendable {
    var shell = ""
    var path = ""
    var mailto = ""
}

enum TaskIdentity {
    static func stable(hostID: UUID, marker: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var mixed = hostID.uuidString + "\n" + marker
        func fold(_ text: String, salt: UInt64) -> UInt64 {
            var value = hash ^ salt
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
            return value
        }
        let left = fold(mixed, salt: 1)
        mixed.append("#")
        let right = fold(mixed, salt: 2)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((left >> (8 * index)) & 0xFF)
            bytes[index + 8] = UInt8((right >> (8 * index)) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum TaskScheduleText {
    static func summary(_ schedule: TaskSchedule, backend: TaskBackend) -> String {
        switch backend {
        case .at:
            return schedule.onceAt.formatted(date: .abbreviated, time: .shortened)
        case .anacron:
            return "Every \(max(schedule.periodDays, 1)) days"
        case .cron, .systemd, .launchd:
            switch schedule.preset {
            case .hourly:
                return "Every hour at :\(String(format: "%02d", schedule.minute))"
            case .daily:
                return "Every day at \(clock(schedule))"
            case .weekly:
                return "Every \(weekday(schedule.weekday)) at \(clock(schedule))"
            case .monthly:
                return "Day \(schedule.dayOfMonth) of each month at \(clock(schedule))"
            case .reboot:
                return "On startup"
            case .interval:
                return "Every \(max(schedule.intervalMinutes, 1)) minutes"
            case .custom:
                return schedule.expression
            }
        }
    }

    static func weekday(_ value: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][min(max(value, 0), 6)]
    }

    static func clock(_ schedule: TaskSchedule) -> String {
        String(format: "%02d:%02d", schedule.hour, schedule.minute)
    }
}
