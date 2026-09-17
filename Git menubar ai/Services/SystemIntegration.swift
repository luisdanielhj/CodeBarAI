import AppKit
import Foundation

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

    static func openInTerminal(_ url: URL) async throws {
        guard
            let terminal = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal"
            )
        else {
            throw SystemIntegrationError.terminalNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(
            [url],
            withApplicationAt: terminal,
            configuration: configuration
        )
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

    /// Opens a new Terminal window in the repository and starts Claude Code's
    /// interactive session there.
    static func openInClaudeCode(_ url: URL) async throws {
        let output = try await runInTerminal("claude", at: url)
        guard output.isSuccess else {
            throw SystemIntegrationError.claudeCodeLaunchFailed(output.diagnostics)
        }
    }

    /// Opens a new Terminal window in the repository and starts its development
    /// server, installing dependencies first when they are missing.
    static func startDevServer(_ server: DevServer, at url: URL) async throws {
        let output = try await runInTerminal(server.shellCommand, at: url)
        guard output.isSuccess else {
            throw SystemIntegrationError.devServerLaunchFailed(output.diagnostics)
        }
    }

    /// Types `command` into a new Terminal window after changing into `url`.
    /// Using Terminal's login shell lets tools like `claude`, `node` and `pnpm`
    /// resolve from the same PATH the user has when opening Terminal normally.
    private static func runInTerminal(_ command: String, at url: URL) async throws -> ProcessOutput {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) != nil else {
            throw SystemIntegrationError.terminalNotFound
        }

        let script = """
        on run argv
            set repositoryPath to item 1 of argv
            set command to item 2 of argv
            tell application "Terminal"
                activate
                do script "cd " & quoted form of repositoryPath & " && " & command
            end tell
        end run
        """
        return try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, url.path, command],
            timeout: 10
        )
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
}

enum SystemIntegrationError: LocalizedError {
    case cursorNotFound
    case cursorLaunchFailed(String)
    case terminalNotFound
    case claudeCodeLaunchFailed(String)
    case devServerLaunchFailed(String)
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
        case .claudeCodeLaunchFailed(let reason):
            return reason.isEmpty
                ? "Claude Code could not be started in Terminal."
                : "Claude Code could not be started in Terminal: \(reason)"
        case .devServerLaunchFailed(let reason):
            return reason.isEmpty
                ? "The server could not be started in Terminal."
                : "The server could not be started in Terminal: \(reason)"
        case .codexNotFound:
            return "Codex could not be found on this Mac. Install the Codex desktop app and try again."
        case .codexLaunchFailed(let reason):
            return reason.isEmpty
                ? "Codex could not open this repository."
                : "Codex could not open this repository: \(reason)"
        }
    }
}
