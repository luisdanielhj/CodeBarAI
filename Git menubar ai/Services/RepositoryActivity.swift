import Foundation

/// Seed recency for existing projects, and catch commits/checkouts made while
/// CodeBarAI was closed. Reads metadata only, without walking project contents.
nonisolated enum RepositoryActivity {
    static func latestChange(in root: URL, changedPaths: [String] = []) async -> Date? {
        await Task.detached(priority: .utility) {
            var candidates = [root]
            // Git already knows which files changed, including edits made
            // while the app was closed. Their parents also cover deletions.
            for path in changedPaths {
                let file = root.appendingPathComponent(path)
                candidates.append(file)
                candidates.append(file.deletingLastPathComponent())
            }
            let git = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    candidates.append(git.appendingPathComponent("logs/HEAD"))
                } else if let size = try? git.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 4096,
                          let contents = try? String(contentsOf: git, encoding: .utf8),
                          contents.hasPrefix("gitdir:") {
                    // Worktrees and submodules point to their own Git metadata.
                    let path = String(contents.dropFirst("gitdir:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        let directory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: root)
                        candidates.append(directory.appendingPathComponent("logs/HEAD"))
                    }
                }
            }
            return candidates.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max()
        }.value
    }
}
