import Foundation

/// Runs the system `git` binary. Nothing about Git is reimplemented here — every
/// answer comes from parsing the CLI's own machine-readable output.
nonisolated struct GitClient: Sendable {
    static let shared = GitClient()

    private let executableURL = URL(filePath: "/usr/bin/git")

    private static let statusTimeout: TimeInterval = 20
    private static let localWriteTimeout: TimeInterval = 60
    private static let networkTimeout: TimeInterval = 120

    // MARK: - Environment

    /// Git must never block on an interactive prompt: this app has no terminal to
    /// answer one, so a missing credential has to surface as an error instead.
    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        // Continuing a merge or rebase would otherwise open an editor for the
        // message. `true` accepts the message git prepared.
        environment["GIT_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        }
        // A bundled app inherits a bare PATH, but git's credential helpers and ssh
        // are found through it.
        let searchPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
        let existing = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (existing + searchPaths).joined(separator: ":")
        return environment
    }

    // MARK: - Running

    private func run(
        _ arguments: [String],
        in repository: URL?,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        try await ProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: repository,
            environment: environment,
            timeout: timeout
        )
    }

    /// Runs git and turns a non-zero exit into a `GitFailure` carrying git's own message.
    @discardableResult
    private func runChecked(
        _ arguments: [String],
        label: String,
        in repository: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        let output: ProcessOutput
        do {
            output = try await run(arguments, in: repository, timeout: timeout)
        } catch {
            throw GitFailure(
                command: label,
                exitCode: -1,
                message: error.localizedDescription
            )
        }
        guard output.isSuccess else {
            throw GitFailure(
                command: label,
                exitCode: output.exitCode,
                message: output.diagnostics.isEmpty
                    ? "git exited with code \(output.exitCode)."
                    : output.diagnostics
            )
        }
        return output.standardOutput
    }

    /// Like `runChecked`, but returns both streams of a successful run, for
    /// commands that report important outcomes on stderr (an autostash that
    /// could not be reapplied, for example).
    private func runReporting(
        _ arguments: [String],
        label: String,
        in repository: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        let output: ProcessOutput
        do {
            output = try await run(arguments, in: repository, timeout: timeout)
        } catch {
            throw GitFailure(command: label, exitCode: -1, message: error.localizedDescription)
        }
        let combined = [output.standardOutput, output.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard output.isSuccess else {
            throw GitFailure(
                command: label,
                exitCode: output.exitCode,
                message: combined.isEmpty ? "git exited with code \(output.exitCode)." : combined
            )
        }
        return combined
    }

    // MARK: - Discovery

    /// Confirms the system git is usable, returning its version string.
    func version() async throws -> String {
        let output = try await runChecked(["--version"], label: "git --version", in: nil, timeout: 15)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves any folder inside a repository to its worktree root.
    func repositoryRoot(containing url: URL) async throws -> String {
        let output = try await runChecked(
            ["rev-parse", "--show-toplevel"],
            label: "git rev-parse",
            in: url,
            timeout: Self.statusTimeout
        )
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw GitFailure(
                command: "git rev-parse",
                exitCode: 1,
                message: "fatal: not a git repository"
            )
        }
        return root
    }

    // MARK: - Status

    func status(at url: URL) async throws -> GitStatus {
        // --no-optional-locks keeps frequent refreshes from fighting a running
        // git command for the index lock.
        let raw = try await runChecked(
            [
                "--no-optional-locks",
                "-c", "core.quotepath=false",
                "status", "--porcelain=v2", "--branch", "--show-stash", "--untracked-files=all", "-z"
            ],
            label: "git status",
            in: url,
            timeout: Self.statusTimeout
        )

        let remotes = try await remoteNames(at: url)
        let operation = await operationInProgress(at: url)
        return Self.parseStatus(raw, remotes: remotes, operation: operation)
    }

    private func remoteNames(at url: URL) async throws -> [String] {
        let raw = try await runChecked(["remote"], label: "git remote", in: url, timeout: Self.statusTimeout)
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Detects an interrupted merge, rebase, cherry-pick or revert from the marker
    /// files git leaves in the git directory.
    private func operationInProgress(at url: URL) async -> GitOperation? {
        guard
            let raw = try? await runChecked(
                ["rev-parse", "--absolute-git-dir"],
                label: "git rev-parse",
                in: url,
                timeout: Self.statusTimeout
            )
        else { return nil }

        let gitDirectory = URL(filePath: raw.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDirectory.appending(path: name).path)
        }

        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    // MARK: - Diff context for message generation

    /// Collects each changed file's diff, plus the start of every new file,
    /// which `git diff HEAD` doesn't show until the file is staged.
    func diffContext(at url: URL, status: GitStatus) async throws -> DiffContext {
        var stats: [FileDiffStat] = []
        var patches: [String: String] = [:]

        if status.hasCommits {
            let numstat = try? await runChecked(
                ["-c", "core.quotepath=false", "diff", "--numstat", "HEAD"],
                label: "git diff",
                in: url,
                timeout: Self.statusTimeout
            )
            if let numstat { stats = Self.parseNumstat(numstat) }

            // Fixed prefixes, so a user's diff.noprefix or mnemonicPrefix
            // setting can't break the per-file split.
            let raw = try? await runChecked(
                [
                    "-c", "core.quotepath=false",
                    "diff", "--no-color", "--no-ext-diff", "--unified=3",
                    "--src-prefix=a/", "--dst-prefix=b/", "HEAD"
                ],
                label: "git diff",
                in: url,
                timeout: Self.statusTimeout
            )
            if let raw { patches = Self.splitPatch(raw) }
        }

        let newFiles = status.changes.filter { change in
            patches[change.path] == nil
                && (change.kind == .untracked || change.kind == .added)
                && SensitiveFileScanner.reason(forPath: change.path) == nil
        }
        if !newFiles.isEmpty {
            let excerpts = await Task.detached(priority: .userInitiated) {
                newFiles.compactMap { change in
                    Self.newFileExcerpt(at: url.appending(path: change.path)).map { (change.path, $0) }
                }
            }.value
            for (path, excerpt) in excerpts {
                patches[path] = excerpt.text
                if !stats.contains(where: { $0.path == path }) {
                    stats.append(FileDiffStat(path: path, insertions: excerpt.lineCount, deletions: 0))
                }
            }
        }

        return DiffContext(
            branch: status.branch,
            changes: status.changes,
            stats: stats,
            patches: patches
        )
    }

    /// Splits a unified diff into one entry per file, keyed by the file's
    /// current path. Git's own header lines are dropped to save space; the
    /// lines that say what happened to the file (new, deleted, renamed,
    /// binary) are kept.
    static func splitPatch(_ raw: String) -> [String: String] {
        var patches: [String: String] = [:]
        var section: [Substring] = []

        func flush() {
            guard let header = section.first else { return }
            var path: String?
            var body: [Substring] = []
            var inHunks = false
            for line in section.dropFirst() {
                if line.hasPrefix("@@") { inHunks = true }
                if inHunks {
                    body.append(line)
                    continue
                }
                if line.hasPrefix("rename to ") {
                    path = String(line.dropFirst("rename to ".count))
                } else if line.hasPrefix("+++ b/") {
                    path = path ?? String(line.dropFirst("+++ b/".count))
                } else if line.hasPrefix("--- a/"), path == nil {
                    // A deletion has `+++ /dev/null`; its old path is the key.
                    path = String(line.dropFirst("--- a/".count))
                }
                if line.hasPrefix("new file") || line.hasPrefix("deleted file")
                    || line.hasPrefix("rename ") || line.hasPrefix("Binary files")
                    || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                    body.append(line)
                }
            }
            // Git ends `---`/`+++` paths that contain spaces with a tab.
            let resolved = path.map { $0.hasSuffix("\t") ? String($0.dropLast()) : $0 }
                ?? symmetricPath(inHeader: header)
            if let resolved {
                patches[resolved] = body.joined(separator: "\n")
            }
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                section = [line]
            } else if !section.isEmpty {
                section.append(line)
            }
        }
        flush()
        return patches
    }

    /// `diff --git a/<path> b/<path>` for a file whose path didn't change,
    /// used when the patch has no `+++` line (a binary or mode-only change).
    private static func symmetricPath(inHeader header: Substring) -> String? {
        let rest = header.dropFirst("diff --git a/".count)
        guard rest.count > 3, (rest.count - 3) % 2 == 0 else { return nil }
        let path = rest.prefix((rest.count - 3) / 2)
        guard rest.dropFirst(path.count) == " b/" + path else { return nil }
        return String(path)
    }

    /// The start of a file git isn't tracking yet, formatted like added diff
    /// lines. `nil` when the file can't be read.
    nonisolated static func newFileExcerpt(
        at url: URL,
        byteLimit: Int = 48_000
    ) -> (text: String, lineCount: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit + 1) else { return nil }
        if data.isEmpty { return ("new file (empty)", 0) }
        if data.prefix(8_000).contains(0) { return ("new file (binary)", 0) }

        var text = String(decoding: data.prefix(byteLimit), as: UTF8.self)
        let isComplete = data.count <= byteLimit
        if !isComplete, let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[..<lastNewline])
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var body = "new file\n" + lines.map { "+" + $0 }.joined(separator: "\n")
        if !isComplete { body += "\n[rest of the file not read]" }
        return (body, lines.count)
    }

    // MARK: - Write operations

    /// `git add -A`
    func stageAll(at url: URL) async throws {
        try await runChecked(["add", "-A"], label: "git add -A", in: url, timeout: Self.localWriteTimeout)
    }

    /// `git commit -m <message>`
    func commit(at url: URL, message: String) async throws {
        try await runChecked(
            ["commit", "-m", message],
            label: "git commit",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// `git push`
    func push(at url: URL) async throws {
        try await runChecked(["push"], label: "git push", in: url, timeout: Self.networkTimeout)
    }

    /// `git push --set-upstream <remote> <branch>` for a branch that has no upstream yet.
    func publishBranch(at url: URL, branch: String, remote: String) async throws {
        try await runChecked(
            ["push", "--set-upstream", remote, branch],
            label: "git push --set-upstream",
            in: url,
            timeout: Self.networkTimeout
        )
    }

    // MARK: - Syncing with the remote

    /// `git fetch --all --prune`: learns about commits pushed from other
    /// machines without touching the worktree.
    func fetch(at url: URL) async throws {
        try await runChecked(
            ["fetch", "--all", "--prune", "--quiet"],
            label: "git fetch",
            in: url,
            timeout: Self.networkTimeout
        )
    }

    /// `git pull` with the chosen strategy. Returns git's output so the caller
    /// can notice an autostash that had to stay in the stash.
    @discardableResult
    func pull(at url: URL, strategy: PullStrategy) async throws -> String {
        try await runReporting(
            strategy.pullArguments,
            label: "git pull",
            in: url,
            timeout: Self.networkTimeout
        )
    }

    /// `git merge --ff-only @{upstream}` against what the last fetch brought
    /// in. Git refuses, changing nothing, when a local edit touches a file
    /// the incoming commits also change, so it is safe to run unattended.
    func fastForward(at url: URL) async throws {
        try await runChecked(
            ["merge", "--ff-only", "--quiet", "@{upstream}"],
            label: "git merge --ff-only",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// Commits on the upstream that HEAD doesn't have yet.
    func incomingCommits(at url: URL, limit: Int = 50) async throws -> [GitCommitSummary] {
        try await commits(at: url, range: "HEAD..@{upstream}", limit: limit)
    }

    /// Commits on HEAD that haven't been pushed to the upstream.
    func outgoingCommits(at url: URL, limit: Int = 50) async throws -> [GitCommitSummary] {
        try await commits(at: url, range: "@{upstream}..HEAD", limit: limit)
    }

    private func commits(at url: URL, range: String, limit: Int) async throws -> [GitCommitSummary] {
        let raw = try await runChecked(
            ["log", "--no-color", "-n", String(limit), "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e", range, "--"],
            label: "git log",
            in: url,
            timeout: Self.statusTimeout
        )
        return Self.parseLog(raw)
    }

    // MARK: - Interrupted operations

    /// `git <operation> --continue`, once every conflict is resolved.
    func continueOperation(_ operation: GitOperation, at url: URL) async throws {
        try await runChecked(
            ["-c", "core.editor=true", operation.subcommand, "--continue"],
            label: "git \(operation.subcommand) --continue",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// `git <operation> --abort`: back to where things were before it started.
    func abortOperation(_ operation: GitOperation, at url: URL) async throws {
        try await runChecked(
            [operation.subcommand, "--abort"],
            label: "git \(operation.subcommand) --abort",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// `git <operation> --skip`: drops the commit that is being applied.
    func skipCommit(_ operation: GitOperation, at url: URL) async throws {
        try await runChecked(
            [operation.subcommand, "--skip"],
            label: "git \(operation.subcommand) --skip",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// Resolves a conflicted file by keeping one whole side, then stages it.
    /// `operation` is `nil` for a conflict left by `git stash pop`.
    /// When the kept side deleted the file, the file is removed.
    func resolveConflict(
        path: String,
        keeping side: ConflictSide,
        during operation: GitOperation?,
        at url: URL
    ) async throws {
        // With no operation in progress, the conflict came from reapplying a
        // stash (an autostash after a pull, usually): "theirs" is the stash.
        let flag = operation?.checkoutFlag(for: side) ?? (side == .mine ? "--theirs" : "--ours")
        do {
            try await runChecked(
                ["checkout", flag, "--", path],
                label: "git checkout \(flag)",
                in: url,
                timeout: Self.localWriteTimeout
            )
        } catch let failure as GitFailure where failure.message.contains("does not have") {
            try await runChecked(
                ["rm", "--quiet", "--", path],
                label: "git rm",
                in: url,
                timeout: Self.localWriteTimeout
            )
            return
        }
        try await markResolved(path: path, at: url)
    }

    /// `git add -- <path>` after the conflict markers were edited by hand.
    func markResolved(path: String, at url: URL) async throws {
        try await runChecked(
            ["add", "--", path],
            label: "git add",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    // MARK: - Stash

    func stashList(at url: URL) async throws -> [GitStashEntry] {
        let raw = try await runChecked(
            ["stash", "list", "--format=%gd%x1f%s"],
            label: "git stash list",
            in: url,
            timeout: Self.statusTimeout
        )
        return Self.parseStashList(raw)
    }

    /// `git stash push --include-untracked`, so new files are set aside too.
    func stash(at url: URL, message: String) async throws {
        try await runChecked(
            ["stash", "push", "--include-untracked", "-m", message],
            label: "git stash",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// `git stash pop`. Git keeps the entry when reapplying it conflicts.
    @discardableResult
    func popStash(_ reference: String, at url: URL) async throws -> String {
        try await runReporting(
            ["stash", "pop", reference],
            label: "git stash pop",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    func dropStash(_ reference: String, at url: URL) async throws {
        try await runChecked(
            ["stash", "drop", reference],
            label: "git stash drop",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    // MARK: - Branches

    /// Local branches and remote-tracking branches, newest commit first.
    func branches(at url: URL) async throws -> [GitBranchRef] {
        let raw = try await runChecked(
            [
                "for-each-ref", "--sort=-committerdate",
                "--format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)",
                "refs/heads", "refs/remotes"
            ],
            label: "git for-each-ref",
            in: url,
            timeout: Self.statusTimeout
        )
        return Self.parseBranches(raw)
    }

    /// `git switch <branch>`. Uncommitted changes come along unless they
    /// conflict with the other branch, in which case git refuses.
    func switchBranch(_ name: String, at url: URL) async throws {
        try await runChecked(
            ["switch", name],
            label: "git switch",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    /// `git switch --track <remote>/<branch>`: a local branch for a branch
    /// another machine pushed.
    func trackRemoteBranch(_ remoteName: String, at url: URL) async throws {
        try await runChecked(
            ["switch", "--track", remoteName],
            label: "git switch --track",
            in: url,
            timeout: Self.localWriteTimeout
        )
    }

    // MARK: - Parsing

    /// Parses `git log --format=%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e`.
    static func parseLog(_ raw: String) -> [GitCommitSummary] {
        raw.split(separator: "\u{1e}").compactMap { record in
            let fields = record
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty else { return nil }
            return GitCommitSummary(
                hash: String(fields[0]),
                shortHash: String(fields[1]),
                subject: String(fields[2]),
                author: String(fields[3]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)
            )
        }
    }

    /// Parses `git for-each-ref` output in the format `branches(at:)` asks for.
    static func parseBranches(_ raw: String) -> [GitBranchRef] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let refname = fields[0]
            // `refs/remotes/origin/HEAD` only points at the default branch.
            if refname.hasSuffix("/HEAD") { return nil }
            let upstream = String(fields[2])
            return GitBranchRef(
                name: String(fields[1]),
                isRemote: refname.hasPrefix("refs/remotes/"),
                upstream: upstream.isEmpty ? nil : upstream,
                lastCommitDate: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    /// Parses `git stash list --format=%gd%x1f%s`.
    static func parseStashList(_ raw: String) -> [GitStashEntry] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return GitStashEntry(reference: String(fields[0]), message: String(fields[1]))
        }
    }


    /// Parses `git status --porcelain=v2 --branch -z`.
    ///
    /// Records are NUL terminated. Rename and copy records (type `2`) are followed
    /// by one extra NUL terminated field holding the original path.
    static func parseStatus(
        _ raw: String,
        remotes: [String],
        operation: GitOperation?
    ) -> GitStatus {
        var status = GitStatus.empty
        status.remotes = remotes
        status.operation = operation

        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1

            if field.hasPrefix("# ") {
                apply(header: String(field.dropFirst(2)), to: &status)
                continue
            }

            switch field.first {
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                let flags = decodeXY(String(parts[1]))
                status.changes.append(
                    GitFileChange(
                        path: String(parts[8]),
                        originalPath: nil,
                        kind: flags.kind,
                        isStaged: flags.isStaged,
                        isUnstaged: flags.isUnstaged
                    )
                )

            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\0<origPath>
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                let flags = decodeXY(String(parts[1]))
                var originalPath: String?
                if index < fields.count {
                    originalPath = fields[index]
                    index += 1
                }
                status.changes.append(
                    GitFileChange(
                        path: String(parts[9]),
                        originalPath: originalPath,
                        kind: parts[8].hasPrefix("C") ? .copied : .renamed,
                        isStaged: flags.isStaged,
                        isUnstaged: flags.isUnstaged
                    )
                )

            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.changes.append(
                    GitFileChange(
                        path: String(parts[10]),
                        originalPath: nil,
                        kind: .conflicted,
                        isStaged: false,
                        isUnstaged: true
                    )
                )

            case "?":
                let path = String(field.dropFirst(2))
                guard !path.isEmpty else { continue }
                status.changes.append(
                    GitFileChange(
                        path: path,
                        originalPath: nil,
                        kind: .untracked,
                        isStaged: false,
                        isUnstaged: true
                    )
                )

            default:
                // "!" is an ignored file; nothing else is expected.
                continue
            }
        }

        status.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    private static func apply(header: String, to status: inout GitStatus) {
        let tokens = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard tokens.count == 2 else { return }
        let value = String(tokens[1]).trimmingCharacters(in: .whitespaces)

        switch tokens[0] {
        case "branch.oid":
            status.hasCommits = value != "(initial)"
            status.headOID = status.hasCommits ? value : nil
        case "stash":
            status.stashCount = Int(value) ?? 0
        case "branch.head":
            if value == "(detached)" {
                status.isDetached = true
            } else {
                status.branch = value
            }
        case "branch.upstream":
            status.upstream = value.isEmpty ? nil : value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") {
                    status.ahead = Int(token.dropFirst()) ?? 0
                } else if token.hasPrefix("-") {
                    status.behind = Int(token.dropFirst()) ?? 0
                }
            }
        default:
            break
        }
    }

    /// Decodes the two-character staged/unstaged status field.
    private static func decodeXY(_ xy: String) -> (kind: FileChangeKind, isStaged: Bool, isUnstaged: Bool) {
        let characters = Array(xy)
        let staged: Character = characters.count > 0 ? characters[0] : "."
        let unstaged: Character = characters.count > 1 ? characters[1] : "."
        let isStaged = staged != "."
        let isUnstaged = unstaged != "."

        let kind: FileChangeKind
        switch isStaged ? staged : unstaged {
        case "A": kind = .added
        case "M": kind = .modified
        case "D": kind = .deleted
        case "R": kind = .renamed
        case "C": kind = .copied
        case "T": kind = .typeChanged
        case "U": kind = .conflicted
        default: kind = .modified
        }
        return (kind, isStaged, isUnstaged)
    }

    /// Parses `git diff --numstat` lines of the form `<added>\t<removed>\t<path>`.
    static func parseNumstat(_ raw: String) -> [FileDiffStat] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return FileDiffStat(
                path: String(parts[2]),
                // Binary files report "-" instead of a count.
                insertions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0
            )
        }
    }
}
