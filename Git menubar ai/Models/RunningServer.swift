import Foundation

/// Start time and executable distinguish a live process from a reused PID.
nonisolated struct ServerProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let userID: UInt32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let executable: String
}

nonisolated struct RunningServer: Identifiable, Sendable {
    let process: ServerProcessIdentity
    let listeners: [ServerProcessIdentity]
    let ports: [UInt16]
    let workingDirectory: String?
    let projectName: String?
    let runtime: String

    var id: ServerProcessIdentity { process }
    var title: String {
        projectName ?? workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? runtime
    }
    var portDescription: String { ports.map { ":\($0)" }.joined(separator: ", ") }

    func localURL(port: UInt16) -> URL? {
        guard ports.contains(port) else { return nil }
        return URL(string: "http://localhost:\(port)")
    }
}

nonisolated enum RunningServerError: Error, LocalizedError, Sendable {
    case inspectionUnavailable
    case processChanged
    case permissionDenied
    case stillRunning

    var errorDescription: String? {
        switch self {
        case .inspectionUnavailable: return "Could not read local server processes. Try refreshing."
        case .processChanged: return "This server stopped or changed. The list has been refreshed."
        case .permissionDenied: return "macOS did not allow this server to be stopped."
        case .stillRunning: return "The server did not stop. You can try Force Stop."
        }
    }
}
