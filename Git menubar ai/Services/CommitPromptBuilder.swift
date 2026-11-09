import Foundation

/// Turns a change set into the text the model reads, within a size budget.
///
/// Every changed file is listed. The diffs then share the budget fairly:
/// small files are included whole and whatever they don't use goes to the
/// large ones, so one big file can no longer crowd out every other change.
/// Lockfiles, generated files and binaries are listed without content, and
/// files that look like secrets never have their content sent.
nonisolated enum CommitPromptBuilder {
    struct Prompt: Sendable {
        var text: String
        /// Files whose diff had to be shortened to fit.
        var shortenedFiles: Int
    }

    static func prompt(for context: DiffContext, characterBudget: Int, maxListedFiles: Int) -> Prompt {
        var lines: [String] = []
        if let branch = context.branch, !branch.isEmpty {
            lines.append("Branch: \(branch)")
        }

        let stats = Dictionary(context.stats.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let totalInsertions = context.stats.reduce(0) { $0 + $1.insertions }
        let totalDeletions = context.stats.reduce(0) { $0 + $1.deletions }
        lines.append("Changed files (\(context.changes.count), +\(totalInsertions)/-\(totalDeletions) lines):")

        let listed = context.changes.prefix(maxListedFiles)
        for change in listed {
            lines.append("- " + describe(change, stat: stats[change.path]))
        }
        if context.changes.count > listed.count {
            lines.append("- and \(context.changes.count - listed.count) more files")
        }

        // Each file's diff, or the reason it has none.
        var sections: [(header: String, body: String)] = []
        for change in listed {
            let header = "=== " + describe(change, stat: stats[change.path]) + " ==="
            if let reason = withheldReason(for: change) {
                sections.append((header, "(\(reason))"))
            } else if let patch = context.patches[change.path], !patch.isEmpty {
                sections.append((header, redactSecrets(in: patch)))
            }
        }

        let list = lines.joined(separator: "\n")
        guard !sections.isEmpty else { return Prompt(text: list, shortenedFiles: 0) }

        let fixed = list.count + 20 + sections.reduce(0) { $0 + $1.header.count + 2 }
        let shares = fairShares(sections.map(\.body.count), budget: max(0, characterBudget - fixed))

        var shortened = 0
        var output = [list, "", "Diffs:"]
        for (section, share) in zip(sections, shares) {
            output.append(section.header)
            if share >= section.body.count {
                output.append(section.body)
            } else {
                shortened += 1
                output.append(shorten(section.body, to: share))
            }
        }
        return Prompt(text: output.joined(separator: "\n"), shortenedFiles: shortened)
    }

    // MARK: - Budget

    /// Water-filling: visit sizes from smallest up, giving each an equal split
    /// of what is left. Small entries get everything they need and the rest
    /// flows to the large ones.
    static func fairShares(_ sizes: [Int], budget: Int) -> [Int] {
        var shares = Array(repeating: 0, count: sizes.count)
        var remaining = budget
        let order = sizes.indices.sorted { sizes[$0] < sizes[$1] }
        for (position, index) in order.enumerated() {
            let equalSplit = remaining / (order.count - position)
            let share = min(sizes[index], equalSplit)
            shares[index] = share
            remaining -= share
        }
        return shares
    }

    /// Keeps the start of a diff, cut on a line boundary, and says how much is missing.
    private static func shorten(_ body: String, to limit: Int) -> String {
        let totalLines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        guard limit > 80 else { return "[\(totalLines) changed lines not shown]" }
        var kept = String(body.prefix(limit - 40))
        if let lastNewline = kept.lastIndex(of: "\n") {
            kept = String(kept[..<lastNewline])
        }
        let keptLines = kept.split(separator: "\n", omittingEmptySubsequences: false).count
        return kept + "\n[\(totalLines - keptLines) more lines not shown]"
    }

    // MARK: - Files

    private static func describe(_ change: GitFileChange, stat: FileDiffStat?) -> String {
        var text = "\(kindWord(change.kind)) \(change.path)"
        if change.kind == .renamed || change.kind == .copied, let original = change.originalPath {
            text += " (from \(original))"
        }
        if let stat, stat.insertions + stat.deletions > 0 {
            text += " (+\(stat.insertions)/-\(stat.deletions))"
        }
        return text
    }

    private static func kindWord(_ kind: FileChangeKind) -> String {
        switch kind {
        case .added, .untracked: return "new"
        case .modified, .typeChanged: return "modified"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .conflicted: return "conflicted"
        }
    }

    /// Why a file's content is left out, or `nil` to include it.
    static func withheldReason(for change: GitFileChange) -> String? {
        if SensitiveFileScanner.reason(forPath: change.path) != nil {
            return "content not sent: looks like a secrets file"
        }
        if change.kind == .deleted { return "file deleted" }

        let name = change.fileName.lowercased()
        let fileExtension = (name as NSString).pathExtension
        let lockfiles: Set<String> = [
            "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
            "bun.lock", "podfile.lock", "package.resolved", "cargo.lock", "gemfile.lock",
            "poetry.lock", "pipfile.lock", "composer.lock", "go.sum", "flake.lock", "uv.lock"
        ]
        if lockfiles.contains(name) || fileExtension == "lock" { return "lockfile, content skipped" }
        if fileExtension == "pbxproj" { return "Xcode project file, content skipped" }
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || fileExtension == "map" {
            return "generated file, content skipped"
        }
        let binary: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "heic", "pdf", "svg",
            "zip", "gz", "tar", "dmg", "woff", "woff2", "ttf", "otf", "mp3", "mp4", "mov", "wav",
            "xcuserstate", "sqlite", "db", "car"
        ]
        if binary.contains(fileExtension) { return "binary or image file, content skipped" }
        if name == ".ds_store" { return "Finder metadata, content skipped" }
        return nil
    }

    // MARK: - Secrets

    private static let secretPatterns: [NSRegularExpression] = [
        // Private key blocks.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        // Provider key formats: OpenAI, Anthropic, GitHub, Slack, AWS, Google.
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        // A quoted literal assigned to something named like a secret.
        #"(?i)((?:api[_-]?key|secret|token|password|passwd)["']?\s*[:=]\s*)["'][^"'\s]{12,}["']"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Replaces values that look like credentials with `[redacted]`, keeping
    /// the name they were assigned to so the model still sees what changed.
    static func redactSecrets(in text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            let range = NSRange(result.startIndex..., in: result)
            let template = pattern.numberOfCaptureGroups > 0 && pattern.pattern.hasPrefix("(?i)")
                ? "$1\"[redacted]\""
                : "[redacted]"
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
