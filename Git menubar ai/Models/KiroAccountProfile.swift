import CryptoKit
import Foundation

/// A Kiro CLI sign-in. Kiro CLI keeps its login in one SQLite database, so a
/// second account is a separate database that `kiro-cli` is pointed at with
/// `KIRO_TEST_DB_PATH`, usually through a small wrapper script:
///
///     export KIRO_TEST_DB_PATH="$HOME/.kiro-account-2/data.sqlite3"
///     exec kiro-cli "$@"
///
/// Only the database location is persisted. Kiro CLI continues to own every
/// account's tokens and sign-in lifecycle.
nonisolated struct KiroAccountProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    let database: URL

    var isDefault: Bool { id == "kiro" }

    /// The environment that makes `kiro-cli` use this account. Empty for the
    /// default account, so it keeps the CLI's own lookup.
    var environment: [String: String] {
        isDefault ? [:] : ["KIRO_TEST_DB_PATH": database.path]
    }

    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(
            id: "kiro",
            name: "Default",
            database: home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        )
    }

    init(directory: URL, name: String? = nil) {
        let directory = URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
        let database = directory.appendingPathComponent("data.sqlite3")
        id = "kiro:\(Self.digest(database.path))"
        self.name = name ?? Self.suggestedName(for: directory)
        self.database = database
    }

    private init(id: String, name: String, database: URL) {
        self.id = id
        self.name = name
        self.database = database
    }

    /// Extra accounts are `~/.kiro-*` folders holding their own sign-in
    /// database. `~/.kiro` itself is Kiro's shared settings folder, not an account.
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        let files = FileManager.default
        let candidates = (try? files.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return candidates.filter { url in
            url.lastPathComponent.hasPrefix(".kiro-")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && files.fileExists(atPath: url.appendingPathComponent("data.sqlite3").path)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { Self(directory: $0) }
    }

    private static func suggestedName(for directory: URL) -> String {
        let name = directory.lastPathComponent
        let suffix = name.hasPrefix(".kiro-") ? String(name.dropFirst(".kiro-".count)) : name
        return suffix.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
