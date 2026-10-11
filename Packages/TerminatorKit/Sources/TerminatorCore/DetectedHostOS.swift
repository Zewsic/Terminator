import Foundation

public struct DetectedHostOS: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var tag: String

    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
        self.tag = version.isEmpty ? name : "\(name) \(version)"
    }
}

public struct HostOSDescriptor: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var aliases: Set<String>
    public var colorHex: String

    public init(id: String, name: String, aliases: Set<String> = [], colorHex: String) {
        self.id = id
        self.name = name
        self.aliases = aliases.union([id])
        self.colorHex = colorHex
    }
}

public enum HostOSCatalog: Sendable {
    public static let all: [HostOSDescriptor] = [
        .init(id: "ubuntu", name: "Ubuntu", aliases: ["ubuntu-core", "ubuntu-server"], colorHex: "E95420"),
        .init(id: "debian", name: "Debian", colorHex: "A81D33"),
        .init(id: "fedora", name: "Fedora", colorHex: "51A2DA"),
        .init(id: "centos", name: "CentOS", aliases: ["centos-stream"], colorHex: "262577"),
        .init(id: "rhel", name: "RHEL", aliases: ["redhat", "red-hat", "rhel"], colorHex: "EE0000"),
        .init(id: "rocky", name: "Rocky Linux", aliases: ["rocky-linux"], colorHex: "10B981"),
        .init(id: "alma", name: "AlmaLinux", aliases: ["almalinux"], colorHex: "0F4C81"),
        .init(id: "arch", name: "Arch Linux", aliases: ["archlinux", "archarm"], colorHex: "1793D1"),
        .init(id: "manjaro", name: "Manjaro", colorHex: "35BF5C"),
        .init(id: "opensuse", name: "openSUSE", aliases: ["opensuse-leap", "opensuse-tumbleweed", "suse", "sles"], colorHex: "73BA25"),
        .init(id: "alpine", name: "Alpine", aliases: ["alpinelinux"], colorHex: "0D597F"),
        .init(id: "amazon", name: "Amazon Linux", aliases: ["amzn", "amazonlinux"], colorHex: "FF9900"),
        .init(id: "oracle", name: "Oracle Linux", aliases: ["ol", "oraclelinux"], colorHex: "C74634"),
        .init(id: "mint", name: "Linux Mint", aliases: ["linuxmint"], colorHex: "87CF3E"),
        .init(id: "popos", name: "Pop!_OS", aliases: ["pop", "pop_os"], colorHex: "48B9C7"),
        .init(id: "elementary", name: "elementary OS", colorHex: "64BAFF"),
        .init(id: "kali", name: "Kali Linux", aliases: ["kali-rolling"], colorHex: "2777FF"),
        .init(id: "parrot", name: "Parrot", aliases: ["parrotsecurity"], colorHex: "00ADEF"),
        .init(id: "gentoo", name: "Gentoo", colorHex: "54487A"),
        .init(id: "void", name: "Void Linux", colorHex: "478061"),
        .init(id: "nixos", name: "NixOS", colorHex: "5277C3"),
        .init(id: "slackware", name: "Slackware", colorHex: "1C1C1C"),
        .init(id: "raspbian", name: "Raspberry Pi OS", aliases: ["raspberrypi", "raspios"], colorHex: "C51A4A"),
        .init(id: "mageia", name: "Mageia", colorHex: "2397D4"),
        .init(id: "zorin", name: "Zorin OS", colorHex: "0CC1F3"),
        .init(id: "deepin", name: "deepin", colorHex: "00B7FF"),
        .init(id: "endeavour", name: "EndeavourOS", aliases: ["endeavouros"], colorHex: "7F3FBF"),
        .init(id: "artix", name: "Artix Linux", colorHex: "10A0C0"),
        .init(id: "mx", name: "MX Linux", colorHex: "1A1A1A"),
        .init(id: "clearlinux", name: "Clear Linux", aliases: ["clear-linux-os"], colorHex: "00AEFF"),
        .init(id: "photon", name: "Photon OS", colorHex: "0080FF"),
        .init(id: "coreos", name: "CoreOS", aliases: ["fedora-coreos", "rhcos"], colorHex: "53A3DA"),
        .init(id: "chromeos", name: "ChromeOS", aliases: ["chromiumos"], colorHex: "1AA15F"),
        .init(id: "openwrt", name: "OpenWrt", colorHex: "00A3E0"),
        .init(id: "proxmox", name: "Proxmox", aliases: ["pve"], colorHex: "E57000"),
        .init(id: "truenas", name: "TrueNAS", aliases: ["freenas"], colorHex: "0095D5"),
        .init(id: "synology", name: "DSM", aliases: ["dsm"], colorHex: "0055A5"),
        .init(id: "qnap", name: "QNAP", colorHex: "0C447C"),
        .init(id: "unraid", name: "Unraid", colorHex: "F15A2C"),
        .init(id: "esxi", name: "ESXi", aliases: ["vmware", "esx"], colorHex: "607078"),
        .init(id: "macos", name: "macOS", aliases: ["darwin", "osx", "mac os x", "mac os"], colorHex: "1C1C1E"),
        .init(id: "ios", name: "iOS", aliases: ["ipados", "iphone os"], colorHex: "1C1C1E"),
        .init(id: "windows", name: "Windows", aliases: ["mingw", "cygwin", "msys", "windows_nt"], colorHex: "0078D4"),
        .init(id: "android", name: "Android", colorHex: "3DDC84"),
        .init(id: "freebsd", name: "FreeBSD", colorHex: "AB2B28"),
        .init(id: "openbsd", name: "OpenBSD", colorHex: "F2CA30"),
        .init(id: "netbsd", name: "NetBSD", colorHex: "FF6600"),
        .init(id: "dragonfly", name: "DragonFly BSD", aliases: ["dragonflybsd"], colorHex: "1A1A1A"),
        .init(id: "solaris", name: "Solaris", aliases: ["sunos", "illumos", "smartos", "omnios"], colorHex: "EE1C25"),
        .init(id: "aix", name: "AIX", colorHex: "1A1A1A"),
        .init(id: "haiku", name: "Haiku", colorHex: "3C8C3C"),
        .init(id: "linux", name: "Linux", aliases: ["gnu/linux"], colorHex: "FCC624"),
    ]

    public static func descriptor(for id: String?) -> HostOSDescriptor? {
        guard let id, !id.isEmpty else { return nil }
        let key = normalize(id)
        if let exact = all.first(where: { $0.aliases.contains(key) || $0.id == key }) {
            return exact
        }
        if let named = all.first(where: { normalize($0.name) == key }) {
            return named
        }
        return all
            .sorted { $0.name.count > $1.name.count }
            .first { key.contains(normalize($0.name)) }
    }

    public static func match(fields: [String: String]) -> DetectedHostOS? {
        if let os = matchSpecial(fields) { return os }
        let candidates = [
            fields["ID"],
            fields["NAME"],
            fields["PRETTY_NAME"],
        ].compactMap { $0 }
        for value in candidates {
            if let descriptor = descriptor(for: value) ?? descriptor(for: firstToken(value)) {
                return make(descriptor, version: version(from: fields, fallback: nil))
            }
        }
        for like in (fields["ID_LIKE"] ?? "").split(whereSeparator: \.isWhitespace) {
            if let descriptor = descriptor(for: String(like)) {
                return make(descriptor, version: version(from: fields, fallback: nil))
            }
        }
        if let uname = fields["UNAME_S"], let descriptor = descriptor(for: uname) {
            let fallback = uname.caseInsensitiveCompare("Linux") == .orderedSame
                ? shortKernel(fields["UNAME_R"])
                : nil
            return make(descriptor, version: version(from: fields, fallback: fallback))
        }
        return nil
    }

    private static func matchSpecial(_ fields: [String: String]) -> DetectedHostOS? {
        if let android = fields["ANDROID"], !android.isEmpty,
           let descriptor = descriptor(for: "android") {
            return make(descriptor, version: shortVersion(android))
        }
        if let product = fields["SW_VERS_PRODUCT"], !product.isEmpty {
            let id = product.localizedCaseInsensitiveContains("ios") || product.localizedCaseInsensitiveContains("ipad")
                ? "ios"
                : "macos"
            if let descriptor = descriptor(for: id) {
                return make(descriptor, version: shortVersion(fields["SW_VERS_VERSION"] ?? ""))
            }
        }
        if let win = fields["WINVER"] ?? windowsVersion(from: fields),
           let descriptor = descriptor(for: "windows") {
            return make(descriptor, version: windowsShortVersion(win))
        }
        if fields["PVE"] != nil, let descriptor = descriptor(for: "proxmox") {
            return make(descriptor, version: shortVersion(fields["PVE"] ?? fields["VERSION_ID"] ?? ""))
        }
        if fields["SYNO"] != nil, let descriptor = descriptor(for: "synology") {
            return make(descriptor, version: shortVersion(fields["productversion"] ?? fields["VERSION_ID"] ?? ""))
        }
        if let tn = fields["TN"], tn.localizedCaseInsensitiveContains("truenas"),
           let descriptor = descriptor(for: "truenas") {
            return make(descriptor, version: shortVersion(tn))
        }
        return nil
    }

    private static func make(_ descriptor: HostOSDescriptor, version: String) -> DetectedHostOS {
        DetectedHostOS(id: descriptor.id, name: descriptor.name, version: version)
    }

    public static func version(from fields: [String: String], fallback: String?) -> String {
        let raw = fields["VERSION_ID"] ?? fields["SW_VERS_VERSION"] ?? fields["VERSION"] ?? fallback ?? ""
        return shortVersion(raw)
    }

    public static func shortVersion(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        guard let match = cleaned.range(of: #"\d+(?:\.\d+){0,2}"#, options: .regularExpression) else {
            return ""
        }
        let number = String(cleaned[match])
        let parts = number.split(separator: ".")
        if parts.count >= 3 { return parts.prefix(2).joined(separator: ".") }
        return number
    }

    public static func shortKernel(_ raw: String?) -> String {
        guard let raw else { return "" }
        return shortVersion(raw)
    }

    public static func windowsShortVersion(_ raw: String) -> String {
        if let build = buildNumber(in: raw) {
            if build >= 22_000 { return "11" }
            if build >= 10_240 { return "10" }
            if build >= 9_600 { return "8.1" }
            if build >= 9_200 { return "8" }
            if build >= 7_600 { return "7" }
        }
        if raw.contains("11") { return "11" }
        if raw.contains("10") { return "10" }
        return shortVersion(raw)
    }

    private static func windowsVersion(from fields: [String: String]) -> String? {
        let blob = fields.values.joined(separator: "\n")
        if blob.localizedCaseInsensitiveContains("windows") { return blob }
        let uname = fields["UNAME_S"] ?? ""
        if uname.localizedCaseInsensitiveContains("mingw")
            || uname.localizedCaseInsensitiveContains("cygwin")
            || uname.localizedCaseInsensitiveContains("windows") {
            return uname
        }
        return nil
    }

    private static func buildNumber(in raw: String) -> Int? {
        let matches = raw.matches(of: /\d+\.\d+\.(\d+)/)
        if let match = matches.first, let value = Int(match.1) { return value }
        return nil
    }

    private static func firstToken(_ value: String) -> String {
        String(value.split(whereSeparator: { $0 == " " || $0 == "/" }).first ?? Substring(value))
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

public enum HostOSProbe: Sendable {
    public static let posixCommand =
        "uname -s; uname -r; uname -m; cat /etc/os-release; sw_vers; pveversion; getprop ro.build.version.release"

    public static let windowsCommand = #"cmd.exe /c ver"#

    public static func parse(_ output: String) -> DetectedHostOS? {
        var fields = keyValues(in: output)
        if fields["WINVER"] == nil, output.localizedCaseInsensitiveContains("windows") {
            fields["WINVER"] = output
        }
        return HostOSCatalog.match(fields: fields)
    }

    public static func keyValues(in output: String) -> [String: String] {
        var fields: [String: String] = [:]
        var unameCandidates: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                fields[key] = value
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "ProductName": fields["SW_VERS_PRODUCT"] = value
                case "ProductVersion": fields["SW_VERS_VERSION"] = value
                default: break
                }
                continue
            }
            unameCandidates.append(line)
        }
        if fields["UNAME_S"] == nil, let system = unameCandidates.first {
            fields["UNAME_S"] = system
        }
        if fields["UNAME_R"] == nil, unameCandidates.count > 1 {
            fields["UNAME_R"] = unameCandidates[1]
        }
        return fields
    }
}

public extension HostProfile {
    func applyingDetectedOS(_ os: DetectedHostOS) -> HostProfile {
        var copy = self
        if let previous = copy.detectedOS?.tag {
            copy.tags.removeAll { $0.caseInsensitiveCompare(previous) == .orderedSame }
        }
        copy.detectedOS = os
        if !copy.tags.contains(where: { $0.caseInsensitiveCompare(os.tag) == .orderedSame }) {
            copy.tags.append(os.tag)
        }
        return copy
    }
}
