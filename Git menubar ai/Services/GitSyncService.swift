import Foundation

/// The multi-step flows that keep one repository in step across machines,
/// built from single `GitClient` commands.
nonisolated struct GitSyncService: Sendable {
    var git = GitClient.shared

    struct PullResult: Sendable, Equatable {
        /// Uncommitted work set aside by `--autostash` could not be put back
        /// cleanly, so git left it in the stash.
        var autostashKept: Bool
    }

    enum PushResult: Sendable, Equatable {
        case pushed
        /// The remote had moved on, so its commits were pulled in first.
        case pulledThenPushed(PullResult)
    }

    /// Whether `fastForward` may run without asking: the branch only needs to
    /// move forward and nothing is in the middle of a merge or rebase.
    static func canAutoFastForward(_ status: GitStatus) -> Bool {
        status.pullBlocker == nil && status.behind > 0 && status.ahead == 0
    }

    /// A push the remote turned down because it has commits HEAD lacks.
    static func isRejectedBecauseBehind(_ failure: GitFailure) -> Bool {
        let text = failure.message.lowercased()
        return text.contains("non-fast-forward") || text.contains("fetch first")
            || (text.contains("rejected") && text.contains("behind"))
    }

    func pull(at url: URL, strategy: PullStrategy) async throws -> PullResult {
        let output = try await git.pull(at: url, strategy: strategy)
        return PullResult(autostashKept: Self.reportsKeptAutostash(output))
    }

    /// Pushes. When another machine pushed first and `strategy` is given,
    /// pulls those commits in and pushes once more. A conflict while pulling
    /// throws and leaves the rebase or merge in progress for the user.
    func push(at url: URL, integratingWith strategy: PullStrategy?) async throws -> PushResult {
        do {
            try await git.push(at: url)
            return .pushed
        } catch let failure as GitFailure {
            guard let strategy, Self.isRejectedBecauseBehind(failure) else { throw failure }
            let pulled = try await pull(at: url, strategy: strategy)
            try await git.push(at: url)
            return .pulledThenPushed(pulled)
        }
    }

    /// Pull, then push whatever is left unpushed.
    func sync(at url: URL, strategy: PullStrategy) async throws -> (pull: PullResult, pushed: Bool) {
        let pulled = try await pull(at: url, strategy: strategy)
        let status = try await git.status(at: url)
        guard status.ahead > 0, status.pushBlocker == nil else { return (pulled, false) }
        try await git.push(at: url)
        return (pulled, true)
    }

    /// Git's wording when an autostash could not be reapplied.
    static func reportsKeptAutostash(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("safe in the stash") || text.contains("autostash resulted in conflicts")
    }
}
