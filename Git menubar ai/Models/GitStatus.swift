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

/// Why pulling cannot run right now.
nonisolated enum PullBlocker: Equatable, Sendable {
    case conflicts(count: Int)
    case operationInProgress(String)
    case detachedHead
    case noUpstream(branch: String)

    var message: String {
        switch self {
        case .conflicts(let count):
            let files = count == 1 ? "file" : "files"
            return "\(count) conflicted \(files). Resolve them before pulling."
        case .operationInProgress(let name):
            return "\(name) is in progress. Continue or abort it first."
        case .detachedHead:
            return "HEAD is detached. Check out a branch to pull."
        case .noUpstream(let branch):
            return "“\(branch)” has no upstream to pull from."
        }
    }
}

/// An interrupted multi-step git command, detected from its marker files.
nonisolated enum GitOperation: String, Sendable, Hashable {
    case rebase
    case merge
    case cherryPick
    case revert

    /// Used in sentences, e.g. "A rebase is in progress".
    var displayName: String {
        switch self {
        case .rebase: return "A rebase"
        case .merge: return "A merge"
        case .cherryPick: return "A cherry-pick"
        case .revert: return "A revert"
        }
    }

    var title: String {
        switch self {
        case .rebase: return "Rebase"
        case .merge: return "Merge"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        }
    }

    /// The git subcommand that owns `--continue` and `--abort`.
    var subcommand: String {
        switch self {
        case .rebase: return "rebase"
        case .merge: return "merge"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }

    /// Whether `--skip` drops the commit being applied.
    var canSkip: Bool { self == .rebase || self == .cherryPick }

    /// The `git checkout` side holding this machine's own work. A rebase
    /// replays local commits on top of the upstream, so "ours" there is the
    /// upstream and "theirs" is the local commit being replayed.
    func checkoutFlag(for side: ConflictSide) -> String {
        let mineIsOurs = self != .rebase
        switch side {
        case .mine: return mineIsOurs ? "--ours" : "--theirs"
        case .theirs: return mineIsOurs ? "--theirs" : "--ours"
        }
    }
}

/// Which version of a conflicted file to keep.
nonisolated enum ConflictSide: Sendable, Hashable {
    /// The version committed on this machine.
    case mine
    /// The version that came from the remote or the commit being applied.
    case theirs
}

/// Why committing cannot run right now.
nonisolated enum CommitBlocker: Equatable, Sendable {
    case conflicts(count: Int)
    case operationInProgress(String)
    case nothingToCommit

    var message: String {
        switch self {
        case .conflicts(let count):
            let files = count == 1 ? "file" : "files"
            return "\(count) conflicted \(files). Resolve the conflicts before committing."
        case .operationInProgress(let name):
            return "\(name) is in progress. Press Continue to finish it, or Abort."
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
    /// An interrupted merge, rebase, cherry-pick or revert.
    var operation: GitOperation?
    /// The commit HEAD points to, when there is one.
    var headOID: String?
    /// Entries in `git stash list`.
    var stashCount: Int

    /// A human readable name for an in-flight merge, rebase or cherry-pick.
    var operationInProgress: String? { operation?.displayName }

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
        if let operationInProgress { return .operationInProgress(operationInProgress) }
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

    /// Both sides have commits the other lacks, so pulling has to rebase or merge.
    var isDiverged: Bool { ahead > 0 && behind > 0 }

    /// Checked before pulling, and also used to explain a disabled Pull button.
    var pullBlocker: PullBlocker? {
        if !conflicts.isEmpty { return .conflicts(count: conflicts.count) }
        if let operationInProgress { return .operationInProgress(operationInProgress) }
        if isDetached { return .detachedHead }
        guard let branch, !branch.isEmpty else { return .detachedHead }
        if upstream == nil { return .noUpstream(branch: branch) }
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
        operation: nil,
        headOID: nil,
        stashCount: 0
    )
}

/// Everything the message generator needs to describe a change set.
nonisolated struct DiffContext: Sendable {
    var branch: String?
    var changes: [GitFileChange]
    var stats: [FileDiffStat]
    /// Each file's diff, or the start of a new file, keyed by repository-relative path.
    var patches: [String: String]

    var totalInsertions: Int { stats.reduce(0) { $0 + $1.insertions } }
    var totalDeletions: Int { stats.reduce(0) { $0 + $1.deletions } }
}
