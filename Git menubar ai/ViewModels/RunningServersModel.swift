import Foundation
import Observation

@Observable
final class RunningServersModel {
    private(set) var servers: [RunningServer] = []
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var failure: String?
    private(set) var stopping: Set<ServerProcessIdentity> = []
    private(set) var stopFailures: [ServerProcessIdentity: String] = [:]
    private(set) var needsForceStop: Set<ServerProcessIdentity> = []

    private let service: any RunningServerServicing
    private var projects: [Repository] = []
    private var generation = UUID()

    init(service: any RunningServerServicing = RunningServerService()) {
        self.service = service
    }

    func refresh(projects: [Repository]? = nil) async {
        if let projects { self.projects = projects }
        guard !isRefreshing else { return }
        let generation = generation
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let found = try await service.discover(projects: self.projects)
            guard generation == self.generation, !Task.isCancelled else { return }
            servers = found
            failure = nil
            hasLoaded = true
            let ids = Set(found.map(\.id))
            stopFailures = stopFailures.filter { ids.contains($0.key) }
            needsForceStop.formIntersection(ids)
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            failure = (error as? RunningServerError)?.errorDescription ?? "Local servers are temporarily unavailable."
        }
    }

    func stop(_ server: RunningServer, force: Bool = false) async {
        guard !stopping.contains(server.id), servers.contains(where: { $0.id == server.id }) else { return }
        generation = UUID()
        stopping.insert(server.id)
        stopFailures.removeValue(forKey: server.id)
        do {
            try await service.stop(server, force: force)
            needsForceStop.remove(server.id)
            servers.removeAll { $0.id == server.id }
        } catch is CancellationError {
            // The next discovery reconciles the actual process state.
        } catch {
            stopFailures[server.id] = (error as? RunningServerError)?.errorDescription ?? "Could not stop this server."
            if case RunningServerError.stillRunning = error { needsForceStop.insert(server.id) }
        }
        // A discovery started during shutdown must not put the stopped row back.
        generation = UUID()
        stopping.remove(server.id)
        await refresh()
    }
}
