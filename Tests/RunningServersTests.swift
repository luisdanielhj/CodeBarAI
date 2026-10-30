import Darwin
import Foundation

/// Only signals processes created by these tests. Existing servers may be
/// discovered, but their PIDs are never passed to a stop operation.
@main
struct RunningServersTests {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Pass node and npm executable paths") }
        let node = URL(fileURLWithPath: CommandLine.arguments[1])
        let npm = URL(fileURLWithPath: CommandLine.arguments[2])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codebar-server-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = Fixtures(node: node, npm: npm, folder: folder)
        defer {
            fixtures.cleanUp()
            try? FileManager.default.removeItem(at: folder)
        }
        try fixtures.writeScript()
        let direct = try await fixtures.start(mode: "serve", name: "direct-project")
        let grouped = try await fixtures.start(mode: "parent", name: "npx-project")
        let npmJob = try await fixtures.start(mode: "npm", name: "npm-project")
        let stubborn = try await fixtures.start(mode: "stubborn", name: "stubborn-project")
        let udp = try await fixtures.start(mode: "udp", name: "udp-process")
        let service = RunningServerService()
        let projects = [Repository(path: direct.directory.path), Repository(path: grouped.directory.path)]
        let servers = try await service.discover(projects: projects)
        let directServer = try require(servers.first { $0.process.pid == direct.pid }, "Discover a Node server started outside CodeBar")
        try check(directServer.ports == direct.ports.sorted(), "Collect all ports on one process without duplicating its row")
        try check(directServer.projectName == "direct-project", "Match the server to its project directory")
        try check(!servers.contains { $0.process.pid == udp.pid }, "Exclude UDP and processes without TCP listeners")
        let groupedServer = try require(servers.first { $0.process.pid == grouped.parentPID }, "Group an npx launcher with its server child")
        try check(groupedServer.listeners.contains { $0.pid == grouped.pid }, "Keep the real listener identity for stopping")
        try check(groupedServer.runtime == "npx", "Show a fixed tool label rather than possibly sensitive command flags")
        try check(directServer.localURL(port: direct.ports[0])?.host == "localhost", "Build a local browser link")
        let unknownPort: UInt16 = direct.ports.contains(1) ? 2 : 1
        try check(directServer.localURL(port: unknownPort) == nil, "Do not open an unreported port")

        let old = directServer.process
        let wrongIdentity = ServerProcessIdentity(pid: old.pid, userID: old.userID,
            startedSeconds: old.startedSeconds + 1, startedMicroseconds: old.startedMicroseconds, executable: old.executable)
        let stale = RunningServer(process: wrongIdentity, listeners: directServer.listeners, ports: directServer.ports,
            workingDirectory: directServer.workingDirectory, projectName: directServer.projectName, runtime: directServer.runtime)
        do {
            try await service.stop(stale, force: false)
            throw CheckFailure(message: "A stale PID identity must never be signalled")
        } catch RunningServerError.processChanged { }
        let afterStale = try await service.discover(projects: projects)
        try check(afterStale.contains { $0.process.pid == direct.pid }, "A stale stop leaves the live process running")

        // The fixture launcher intentionally does not forward SIGTERM, so the
        // service must also stop the child rather than leave an orphan server.
        try check(fixtures.owns(groupedServer), "Only stop this test's launcher")
        try await service.stop(groupedServer, force: false)
        let afterGroupStop = try await service.discover(projects: projects)
        try check(!afterGroupStop.contains { $0.listeners.contains { $0.pid == grouped.pid } }, "Stopping an npx job also closes the child server")
        try check(afterGroupStop.contains { $0.process.pid == direct.pid }, "Stopping one job leaves another project running")

        let npmServer = try require(afterGroupStop.first { $0.process.pid == npmJob.parentPID }, "Find the real npm run dev launcher across its intermediate shell")
        try check(fixtures.owns(npmServer), "Only stop this test's npm job")
        try await service.stop(npmServer, force: false)
        let afterNpmStop = try await service.discover(projects: projects)
        try check(!afterNpmStop.contains { $0.listeners.contains { $0.pid == npmJob.pid } }, "Stopping npm also stops its actual Node listener")

        let model = RunningServersModel(service: service)
        await model.refresh(projects: projects)
        let stubbornServer = try require(model.servers.first { $0.process.pid == stubborn.pid }, "Detect runtimes outside saved projects")
        try check(fixtures.owns(stubbornServer), "Only stop this test's stubborn server")
        await model.stop(stubbornServer)
        try check(model.needsForceStop.contains(stubbornServer.id), "Offer Force Stop only after graceful termination fails")
        try check(model.stopFailures[stubbornServer.id] != nil && model.stopping.isEmpty, "Explain the failure and reset the busy state")
        await model.stop(stubbornServer, force: true)
        try check(!model.servers.contains { $0.id == stubbornServer.id }, "Force Stop removes an unresponsive server")
        try check(!model.needsForceStop.contains(stubbornServer.id), "Clear stale force-stop state")
        let remaining = try require(model.servers.first { $0.process.pid == direct.pid }, "Keep the other server running after force-stop")
        try check(fixtures.owns(remaining), "Only stop this test's direct server")
        await model.stop(remaining)
        try check(!model.servers.contains { $0.id == remaining.id }, "Graceful Stop refreshes the list immediately")
        try await staleRefresh(server: directServer)
        print("PASS: live TCP discovery, multiple ports, real npm/npx grouping, project matching, UDP exclusion, stale-PID protection, graceful/force stop, unrelated-server isolation, and refresh races")
    }

    @MainActor
    static func staleRefresh(server: RunningServer) async throws {
        let service = HeldDiscoveryService(server: server)
        let model = RunningServersModel(service: service)
        await model.refresh()
        await service.holdNextDiscovery()
        let refresh = Task { await model.refresh() }
        await service.waitForHeldDiscovery()
        await model.stop(server)
        try check(model.servers.isEmpty, "A successful stop removes the row even while an older scan is still running")
        await service.releaseDiscovery()
        await refresh.value
        try check(model.servers.isEmpty, "A late discovery must not restore a stopped server")
    }

    struct CheckFailure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure(message: message) }
        return value
    }
}

@MainActor
private final class Fixtures {
    struct Ready: Decodable {
        let pid: Int32
        let ports: [UInt16]
    }
    struct Server {
        let pid: Int32
        let parentPID: Int32
        let ports: [UInt16]
        let directory: URL
    }

    let node: URL
    let npm: URL
    let folder: URL
    private var children: [Process] = []
    private var identities: [Int32: (seconds: UInt64, microseconds: UInt64)] = [:]
    private var script: URL { folder.appendingPathComponent("server.cjs") }

    init(node: URL, npm: URL, folder: URL) {
        self.node = node
        self.npm = npm
        self.folder = folder
    }

    func writeScript() throws {
        try Data(#"""
const fs = require('node:fs');
const http = require('node:http');
const { spawn } = require('node:child_process');
const [mode, ready] = process.argv.slice(2);
setTimeout(() => process.exit(0), 60000).unref();
if (mode === 'parent') {
  process.title = 'npm exec http-server --token=synthetic-test-value';
  spawn(process.execPath, [__filename, 'serve', ready], { cwd: process.cwd(), stdio: 'ignore' });
  process.on('SIGTERM', () => process.exit(0));
  setInterval(() => {}, 1000);
} else if (mode === 'udp') {
  const socket = require('node:dgram').createSocket('udp4');
  socket.bind(0, '127.0.0.1', () => fs.writeFileSync(ready, JSON.stringify({pid:process.pid, ports:[socket.address().port]})));
} else {
  if (mode === 'stubborn') process.on('SIGTERM', () => {});
  const ports = [];
  for (let index = 0; index < 2; index++) {
    const server = http.createServer((req,res) => res.end('CodeBar isolated fixture'));
    server.listen(0, '127.0.0.1', () => {
      ports.push(server.address().port);
      if (ports.length === 2) fs.writeFileSync(ready, JSON.stringify({pid:process.pid, ports}));
    });
  }
}
"""#.utf8).write(to: script)
    }

    func start(mode: String, name: String) async throws -> Server {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readyURL = directory.appendingPathComponent("ready.json")
        let process = Process()
        if mode == "npm" {
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = "\(quote(node.path)) \(quote(script.path)) serve \(quote(readyURL.path))"
            let manifest = try JSONSerialization.data(withJSONObject: ["scripts": ["dev": command]])
            try manifest.write(to: directory.appendingPathComponent("package.json"))
            process.executableURL = npm
            process.arguments = ["run", "dev", "--silent"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = node.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["npm_config_update_notifier"] = "false"
            process.environment = environment
        } else {
            process.executableURL = node
            process.arguments = [script.path, mode, readyURL.path]
        }
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        children.append(process)
        remember(process.processIdentifier)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let data = try? Data(contentsOf: readyURL), let ready = try? JSONDecoder().decode(Ready.self, from: data) {
                remember(ready.pid)
                return Server(pid: ready.pid, parentPID: process.processIdentifier, ports: ready.ports, directory: directory)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RunningServersTests.CheckFailure(message: "Node fixture did not start")
    }

    func owns(_ server: RunningServer) -> Bool { identities[server.process.pid] != nil }

    private func remember(_ pid: Int32) {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            identities[pid] = (info.pbi_start_tvsec, info.pbi_start_tvusec)
        }
    }

    func cleanUp() {
        for (pid, expected) in identities {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
               info.pbi_uid == getuid(), info.pbi_start_tvsec == expected.seconds, info.pbi_start_tvusec == expected.microseconds {
                Darwin.kill(pid, SIGKILL)
            }
        }
        for process in children { process.waitUntilExit() }
    }
}

private actor HeldDiscoveryService: RunningServerServicing {
    let server: RunningServer
    private var shouldHold = false
    private var held: CheckedContinuation<[RunningServer], Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var stopped = false

    init(server: RunningServer) { self.server = server }

    func discover(projects: [Repository]) async throws -> [RunningServer] {
        if shouldHold {
            shouldHold = false
            return await withCheckedContinuation {
                held = $0
                observer?.resume()
                observer = nil
            }
        }
        return stopped ? [] : [server]
    }

    func stop(_ server: RunningServer, force: Bool) async throws { stopped = true }
    func holdNextDiscovery() { shouldHold = true }
    func waitForHeldDiscovery() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseDiscovery() {
        held?.resume(returning: [server])
        held = nil
    }
}
