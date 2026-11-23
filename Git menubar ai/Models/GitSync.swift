import Foundation

/// One commit from `git log`, for the incoming and outgoing lists.
nonisolated struct GitCommitSummary: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date

    var id: String { hash }
}

/// A local or remote-tracking branch from `git for-each-ref`.
nonisolated struct GitBranchRef: Identifiable, Hashable, Sendable {
    /// Short name, e.g. `main` or `origin/feature`.
    let name: String
    let isRemote: Bool
    /// The upstream of a local branch, e.g. `origin/main`.
    let upstream: String?
    let lastCommitDate: Date?

    var id: String { (isRemote ? "remote:" : "local:") + name }

    /// For a remote branch, the name a local branch tracking it gets.
    var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// One entry from `git stash list`.
nonisolated struct GitStashEntry: Identifiable, Hashable, Sendable {
    /// `stash@{0}` and so on. Indexes shift as entries are dropped, so
    /// always reload the list after changing it.
    let reference: String
    let message: String

    var id: String { reference }
}

/// How `git pull` combines remote commits with local ones.
nonisolated enum PullStrategy: String, CaseIterable, Identifiable, Sendable {
    /// Replays local commits on top of the remote. Keeps history linear,
    /// which suits one person committing from several machines.
    case rebase
    /// Joins the two histories with a merge commit.
    case merge
    /// Only moves the branch forward; refuses when both sides have commits.
    case fastForwardOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rebase: return "Rebase"
        case .merge: return "Merge"
        case .fastForwardOnly: return "Fast-forward"
        }
    }

    var explanation: String {
        switch self {
        case .rebase:
            return "Puts your local commits on top of the remote ones. History stays in one line."
        case .merge:
            return "Joins both histories with a merge commit."
        case .fastForwardOnly:
            return "Only pulls when this machine has no unpushed commits."
        }
    }

    /// `git pull` arguments. `--autostash` sets uncommitted work aside and
    /// puts it back afterwards, so a dirty worktree never blocks a pull.
    var pullArguments: [String] {
        switch self {
        case .rebase: return ["pull", "--rebase", "--autostash"]
        case .merge: return ["pull", "--no-rebase", "--no-edit", "--autostash"]
        case .fastForwardOnly: return ["pull", "--ff-only", "--autostash"]
        }
    }
}

/// How often to fetch every repository in the background.
nonisolated enum AutoFetchInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        }
    }

    var duration: Duration? {
        self == .off ? nil : .seconds(rawValue)
    }
}
