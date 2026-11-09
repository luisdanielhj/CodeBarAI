import AppKit
import Foundation

/// Observable per-repository state: the last status snapshot plus the in-progress
/// commit the user is composing.
@Observable
final class RepositoryState: Identifiable {
    private(set) var repository: Repository

    /// Last successful `git status` snapshot, or `nil` before the first refresh.
    var status: GitStatus?
    /// Set when reading status failed, e.g. the folder was moved or deleted.
    var loadFailure: GitFailure?
    var isRefreshing = false
    /// Set when a change arrives while a refresh is already reading status, so
    /// that refresh runs once more instead of a second one starting alongside it.
    @ObservationIgnored var needsAnotherRefresh = false
    /// Small project artwork discovered from an `.ico` file in the repository,
    /// decoded once so list rows do not decode it on every render.
    var projectIcon: NSImage?
    var didSearchForProjectIcon = false
    /// How to start this repository's Node server, or `nil` when it has none.
    var devServer: DevServer?

    // MARK: Commit composer

    var commitMessage = ""
    var isGeneratingMessage = false
    /// Note about how the last message was produced, or why the model was skipped.
    var generationNote: String?

    // MARK: Operations

    /// Non-nil while a git write operation runs, e.g. "Pushing…".
    var activity: String?
    var operationFailure: GitFailure?
    /// Confirmation of the last completed operation.
    var lastSuccess: String?

    var id: UUID { repository.id }

    init(repository: Repository) {
        self.repository = repository
    }

    /// Older filesystem timestamps must not undo a more recent explicit open.
    @discardableResult
    func recordActivity(at date: Date = Date()) -> Bool {
        guard date > (repository.lastWorkedAt ?? .distantPast) else { return false }
        repository.lastWorkedAt = date
        return true
    }

    var isBusy: Bool { activity != nil }

    var trimmedCommitMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCommit: Bool {
        guard let status, !isBusy else { return false }
        return status.commitBlocker == nil && !trimmedCommitMessage.isEmpty
    }

    var canPush: Bool {
        guard let status, !isBusy else { return false }
        return status.pushBlocker == nil && canCommit
    }

    /// Clears the transient banners so a new action starts from a clean slate.
    func clearOutcome() {
        operationFailure = nil
        lastSuccess = nil
    }
}
