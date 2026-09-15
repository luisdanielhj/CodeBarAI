import Foundation
import Observation

/// A commit the user asked for that is waiting on confirmation because it would
/// include files that look sensitive.
struct PendingCommit: Identifiable {
    let id = UUID()
    let repositoryID: UUID
    let message: String
    let push: Bool
    let files: [SensitiveFile]
}

/// Owns the repository list, refresh scheduling and the git actions.
@Observable
final class AppModel {
    private(set) var repositories: [RepositoryState] = []
    var selectedRepositoryID: UUID?

    /// Problem adding a repository, shown on the list screen.
    var addFailure: String?
    /// Set when the system git itself cannot run at all.
    var gitFailure: String?
    /// Sensitive-file confirmation waiting on the user.
    var pendingCommit: PendingCommit?

    private let git = GitClient.shared
    private let store = RepositoryStore()
    private let generator = CommitMessageGenerator()
    private var watcher: FileSystemWatcher?
    /// Debounce timers, one per repository.
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        repositories = store.load().map { RepositoryState(repository: $0) }
    }

    /// Begins watching the stored repositories. Idempotent, so the view can call
    /// it every time the menu bar window opens.
    func start() {
        guard watcher == nil else { return }
        watcher = FileSystemWatcher { [weak self] root in
            // Bind strongly here so the hop to the main actor does not capture
            // the weak reference itself.
            guard let self else { return }
            Task { @MainActor in
                self.fileSystemDidChange(root: root)
            }
        }
        updateWatchedPaths()
    }

    // MARK: - Derived state

    var selectedRepository: RepositoryState? {
        guard let selectedRepositoryID else { return nil }
        return repositories.first { $0.id == selectedRepositoryID }
    }

    /// Total number of changed files across every repository, for the menu bar icon.
    var totalChangedFileCount: Int {
        repositories.reduce(0) { $0 + ($1.status?.changedFileCount ?? 0) }
    }

    var generatorEngineDescription: String {
        generator.engineDescription
    }

    // MARK: - Lifecycle

    /// Called when the menu bar window opens.
    func refreshAll() async {
        await verifyGitIsAvailable()
        await withTaskGroup(of: Void.self) { group in
            for state in repositories {
                group.addTask { @MainActor in
                    await self.refresh(state)
                }
            }
        }
    }

    private func verifyGitIsAvailable() async {
        do {
            _ = try await git.version()
            gitFailure = nil
        } catch let failure as GitFailure {
            gitFailure = failure.hint ?? failure.message
        } catch {
            gitFailure = error.localizedDescription
        }
    }

    func refresh(_ state: RepositoryState) async {
        state.isRefreshing = true
        defer { state.isRefreshing = false }

        do {
            let status = try await git.status(at: state.repository.url)
            state.status = status
            state.loadFailure = nil
        } catch let failure as GitFailure {
            state.loadFailure = failure
        } catch {
            state.loadFailure = GitFailure(
                command: "git status",
                exitCode: -1,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - File system events

    private func fileSystemDidChange(root: String) {
        guard let state = repositories.first(where: { $0.repository.path == root }) else { return }
        scheduleRefresh(for: state)
    }

    /// Coalesces bursts of file system events into a single refresh.
    private func scheduleRefresh(for state: RepositoryState) {
        refreshTasks[state.id]?.cancel()
        refreshTasks[state.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            // Never refresh underneath a commit or push in flight.
            guard !state.isBusy else { return }
            await self.refresh(state)
        }
    }

    private func updateWatchedPaths() {
        watcher?.watch(roots: repositories.map(\.repository.path))
    }

    private func persist() {
        store.save(repositories.map(\.repository))
    }

    // MARK: - Managing repositories

    func addRepository() async {
        addFailure = nil
        guard let url = SystemIntegration.chooseRepositoryFolder() else { return }

        do {
            let root = try await git.repositoryRoot(containing: url)
            guard !repositories.contains(where: { $0.repository.path == root }) else {
                addFailure = "“\(url.lastPathComponent)” is already in the list."
                return
            }

            let state = RepositoryState(repository: Repository(path: root))
            repositories.append(state)
            sortRepositories()
            persist()
            updateWatchedPaths()
            await refresh(state)
        } catch let failure as GitFailure {
            addFailure = failure.message.lowercased().contains("not a git repository")
                ? "“\(url.lastPathComponent)” is not inside a Git repository."
                : failure.message
        } catch {
            addFailure = error.localizedDescription
        }
    }

    func remove(_ state: RepositoryState) {
        refreshTasks[state.id]?.cancel()
        refreshTasks[state.id] = nil
        repositories.removeAll { $0.id == state.id }
        if selectedRepositoryID == state.id { selectedRepositoryID = nil }
        persist()
        updateWatchedPaths()
    }

    private func sortRepositories() {
        repositories.sort {
            $0.repository.name.localizedStandardCompare($1.repository.name) == .orderedAscending
        }
    }

    // MARK: - Message generation

    func generateCommitMessage(for state: RepositoryState) async {
        guard let status = state.status, !status.changes.isEmpty else { return }

        state.isGeneratingMessage = true
        state.generationNote = nil
        defer { state.isGeneratingMessage = false }

        let context: DiffContext
        do {
            context = try await git.diffContext(at: state.repository.url, status: status)
        } catch {
            // Without a diff we can still describe the change from the file list.
            context = DiffContext(
                branch: status.branch,
                changes: status.changes,
                stats: [],
                patchExcerpt: ""
            )
        }

        let generated = await generator.generate(for: context)
        state.commitMessage = generated.message
        switch generated.source {
        case .foundationModels:
            state.generationNote = "Written by the on-device model."
        case .heuristic(let reason):
            state.generationNote = reason.map { "Local fallback — \($0)" } ?? "Local fallback."
        }
    }

    // MARK: - Commit and push

    /// Validates, screens for secrets, then runs the operation.
    func commit(_ state: RepositoryState, push: Bool) async {
        state.clearOutcome()

        guard let status = state.status else { return }
        let message = state.trimmedCommitMessage

        guard !message.isEmpty else {
            state.operationFailure = GitFailure(
                command: "git commit",
                exitCode: -1,
                message: "Enter a commit message first."
            )
            return
        }
        if let blocker = status.commitBlocker {
            state.operationFailure = GitFailure(
                command: "git commit",
                exitCode: -1,
                message: blocker.message
            )
            return
        }
        if push, let blocker = status.pushBlocker {
            state.operationFailure = GitFailure(
                command: "git push",
                exitCode: -1,
                message: blocker.message
            )
            return
        }

        // `git add -A` sweeps in everything, so screen the whole change set.
        let sensitive = SensitiveFileScanner.scan(status.changes)
        guard sensitive.isEmpty else {
            pendingCommit = PendingCommit(
                repositoryID: state.id,
                message: message,
                push: push,
                files: sensitive
            )
            return
        }

        await perform(on: state, message: message, push: push)
    }

    /// Runs the commit the user confirmed despite the sensitive-file warning.
    func confirmPendingCommit() async {
        guard
            let pending = pendingCommit,
            let state = repositories.first(where: { $0.id == pending.repositoryID })
        else {
            pendingCommit = nil
            return
        }
        pendingCommit = nil
        await perform(on: state, message: pending.message, push: pending.push)
    }

    func cancelPendingCommit() {
        pendingCommit = nil
    }

    /// `git add -A`, `git commit -m …`, then optionally `git push`.
    private func perform(on state: RepositoryState, message: String, push: Bool) async {
        let upstream = state.status?.upstream
        state.clearOutcome()

        do {
            state.activity = "Staging changes…"
            try await git.stageAll(at: state.repository.url)

            state.activity = "Committing…"
            try await git.commit(at: state.repository.url, message: message)

            if push {
                state.activity = "Pushing…"
                try await git.push(at: state.repository.url)
            }

            state.activity = nil
            state.commitMessage = ""
            state.generationNote = nil
            if push {
                state.lastSuccess = upstream.map { "Committed and pushed to \($0)." }
                    ?? "Committed and pushed."
            } else {
                state.lastSuccess = "Committed locally."
            }
        } catch let failure as GitFailure {
            state.activity = nil
            state.operationFailure = failure
        } catch {
            state.activity = nil
            state.operationFailure = GitFailure(
                command: "git",
                exitCode: -1,
                message: error.localizedDescription
            )
        }

        await refresh(state)
    }

    /// `git push --set-upstream <remote> <branch>` for a branch with no upstream.
    func publishBranch(for state: RepositoryState) async {
        guard
            let status = state.status,
            let branch = status.branch,
            let remote = status.hasOrigin ? "origin" : status.remotes.first
        else { return }

        state.clearOutcome()
        do {
            state.activity = "Publishing \(branch)…"
            try await git.publishBranch(at: state.repository.url, branch: branch, remote: remote)
            state.activity = nil
            state.lastSuccess = "Published \(branch) to \(remote)."
        } catch let failure as GitFailure {
            state.activity = nil
            state.operationFailure = failure
        } catch {
            state.activity = nil
            state.operationFailure = GitFailure(
                command: "git push --set-upstream",
                exitCode: -1,
                message: error.localizedDescription
            )
        }
        await refresh(state)
    }

    // MARK: - Reveal

    func openInFinder(_ state: RepositoryState) {
        SystemIntegration.openInFinder(state.repository.url)
    }

    func openInTerminal(_ state: RepositoryState) async {
        do {
            try await SystemIntegration.openInTerminal(state.repository.url)
        } catch {
            state.operationFailure = GitFailure(
                command: "Open in Terminal",
                exitCode: -1,
                message: error.localizedDescription
            )
        }
    }
}
