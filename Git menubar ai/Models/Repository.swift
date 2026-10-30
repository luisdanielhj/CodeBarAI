import Foundation

/// A Git repository the user added by hand, with its most recent local activity.
nonisolated struct Repository: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Absolute path to the top level of the worktree.
    var path: String
    /// Optional so repository lists saved before activity tracking still load.
    var lastWorkedAt: Date?

    init(id: UUID = UUID(), path: String, lastWorkedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.lastWorkedAt = lastWorkedAt
    }

    var url: URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }

    /// A stable path used when comparing repositories. Folder pickers may return
    /// the same directory through a symlink or with redundant path components.
    var canonicalPath: String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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
