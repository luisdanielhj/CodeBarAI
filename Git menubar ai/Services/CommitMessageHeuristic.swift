import Foundation

/// Builds a Conventional Commit line from filenames and the diff summary alone.
///
/// Used when the on-device model is unavailable. No network, no third-party service.
nonisolated enum CommitMessageHeuristic {
    static func message(for context: DiffContext) -> String {
        let changes = context.changes
        guard !changes.isEmpty else { return "chore: update project" }

        let type = commitType(for: changes, branch: context.branch)
        let summary = summarize(changes, stats: context.stats)

        var prefix = type
        if let scope = scope(for: changes) {
            prefix += "(\(scope))"
        }
        return truncate("\(prefix): \(summary)", to: 72)
    }

    // MARK: - Type

    private static func commitType(for changes: [GitFileChange], branch: String?) -> String {
        let paths = changes.map { $0.path.lowercased() }

        if paths.allSatisfy(isDocumentation) { return "docs" }
        if paths.allSatisfy(isTest) { return "test" }
        if paths.allSatisfy(isContinuousIntegration) { return "ci" }
        if paths.allSatisfy(isBuildConfiguration) { return "build" }

        // The branch name is often the clearest signal of intent available locally.
        if let branch = branch?.lowercased() {
            if branch.hasPrefix("fix/") || branch.hasPrefix("bugfix/") || branch.hasPrefix("hotfix/") {
                return "fix"
            }
            if branch.hasPrefix("feat/") || branch.hasPrefix("feature/") {
                return "feat"
            }
        }

        if changes.allSatisfy({ $0.kind == .added || $0.kind == .untracked }) { return "feat" }
        if changes.allSatisfy({ $0.kind == .deleted }) { return "chore" }
        if changes.allSatisfy({ $0.kind == .renamed || $0.kind == .copied }) { return "refactor" }
        return "chore"
    }

    private static func isDocumentation(_ path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        if ["md", "markdown", "rst", "adoc"].contains(fileExtension) { return true }
        return path.hasPrefix("docs/") || path.hasPrefix("documentation/")
    }

    private static func isTest(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { $0 == "tests" || $0 == "test" || $0 == "__tests__" || $0 == "spec" }) {
            return true
        }
        let name = (path as NSString).lastPathComponent
        return name.contains("test") || name.contains("spec")
    }

    private static func isContinuousIntegration(_ path: String) -> Bool {
        if path.hasPrefix(".github/") || path.hasPrefix(".gitlab") || path.hasPrefix(".circleci/") {
            return true
        }
        let name = (path as NSString).lastPathComponent
        return ["jenkinsfile", ".travis.yml", "azure-pipelines.yml"].contains(name)
    }

    private static func isBuildConfiguration(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let buildFiles: Set<String> = [
            "package.swift", "package.json", "podfile", "cartfile", "makefile",
            "dockerfile", "project.pbxproj", "build.gradle", "cargo.toml"
        ]
        if buildFiles.contains(name) { return true }
        return ["xcconfig", "entitlements", "lock", "gradle"].contains((path as NSString).pathExtension)
    }

    // MARK: - Scope

    /// The deepest directory shared by every changed file, skipping container
    /// folder names that carry no meaning.
    private static func scope(for changes: [GitFileChange]) -> String? {
        let directories = changes.map { $0.directory }
        guard var common = directories.first?.split(separator: "/").map(String.init) else { return nil }

        for directory in directories.dropFirst() {
            let components = directory.split(separator: "/").map(String.init)
            var shared: [String] = []
            for (lhs, rhs) in zip(common, components) {
                guard lhs == rhs else { break }
                shared.append(lhs)
            }
            common = shared
            if common.isEmpty { return nil }
        }

        let generic: Set<String> = [
            "src", "sources", "source", "lib", "libs", "app", "apps",
            "packages", "modules", "code"
        ]
        guard let component = common.reversed().first(where: { !generic.contains($0.lowercased()) }) else {
            return nil
        }
        return sanitize(scope: component)
    }

    static func sanitize(scope: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let lowercased = scope.lowercased().replacingOccurrences(of: " ", with: "-")
        let filtered = String(lowercased.unicodeScalars.filter { allowed.contains($0) })
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        guard !trimmed.isEmpty, trimmed.count <= 20 else { return nil }
        // Placeholders the model sometimes emits when no scope fits.
        guard !["none", "n-a", "na", "unknown", "root", "misc", "general"].contains(trimmed) else {
            return nil
        }
        return trimmed
    }

    // MARK: - Summary

    private static func summarize(_ changes: [GitFileChange], stats: [FileDiffStat]) -> String {
        if changes.count == 1, let change = changes.first {
            switch change.kind {
            case .added, .untracked:
                return "add \(change.fileName)"
            case .deleted:
                return "remove \(change.fileName)"
            case .renamed:
                let original = (change.originalPath as NSString?)?.lastPathComponent
                return original.map { "rename \($0) to \(change.fileName)" } ?? "rename \(change.fileName)"
            case .copied:
                return "copy \(change.fileName)"
            case .modified, .typeChanged, .conflicted:
                return "update \(change.fileName)"
            }
        }

        if changes.allSatisfy({ $0.kind == .added || $0.kind == .untracked }) {
            return "add \(changes.count) files"
        }
        if changes.allSatisfy({ $0.kind == .deleted }) {
            return "remove \(changes.count) files"
        }

        // Lead with the file that moved the most lines; it is usually the point of the change.
        let busiest = stats.max { ($0.insertions + $0.deletions) < ($1.insertions + $1.deletions) }
        if let busiest, busiest.insertions + busiest.deletions > 0 {
            let name = (busiest.path as NSString).lastPathComponent
            let others = changes.count - 1
            return others > 0 ? "update \(name) and \(others) more" : "update \(name)"
        }

        return "update \(changes.count) files"
    }

    // MARK: - Formatting

    /// Trims to a length limit on a word boundary.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > limit / 2 {
            return String(clipped[..<lastSpace])
        }
        return clipped
    }
}
