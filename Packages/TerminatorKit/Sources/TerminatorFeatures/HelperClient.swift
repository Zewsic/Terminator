import Foundation
import Security
import TerminatorCore

struct HelperInstallation: Codable, Equatable, Sendable, Identifiable {
    var hostID: UUID
    var port: Int
    var localPort: Int?
    var tokenSecretID: SecretID
    var certificateDER: Data
    var version: String

    var id: UUID { hostID }
    private enum CodingKeys: String, CodingKey {
        case hostID, port, localPort, tokenSecretID, certificateDER, version
    }

    init(
        hostID: UUID,
        port: Int,
        tokenSecretID: SecretID,
        certificateDER: Data,
        version: String = HelperSnapshot.version,
        localPort: Int? = nil
    ) {
        self.hostID = hostID
        self.port = port
        self.localPort = localPort
        self.tokenSecretID = tokenSecretID
        self.certificateDER = certificateDER
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        port = try container.decode(Int.self, forKey: .port)
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort)
        tokenSecretID = try container.decode(SecretID.self, forKey: .tokenSecretID)
        certificateDER = try container.decode(Data.self, forKey: .certificateDER)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(localPort, forKey: .localPort)
        try container.encode(tokenSecretID, forKey: .tokenSecretID)
        try container.encode(certificateDER, forKey: .certificateDER)
        try container.encode(version, forKey: .version)
    }
}

enum HelperForward {
    static func tunnelID(for hostID: UUID) -> UUID {
        let raw = hostID.uuid
        return UUID(uuid: (
            raw.0 ^ 0xA5, raw.1, raw.2, raw.3,
            raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11,
            raw.12, raw.13, raw.14, raw.15
        ))
    }

    static func localPort(for hostID: UUID) -> Int {
        let raw = hostID.uuid
        let mixed = (Int(raw.14) << 8) | Int(raw.15)
        return 20_000 + (mixed % 20_000)
    }
}

enum HelperStore {
    static var url: URL { ConnectionServicePaths.applicationSupport.appending(path: "helpers.json") }

    static func load() -> [HelperInstallation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HelperInstallation].self, from: data)) ?? []
    }

    static func save(_ items: [HelperInstallation]) throws {
        try FileManager.default.createDirectory(at: ConnectionServicePaths.applicationSupport, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: url, options: .atomic)
    }
}

enum HelperInstallError: LocalizedError {
    case openssl
    case unavailable
    case remote(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .openssl: FeatureL10n.text(.helperOpenSSL)
        case .unavailable: FeatureL10n.text(.helperUnavailable)
        case .remote(let message): message
        case .timedOut: FeatureL10n.text(.helperTimedOut)
        }
    }
}
enum HelperCertificate {
    static func der(pem: String) -> Data? {
        let body = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: String(body), options: .ignoreUnknownCharacters)
    }
}

enum HelperMaterial {
    struct Bundle: Sendable {
        var certificatePEM: String
        var privateKeyPEM: String
        var certificateDER: Data
        var token: String
    }

    static func generate() throws -> Bundle {
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "terminator-helper-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appending(path: "key.pem")
        let certificate = directory.appending(path: "cert.pem")
        let der = directory.appending(path: "cert.der")
        guard runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", key.path, "-out", certificate.path, "-subj", "/CN=terminator-helper",
        ]), runOpenSSL(["x509", "-in", certificate.path, "-outform", "DER", "-out", der.path]) else {
            throw HelperInstallError.openssl
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HelperInstallError.openssl
        }
        return Bundle(
            certificatePEM: try String(contentsOf: certificate, encoding: .utf8),
            privateKeyPEM: try String(contentsOf: key, encoding: .utf8),
            certificateDER: try Data(contentsOf: der),
            token: bytes.map { String(format: "%02x", $0) }.joined()
        )
        #else
        throw HelperInstallError.openssl
        #endif
    }

    #if os(macOS)
    private static func runOpenSSL(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #endif
}

enum HelperRemoteScript {
    static let server = #"""
import json, os, ssl, time, socket, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = open("/helper/token", encoding="utf-8").read().strip()
PORT = 53621
VERSION = "\#(HelperSnapshot.version)"
LAST = {"time": None, "rx": 0, "tx": 0}

def cpu_sample():
    rows = {}
    try:
        for line in open("/proc/stat", encoding="utf-8"):
            if not line.startswith("cpu"):
                break
            parts = line.split()
            nums = [int(part) for part in parts[1:]]
            idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
            rows[parts[0]] = (sum(nums), idle)
    except OSError:
        return {}
    return rows

SKIP_FS = {
    "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "cgroup", "cgroup2", "overlay",
    "squashfs", "nsfs", "autofs", "bpf", "tracefs", "securityfs", "pstore", "mqueue",
    "hugetlbfs", "debugfs", "configfs", "fusectl", "binfmt_misc", "rpc_pipefs", "nfsd",
    "ramfs", "efivarfs",
}

def core_rows(first, second):
    result = []
    for name, total_idle in second.items():
        if name not in first:
            continue
        previous = first[name]
        delta = total_idle[0] - previous[0]
        idle = total_idle[1] - previous[1]
        usage = ((delta - idle) / delta) if delta else 0
        if usage < 0:
            usage = 0
        if usage > 1:
            usage = 1
        result.append({"name": name, "usage": usage})
    return result

def disk_sample():
    rows = {}
    try:
        for line in open("/proc/diskstats", encoding="utf-8"):
            fields = line.split()
            if len(fields) < 10:
                continue
            rows[fields[2]] = (int(fields[5]), int(fields[9]))
    except (OSError, ValueError, IndexError):
        pass
    return rows

def nic_sample():
    rows = {}
    try:
        for line in open("/proc/net/dev", encoding="utf-8"):
            if ":" not in line:
                continue
            name, rest = line.split(":", 1)
            name = name.strip()
            if name in ("lo", ""):
                continue
            fields = rest.split()
            if len(fields) <= 8:
                continue
            rows[name] = (int(fields[0]), int(fields[8]))
    except (OSError, ValueError, IndexError):
        pass
    return rows

def proc_sample():
    rows = {}
    try:
        names = os.listdir("/proc")
    except OSError:
        return rows
    for name in names:
        if not name.isdigit():
            continue
        try:
            stat = open("/proc/" + name + "/stat", encoding="utf-8", errors="replace").read()
            start = stat.find("(")
            end = stat.rfind(")")
            if start < 0 or end < start:
                continue
            comm = stat[start + 1:end]
            rest = stat[end + 2:].split()
            if len(rest) < 13:
                continue
            ticks = int(rest[11]) + int(rest[12])
            rss = 0
            uid = 0
            for line in open("/proc/" + name + "/status", encoding="utf-8", errors="replace"):
                if line.startswith("Uid:"):
                    uid = int(line.split()[1])
                elif line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) * 1024
            read_b = write_b = 0
            try:
                for line in open("/proc/" + name + "/io", encoding="utf-8"):
                    if line.startswith("read_bytes:"):
                        read_b = int(line.split()[1])
                    elif line.startswith("write_bytes:"):
                        write_b = int(line.split()[1])
            except OSError:
                pass
            rows[int(name)] = (comm, ticks, rss, uid, read_b, write_b)
        except (OSError, ValueError, IndexError):
            continue
    return rows

def user_names():
    table = {}
    path = "/host/etc/passwd" if os.path.isfile("/host/etc/passwd") else "/etc/passwd"
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            parts = line.split(":")
            if len(parts) > 2 and parts[2].isdigit():
                table[int(parts[2])] = parts[0]
    except OSError:
        pass
    return table

def host_df():
    if not os.path.isdir("/host"):
        return ""
    for binary in ("/usr/sbin/chroot", "/bin/chroot", "chroot"):
        try:
            completed = subprocess.run(
                [binary, "/host", "df", "-PT", "-B1"],
                capture_output=True, text=True, timeout=2,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if completed.returncode == 0 and completed.stdout:
            return completed.stdout
    return ""

def disk_rows(first, second, elapsed):
    rates = {}
    if elapsed > 0:
        for name, (read, write) in second.items():
            previous = first.get(name, (read, write))
            rates[name] = (
                max(0, (read - previous[0]) * 512 / elapsed),
                max(0, (write - previous[1]) * 512 / elapsed),
            )
    result = []
    seen = set()
    for line in host_df().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 7:
            continue
        kind = parts[1]
        if kind in SKIP_FS:
            continue
        mount = parts[6] if len(parts) == 7 else " ".join(parts[6:])
        if mount in seen:
            continue
        seen.add(mount)
        device = parts[0].rsplit("/", 1)[-1]
        read, write = rates.get(device, (0, 0))
        try:
            total = int(parts[2])
            used = int(parts[3])
        except ValueError:
            continue
        result.append({
            "name": device or mount,
            "fileSystem": kind,
            "mount": mount,
            "total": total,
            "used": used,
            "read": read,
            "write": write,
        })
    if result:
        return result
    path = "/host" if os.path.isdir("/host") else "/"
    try:
        stats = os.statvfs(path)
    except OSError:
        return []
    total = stats.f_blocks * stats.f_frsize
    free = stats.f_bavail * stats.f_frsize
    return [{
        "name": "root",
        "fileSystem": "",
        "mount": "/",
        "total": total,
        "used": max(0, total - free),
        "read": 0,
        "write": 0,
    }]

def network_rows(first, second, elapsed):
    interfaces = []
    receive = transmit = 0
    for name, (rx, tx) in second.items():
        previous = first.get(name, (rx, tx))
        rate_rx = rate_tx = 0
        if elapsed > 0:
            rate_rx = max(0, (rx - previous[0]) / elapsed)
            rate_tx = max(0, (tx - previous[1]) / elapsed)
        receive += rate_rx
        transmit += rate_tx
        interfaces.append({"name": name, "receive": rate_rx, "transmit": rate_tx})
    interfaces.sort(key=lambda item: item["name"])
    return {"receive": receive, "transmit": transmit, "interfaces": interfaces}

def process_rows(first, second, cpu_first, cpu_second, elapsed):
    total_first = cpu_first.get("cpu", (0, 0))[0]
    total_second = cpu_second.get("cpu", (0, 0))[0]
    core_count = max(1, sum(1 for name in cpu_second if name.startswith("cpu") and name != "cpu"))
    delta_total = total_second - total_first
    names = user_names()
    rows = []
    for pid, current in second.items():
        if pid not in first:
            continue
        previous = first[pid]
        cpu = 0
        if delta_total > 0:
            cpu = ((current[1] - previous[1]) * core_count) / delta_total
        if cpu < 0:
            cpu = 0
        read = write = 0
        if elapsed > 0:
            read = max(0, (current[4] - previous[4]) / elapsed)
            write = max(0, (current[5] - previous[5]) / elapsed)
        rows.append({
            "pid": pid,
            "user": names.get(current[3], str(current[3])),
            "name": current[0],
            "cpu": cpu,
            "memory": current[2],
            "read": read,
            "write": write,
        })
    rows.sort(key=lambda item: item["cpu"], reverse=True)
    return rows[:40]

def memory():
    info = {}
    try:
        for line in open("/proc/meminfo", encoding="utf-8"):
            key, rest = line.split(":", 1)
            info[key] = int(rest.split()[0]) * 1024
    except OSError:
        pass
    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", 0)
    used = total - available
    if used < 0:
        used = 0
    swap = info.get("SwapTotal", 0) - info.get("SwapFree", 0)
    if swap < 0:
        swap = 0
    return {
        "total": total,
        "used": used,
        "available": available,
        "swapTotal": info.get("SwapTotal", 0),
        "swapUsed": swap,
        "cached": info.get("Cached", 0) + info.get("Buffers", 0),
    }

def uptime_load():
    uptime = 0
    load = [0, 0, 0]
    try:
        uptime = float(open("/proc/uptime", encoding="utf-8").read().split()[0])
        load = [float(part) for part in open("/proc/loadavg", encoding="utf-8").read().split()[:3]]
    except (OSError, ValueError):
        pass
    return uptime, load

def unix_get(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect("/var/run/docker.sock")
        sock.sendall(("GET " + path + " HTTP/1.0\r\nHost: localhost\r\n\r\n").encode())
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError:
        return b""
    finally:
        sock.close()
    raw = b"".join(chunks)
    return raw.split(b"\r\n\r\n", 1)[-1]

IMAGE_FACTS = {}

def from_image(line):
    marker = "FROM "
    index = line.find(marker)
    if index < 0:
        return None
    prefix = line[:index].strip()
    if prefix and not prefix.endswith("#(nop)") and not prefix.endswith("nop)"):
        return None
    parts = line[index + len(marker):].strip().split()
    if not parts:
        return None
    image = parts[0].split("@", 1)[0]
    if not image or image.lower() == "scratch":
        return None
    return image

def image_facts(image, image_id):
    key = image_id or image or ""
    if key in IMAGE_FACTS:
        return IMAGE_FACTS[key]
    fact = {"local": False, "baseImage": None}
    if image:
        quoted = urllib.parse.quote(image, safe="/")
        info = unix_get("/images/" + quoted + "/json")
        try:
            data = json.loads(info) if info else {}
        except json.JSONDecodeError:
            data = {}
        fact["local"] = not (data.get("RepoDigests") or [])
        if fact["local"]:
            history = unix_get("/images/" + quoted + "/history")
            try:
                rows = json.loads(history) if history else []
            except json.JSONDecodeError:
                rows = []
            for row in rows:
                base = from_image(row.get("CreatedBy") or "")
                if base:
                    fact["baseImage"] = base
                    break
    IMAGE_FACTS[key] = fact
    return fact

def containers():
    body = unix_get("/containers/json?all=1")
    try:
        items = json.loads(body) if body else []
    except json.JSONDecodeError:
        return []
    result = []
    for item in items:
        names = item.get("Names") or ["/"]
        name = names[0][1:] if names[0].startswith("/") else names[0]
        image_id = item.get("ImageID") or ""
        if image_id.startswith("sha256:"):
            image_id = image_id[7:19]
        status = (item.get("Status") or "").lower()
        health = None
        if "unhealthy" in status:
            health = "unhealthy"
        elif "healthy" in status:
            health = "healthy"
        image = item.get("Image") or ""
        facts = image_facts(image, image_id)
        result.append({
            "id": item.get("Id") or "",
            "name": name,
            "image": image,
            "imageID": image_id,
            "state": (item.get("State") or "").lower(),
            "health": health,
            "labels": item.get("Labels") or {},
            "local": facts["local"],
            "baseImage": facts["baseImage"],
            "ports": published_ports(item),
        })
    return result


def snapshot():
    uptime, load = uptime_load()
    cpu1 = cpu_sample()
    proc1 = proc_sample()
    disk1 = disk_sample()
    nic1 = nic_sample()
    started = time.time()
    time.sleep(0.2)
    elapsed = max(time.time() - started, 0.05)
    return {
        "version": VERSION,
        "uptime": uptime,
        "load": load,
        "cores": core_rows(cpu1, cpu_sample()),
        "memory": memory(),
        "disks": disk_rows(disk1, disk_sample(), elapsed),
        "network": network_rows(nic1, nic_sample(), elapsed),
        "processes": process_rows(proc1, proc_sample(), cpu1, cpu_sample(), elapsed),
        "containers": containers(),
        "services": [],
    }

def safe_id(value):
    if not value or len(value) > 128:
        return False
    for char in value:
        if char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789":
            return False
    return True

def unix_call(method, path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect("/var/run/docker.sock")
        sock.sendall((method + " " + path + " HTTP/1.0\r\nHost: localhost\r\n\r\n").encode())
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError:
        return 502, b""
    finally:
        sock.close()
    raw = b"".join(chunks)
    head, _, body = raw.partition(b"\r\n\r\n")
    parts = head.split(b"\r\n", 1)[0].split()
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 502
    return status, body

def demux(raw):
    if len(raw) < 8:
        return raw
    out = bytearray()
    index = 0
    while index + 8 <= len(raw):
        size = int.from_bytes(raw[index + 4:index + 8], "big")
        if size < 0 or index + 8 + size > len(raw):
            return raw
        out += raw[index + 8:index + 8 + size]
        index += 8 + size
    return bytes(out) if index == len(raw) else raw

ACTIONS = {
    "start": ("POST", "/containers/{id}/start"),
    "stop": ("POST", "/containers/{id}/stop"),
    "pause": ("POST", "/containers/{id}/pause"),
    "unpause": ("POST", "/containers/{id}/unpause"),
    "restart": ("POST", "/containers/{id}/restart"),
    "remove": ("DELETE", "/containers/{id}?force=1"),
}

def docker_action(container_id, action):
    if not safe_id(container_id) or action not in ACTIONS:
        return 400, b""
    method, path = ACTIONS[action]
    return unix_call(method, path.replace("{id}", container_id))

def published_ports(item):
    rows = []
    seen = set()
    for port in item.get("Ports") or []:
        public = port.get("PublicPort") or 0
        private = port.get("PrivatePort") or 0
        if not public or not private:
            continue
        proto = port.get("Type") or "tcp"
        key = (public, private, proto)
        if key in seen:
            continue
        seen.add(key)
        rows.append({
            "ip": port.get("IP") or "0.0.0.0",
            "hostPort": public,
            "containerPort": private,
            "proto": proto,
        })
    return rows

def human(value):
    number = float(value or 0)
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if number < 1000 or unit == "TB":
            if unit == "B":
                return "%dB" % int(number)
            return "%.2f%s" % (number, unit)
        number /= 1000.0
    return "0B"

def cpu_percent(stats):
    cpu = stats.get("cpu_stats") or {}
    pre = stats.get("precpu_stats") or {}
    usage = (cpu.get("cpu_usage") or {}).get("total_usage") or 0
    previous = (pre.get("cpu_usage") or {}).get("total_usage") or 0
    system = cpu.get("system_cpu_usage") or 0
    previous_system = pre.get("system_cpu_usage") or 0
    online = cpu.get("online_cpus") or len((cpu.get("cpu_usage") or {}).get("percpu_usage") or []) or 1
    cpu_delta = usage - previous
    system_delta = system - previous_system
    if system_delta <= 0 or cpu_delta < 0:
        return "0.00%"
    return "%.2f%%" % ((cpu_delta / system_delta) * online * 100.0)

def memory_usage(stats):
    mem = stats.get("memory_stats") or {}
    usage = mem.get("usage") or 0
    details = mem.get("stats") or {}
    cache = details.get("inactive_file") or details.get("cache") or 0
    used = usage - cache if usage > cache else usage
    return human(used) + " / " + human(mem.get("limit") or 0)

def network_io(stats):
    received = 0
    sent = 0
    for nic in (stats.get("networks") or {}).values():
        received += nic.get("rx_bytes") or 0
        sent += nic.get("tx_bytes") or 0
    return human(received) + " / " + human(sent)

def block_io(stats):
    read = 0
    write = 0
    for row in ((stats.get("blkio_stats") or {}).get("io_service_bytes_recursive") or []):
        op = (row.get("op") or "").lower()
        if op == "read":
            read += row.get("value") or 0
        elif op == "write":
            write += row.get("value") or 0
    return human(read) + " / " + human(write)

def docker_runtime(container_id):
    if not safe_id(container_id):
        return 400, b""
    code, inspect = unix_call("GET", "/containers/" + container_id + "/json")
    if code != 200:
        return code, inspect
    _, stats_body = unix_call("GET", "/containers/" + container_id + "/stats?stream=0")
    try:
        stats = json.loads(stats_body) if stats_body else {}
    except json.JSONDecodeError:
        stats = {}
    summary = json.dumps({
        "CPUPerc": cpu_percent(stats),
        "MemUsage": memory_usage(stats),
        "NetIO": network_io(stats),
        "BlockIO": block_io(stats),
    }).encode()
    return 200, inspect + b"\\n__TERMINATOR_SPLIT__\\n" + summary

def docker_logs(container_id):
    if not safe_id(container_id):
        return 400, b""
    return unix_call("GET", "/containers/" + container_id + "/logs?stdout=1&stderr=1&timestamps=1&tail=200")

class Handler(BaseHTTPRequestHandler):
    def authorized(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def reject(self, code):
        self.send_response(code)
        self.end_headers()

    def send_bytes(self, code, payload, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def container_route(self):
        parts = self.path.split("?", 1)[0].strip("/").split("/")
        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "containers":
            return parts[2], parts[3]
        return None

    def do_GET(self):
        if not self.authorized():
            self.reject(401)
            return
        route = self.container_route()
        if route and route[1] == "logs":
            code, body = docker_logs(route[0])
            if code == 200:
                body = demux(body)
            self.send_bytes(code, body, "text/plain")
            return
        if route and route[1] == "stats":
            code, body = docker_runtime(route[0])
            self.send_bytes(code, body, "text/plain")
            return
        if self.path.split("?", 1)[0] != "/v1/snapshot":
            self.reject(404)
            return
        self.send_bytes(200, json.dumps(snapshot()).encode(), "application/json")

    def do_POST(self):
        if not self.authorized():
            self.reject(401)
            return
        route = self.container_route()
        if not route:
            self.reject(404)
            return
        code, body = docker_action(route[0], route[1])
        self.send_bytes(code, body, "text/plain")

    def log_message(self, fmt, *args):
        return

def main():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain("/helper/cert.pem", "/helper/key.pem")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("terminator-helper listening", flush=True)
    server.serve_forever()

if __name__ == "__main__":
    main()
"""#

    static func command(prefix: String, material: HelperMaterial.Bundle) -> String {
        let tool = dockerTool(prefix)
        return """
        set -e
        # TERMINATOR_HELPER_INSTALL
        export PATH="/usr/sbin:/usr/bin:/bin:/usr/local/bin:$PATH"
        dir="${HOME:-/tmp}/.terminator-helper"
        mkdir -p "$dir"
        chmod 700 "$dir"
        cat > "$dir/cert.pem" <<'TERMINATOR_CERT'
        \(material.certificatePEM.trimmingCharacters(in: .whitespacesAndNewlines))
        TERMINATOR_CERT
        cat > "$dir/key.pem" <<'TERMINATOR_KEY'
        \(material.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        TERMINATOR_KEY
        chmod 600 "$dir/key.pem"
        printf '%s' '\(material.token)' > "$dir/token"
        chmod 600 "$dir/token"
        cat > "$dir/server.py" <<'TERMINATOR_PY'
        \(server)
        TERMINATOR_PY
        \(relaunch(tool: tool))
        echo TERMINATOR_HELPER_STARTED
        """
    }
    static func updateCommand(prefix: String) -> String {
        let tool = dockerTool(prefix)
        return """
        set -e
        # TERMINATOR_HELPER_UPDATE
        export PATH="/usr/sbin:/usr/bin:/bin:/usr/local/bin:$PATH"
        dir="${HOME:-/tmp}/.terminator-helper"
        test -s "$dir/cert.pem"
        test -s "$dir/key.pem"
        test -s "$dir/token"
        cat > "$dir/server.py" <<'TERMINATOR_PY'
        \(server)
        TERMINATOR_PY
        \(relaunch(tool: tool))
        echo TERMINATOR_HELPER_UPDATED
        """
    }

    private static func dockerTool(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DockerCommandPrefix.fallback : trimmed
    }

    private static func relaunch(tool: String) -> String {
        """
        \(tool) rm -f terminator-helper >/dev/null 2>&1 || true
        if ! \(tool) run -d --name terminator-helper --restart unless-stopped --pid host -p \(HelperSnapshot.port):\(HelperSnapshot.port) -v /var/run/docker.sock:/var/run/docker.sock -v /:/host:ro -v "$dir":/helper:ro python:3.12-alpine python /helper/server.py >> "$dir/install.log" 2>&1; then
          echo "Could not start the helper container."
          tail -n 40 "$dir/install.log" 2>/dev/null || true
          exit 1
        fi
        ok=0
        i=0
        while [ "$i" -lt 20 ]; do
          state=$(\(tool) inspect -f '{{.State.Status}}' terminator-helper 2>/dev/null || true)
          if [ "$state" = "running" ]; then ok=1; break; fi
          i=$((i + 1))
          sleep 1
        done
        if [ "$ok" != 1 ]; then
          echo "Helper container did not stay running."
          \(tool) logs --tail 80 terminator-helper 2>&1 || true
          exit 1
        fi
        """
    }

}

final class HelperPin: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificateDER: Data

    init(certificateDER: Data) { self.certificateDER = certificateDER }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pinned = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              (SecCertificateCopyData(leaf) as Data) == certificateDER else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [pinned] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum HelperPoll {
    struct Payload: Sendable {
        var snapshot: HostStatusSnapshot
        var containers: [DockerContainer]
        var version: String?
    }

    static func fetch(
        hostname: String,
        port: Int,
        token: String,
        certificateDER: Data,
        hostID: UUID,
        endpoint: DockerEndpoint
    ) async -> Payload? {
        let literal = hostname.contains(":") ? "[\(hostname)]" : hostname
        guard let url = URL(string: "https://\(literal):\(port)/v1/snapshot") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let pin = HelperPin(certificateDER: certificateDER)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let parsed = HelperSnapshot.parse(data, hostID: hostID, endpoint: endpoint) else { return nil }
        return Payload(
            snapshot: parsed.0,
            containers: parsed.1,
            version: HelperSnapshot.reportedVersion(data)
        )
    }


    static func control(
        hostname: String,
        port: Int,
        token: String,
        certificateDER: Data,
        containerID: String,
        action: DockerControlAction
    ) async throws -> String {
        let method: String
        let path: String
        switch action {
        case .logs:
            method = "GET"
            path = "/v1/containers/\(containerID)/logs"
        case .stats:
            throw HelperInstallError.unavailable
        default:
            method = "POST"
            path = "/v1/containers/\(containerID)/\(action.rawValue)"
        }
        let (status, data) = try await send(
            hostname: hostname,
            port: port,
            token: token,
            certificateDER: certificateDER,
            method: method,
            path: path
        )
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) || status == 304 else {
            throw HelperInstallError.remote(text.isEmpty ? "Docker returned \(status)" : text)
        }
        return text
    }

    static func runtime(
        hostname: String,
        port: Int,
        token: String,
        certificateDER: Data,
        containerID: String
    ) async throws -> String {
        let (status, data) = try await send(
            hostname: hostname,
            port: port,
            token: token,
            certificateDER: certificateDER,
            method: "GET",
            path: "/v1/containers/\(containerID)/stats"
        )
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw HelperInstallError.remote(text.isEmpty ? "Docker returned \(status)" : text)
        }
        return text
    }

    private static func send(
        hostname: String,
        port: Int,
        token: String,
        certificateDER: Data,
        method: String,
        path: String
    ) async throws -> (Int, Data) {
        let literal = hostname.contains(":") ? "[\(hostname)]" : hostname
        guard let url = URL(string: "https://\(literal):\(port)\(path)") else {
            throw HelperInstallError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let pin = HelperPin(certificateDER: certificateDER)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HelperInstallError.unavailable }
        return (http.statusCode, data)
    }
}
