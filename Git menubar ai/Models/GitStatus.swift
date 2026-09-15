import Foundation

/// How a single path differs from `HEAD`.
nonisolated enum FileChangeKind: String, Sendable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .untracked: return "New"
        case .conflicted: return "Conflict"
        }
    }

    var symbolName: String {
        switch self {
        case .added, .untracked: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed, .copied: return "arrow.forward.circle.fill"
        case .typeChanged: return "arrow.2.squarepath"
        case .conflicted: return "exclamationmark.triangle.fill"
        }
    }
}

/// One entry from `git status --porcelain=v2`.
nonisolated struct GitFileChange: Identifiable, Hashable, Sendable {
    /// Repository-relative path.
    var path: String
    /// Previous path, for renames and copies.
    var originalPath: String?
    var kind: FileChangeKind
    var isStaged: Bool
    var isUnstaged: Bool

    var id: String { path }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// Parent directory, or an empty string when the file sits at the repository root.
    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent
    }
}

/// A file's insertion/deletion counts from `git diff --numstat`.
nonisolated struct FileDiffStat: Sendable, Hashable {
    var path: String
    var insertions: Int
    var deletions: Int
}

/// Why `Commit & Push` cannot run right now.
nonisolated enum PushBlocker: Equatable, Sendable {
    case conflicts(count: Int)
    case operationInProgress(String)
    case detachedHead
    case noUpstream(branch: String, canPublish: Bool)

    var message: String {
        switch self {
        case .conflicts(let count):
            let files = count == 1 ? "file" : "files"
            return "\(count) conflicted \(files). Resolve the conflicts before committing."
        case .operationInProgress(let name):
            return "\(name) is in progress. Finish or abort it before pushing."
        case .detachedHead:
            return "HEAD is detached. Check out a branch before pushing."
        case .noUpstream(let branch, let canPublish):
            return canPublish
                ? "“\(branch)” has no upstream yet. Publish the branch to push it."
                : "“\(branch)” has no upstream and this repository has no remote."
        }
    }

    var symbolName: String {
        switch self {
        case .conflicts, .operationInProgress: return "exclamationmark.triangle.fill"
        case .detachedHead: return "arrow.triangle.branch"
        case .noUpstream: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

/// Why committing cannot run right now.
nonisolated enum CommitBlocker: Equatable, Sendable {
    case conflicts(count: Int)
    case nothingToCommit

    var message: String {
        switch self {
        case .conflicts(let count):
            let files = count == 1 ? "file" : "files"
            return "\(count) conflicted \(files). Resolve the conflicts before committing."
        case .nothingToCommit:
            return "No changes to commit."
        }
    }
}

/// A snapshot of `git status` for one repository.
nonisolated struct GitStatus: Sendable, Equatable {
    /// Current branch name, or `nil` when HEAD is detached.
    var branch: String?
    var isDetached: Bool
    /// Upstream ref such as `origin/main`, when one is configured.
    var upstream: String?
    var ahead: Int
    var behind: Int
    var changes: [GitFileChange]
    var remotes: [String]
    /// `true` once the repository has at least one commit.
    var hasCommits: Bool
    /// A human readable name for an in-flight merge, rebase or cherry-pick.
    var operationInProgress: String?

    var conflicts: [GitFileChange] {
        changes.filter { $0.kind == .conflicted }
    }

    var isClean: Bool { changes.isEmpty }

    var changedFileCount: Int { changes.count }

    var branchDisplayName: String {
        if isDetached { return "detached HEAD" }
        return branch ?? "no branch"
    }

    var hasOrigin: Bool { remotes.contains("origin") }

    var commitBlocker: CommitBlocker? {
        if !conflicts.isEmpty { return .conflicts(count: conflicts.count) }
        if changes.isEmpty { return .nothingToCommit }
        return nil
    }

    /// Checked before pushing, and also used to explain a disabled button.
    var pushBlocker: PushBlocker? {
        if !conflicts.isEmpty { return .conflicts(count: conflicts.count) }
        if let operationInProgress { return .operationInProgress(operationInProgress) }
        if isDetached { return .detachedHead }
        guard let branch, !branch.isEmpty else { return .detachedHead }
        if upstream == nil {
            return .noUpstream(branch: branch, canPublish: !remotes.isEmpty)
        }
        return nil
    }

    /// Short summary of the divergence from the upstream, e.g. `↑2 ↓1`.
    var divergenceSummary: String? {
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static let empty = GitStatus(
        branch: nil,
        isDetached: false,
        upstream: nil,
        ahead: 0,
        behind: 0,
        changes: [],
        remotes: [],
        hasCommits: false,
        operationInProgress: nil
    )
}

/// Everything the message generator needs to describe a change set.
nonisolated struct DiffContext: Sendable {
    var branch: String?
    var changes: [GitFileChange]
    var stats: [FileDiffStat]
    /// A truncated unified diff, used only as extra signal for the on-device model.
    var patchExcerpt: String

    var totalInsertions: Int { stats.reduce(0) { $0 + $1.insertions } }
    var totalDeletions: Int { stats.reduce(0) { $0 + $1.deletions } }
}
