import Darwin
import Foundation

nonisolated protocol RunningServerServicing: Sendable {
    func discover(projects: [Repository]) async throws -> [RunningServer]
    func stop(_ server: RunningServer, force: Bool) async throws
}

/// Reads this user's TCP listeners through libproc. Nothing is executed in a
/// shell, and command arguments are never displayed, logged, or persisted.
actor RunningServerService: RunningServerServicing {
    private nonisolated struct ProcessRecord {
        let identity: ServerProcessIdentity
        let parentID: Int32
        let directory: String?
        var executableName: String { URL(fileURLWithPath: identity.executable).lastPathComponent.lowercased() }
        var isShell: Bool { ["sh", "bash", "zsh", "fish", "dash"].contains(executableName) }
        var isRuntime: Bool {
            ["node", "nodejs", "bun", "deno", "ruby", "php", "java", "dotnet", "go", "uvicorn", "gunicorn", "vite", "next-server"].contains(executableName)
                || executableName == "python" || executableName.hasPrefix("python3")
        }
    }

    func discover(projects: [Repository]) async throws -> [RunningServer] {
        let processes = try Self.processes()
        let roots = projects.map { (path: $0.canonicalPath, name: $0.name) }
            .sorted { $0.path.count > $1.path.count }
        var groups: [ServerProcessIdentity: RunningServer] = [:]

        for record in processes.values {
            try Task.checkCancellation()
            let project = record.directory.flatMap { directory in
                roots.first { directory == $0.path || directory.hasPrefix($0.path + "/") }
            }
            guard record.isRuntime || project != nil else { continue }
            let ports = Self.listeningPorts(pid: record.identity.pid)
            guard !ports.isEmpty, Self.matches(record.identity) else { continue }

            let launcher = Self.launcher(for: record, in: processes)
            let existing = groups[launcher.identity]
            let runtime = Self.launchLabel(pid: launcher.identity.pid) ?? Self.runtimeName(record.executableName)
            groups[launcher.identity] = RunningServer(
                process: launcher.identity,
                listeners: (existing?.listeners ?? []) + [record.identity],
                ports: Array(Set((existing?.ports ?? []) + ports)).sorted(),
                workingDirectory: record.directory,
                projectName: project?.name,
                runtime: runtime
            )
        }
        return groups.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.process.pid < $1.process.pid : order == .orderedAscending
        }
    }

    func stop(_ server: RunningServer, force: Bool = false) async throws {
        try Task.checkCancellation()
        let snapshot = try Self.processes()
        guard Self.matches(server.process),
              server.listeners.contains(where: { identity in
                  Self.matches(identity) && !Set(Self.listeningPorts(pid: identity.pid)).isDisjoint(with: server.ports)
              }) else { throw RunningServerError.processChanged }

        // Stop a recognized npm/npx launcher and its descendants individually.
        // A terminal's process group can contain unrelated jobs; never signal it.
        var family = Set([server.process.pid])
        var changed = true
        while changed {
            changed = false
            for record in snapshot.values where family.contains(record.parentID) {
                if family.insert(record.identity.pid).inserted { changed = true }
            }
        }
        let descendants = snapshot.values.filter { family.contains($0.identity.pid) && $0.identity != server.process }
        let targets = [server.process] + descendants.map(\.identity)
        for identity in targets where Self.matches(identity) {
            if Darwin.kill(identity.pid, force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
                throw RunningServerError.permissionDenied
            }
        }

        let deadline = Date().addingTimeInterval(2)
        repeat {
            if !targets.contains(where: { Self.matches($0) && !Self.listeningPorts(pid: $0.pid).isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw RunningServerError.stillRunning
    }

    nonisolated private static func processes() throws -> [Int32: ProcessRecord] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw RunningServerError.inspectionUnavailable }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { throw RunningServerError.inspectionUnavailable }
        var result: [Int32: ProcessRecord] = [:]
        for pid in pids.prefix(min(Int(actual), pids.count)) where pid > 1 && pid != getpid() {
            guard let identity = identity(pid: pid), let info = bsdInfo(pid: pid) else { continue }
            result[pid] = ProcessRecord(identity: identity, parentID: Int32(info.pbi_ppid), directory: workingDirectory(pid: pid))
        }
        return result
    }

    nonisolated private static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return nil }
        return info
    }

    nonisolated private static func identity(pid: Int32) -> ServerProcessIdentity? {
        guard pid > 1, pid != getpid(), let info = bsdInfo(pid: pid) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a sizeof-based C macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return ServerProcessIdentity(pid: pid, userID: info.pbi_uid,
            startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec,
            executable: String(cString: path))
    }

    nonisolated private static func matches(_ expected: ServerProcessIdentity) -> Bool {
        expected.userID == getuid() && identity(pid: expected.pid) == expected
    }

    nonisolated private static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func listeningPorts(pid: Int32) -> [UInt16] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes < 4_194_304 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        let actual = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard actual > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in descriptors.prefix(min(Int(actual) / MemoryLayout<proc_fdinfo>.stride, descriptors.count))
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    nonisolated private static func launcher(for listener: ProcessRecord, in processes: [Int32: ProcessRecord]) -> ProcessRecord {
        var selected = listener
        var cursor = listener
        var visited = Set([listener.identity.pid])
        for _ in 0..<16 {
            guard let parent = processes[cursor.parentID], visited.insert(parent.identity.pid).inserted,
                  parent.directory == listener.directory else { break }
            if parent.isShell {
                cursor = parent
            } else if parent.isRuntime, launchLabel(pid: parent.identity.pid) != nil {
                selected = parent
                cursor = parent
            } else {
                break
            }
        }
        return selected
    }

    /// Read only argv from KERN_PROCARGS2; the following environment block is
    /// ignored. Return a fixed tool label rather than possibly sensitive flags.
    nonisolated private static func launchLabel(pid: Int32) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 16_384 else { return nil }
        var cursor = 4
        while cursor < size && bytes[cursor] != 0 { cursor += 1 }
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<min(Int(count), 4) {
            let start = cursor
            while cursor < size && bytes[cursor] != 0 { cursor += 1 }
            guard cursor <= size else { break }
            arguments.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
            if cursor >= size { break }
        }
        guard let first = arguments.first else { return nil }
        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        if executable.hasPrefix("npm exec") || executable.hasPrefix("npx ") { return "npx" }
        for tool in ["npm", "pnpm", "yarn"] where executable == tool || executable.hasPrefix(tool + " ") { return tool }
        let entry = arguments.dropFirst().first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        if executable == "bun", let entry, ["run", "x", "--watch", "--hot"].contains(entry) { return "Bun" }
        switch entry {
        case "npm-cli.js": return "npm"
        case "npx-cli.js": return "npx"
        case "pnpm.cjs", "pnpm.js": return "pnpm"
        case "yarn.js", "yarn.cjs": return "yarn"
        case "next": return "Next.js"
        case "vite", "vite.js": return "Vite"
        case "astro", "nuxt", "nodemon", "webpack", "react-scripts": return entry
        case "-m" where arguments.count > 2 && ["uvicorn", "gunicorn", "flask"].contains(arguments[2]): return "Python"
        default: return nil
        }
    }

    nonisolated private static func runtimeName(_ executable: String) -> String {
        if executable == "node" || executable == "nodejs" { return "Node" }
        if executable.hasPrefix("python") { return "Python" }
        return executable.capitalized
    }
}
