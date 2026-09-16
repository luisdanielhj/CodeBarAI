import Foundation

/// Finds a useful `.ico` file without blocking the menu-bar UI. Generated and
/// dependency directories are skipped so large repositories remain cheap to scan.
nonisolated enum ProjectIconLoader {
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".next", "build", "DerivedData", "dist",
        "node_modules", "Pods", "vendor"
    ]
    private static let maximumDepth = 6
    private static let maximumEntries = 20_000
    private static let maximumIconBytes = 5 * 1_024 * 1_024

    static func loadIconData(in repositoryURL: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            findAndLoadIcon(in: repositoryURL)
        }.value
    }

    private static func findAndLoadIcon(in repositoryURL: URL) -> Data? {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var icons: [URL] = []
        var visitedEntries = 0

        while let url = enumerator.nextObject() as? URL {
            visitedEntries += 1
            guard visitedEntries <= maximumEntries else { break }

            let relativeDepth = max(0, url.pathComponents.count - repositoryURL.pathComponents.count)
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) || relativeDepth >= maximumDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true,
                  url.pathExtension.caseInsensitiveCompare("ico") == .orderedSame,
                  (values?.fileSize ?? 0) <= maximumIconBytes
            else { continue }
            icons.append(url)
        }

        guard let iconURL = icons.min(by: { iconRank($0, root: repositoryURL) < iconRank($1, root: repositoryURL) })
        else { return nil }
        return try? Data(contentsOf: iconURL, options: .mappedIfSafe)
    }

    /// Prefer conventional favicon names, then the shallowest deterministic path.
    private static func iconRank(_ url: URL, root: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let preferredName = name == "favicon.ico" ? "0" : "1"
        let depth = max(0, url.pathComponents.count - root.pathComponents.count)
        return "\(preferredName)-\(String(format: "%03d", depth))-\(url.path.lowercased())"
    }
}
