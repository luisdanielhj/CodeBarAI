import CryptoKit
import Foundation

/// Only account labels and credential locations are persisted. Claude Code
/// continues to own every account's tokens and sign-in lifecycle.
nonisolated struct ClaudeAccountProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    let configDirectory: URL
    let usesDefaultConfigDirectory: Bool
    /// Nil means Claude Code's original, unscoped Keychain entry. Setting
    /// CLAUDE_CONFIG_DIR explicitly, even to ~/.claude, uses a scoped entry.
    let keychainDirectory: String?

    var isDefault: Bool { id == "claude" }

    init(directory: URL, name: String? = nil) {
        let directory = Self.normalized(directory)
        id = "claude:\(Self.digest(directory.path))"
        self.name = name ?? Self.suggestedName(for: directory)
        configDirectory = directory
        usesDefaultConfigDirectory = false
        keychainDirectory = directory.path
    }

    static func current(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let directory = custom.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? home.appendingPathComponent(".claude", isDirectory: true)
        let normalized = normalized(directory)
        let keychainDirectory: String?
        if let secureDirectory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            keychainDirectory = secureDirectory.isEmpty ? nil : secureDirectory.precomposedStringWithCanonicalMapping
        } else {
            keychainDirectory = custom == nil ? nil : normalized.path
        }
        return Self(
            id: "claude",
            name: "Default",
            configDirectory: normalized,
            usesDefaultConfigDirectory: custom == nil,
            keychainDirectory: keychainDirectory
        )
    }

    private init(id: String, name: String, configDirectory: URL, usesDefaultConfigDirectory: Bool, keychainDirectory: String?) {
        self.id = id
        self.name = name
        self.configDirectory = configDirectory
        self.usesDefaultConfigDirectory = usesDefaultConfigDirectory
        self.keychainDirectory = keychainDirectory
    }

    /// Matches Claude Code's macOS service naming: SHA-256 of the NFC config
    /// path, truncated to eight hex characters. Never fall back to another
    /// account's unscoped entry when a scoped entry is missing.
    var keychainService: String {
        "Claude Code-credentials" + (keychainDirectory.map { "-\(Self.digest($0).prefix(8))" } ?? "")
    }

    static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Self] {
        let files = FileManager.default
        let candidates = (try? files.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return candidates.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(".claude-"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            // Backups and unrelated similarly named folders are not accounts.
            return [".claude.json", ".credentials.json", "settings.json"].contains {
                files.fileExists(atPath: url.appendingPathComponent($0).path)
            }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { Self(directory: $0) }
    }

    static func normalized(_ directory: URL) -> URL {
        URL(fileURLWithPath: directory.standardizedFileURL.path.precomposedStringWithCanonicalMapping,
            isDirectory: true)
    }

    private static func suggestedName(for directory: URL) -> String {
        let name = directory.lastPathComponent
        let suffix = name.hasPrefix(".claude-") ? String(name.dropFirst(".claude-".count)) : name
        return suffix.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
