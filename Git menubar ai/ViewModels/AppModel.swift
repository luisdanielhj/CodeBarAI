import AppKit
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
    var selectedRepositoryID: UUID? {
        didSet {
            if let state = selectedRepository { recordActivity(for: state) }
        }
    }

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
    let servers = RunningServersModel()
    let deployments = VercelDeploymentsModel()
    let tokens = TokenUsageModel()
    let commitAI = CommitAISettingsModel()
    let sync = SyncSettingsModel()

    /// The Settings screen covers whatever was showing; closing it returns there.
    var isShowingSettings = false

    /// Rescans the local Claude Code, Codex and Kiro logs, including every Claude account.
    func refreshTokenUsage(force: Bool = false) async {
        let directories = usage.claudeAccounts.compactMap(\.claudeProfile?.configDirectory)
        await tokens.refresh(claudeDirectories: directories, force: force)
    }

    private let git = GitClient.shared
    private let store = RepositoryStore()
    private let generator = CommitMessageGenerator()
    private let syncService = GitSyncService()
    /// Fetches every repository on `sync.fetchInterval`, window open or not.
    @ObservationIgnored private var backgroundSyncTask: Task<Void, Never>?
    private var watcher: FileSystemWatcher?
    /// Pending file-event refreshes, one per repository.
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    /// When each repository last refreshed because of file events.
    @ObservationIgnored private var lastFileEventRefresh: [UUID: ContinuousClock.Instant] = [:]
    /// Pending write of the repository list.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Lets a burst of writes land before reading status.
    private static let fileEventSettleDelay: Duration = .milliseconds(500)
    /// Upper bound on file-event refreshes per repository while files keep changing.
    private static let minimumFileEventRefreshInterval: Duration = .seconds(3)
    /// Opening the window fetches repositories not fetched for this long.
    private static let staleFetchAge: TimeInterval = 30
    /// Fetches running at once, so many repositories don't open many
    /// connections together.
    private static let maximumConcurrentFetches = 4

    init() {
        repositories = store.load().map { RepositoryState(repository: $0) }
        sortRepositories()
        usage.startAutoRefresh()
        // Fetching starts at launch, not when the window first opens, so the
        // other machines' commits arrive even if the menu is never opened.
        restartBackgroundSync()
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

    /// Recent activity takes precedence over whether an older project is dirty.
    var displayedRepositories: [RepositoryState] {
        repositories.sorted { lhs, rhs in
            let lhsDate = lhs.repository.lastWorkedAt ?? .distantPast
            let rhsDate = rhs.repository.lastWorkedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            let nameOrder = lhs.repository.name.localizedStandardCompare(rhs.repository.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.repository.path < rhs.repository.path
        }
    }

    var generatorEngineDescription: String {
        commitAI.engineDescription
    }

    // MARK: - Lifecycle

    /// Called when the menu bar window opens, and on its poll.
    /// - Parameter forceFetch: Fetch every remote now, instead of only the
    ///   ones not fetched in the last half minute.
    func refreshAll(forceFetch: Bool = false) async {
        actionFailure = nil
        await verifyGitIsAvailable()
        await withTaskGroup(of: Void.self) { group in
            for state in repositories {
                group.addTask { @MainActor in
                    await self.refresh(state)
                }
            }
        }
        await fetchAll(onlyIfOlderThan: forceFetch ? nil : Self.staleFetchAge)
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
        // One refresh per repository at a time. A request that arrives while
        // one is running becomes one more pass, because the running pass may
        // have read status before the change it was asked about.
        guard !state.isRefreshing else {
            state.needsAnotherRefresh = true
            return
        }
        state.isRefreshing = true
        defer { state.isRefreshing = false }

        repeat {
            state.needsAnotherRefresh = false
            await readStatus(of: state)
        } while state.needsAnotherRefresh && repositories.contains(where: { $0 === state })
    }

    private func readStatus(of state: RepositoryState) async {
        loadProjectIconIfNeeded(for: state)
        let devServer = await DevServer.detect(in: state.repository.url)
        // Assign only real changes. Every assignment to an observed property
        // re-renders the views reading it, including the menu bar label.
        if state.devServer != devServer { state.devServer = devServer }

        do {
            let status = try await git.status(at: state.repository.url)
            if let date = await RepositoryActivity.latestChange(
                in: state.repository.url,
                changedPaths: status.changes.map(\.path)
            ) {
                recordActivity(for: state, at: date)
            }
            if let previous = state.status, previous != status {
                recordActivity(for: state)
            }
            if state.status != status { state.status = status }
            if state.loadFailure != nil { state.loadFailure = nil }
            if state.lastFetchedAt == nil {
                state.lastFetchedAt = Self.lastFetchDate(in: state.repository.url)
            }
            await loadCommitLists(for: state, status: status)
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
        recordActivity(for: state)
        scheduleRefresh(for: state)
    }

    /// Coalesces bursts of file system events into one refresh, and spaces
    /// refreshes out while files keep changing (a build, an agent editing many
    /// files, an editor rewriting the index). Each refresh starts several git
    /// processes, so an unbounded rate shows up as CPU spikes.
    private func scheduleRefresh(for state: RepositoryState) {
        // A refresh is already pending and will read these changes as well.
        guard refreshTasks[state.id] == nil else { return }

        let now = ContinuousClock.now
        let earliest = lastFileEventRefresh[state.id].map { $0 + Self.minimumFileEventRefreshInterval } ?? now
        let delay = max(Self.fileEventSettleDelay, earliest - now)

        refreshTasks[state.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            refreshTasks[state.id] = nil
            guard repositories.contains(where: { $0 === state }) else { return }
            // Never refresh underneath a commit or push in flight. It refreshes
            // itself when it finishes.
            guard !state.isBusy else { return }
            lastFileEventRefresh[state.id] = .now
            await refresh(state)
        }
    }

    private func updateWatchedPaths() {
        watcher?.watch(roots: repositories.map(\.repository.path))
    }

    private func persist() {
        store.save(repositories.map(\.repository))
    }

    /// Activity is recorded on every file event, so batch the UserDefaults
    /// writes instead of encoding and saving the whole list each time.
    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            persistTask = nil
            persist()
        }
    }

    private func recordActivity(for state: RepositoryState, at date: Date = Date()) {
        guard repositories.contains(where: { $0 === state }), state.recordActivity(at: date) else { return }
        schedulePersist()
    }

    private func loadProjectIconIfNeeded(for state: RepositoryState) {
        guard !state.didSearchForProjectIcon else { return }
        state.didSearchForProjectIcon = true
        let repositoryURL = state.repository.url

        Task { @MainActor [weak self, weak state] in
            let data = await ProjectIconLoader.loadIconData(in: repositoryURL)
            guard let self, let state, repositories.contains(where: { $0 === state }) else { return }
            state.projectIcon = data.flatMap(NSImage.init(data:))
        }
    }

    // MARK: - Managing repositories

    func addRepository() async {
        addFailure = nil
        guard let url = SystemIntegration.chooseRepositoryFolder() else { return }

        do {
            let root = try await git.repositoryRoot(containing: url)
            let repository = Repository(path: root, lastWorkedAt: Date())
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
        lastFileEventRefresh[state.id] = nil
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
        state.operationFailure = nil
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
                patches: [:]
            )
        }

        do {
            let configuration = try await commitAI.configuration()
            let generated = try await generator.generate(for: context, configuration: configuration)
            state.commitMessage = generated.message
            state.generationNote = generated.note
            recordActivity(for: state)
        } catch is CancellationError {
            return
        } catch {
            // Keep whatever the user already typed; explain what went wrong.
            state.operationFailure = GitFailure(
                command: "Generate message",
                exitCode: -1,
                message: error.localizedDescription
            )
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
            recordActivity(for: state)

            // The commit is made. Clear the composer now, so a push that
            // fails below doesn't invite committing the same message twice.
            state.commitMessage = ""
            state.generationNote = nil

            var pushResult: GitSyncService.PushResult?
            if push {
                state.activity = "Pushing…"
                await waitForFetch(of: state)
                pushResult = try await syncService.push(
                    at: state.repository.url,
                    integratingWith: sync.pullBeforePush ? sync.pullStrategy : nil
                )
            }

            state.activity = nil
            switch pushResult {
            case nil:
                state.lastSuccess = "Committed locally."
            case .pushed:
                state.lastSuccess = upstream.map { "Committed and pushed to \($0)." }
                    ?? "Committed and pushed."
            case .pulledThenPushed(let pulled):
                state.lastSuccess = "Committed, pulled the other machine’s commits, and pushed."
                noteKeptAutostash(pulled, on: state)
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
            recordActivity(for: state)
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

    // MARK: - Syncing with other machines

    /// (Re)starts the background fetch loop with the current interval.
    func restartBackgroundSync() {
        backgroundSyncTask?.cancel()
        guard let interval = sync.fetchInterval.duration else {
            backgroundSyncTask = nil
            return
        }
        backgroundSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await fetchAll(onlyIfOlderThan: nil)
            }
        }
    }

    /// Fetches every repository that has a remote, a few at a time.
    /// - Parameter maxAge: Skip repositories fetched more recently than this.
    func fetchAll(onlyIfOlderThan maxAge: TimeInterval?) async {
        // The window may never have opened since launch.
        for state in repositories where state.status == nil && state.loadFailure == nil {
            await refresh(state)
        }
        let now = Date()
        let due = repositories.filter { state in
            guard let status = state.status, !status.remotes.isEmpty else { return false }
            guard let maxAge, let last = state.lastFetchedAt else { return true }
            return now.timeIntervalSince(last) >= maxAge
        }
        var index = 0
        while index < due.count {
            let batch = due[index..<min(index + Self.maximumConcurrentFetches, due.count)]
            index += batch.count
            await withTaskGroup(of: Void.self) { group in
                for state in batch {
                    group.addTask { @MainActor in
                        await self.fetch(state, userInitiated: false)
                    }
                }
            }
        }
    }

    /// `git fetch`, then an automatic fast-forward when it is safe.
    func fetch(_ state: RepositoryState, userInitiated: Bool = true) async {
        guard !state.isFetching, !state.isBusy else { return }
        guard repositories.contains(where: { $0 === state }) else { return }
        guard let remotes = state.status?.remotes, !remotes.isEmpty else {
            await refresh(state)
            return
        }
        state.isFetching = true
        if userInitiated { state.clearOutcome() }

        do {
            try await git.fetch(at: state.repository.url)
            state.lastFetchedAt = Date()
            if state.fetchFailure != nil { state.fetchFailure = nil }
            // The remote refs moved, so the commit lists must be read again.
            state.commitListKey = nil
        } catch let failure as GitFailure {
            state.fetchFailure = failure
            if userInitiated { state.operationFailure = failure }
        } catch {
            let failure = GitFailure(command: "git fetch", exitCode: -1, message: error.localizedDescription)
            state.fetchFailure = failure
            if userInitiated { state.operationFailure = failure }
        }
        state.isFetching = false

        await refresh(state)
        await fastForwardIfPossible(state)
    }

    /// Brings a branch with no local commits up to date unattended. Git itself
    /// refuses, changing nothing, if a local edit overlaps an incoming change.
    private func fastForwardIfPossible(_ state: RepositoryState) async {
        guard
            sync.autoFastForward,
            !state.isBusy,
            let status = state.status,
            GitSyncService.canAutoFastForward(status)
        else {
            if state.autoUpdateBlocked, state.status?.behind == 0 { state.autoUpdateBlocked = false }
            return
        }

        state.activity = "Updating…"
        do {
            try await git.fastForward(at: state.repository.url)
            state.lastAutoUpdate = .init(commitCount: status.behind, date: Date())
            state.autoUpdateBlocked = false
            recordActivity(for: state)
        } catch {
            state.autoUpdateBlocked = true
        }
        state.activity = nil
        await refresh(state)
    }

    /// `git pull` with the strategy chosen in Settings.
    func pull(_ state: RepositoryState) async {
        guard let status = state.status else { return }
        if let blocker = status.pullBlocker {
            state.operationFailure = GitFailure(command: "git pull", exitCode: -1, message: blocker.message)
            return
        }
        let upstream = status.upstream ?? "the remote"
        await runSyncAction(on: state, activity: "Pulling…", command: "git pull") {
            let pulled = try await self.syncService.pull(at: state.repository.url, strategy: self.sync.pullStrategy)
            self.noteKeptAutostash(pulled, on: state)
            return "Pulled the latest commits from \(upstream)."
        }
    }

    /// `git push` of commits already made, pulling first if the remote moved.
    func push(_ state: RepositoryState) async {
        guard let status = state.status else { return }
        if let blocker = status.pushBlocker {
            state.operationFailure = GitFailure(command: "git push", exitCode: -1, message: blocker.message)
            return
        }
        let upstream = status.upstream ?? "the remote"
        await runSyncAction(on: state, activity: "Pushing…", command: "git push") {
            let result = try await self.syncService.push(
                at: state.repository.url,
                integratingWith: self.sync.pullBeforePush ? self.sync.pullStrategy : nil
            )
            switch result {
            case .pushed:
                return "Pushed to \(upstream)."
            case .pulledThenPushed(let pulled):
                self.noteKeptAutostash(pulled, on: state)
                return "Pulled the other machine’s commits, then pushed to \(upstream)."
            }
        }
    }

    /// Pull, then push: both machines end up with the same history.
    func syncNow(_ state: RepositoryState) async {
        guard let status = state.status else { return }
        if let blocker = status.pullBlocker {
            state.operationFailure = GitFailure(command: "git pull", exitCode: -1, message: blocker.message)
            return
        }
        let upstream = status.upstream ?? "the remote"
        await runSyncAction(on: state, activity: "Syncing…", command: "git pull") {
            let result = try await self.syncService.sync(at: state.repository.url, strategy: self.sync.pullStrategy)
            self.noteKeptAutostash(result.pull, on: state)
            return result.pushed ? "In sync with \(upstream)." : "Pulled from \(upstream)."
        }
    }

    // MARK: Interrupted merges and rebases

    func continueOperation(_ state: RepositoryState) async {
        guard let operation = state.status?.operation else { return }
        await runSyncAction(on: state, activity: "Continuing…", command: "git \(operation.subcommand) --continue") {
            try await self.git.continueOperation(operation, at: state.repository.url)
            return "\(operation.title) finished."
        }
    }

    func abortOperation(_ state: RepositoryState) async {
        guard let operation = state.status?.operation else { return }
        await runSyncAction(on: state, activity: "Aborting…", command: "git \(operation.subcommand) --abort") {
            try await self.git.abortOperation(operation, at: state.repository.url)
            return "\(operation.title) aborted. Everything is back as it was."
        }
    }

    func skipCommit(_ state: RepositoryState) async {
        guard let operation = state.status?.operation, operation.canSkip else { return }
        await runSyncAction(on: state, activity: "Skipping…", command: "git \(operation.subcommand) --skip") {
            try await self.git.skipCommit(operation, at: state.repository.url)
            return "Skipped that commit."
        }
    }

    func resolveConflict(_ change: GitFileChange, keeping side: ConflictSide, in state: RepositoryState) async {
        let operation = state.status?.operation
        await runSyncAction(on: state, activity: "Resolving…", command: "Resolve conflict") {
            try await self.git.resolveConflict(
                path: change.path,
                keeping: side,
                during: operation,
                at: state.repository.url
            )
            return nil
        }
    }

    func markResolved(_ change: GitFileChange, in state: RepositoryState) async {
        if Self.containsConflictMarkers(state.repository.url.appending(path: change.path)) {
            state.clearOutcome()
            state.operationFailure = GitFailure(
                command: "Mark resolved",
                exitCode: -1,
                message: "\(change.fileName) still has conflict markers (<<<<<<<). Edit it first, or keep one whole version."
            )
            return
        }
        await runSyncAction(on: state, activity: "Resolving…", command: "git add") {
            try await self.git.markResolved(path: change.path, at: state.repository.url)
            return nil
        }
    }

    /// Unresolved files still contain git's marker lines.
    private nonisolated static func containsConflictMarkers(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.prefix(8_000).contains(0) else {
            return false
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ")
    }

    // MARK: Stash

    func stashChanges(_ state: RepositoryState) async {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        await runSyncAction(on: state, activity: "Stashing…", command: "git stash") {
            try await self.git.stash(at: state.repository.url, message: "CodeBarAI \(stamp)")
            return "Changes stashed. Restore them from the ⋯ menu."
        }
    }

    func popStash(_ entry: GitStashEntry, in state: RepositoryState) async {
        await runSyncAction(on: state, activity: "Restoring…", command: "git stash pop") {
            let output = try await self.git.popStash(entry.reference, at: state.repository.url)
            if output.lowercased().contains("conflict") {
                state.syncNotice = "Restored with conflicts. The stash entry was kept; delete it once the files look right."
                return nil
            }
            return "Stashed changes restored."
        }
    }

    func dropStash(_ entry: GitStashEntry, in state: RepositoryState) async {
        await runSyncAction(on: state, activity: "Deleting stash…", command: "git stash drop") {
            try await self.git.dropStash(entry.reference, at: state.repository.url)
            return "Stash entry deleted."
        }
    }

    // MARK: Branches

    /// Loads branches and stash entries for the detail screen's menus.
    func loadRefs(for state: RepositoryState) async {
        let url = state.repository.url
        async let branches = try? git.branches(at: url)
        async let stashes = try? git.stashList(at: url)
        let (loadedBranches, loadedStashes) = await (branches, stashes)
        if let loadedBranches, loadedBranches != state.branches { state.branches = loadedBranches }
        if let loadedStashes, loadedStashes != state.stashes { state.stashes = loadedStashes }
    }

    /// Switches to a local branch, or creates one tracking a remote branch.
    func switchBranch(to branch: GitBranchRef, in state: RepositoryState) async {
        let hasLocal = state.branches.contains { !$0.isRemote && $0.name == branch.localName }
        await runSyncAction(on: state, activity: "Switching…", command: "git switch") {
            if branch.isRemote && !hasLocal {
                try await self.git.trackRemoteBranch(branch.name, at: state.repository.url)
            } else {
                try await self.git.switchBranch(branch.localName, at: state.repository.url)
            }
            return "Switched to \(branch.localName)."
        }
        await loadRefs(for: state)
    }

    // MARK: Helpers

    /// Runs one sync action with the usual busy state, banners and refresh.
    /// `work` returns the success message, or `nil` for none.
    private func runSyncAction(
        on state: RepositoryState,
        activity: String,
        command: String,
        _ work: () async throws -> String?
    ) async {
        guard !state.isBusy else { return }
        state.clearOutcome()
        state.activity = activity
        await waitForFetch(of: state)
        do {
            if let message = try await work() { state.lastSuccess = message }
            state.autoUpdateBlocked = false
        } catch let failure as GitFailure {
            state.operationFailure = failure
        } catch {
            state.operationFailure = GitFailure(command: command, exitCode: -1, message: error.localizedDescription)
        }
        state.activity = nil
        state.commitListKey = nil
        recordActivity(for: state)
        await refresh(state)
        if state.stashes.count != state.status?.stashCount ?? 0 { await loadRefs(for: state) }
    }

    /// A background fetch and a pull or push would race for the same refs.
    private func waitForFetch(of state: RepositoryState) async {
        while state.isFetching, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func noteKeptAutostash(_ result: GitSyncService.PullResult, on state: RepositoryState) {
        guard result.autostashKept else { return }
        state.syncNotice = "Your uncommitted changes overlapped the pulled ones, so git kept them in the stash. Restore them from the ⋯ menu."
    }

    /// Reads the incoming and outgoing commits when HEAD or the counts moved.
    private func loadCommitLists(for state: RepositoryState, status: GitStatus) async {
        let key = [status.headOID ?? "", status.upstream ?? "", "\(status.ahead)", "\(status.behind)"]
            .joined(separator: "|")
        guard key != state.commitListKey else { return }
        state.commitListKey = key

        guard status.upstream != nil, status.ahead > 0 || status.behind > 0 else {
            if !state.incoming.isEmpty { state.incoming = [] }
            if !state.outgoing.isEmpty { state.outgoing = [] }
            return
        }
        let url = state.repository.url
        let incoming = status.behind > 0 ? (try? await git.incomingCommits(at: url)) ?? [] : []
        let outgoing = status.ahead > 0 ? (try? await git.outgoingCommits(at: url)) ?? [] : []
        if state.incoming != incoming { state.incoming = incoming }
        if state.outgoing != outgoing { state.outgoing = outgoing }
    }

    /// `FETCH_HEAD` is rewritten by every fetch, including ones from Terminal.
    private nonisolated static func lastFetchDate(in repository: URL) -> Date? {
        let fetchHead = repository.appending(path: ".git/FETCH_HEAD")
        return try? fetchHead.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Opening the repository elsewhere

    func openInFinder(_ state: RepositoryState) {
        SystemIntegration.openInFinder(state.repository.url)
        recordActivity(for: state)
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

    func openInClaudeCode(_ state: RepositoryState, account: AIUsageState? = nil) async {
        let selected = account ?? usage.selectedClaudeAccount
        let profile = (account != nil || usage.claudeAccounts.count > 1) ? selected?.claudeProfile : nil
        await handOff(state, named: "Open in Claude Code") {
            try await SystemIntegration.openInClaudeCode(state.repository.url, profile: profile)
        }
    }

    func openInCodex(_ state: RepositoryState) async {
        await handOff(state, named: "Open in Codex") {
            try await SystemIntegration.openInCodex(state.repository.url)
        }
    }

    func openInKiro(_ state: RepositoryState) async {
        await handOff(state, named: "Open in Kiro") {
            try await SystemIntegration.openInKiro(state.repository.url)
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
            recordActivity(for: state)
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
