import Foundation

/// A Git repository the user added by hand. Only the worktree root is persisted.
nonisolated struct Repository: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Absolute path to the top level of the worktree.
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    var url: URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }

    var name: String {
        let component = url.lastPathComponent
        return component.isEmpty ? path : component
    }

    /// Path shown in the UI, with the home directory abbreviated.
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
