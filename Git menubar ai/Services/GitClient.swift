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
                "status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"
            ],
            label: "git status",
            in: url,
            timeout: Self.statusTimeout
        )

        let remotes = try await remoteNames(at: url)
        let operation = await operationInProgress(at: url)
        return Self.parseStatus(raw, remotes: remotes, operationInProgress: operation)
    }

    private func remoteNames(at url: URL) async throws -> [String] {
        let raw = try await runChecked(["remote"], label: "git remote", in: url, timeout: Self.statusTimeout)
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Detects an interrupted merge, rebase, cherry-pick or revert from the marker
    /// files git leaves in the git directory.
    private func operationInProgress(at url: URL) async -> String? {
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

        if exists("rebase-merge") || exists("rebase-apply") { return "A rebase" }
        if exists("MERGE_HEAD") { return "A merge" }
        if exists("CHERRY_PICK_HEAD") { return "A cherry-pick" }
        if exists("REVERT_HEAD") { return "A revert" }
        return nil
    }

    // MARK: - Diff context for message generation

    func diffContext(at url: URL, status: GitStatus) async throws -> DiffContext {
        var stats: [FileDiffStat] = []
        var patch = ""

        if status.hasCommits {
            let numstat = try? await runChecked(
                ["-c", "core.quotepath=false", "diff", "--numstat", "HEAD"],
                label: "git diff",
                in: url,
                timeout: Self.statusTimeout
            )
            if let numstat { stats = Self.parseNumstat(numstat) }

            let raw = try? await runChecked(
                ["-c", "core.quotepath=false", "diff", "--no-color", "--unified=1", "HEAD"],
                label: "git diff",
                in: url,
                timeout: Self.statusTimeout
            )
            if let raw { patch = String(raw.prefix(6000)) }
        }

        return DiffContext(
            branch: status.branch,
            changes: status.changes,
            stats: stats,
            patchExcerpt: patch
        )
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

    // MARK: - Parsing

    /// Parses `git status --porcelain=v2 --branch -z`.
    ///
    /// Records are NUL terminated. Rename and copy records (type `2`) are followed
    /// by one extra NUL terminated field holding the original path.
    static func parseStatus(
        _ raw: String,
        remotes: [String],
        operationInProgress: String?
    ) -> GitStatus {
        var status = GitStatus.empty
        status.remotes = remotes
        status.operationInProgress = operationInProgress

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
