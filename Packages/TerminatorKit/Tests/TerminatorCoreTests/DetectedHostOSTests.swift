import Foundation
import Testing
@testable import TerminatorCore

@Suite("Detected host OS")
struct DetectedHostOSTests {
    @Test("Parses Ubuntu os-release")
    func ubuntu() {
        let output = """
        UNAME_S=Linux
        UNAME_R=6.8.0-40-generic
        ID=ubuntu
        ID_LIKE=debian
        NAME="Ubuntu"
        VERSION_ID="24.04"
        VERSION="24.04.1 LTS (Noble Numbat)"
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        """
        let os = HostOSProbe.parse(output)
        #expect(os?.id == "ubuntu")
        #expect(os?.name == "Ubuntu")
        #expect(os?.version == "24.04")
        #expect(os?.tag == "Ubuntu 24.04")
    }

    @Test("Parses raw uname and os-release")
    func rawProbeOutput() {
        let output = """
        Linux
        6.8.0-40-generic
        x86_64
        NAME="Ubuntu"
        VERSION="24.04.1 LTS (Noble Numbat)"
        ID=ubuntu
        ID_LIKE=debian
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        VERSION_ID="24.04"
        """
        let os = HostOSProbe.parse(output)
        #expect(os?.tag == "Ubuntu 24.04")
    }

    @Test("Parses macOS sw_vers")
    func macOS() {
        let output = """
        UNAME_S=Darwin
        UNAME_R=24.5.0
        SW_VERS_PRODUCT=macOS
        SW_VERS_VERSION=15.5
        """
        let os = HostOSProbe.parse(output)
        #expect(os?.id == "macos")
        #expect(os?.tag == "macOS 15.5")

        let raw = """
        Darwin
        24.5.0
        ProductName:	macOS
        ProductVersion:	15.5
        BuildVersion:	24F74
        """
        #expect(HostOSProbe.parse(raw)?.tag == "macOS 15.5")
    }

    @Test("Maps Windows 11 build numbers")
    func windows() {
        let os = HostOSProbe.parse("Microsoft Windows [Version 10.0.22631.3880]")
        #expect(os?.id == "windows")
        #expect(os?.tag == "Windows 11")
    }

    @Test("Prefers Proxmox over Debian")
    func proxmox() {
        let output = """
        UNAME_S=Linux
        ID=debian
        VERSION_ID=12
        PVE=pve-manager/8.2.4
        """
        let os = HostOSProbe.parse(output)
        #expect(os?.id == "proxmox")
        #expect(os?.name == "Proxmox")
    }

    @Test("Replaces previous OS tag")
    func replacesTag() {
        let tagged = HostProfile(
            displayName: "Box",
            hostname: "box.example.com",
            authentication: .manual(username: "root", authenticationMethods: []),
            tags: ["lab", "Ubuntu 22.04"],
            detectedOS: DetectedHostOS(id: "ubuntu", name: "Ubuntu", version: "22.04")
        )
        let updated = tagged.applyingDetectedOS(DetectedHostOS(id: "debian", name: "Debian", version: "12"))
        #expect(updated.tags.contains("lab"))
        #expect(updated.tags.contains("Debian 12"))
        #expect(!updated.tags.contains("Ubuntu 22.04"))
        #expect(updated.detectedOS?.id == "debian")
    }
}
