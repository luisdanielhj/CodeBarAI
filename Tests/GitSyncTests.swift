import Foundation

/// Two clones of one bare repository stand in for two machines. Every git
/// command runs against temporary folders with an isolated git config.
@main
struct GitSyncTests {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codebar-git-sync-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Keep the user's own git config (hooks, signing, pull.rebase) out of it.
        let config = root.appendingPathComponent("gitconfig")
        try """
        [user]
            name = Sync Test
            email = sync-test@example.invalid
        [init]
            defaultBranch = main
        [commit]
            gpgsign = false
        [advice]
            detachedHead = false
        """.write(to: config, atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)

        let git = GitClient.shared
        let sync = GitSyncService()
        let remote = root.appendingPathComponent("remote.git")
        let a = root.appendingPathComponent("machine-a")
        let b = root.appendingPathComponent("machine-b")

        try await sh(["init", "--bare", "-b", "main", remote.path], in: root)
        try await sh(["clone", "--quiet", remote.path, a.path], in: root)
        try await sh(["symbolic-ref", "HEAD", "refs/heads/main"], in: a)
        try write("hello\n", to: a, "README.md")
        try write("line one\n", to: a, "shared.txt")
        try await commit(a, "initial")
        try await sh(["push", "--quiet", "-u", "origin", "main"], in: a)
        try await sh(["clone", "--quiet", remote.path, b.path], in: root)

        // MARK: Fetch, incoming list and automatic fast-forward

        try write("from a\n", to: a, "a.txt")
        try await commit(a, "feat: add a")
        try await git.push(at: a)

        try await git.fetch(at: b)
        var status = try await git.status(at: b)
        try check(status.behind == 1 && status.ahead == 0, "Fetch reveals the other machine's commit")
        try check(GitSyncService.canAutoFastForward(status), "A branch that is only behind can fast-forward unattended")
        let incoming = try await git.incomingCommits(at: b)
        try check(incoming.map(\.subject) == ["feat: add a"], "List the incoming commit")
        try check(incoming.first?.author == "Sync Test", "Parse the commit author")

        // Uncommitted work on an unrelated file must survive the update.
        try write("local note\n", to: b, "notes.txt")
        try await git.fastForward(at: b)
        status = try await git.status(at: b)
        try check(status.behind == 0, "Fast-forward catches up")
        try check(exists(b, "a.txt"), "Fast-forward brings the new file")
        try check(try read(b, "notes.txt") == "local note\n", "Fast-forward keeps unrelated uncommitted work")
        try FileManager.default.removeItem(at: b.appendingPathComponent("notes.txt"))

        // MARK: Fast-forward refuses when a local edit overlaps

        try write("line one\nfrom a\n", to: a, "shared.txt")
        try await commit(a, "fix: edit shared on a")
        try await git.push(at: a)
        try write("line one\nlocal edit on b\n", to: b, "shared.txt")
        try await git.fetch(at: b)
        let headBefore = try await git.status(at: b).headOID
        var refused = false
        do { try await git.fastForward(at: b) } catch is GitFailure { refused = true }
        try check(refused, "Fast-forward refuses to overwrite an overlapping local edit")
        try check(try await git.status(at: b).headOID == headBefore, "A refused fast-forward changes nothing")
        try check(try read(b, "shared.txt") == "line one\nlocal edit on b\n", "The local edit is untouched")

        // Pull with autostash: the stash can't go back cleanly, so git keeps it.
        let pulled = try await sync.pull(at: b, strategy: .rebase)
        status = try await git.status(at: b)
        try check(status.behind == 0, "Pull with autostash still updates a dirty worktree")
        try check(pulled.autostashKept, "Report an autostash that could not be reapplied")
        try check(status.operation == nil && status.conflicts.map(\.path) == ["shared.txt"], "The overlapping edit shows as a conflict")
        try check(status.stashCount == 1, "Git keeps the autostash entry")
        try await git.resolveConflict(path: "shared.txt", keeping: .mine, during: nil, at: b)
        try check(try read(b, "shared.txt") == "line one\nlocal edit on b\n", "Outside an operation, mine is the stashed local work")
        try await sh(["reset", "--quiet", "--hard"], in: b)
        try await sh(["stash", "clear"], in: b)

        // MARK: Rejected push integrates and retries

        try write("x\n", to: a, "x.txt")
        try await commit(a, "feat: x from a")
        try await git.push(at: a)
        try write("y\n", to: b, "y.txt")
        try await commit(b, "feat: y from b")
        let pushResult = try await sync.push(at: b, integratingWith: .rebase)
        try check(pushResult == .pulledThenPushed(.init(autostashKept: false)), "A rejected push pulls, then pushes again")
        status = try await git.status(at: b)
        try check(status.ahead == 0 && status.behind == 0, "Both sides match after the retry")
        let merges = try await sh(["rev-list", "--merges", "--count", "HEAD"], in: b)
        try check(merges.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "Rebase keeps history linear")

        var rejected = false
        try await sh(["pull", "--quiet", "--rebase"], in: a)
        try write("z\n", to: a, "z.txt")
        try await commit(a, "feat: z from a")
        try await git.push(at: a)
        try write("w\n", to: b, "w.txt")
        try await commit(b, "feat: w from b")
        do { _ = try await sync.push(at: b, integratingWith: nil) } catch let failure as GitFailure {
            rejected = GitSyncService.isRejectedBecauseBehind(failure)
        }
        try check(rejected, "Without integration a push behind the remote is rejected as such")
        let synced = try await sync.sync(at: b, strategy: .rebase)
        try check(synced.pushed, "Sync pulls then pushes")

        // MARK: Conflict during a rebase: keep mine, continue, push

        try await sh(["pull", "--quiet", "--rebase"], in: a)
        try write("version a\n", to: a, "conflict.txt")
        try await commit(a, "a writes conflict")
        try await git.push(at: a)
        try write("version b\n", to: b, "conflict.txt")
        try await commit(b, "b writes conflict")

        var conflicted = false
        do { _ = try await sync.push(at: b, integratingWith: .rebase) } catch let failure as GitFailure {
            conflicted = failure.hint?.contains("Continue") == true
        }
        status = try await git.status(at: b)
        try check(conflicted, "A conflicting pull explains the next step")
        try check(status.operation == .rebase, "The rebase stays in progress")
        try check(status.conflicts.map(\.path) == ["conflict.txt"], "The conflicted file is listed")
        try check(status.commitBlocker != nil && status.pullBlocker != nil, "Commit and pull wait for the rebase")

        try await git.resolveConflict(path: "conflict.txt", keeping: .mine, during: .rebase, at: b)
        status = try await git.status(at: b)
        try check(status.conflicts.isEmpty, "Keeping a side resolves the file")
        try check(try read(b, "conflict.txt") == "version b\n", "During a rebase, mine is this machine's commit")
        try await git.continueOperation(.rebase, at: b)
        status = try await git.status(at: b)
        try check(status.operation == nil && status.ahead == 1 && status.behind == 0, "Continue finishes the rebase")
        try await git.push(at: b)
        try await git.fetch(at: a)
        try await git.fastForward(at: a)
        try check(try read(a, "conflict.txt") == "version b\n", "The other machine gets the resolution")

        // MARK: Abort, fast-forward-only refusal, merge and keep theirs

        try write("a again\n", to: a, "conflict.txt")
        try await commit(a, "a again")
        try await git.push(at: a)
        try write("b again\n", to: b, "conflict.txt")
        try await commit(b, "b again")
        try await git.fetch(at: b)
        do { _ = try await sync.pull(at: b, strategy: .rebase) } catch is GitFailure {}
        try check(try await git.status(at: b).operation == .rebase, "Conflict again")
        try await git.abortOperation(.rebase, at: b)
        status = try await git.status(at: b)
        try check(status.operation == nil && status.isDiverged, "Abort goes back to the diverged branch")
        try check(try read(b, "conflict.txt") == "b again\n", "Abort restores this machine's version")

        var ffRefused = false
        do { _ = try await sync.pull(at: b, strategy: .fastForwardOnly) } catch let failure as GitFailure {
            ffRefused = failure.hint != nil
        }
        try check(ffRefused, "Fast-forward-only refuses diverged branches with a hint")

        do { _ = try await sync.pull(at: b, strategy: .merge) } catch is GitFailure {}
        status = try await git.status(at: b)
        try check(status.operation == .merge && status.conflicts.count == 1, "A merge pull stops on the conflict")
        try await git.resolveConflict(path: "conflict.txt", keeping: .theirs, during: .merge, at: b)
        try check(try read(b, "conflict.txt") == "a again\n", "During a merge, theirs is the remote's version")
        try await git.continueOperation(.merge, at: b)
        status = try await git.status(at: b)
        try check(status.operation == nil && status.behind == 0 && status.ahead == 2, "Continue makes the merge commit")
        try await git.push(at: b)

        // MARK: Stash

        try write("stash me\n", to: b, "stashed.txt")
        try await git.stash(at: b, message: "CodeBarAI test")
        status = try await git.status(at: b)
        try check(status.isClean && status.stashCount == 1, "Stash sets untracked work aside and counts it")
        let stashes = try await git.stashList(at: b)
        try check(stashes.count == 1 && stashes[0].reference == "stash@{0}", "List the stash entry")
        try check(stashes[0].message.contains("CodeBarAI test"), "Keep the stash message")
        try await git.popStash(stashes[0].reference, at: b)
        try check(try read(b, "stashed.txt") == "stash me\n", "Pop restores the work")
        try check(try await git.status(at: b).stashCount == 0, "Pop removes the entry")
        try FileManager.default.removeItem(at: b.appendingPathComponent("stashed.txt"))

        // MARK: Branch pushed from the other machine

        try await sh(["pull", "--quiet", "--rebase"], in: a)
        try await sh(["switch", "--quiet", "-c", "feature"], in: a)
        try write("feature\n", to: a, "feature.txt")
        try await commit(a, "feat: start feature")
        try await sh(["push", "--quiet", "-u", "origin", "feature"], in: a)
        try await git.fetch(at: b)
        let branches = try await git.branches(at: b)
        let remoteFeature = try require(branches.first { $0.isRemote && $0.name == "origin/feature" }, "List the other machine's branch")
        try check(remoteFeature.localName == "feature", "Derive the local branch name")
        try check(!branches.contains { $0.name.hasSuffix("/HEAD") }, "Skip the remote HEAD alias")
        try check(branches.contains { !$0.isRemote && $0.name == "main" && $0.upstream == "origin/main" }, "Read a local branch's upstream")
        try await git.trackRemoteBranch(remoteFeature.name, at: b)
        status = try await git.status(at: b)
        try check(status.branch == "feature" && status.upstream == "origin/feature", "Track the remote branch")
        try await git.switchBranch("main", at: b)
        try check(try await git.status(at: b).branch == "main", "Switch back")

        // MARK: Parsing

        let parsed = GitClient.parseStatus(
            "# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -3\0# stash 4\0",
            remotes: ["origin"],
            operation: nil
        )
        try check(parsed.stashCount == 4 && parsed.headOID == "abc", "Parse the stash count and HEAD")
        try check(parsed.isDiverged && !GitSyncService.canAutoFastForward(parsed), "Never fast-forward a diverged branch")
        try check(GitOperation.rebase.checkoutFlag(for: .mine) == "--theirs", "Rebase swaps ours and theirs")
        try check(GitOperation.merge.checkoutFlag(for: .mine) == "--ours", "Merge keeps ours as mine")
        try check(GitSyncService.reportsKeptAutostash("Applying autostash resulted in conflicts.\nYour changes are safe in the stash."), "Detect a kept autostash")

        print("GitSyncTests passed")
    }

    // MARK: Helpers

    @discardableResult
    static func sh(_ arguments: [String], in directory: URL) async throws -> String {
        let output = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: directory,
            environment: ProcessInfo.processInfo.environment,
            timeout: 60
        )
        guard output.isSuccess else {
            throw TestFailure("git \(arguments.joined(separator: " ")) failed: \(output.diagnostics)")
        }
        return output.standardOutput
    }

    static func commit(_ repository: URL, _ message: String) async throws {
        try await GitClient.shared.stageAll(at: repository)
        try await GitClient.shared.commit(at: repository, message: message)
    }

    static func write(_ text: String, to repository: URL, _ path: String) throws {
        try text.write(to: repository.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    static func read(_ repository: URL, _ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    static func exists(_ repository: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path)
    }

    static func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw TestFailure(description) }
        print("✓ \(description)")
    }

    static func require<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw TestFailure(description) }
        print("✓ \(description)")
        return value
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "✗ \(description)" }
}
