import Foundation

/// The result of running an external command to completion.
nonisolated struct ProcessOutput: Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    var isSuccess: Bool { exitCode == 0 }

    /// Whichever stream carries the diagnostic text, preferring stderr.
    var diagnostics: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not launch the command: \(reason)"
        case .timedOut(let seconds):
            return "The command did not finish within \(seconds) seconds and was cancelled."
        }
    }
}

/// A thin `Process` wrapper that runs a command off the main actor and returns its output.
nonisolated enum ProcessRunner {
    /// Work queue for spawning processes and draining their pipes. Concurrent so that the
    /// stdout and stderr readers of a single process can run at the same time.
    private static let queue = DispatchQueue(
        label: "com.commitbar.process",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let output = try runBlocking(
                        executableURL: executableURL,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeout: timeout
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Never let a command (or a git hook) block waiting on input.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently: a large diff would otherwise fill the
        // 64 KB pipe buffer and deadlock the child before it can exit.
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(outputPipe, outputBox), (errorPipe, errorBox)] {
            readers.enter()
            queue.async {
                box.value = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                readers.leave()
            }
        }

        // The readers finish when the child closes its pipe ends, so waiting on
        // them doubles as waiting for the process itself.
        if readers.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = readers.wait(timeout: .now() + 2)
            throw ProcessRunnerError.timedOut(seconds: Int(timeout))
        }

        process.waitUntilExit()

        return ProcessOutput(
            standardOutput: String(decoding: outputBox.value),
            standardError: String(decoding: errorBox.value),
            exitCode: process.terminationStatus
        )
    }
}

/// Lock-guarded `Data` holder so pipe readers can hand their bytes back across queues.
private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private nonisolated extension String {
    /// Git output is UTF-8, but never trust a repository to contain only valid sequences.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
