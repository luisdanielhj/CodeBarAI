import Foundation

/// How to start a Node project's development server from its repository root.
nonisolated struct DevServer: Equatable, Sendable {
    enum PackageManager: String, Sendable {
        case npm, pnpm, yarn, bun
    }

    let packageManager: PackageManager
    /// A script from `package.json`, always one of `scriptPreference`.
    let script: String
    /// Whether `node_modules` is missing, so dependencies must be installed first.
    let needsInstall: Bool

    /// Scripts that conventionally start a server, most specific first.
    private static let scriptPreference = ["dev", "start", "serve"]
    private static let maximumManifestBytes = 1_048_576

    /// Short form for menus, e.g. `pnpm run dev`.
    var title: String {
        "\(packageManager.rawValue) run \(script)"
    }

    /// The shell command typed into Terminal. Every part is a fixed word, so
    /// nothing from the repository needs quoting.
    var shellCommand: String {
        needsInstall
            ? "\(packageManager.rawValue) install && \(title)"
            : title
    }

    /// Returns `nil` unless the repository root has a `package.json` with a
    /// server script.
    static func detect(in repositoryURL: URL) async -> DevServer? {
        await Task.detached(priority: .utility) {
            detectBlocking(in: repositoryURL)
        }.value
    }

    private static func detectBlocking(in root: URL) -> DevServer? {
        let files = FileManager.default
        let manifestURL = root.appending(path: "package.json")
        guard let attributes = try? files.attributesOfItem(atPath: manifestURL.path),
              let size = attributes[.size] as? Int, size <= maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = manifest["scripts"] as? [String: Any],
              let script = scriptPreference.first(where: { scripts[$0] is String })
        else { return nil }

        return DevServer(
            packageManager: packageManager(manifest: manifest, root: root),
            script: script,
            needsInstall: !files.fileExists(atPath: root.appending(path: "node_modules").path)
        )
    }

    /// The `packageManager` field wins (Corepack enforces it), then lockfiles,
    /// then npm.
    private static func packageManager(manifest: [String: Any], root: URL) -> PackageManager {
        if let declared = manifest["packageManager"] as? String,
           let name = declared.split(separator: "@").first,
           let manager = PackageManager(rawValue: String(name)) {
            return manager
        }

        let lockfiles: [(String, PackageManager)] = [
            ("pnpm-lock.yaml", .pnpm),
            ("yarn.lock", .yarn),
            ("bun.lock", .bun),
            ("bun.lockb", .bun),
            ("package-lock.json", .npm)
        ]
        let files = FileManager.default
        return lockfiles.first { files.fileExists(atPath: root.appending(path: $0.0).path) }?.1 ?? .npm
    }
}
