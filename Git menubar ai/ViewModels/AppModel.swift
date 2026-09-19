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
    /// Last failed hand-off to Finder, Terminal or an editor. The detail screen
    /// has its own banner, so this exists for the list, where a context menu
    /// action would otherwise fail silently.
    var actionFailure: GitFailure?
    /// Set when the system git itself cannot run at all.
    var gitFailure: String?
    /// Sensitive-file confirmation waiting on the user.
    var pendingCommit: PendingCommit?

    let usage = AIUsageModel()

    private let git = GitClient.shared
    private let store = RepositoryStore()
    private let generator = CommitMessageGenerator()
    private var watcher: FileSystemWatcher?
    /// Debounce timers, one per repository.
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        repositories = store.load().map { RepositoryState(repository: $0) }
        sortRepositories()
        usage.startAutoRefresh()
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

    /// Repositories with uncommitted changes come first; each group remains
    /// alphabetized. This changes presentation only and does not rewrite storage.
    var displayedRepositories: [RepositoryState] {
        repositories.sorted { lhs, rhs in
            let lhsHasChanges = lhs.status?.isClean == false
            let rhsHasChanges = rhs.status?.isClean == false
            if lhsHasChanges != rhsHasChanges { return lhsHasChanges }
            return lhs.repository.name.localizedStandardCompare(rhs.repository.name) == .orderedAscending
        }
    }

    var generatorEngineDescription: String {
        generator.engineDescription
    }

    // MARK: - Lifecycle

    /// Called when the menu bar window opens.
    func refreshAll() async {
        actionFailure = nil
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
        loadProjectIconIfNeeded(for: state)
        state.devServer = await DevServer.detect(in: state.repository.url)
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

    private func loadProjectIconIfNeeded(for state: RepositoryState) {
        guard !state.didSearchForProjectIcon else { return }
        state.didSearchForProjectIcon = true
        let repositoryURL = state.repository.url

        Task { @MainActor [weak self, weak state] in
            let data = await ProjectIconLoader.loadIconData(in: repositoryURL)
            guard let self, let state, repositories.contains(where: { $0 === state }) else { return }
            state.projectIconData = data
        }
    }

    // MARK: - Managing repositories

    func addRepository() async {
        addFailure = nil
        guard let url = SystemIntegration.chooseRepositoryFolder() else { return }

        do {
            let root = try await git.repositoryRoot(containing: url)
            let repository = Repository(path: root)
            if let existing = repositories.first(where: {
                $0.repository.canonicalPath == repository.canonicalPath
            }) {
                // Choosing an existing repository is harmless. Reveal it instead
                // of leaving the user with an error and no obvious way forward.
                await refresh(existing)
                selectedRepositoryID = existing.id
                return
            }

            let state = RepositoryState(repository: repository)
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

    // MARK: - Opening the repository elsewhere

    func openInFinder(_ state: RepositoryState) {
        SystemIntegration.openInFinder(state.repository.url)
    }

    func openInTerminal(_ state: RepositoryState) async {
        await handOff(state, named: "Open in Terminal") {
            try await SystemIntegration.openInTerminal(state.repository.url)
        }
    }

    func openInCursor(_ state: RepositoryState) async {
        await openInCursor(projectURL: state.repository.url, reportingOn: state)
    }

    func openInCursor(_ change: GitFileChange, in state: RepositoryState) async {
        let fileURL = state.repository.url.appending(path: change.path)
        let existingFileURL = FileManager.default.fileExists(atPath: fileURL.path)
            ? fileURL
            : nil
        await openInCursor(
            projectURL: state.repository.url,
            fileURL: existingFileURL,
            reportingOn: state
        )
    }

    private func openInCursor(
        projectURL: URL,
        fileURL: URL? = nil,
        reportingOn state: RepositoryState
    ) async {
        await handOff(state, named: "Open in Cursor") {
            try await SystemIntegration.openInCursor(
                projectURL: projectURL,
                fileURL: fileURL
            )
        }
    }

    func openInClaudeCode(_ state: RepositoryState) async {
        await handOff(state, named: "Open in Claude Code") {
            try await SystemIntegration.openInClaudeCode(state.repository.url)
        }
    }

    func openInCodex(_ state: RepositoryState) async {
        await handOff(state, named: "Open in Codex") {
            try await SystemIntegration.openInCodex(state.repository.url)
        }
    }

    /// Runs one hand-off to another app, recording why it failed on both the
    /// repository and the list screen.
    private func handOff(
        _ state: RepositoryState,
        named command: String,
        _ work: () async throws -> Void
    ) async {
        state.operationFailure = nil
        actionFailure = nil
        do {
            try await work()
        } catch {
            let failure = GitFailure(
                command: command,
                exitCode: -1,
                message: error.localizedDescription
            )
            state.operationFailure = failure
            actionFailure = failure
        }
    }

    func startDevServer(_ state: RepositoryState) async {
        // Detect again so a lockfile or script changed since the last refresh
        // is honored.
        guard let server = await DevServer.detect(in: state.repository.url) else {
            state.devServer = nil
            return
        }
        state.devServer = server
        await handOff(state, named: "Start Server") {
            try await SystemIntegration.startDevServer(server, at: state.repository.url)
        }
    }
}
