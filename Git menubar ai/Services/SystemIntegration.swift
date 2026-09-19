import AppKit
import Foundation
import UniformTypeIdentifiers

/// Small wrappers around the macOS APIs for picking folders and handing a
/// repository off to development tools.
enum SystemIntegration {
    /// Presents a folder picker. Returns `nil` when the user cancels.
    static func chooseRepositoryFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder inside the Git repository you want to add."
        panel.prompt = "Add Repository"

        // The menu bar window is not a normal key window, so the app has to be
        // activated for the panel to come forward.
        NSApplication.shared.activate()

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens the repository in a new terminal window with no command typed.
    static func openInTerminal(_ url: URL) async throws {
        try await launch([url], with: preferredTerminalApplication())
    }

    static func openInCursor(projectURL: URL, fileURL: URL? = nil) async throws {
        guard
            let cursor = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            )
        else {
            throw SystemIntegrationError.cursorNotFound
        }

        // Cursor's newer agent-first workbench can treat a bare file or folder
        // as a standalone agent surface. Force the classic IDE workbench and
        // always include the repository folder so cold file launches retain
        // their project context.
        let cli = cursor.appending(path: "Contents/Resources/app/bin/cursor")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw SystemIntegrationError.cursorLaunchFailed(
                "The Cursor editor command is missing from the application bundle."
            )
        }

        var arguments = [
            "--classic",
            "--new-window",
            projectURL.standardizedFileURL.path,
        ]
        if let fileURL {
            arguments.append(fileURL.standardizedFileURL.path)
        }

        let output = try await ProcessRunner.run(
            executableURL: cli,
            arguments: arguments,
            timeout: 10
        )
        guard output.isSuccess else {
            throw SystemIntegrationError.cursorLaunchFailed(output.diagnostics)
        }
    }

    /// Opens the repository as a workspace in the native Codex desktop app.
    static func openInCodex(_ url: URL) async throws {
        guard
            let codex = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            )
        else {
            throw SystemIntegrationError.codexNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: codex,
                configuration: configuration
            )
        } catch {
            throw SystemIntegrationError.codexLaunchFailed(error.localizedDescription)
        }
    }

    /// Opens a new terminal window in the repository and starts Claude Code's
    /// interactive session there.
    static func openInClaudeCode(_ url: URL) async throws {
        let directories = try await resolve(
            tool: "claude",
            hint: "Install Claude Code, then try again."
        )
        try await runInTerminal(
            "claude",
            at: url,
            windowTitle: "Claude Code — \(url.lastPathComponent)",
            pathAdditions: directories
        )
    }

    /// Opens a new terminal window in the repository and starts its development
    /// server, installing dependencies first when they are missing.
    static func startDevServer(_ server: DevServer, at url: URL) async throws {
        let manager = server.packageManager.rawValue
        let directories = try await resolve(
            tool: manager,
            hint: "Install \(manager), or open the project and start the server yourself."
        )
        try await runInTerminal(
            server.shellCommand,
            at: url,
            windowTitle: "\(server.title) — \(url.lastPathComponent)",
            pathAdditions: directories
        )
    }

    // MARK: - Running a command in a terminal window

    /// Starts `command` in a new terminal window whose working directory is `url`.
    ///
    /// The command is written to a throwaway `.command` script that the terminal
    /// is asked to open. Driving Terminal with AppleScript instead would make
    /// this an Apple Event, which macOS gates behind an automation permission
    /// prompt that returns after every rebuild of an ad-hoc signed app.
    /// Opening a document needs no permission at all.
    private static func runInTerminal(
        _ command: String,
        at url: URL,
        windowTitle: String,
        pathAdditions: [String] = []
    ) async throws {
        let script = try writeLaunchScript(
            command: command,
            directory: url,
            windowTitle: windowTitle,
            pathAdditions: pathAdditions
        )
        try await launch([script], with: preferredTerminalApplication(forOpening: script))
    }

    /// The script runs the command through the user's own interactive shell, so
    /// tools set up in `.zshrc` (nvm, mise, asdf) resolve exactly as they do in
    /// a terminal window the user opened. Any directory we already resolved is
    /// prepended to PATH as a backstop, and the window is left at a prompt in
    /// the repository once the command exits.
    private static func writeLaunchScript(
        command: String,
        directory: URL,
        windowTitle: String,
        pathAdditions: [String]
    ) throws -> URL {
        let folder = try launchScriptsDirectory()
        pruneLaunchScripts(in: folder)

        var lines = [
            "#!/bin/sh",
            "# Written by CodeBarAI to start a command in this window. Safe to delete.",
            "cd \(quoted(directory.standardizedFileURL.path)) || exit 1",
        ]
        if !pathAdditions.isEmpty {
            let prefix = pathAdditions.map(quoted).joined(separator: ":")
            lines.append("PATH=\(prefix):\"$PATH\"")
            lines.append("export PATH")
        }
        lines.append(contentsOf: [
            // Name the window after the task rather than the throwaway script.
            "printf '\\033]0;%s\\007' \(quoted(windowTitle))",
            "\"${SHELL:-/bin/zsh}\" -i -c \(quoted(command))",
            "exec \"${SHELL:-/bin/zsh}\" -i",
            "",
        ])

        let script = folder.appending(path: "\(slug(windowTitle))-\(UUID().uuidString.prefix(8)).command")
        try Data(lines.joined(separator: "\n").utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        return script
    }

    private static func launchScriptsDirectory() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = caches
            .appending(path: Bundle.main.bundleIdentifier ?? "CodeBarAI", directoryHint: .isDirectory)
            .appending(path: "TerminalLaunches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A terminal only reads the script as it opens it, so yesterday's scripts
    /// are dead weight. Deleting on a delay instead would race the launch.
    private static func pruneLaunchScripts(in folder: URL) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let contents = try? files.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        for file in contents ?? [] {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? files.removeItem(at: file)
        }
    }

    // MARK: - Terminal application

    /// Terminals that run a `.command` file when it is opened. The user's own
    /// default handler wins when it is one of these, so replacing Terminal.app
    /// keeps working; anything else falls back to Terminal.
    private static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
    ]

    private static func preferredTerminalApplication(forOpening script: URL? = nil) throws -> URL {
        guard
            let terminal = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal"
            )
        else {
            throw SystemIntegrationError.terminalNotFound
        }

        let handler = script.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            ?? UTType(filenameExtension: "command").flatMap {
                NSWorkspace.shared.urlForApplication(toOpen: $0)
            }
        guard
            let handler,
            let identifier = Bundle(url: handler)?.bundleIdentifier,
            knownTerminals.contains(identifier)
        else {
            return terminal
        }
        return handler
    }

    /// Opens `urls` with `application`, retrying with Terminal.app when a
    /// replacement terminal refuses the document.
    private static func launch(_ urls: [URL], with application: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.open(
                urls,
                withApplicationAt: application,
                configuration: configuration
            )
        } catch {
            guard
                let terminal = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Terminal"
                ),
                terminal != application
            else {
                throw SystemIntegrationError.terminalLaunchFailed(error.localizedDescription)
            }
            do {
                _ = try await NSWorkspace.shared.open(
                    urls,
                    withApplicationAt: terminal,
                    configuration: configuration
                )
            } catch {
                throw SystemIntegrationError.terminalLaunchFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Locating command line tools

    /// Directories already resolved this session, keyed by tool name. A tool
    /// that moved is caught by the existence check before its entry is reused.
    private static var resolvedToolDirectories: [String: [String]] = [:]

    /// Finds `tool` the way the user's shell would and returns the directory to
    /// prepend to PATH in the launch script, so a missing tool is a clear
    /// message instead of a terminal window that prints `command not found`.
    /// The result is empty when the tool is only a shell alias or function,
    /// which the interactive shell in the launch script resolves by itself.
    private static func resolve(tool: String, hint: String) async throws -> [String] {
        if let cached = resolvedToolDirectories[tool], isUsable(cached, named: tool) {
            return cached
        }

        var directories: [String]?
        if let url = installedLocations(for: tool).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            directories = [url.deletingLastPathComponent().path]
        } else {
            directories = await locateUsingLoginShell(tool)
        }

        guard let directories else {
            throw SystemIntegrationError.toolNotFound(name: tool, hint: hint)
        }
        resolvedToolDirectories[tool] = directories
        return directories
    }

    private static func isUsable(_ directories: [String], named tool: String) -> Bool {
        guard let directory = directories.first else { return true }
        return FileManager.default.isExecutableFile(
            atPath: URL(filePath: directory).appending(path: tool).path
        )
    }

    /// Where package managers and AI tools install by default. A bundled app
    /// inherits a bare PATH, so these are checked before paying for a shell.
    private static func installedLocations(for tool: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            home.appending(path: ".local/bin"),
            home.appending(path: ".claude/local"),
            URL(filePath: "/opt/homebrew/bin"),
            URL(filePath: "/usr/local/bin"),
            home.appending(path: ".bun/bin"),
            home.appending(path: ".volta/bin"),
            home.appending(path: "Library/pnpm"),
            home.appending(path: ".yarn/bin"),
            home.appending(path: ".npm-global/bin"),
            home.appending(path: "bin"),
            URL(filePath: "/usr/bin"),
        ]
        // The app's own PATH is short, but it costs nothing to honor it.
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)) }

        return directories.map { $0.appending(path: tool) }
    }

    /// Last resort: ask the user's login shell, which knows about version
    /// managers that install into paths no one can guess. Returns `nil` only
    /// when the shell cannot find the tool either.
    private static func locateUsingLoginShell(_ tool: String) async -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let output = try? await ProcessRunner.run(
            executableURL: URL(filePath: shell),
            arguments: ["-ilc", "command -v \(tool)"],
            timeout: 10
        )
        guard let output, output.isSuccess else { return nil }

        let found = output.standardOutput
            .split(separator: "\n")
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !found.isEmpty else { return nil }
        // An alias or a shell function has no directory of its own.
        guard found.hasPrefix("/") else { return [] }
        return [URL(filePath: found).deletingLastPathComponent().path]
    }

    // MARK: - Shell text

    /// Wraps a value so a POSIX shell reads it as one literal word.
    private nonisolated static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A file-name-safe stem, so the scripts folder stays readable.
    private nonisolated static func slug(_ title: String) -> String {
        let allowed = title.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "CodeBarAI" : String(slug.prefix(40))
    }

}

enum SystemIntegrationError: LocalizedError {
    case cursorNotFound
    case cursorLaunchFailed(String)
    case terminalNotFound
    case terminalLaunchFailed(String)
    case toolNotFound(name: String, hint: String)
    case codexNotFound
    case codexLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cursorNotFound:
            return "Cursor could not be found on this Mac."
        case .cursorLaunchFailed(let reason):
            return reason.isEmpty
                ? "Cursor could not open this project folder."
                : "Cursor could not open this project folder: \(reason)"
        case .terminalNotFound:
            return "Terminal could not be found on this Mac."
        case .terminalLaunchFailed(let reason):
            return reason.isEmpty
                ? "The terminal could not be opened."
                : "The terminal could not be opened: \(reason)"
        case .toolNotFound(let name, let hint):
            return "“\(name)” was not found in your shell’s PATH. \(hint)"
        case .codexNotFound:
            return "Codex could not be found on this Mac. Install the Codex desktop app and try again."
        case .codexLaunchFailed(let reason):
            return reason.isEmpty
                ? "Codex could not open this repository."
                : "Codex could not open this repository: \(reason)"
        }
    }
}
