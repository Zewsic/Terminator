import Foundation

public enum AuthorizedKeyLine {
    private static let pattern = #"^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+( [!-~]+)?$"#

    public static func validate(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              !line.contains("'"),
              !line.contains("\n"),
              !line.contains("\r"),
              line.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return line
    }

    public static func installCommand(_ line: String) -> String? {
        guard let line = validate(line) else { return nil }
        return """
        umask 077
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 2
        touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" || exit 3
        key='\(line)'
        if grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then echo TERMINATOR_ALREADY; exit 0; fi
        printf '%s\\n' "$key" >> "$HOME/.ssh/authorized_keys" || exit 4
        echo TERMINATOR_INSTALLED
        """
    }
}
