import Foundation

/// Stores AI provider API keys in the login keychain.
///
/// Items are written and read through `/usr/bin/security`, the same way the
/// app reads Claude Code's credentials. An item created by that tool trusts
/// only that tool, so reading it never shows a keychain prompt, even after
/// this ad-hoc signed app is rebuilt. `SecItemAdd` from the app would tie the
/// item to the app's signature and prompt again after every rebuild.
///
/// The key is passed on stdin, never as an argument, so it does not show up
/// in the process list.
nonisolated enum APIKeyStore {
    private static let service = "CodeBarAI AI Provider Key"
    private static let tool = URL(filePath: "/usr/bin/security")
    /// `errSecItemNotFound` as `security`'s exit status.
    private static let notFoundExitCode: Int32 = 44

    static func key(for provider: CommitAIProvider) async throws -> String? {
        let output = try await run(["find-generic-password", "-s", service, "-a", provider.rawValue, "-w"])
        if output.exitCode == notFoundExitCode { return nil }
        guard output.isSuccess else { throw APIKeyStoreError.readFailed(output.diagnostics) }
        let key = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String, for provider: CommitAIProvider) async throws {
        guard !key.isEmpty, !key.contains(where: \.isNewline) else {
            throw APIKeyStoreError.invalidKey
        }
        // `-w` as the last option makes `security` ask for the password, twice,
        // on stdin.
        let input = Data("\(key)\n\(key)\n".utf8)
        let output = try await run(
            [
                "add-generic-password", "-U",
                "-s", service,
                "-a", provider.rawValue,
                "-l", "CodeBarAI \(provider.title) API key",
                "-w"
            ],
            input: input
        )
        guard output.isSuccess else { throw APIKeyStoreError.writeFailed(output.diagnostics) }
    }

    static func delete(for provider: CommitAIProvider) async throws {
        let output = try await run(["delete-generic-password", "-s", service, "-a", provider.rawValue])
        guard output.isSuccess || output.exitCode == notFoundExitCode else {
            throw APIKeyStoreError.writeFailed(output.diagnostics)
        }
    }

    private static func run(_ arguments: [String], input: Data? = nil) async throws -> ProcessOutput {
        do {
            return try await ProcessRunner.run(
                executableURL: tool,
                arguments: arguments,
                standardInput: input,
                timeout: 10
            )
        } catch {
            throw APIKeyStoreError.readFailed(error.localizedDescription)
        }
    }
}

nonisolated enum APIKeyStoreError: LocalizedError {
    case invalidKey
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The API key can't be empty or span several lines."
        case .readFailed(let reason):
            return reason.isEmpty
                ? "Could not read the API key from your keychain."
                : "Could not read the API key from your keychain: \(reason)"
        case .writeFailed(let reason):
            return reason.isEmpty
                ? "Could not save the API key to your keychain."
                : "Could not save the API key to your keychain: \(reason)"
        }
    }
}
