import Foundation
import Observation

/// API-equivalent cost and token counts from local Claude Code and Codex logs.
@Observable
final class TokenUsageModel {
    private(set) var report: UsageReport?
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    @ObservationIgnored private let scanner = UsageLogScanner()
    /// Logs only grow while a tool is in use, so a minute between scans is plenty.
    @ObservationIgnored private let minimumInterval: TimeInterval = 60

    /// Scans unless a scan finished within the last minute. `force` is for the
    /// refresh button.
    func refresh(claudeDirectories: [URL], force: Bool = false) async {
        guard !isScanning else { return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < minimumInterval { return }
        isScanning = true
        defer { isScanning = false }

        let codex = Self.codexDirectory()
        let claude = Array(Set(claudeDirectories.map(\.standardizedFileURL)))
        let scanner = scanner
        let result = await Task.detached(priority: .utility) {
            await scanner.scan(claudeDirectories: claude, codexDirectories: [codex])
        }.value
        if report != result { report = result }
        lastScan = Date()
    }

    private static func codexDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
}
