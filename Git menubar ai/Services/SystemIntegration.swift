import AppKit
import Foundation

/// Small wrappers around the macOS APIs for picking folders and handing a
/// repository off to Finder or Terminal.
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
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
    }
}

enum SystemIntegrationError: LocalizedError {
    case terminalNotFound

    var errorDescription: String? {
        switch self {
        case .terminalNotFound:
            return "Terminal could not be found on this Mac."
        }
    }
}
