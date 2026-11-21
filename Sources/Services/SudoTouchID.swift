import Foundation

/// Whether `sudo` on this Mac is set up to take Touch ID.
///
/// That's a `pam_tid.so` line in `sudo`'s PAM stack, which macOS ships commented out in
/// `/etc/pam.d/sudo_local` (included by `/etc/pam.d/sudo`). It matters because of how Homebrew calls
/// `sudo`: with `SUDO_ASKPASS` set it adds `-A`, and `sudo -A` goes straight to the askpass helper,
/// so Touch ID never comes up even for someone who turned it on.
enum SudoTouchID {
    static let configurationFiles = [
        URL(fileURLWithPath: "/etc/pam.d/sudo_local"),
        URL(fileURLWithPath: "/etc/pam.d/sudo"),
    ]

    /// A file that's missing or can't be read counts as no Touch ID: the password dialog stays.
    static func isEnabled(configurationFiles files: [URL] = configurationFiles) -> Bool {
        files.contains { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.split(whereSeparator: \.isNewline).contains { usesTouchID(String($0)) }
        }
    }

    /// `auth <control> pam_tid.so …` — any control (`sufficient` is what Apple ships), the module by
    /// name or by path, not commented out.
    static func usesTouchID(_ line: String) -> Bool {
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let fields = content.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, fields[0] == "auth" else { return false }
        let module = fields[2].split(separator: "/").last ?? ""
        return module == "pam_tid.so" || module.hasPrefix("pam_tid.so.")
    }
}
