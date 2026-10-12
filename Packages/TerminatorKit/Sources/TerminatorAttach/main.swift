import Darwin
import Foundation

private enum FrameType: UInt8 { case hello = 1, input = 2, resize = 3, stdout = 10, stderr = 11, status = 12, exit = 13 }

private struct Hello: Codable {
    var version: UInt16
    var token: String
    var columns: Int
    var rows: Int
}

private enum PumpResult { case exit, stdinEOF, socketClosed }

@main
enum TerminatorAttachMain {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("terminator-attach: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard let socketPath = value(after: "--socket", in: arguments),
              let token = value(after: "--token", in: arguments) else {
            throw AttachError.usage
        }
        var original = termios()
        let hasTTY = tcgetattr(STDIN_FILENO, &original) == 0
        if hasTTY {
            var raw = original
            cfmakeraw(&raw)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if hasTTY { var value = original; _ = tcsetattr(STDIN_FILENO, TCSANOW, &value) } }

        var delay = 0.5
        var announcedOutage = false
        while true {
            do {
                let socketFD = try connect(socketPath)
                defer { Darwin.close(socketFD) }
                let size = terminalSize()
                try send(.hello, try JSONEncoder().encode(Hello(version: 1, token: token, columns: size.0, rows: size.1)), to: socketFD)
                announcedOutage = false
                delay = 0.5
                switch try pump(socketFD) {
                case .exit, .stdinEOF: return
                case .socketClosed: break
                }
            } catch AttachError.usage {
                throw AttachError.usage
            } catch AttachError.pathTooLong {
                throw AttachError.pathTooLong
            } catch {
                // A missing socket or a dropped connection uses the same backoff.
            }
            if !announcedOutage {
                try writeAll(Data("\r\n[Terminator: Reconnecting...]\r\n".utf8), to: STDOUT_FILENO)
                announcedOutage = true
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 5)
        }
    }

    private static func connect(_ socketPath: String) throws -> Int32 {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw AttachError.system(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            throw AttachError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in socketPath.utf8.enumerated() { bytes[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = errno
            Darwin.close(socketFD)
            throw AttachError.system(error)
        }
        return socketFD
    }

    private static func pump(_ socketFD: Int32) throws -> PumpResult {
        var lastSize = terminalSize()
        var pollDescriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let result = Darwin.poll(&pollDescriptors, nfds_t(pollDescriptors.count), 250)
            guard result >= 0 || errno == EINTR else { return .socketClosed }
            let currentSize = terminalSize()
            if currentSize != lastSize {
                lastSize = currentSize
                try send(.resize, try JSONEncoder().encode([currentSize.0, currentSize.1]), to: socketFD)
            }
            if pollDescriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { return .stdinEOF }
                if count > 0 { try send(.input, Data(bytes.prefix(count)), to: socketFD) }
            }
            if pollDescriptors[1].revents & Int16(POLLIN) != 0 {
                guard let (type, payload) = try receive(from: socketFD) else { return .socketClosed }
                switch type {
                case .stdout, .status: try writeAll(payload, to: STDOUT_FILENO)
                case .stderr: try writeAll(payload, to: STDERR_FILENO)
                case .exit: return .exit
                default: break
                }
            } else if pollDescriptors[1].revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                return .socketClosed
            }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func terminalSize() -> (Int, Int) {
        var size = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { return (80, 24) }
        return (max(1, Int(size.ws_col)), max(1, Int(size.ws_row)))
    }

    private static func send(_ type: FrameType, _ payload: Data, to fd: Int32) throws {
        var frame = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeAll(frame, to: fd)
    }

    private static func receive(from fd: Int32) throws -> (FrameType, Data)? {
        guard let header = try readExact(5, from: fd) else { return nil }
        guard let type = FrameType(rawValue: header[0]) else { throw AttachError.protocolError }
        let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= 16 * 1_024 * 1_024 else { throw AttachError.protocolError }
        return (type, try readExact(Int(length), from: fd) ?? Data())
    }

    private static func readExact(_ count: Int, from fd: Int32) throws -> Data? {
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let readCount = Darwin.read(fd, &bytes, bytes.count)
            if readCount == 0 { return result.isEmpty ? nil : result }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw AttachError.system(errno)
            }
            result.append(contentsOf: bytes.prefix(readCount))
        }
        return result
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AttachError.system(errno)
                }
                offset += count
            }
        }
    }
}

private enum AttachError: LocalizedError {
    case usage, pathTooLong, protocolError, system(Int32)
    var errorDescription: String? {
        switch self {
        case .usage: String(localized: "attach.error.usage", bundle: .module)
        case .pathTooLong: String(localized: "attach.error.pathTooLong", bundle: .module)
        case .protocolError: String(localized: "attach.error.protocolError", bundle: .module)
        case .system(let code): String(cString: strerror(code))
        }
    }
}
