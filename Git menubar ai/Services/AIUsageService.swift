import Foundation
import Security
import SQLite3
import CryptoKit

nonisolated enum AIUsageProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, cursor, codex, kiro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .kiro: return "Kiro CLI"
        }
    }

    var logoName: String {
        switch self {
        case .claude: return "ClaudeLogo"
        case .cursor: return "CursorLogo"
        case .codex: return "CodexLogo"
        case .kiro: return "KiroLogo"
        }
    }

    var connectionHint: String {
        switch self {
        case .claude:
            return "Sign in to Claude Code with your subscription. Usage access requires the user:profile scope."
        case .cursor:
            return "Sign in to the Cursor desktop app to read your subscription usage."
        case .codex:
            return "Sign in to Codex with ChatGPT. API keys do not provide subscription limits."
        case .kiro:
            return "Sign in with kiro-cli login. API keys do not provide plan credits."
        }
    }

    /// Detects local installations without launching a process or reading any
    /// credentials. Credential access still happens only when usage refreshes.
    var isInstalled: Bool {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let candidates: [URL]
        let executable: String

        switch self {
        case .claude:
            executable = "claude"
            candidates = [
                home.appendingPathComponent(".claude", isDirectory: true),
                home.appendingPathComponent(".local/bin/claude"),
                home.appendingPathComponent("Applications/Claude.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
            ]
        case .cursor:
            executable = "cursor"
            candidates = [
                home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true),
                home.appendingPathComponent("Applications/Cursor.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Cursor.app", isDirectory: true)
            ]
        case .codex:
            executable = "codex"
            candidates = [
                home.appendingPathComponent(".codex", isDirectory: true),
                home.appendingPathComponent(".local/bin/codex"),
                home.appendingPathComponent("Applications/Codex.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
            ]
        case .kiro:
            // ~/.kiro is shared with the Kiro IDE, so it does not imply the CLI.
            executable = "kiro-cli"
            candidates = [
                home.appendingPathComponent("Library/Application Support/kiro-cli", isDirectory: true),
                home.appendingPathComponent(".local/bin/kiro-cli"),
                URL(fileURLWithPath: "/Applications/Kiro CLI.app", isDirectory: true)
            ]
        }

        if candidates.contains(where: { files.fileExists(atPath: $0.path) }) {
            return true
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executable) }
            .contains(where: { files.isExecutableFile(atPath: $0.path) }) == true
    }
}

nonisolated struct AIUsageWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double?
    let resetsAt: Date?
    let detail: String?
    /// Length of the limit window, used to show how much of it has elapsed.
    var duration: TimeInterval? = nil
}

nonisolated struct AIUsageSnapshot: Sendable {
    let plan: String?
    let windows: [AIUsageWindow]
    let fetchedAt: Date
}

nonisolated enum AIUsageError: Error, LocalizedError, Sendable {
    case signInRequired(AIUsageProvider)
    case credentialAccessDenied(AIUsageProvider)
    case expiredCredentials(AIUsageProvider)
    case missingScope
    case invalidResponse
    case networkUnavailable
    case timedOut
    case redirectRejected
    case serviceUnavailable
    case cancelled
    case rateLimited(Date)

    var retryAt: Date? {
        if case .rateLimited(let date) = self { return date }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired(let provider):
            return "Subscription credentials are unavailable or were rejected. \(provider.connectionHint)"
        case .credentialAccessDenied(let provider):
            return "Could not read \(provider.title) credentials. Check local file permissions or allow this app access in Keychain Access, then retry. No credential prompt was opened."
        case .expiredCredentials(let provider):
            return "Your \(provider.title) session has expired. Sign in again in \(provider.title), then retry."
        case .missingScope:
            return "Claude Code credentials need the user:profile scope. Sign in again in Claude Code, then retry."
        case .invalidResponse:
            return "The provider returned an unsupported usage response."
        case .networkUnavailable:
            return "Could not reach the usage service. Check your connection and retry."
        case .timedOut:
            return "The usage request timed out. Please retry."
        case .redirectRejected:
            return "The usage service requested a redirect. It was blocked to protect your credentials."
        case .serviceUnavailable:
            return "The usage service is temporarily unavailable. Please retry later."
        case .cancelled:
            return "The usage request was cancelled."
        case .rateLimited:
            return "The usage service is rate limiting requests. Wait until the retry time before trying again."
        }
    }
}

nonisolated protocol AIUsageLoading: Sendable {
    func load(_ provider: AIUsageProvider, claudeProfile: ClaudeAccountProfile?) async throws -> AIUsageSnapshot
}

actor AIUsageService: AIUsageLoading {
    /// Each account owns a separate cache entry. A rejection must never evict
    /// another account's token or make a refresh fall back to that account.
    private var claudeCache: [String: (token: String, expiresAt: Date?)] = [:]
    /// Last time `kiro-cli` was asked to renew its expired sign-in, so a
    /// broken login does not launch the CLI on every refresh.
    private var kiroRenewalAttemptedAt: Date?

    func load(_ provider: AIUsageProvider, claudeProfile: ClaudeAccountProfile? = nil) async throws -> AIUsageSnapshot {
        let profile = claudeProfile ?? .current()
        do {
            try Task.checkCancellation()
            let request = try await makeRequest(for: provider, claudeProfile: profile)
            try Task.checkCancellation()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(
                configuration: configuration,
                delegate: AIUsageRedirectDelegate(),
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw AIUsageError.invalidResponse
            }
            switch response.statusCode {
            case 200..<300:
                return try Self.parse(data, for: provider)
            case 300..<400:
                throw AIUsageError.redirectRejected
            case 401, 403:
                if provider == .claude { claudeCache.removeValue(forKey: cacheKey(for: profile)) }
                throw AIUsageError.signInRequired(provider)
            case 429:
                throw AIUsageError.rateLimited(Self.retryDate(response, now: Date()))
            default:
                throw AIUsageError.serviceUnavailable
            }
        } catch let error as AIUsageError {
            throw error
        } catch is CancellationError {
            throw AIUsageError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AIUsageError.timedOut
            case .cancelled: throw AIUsageError.cancelled
            default: throw AIUsageError.networkUnavailable
            }
        } catch {
            throw AIUsageError.networkUnavailable
        }
    }

    nonisolated static func parse(
        _ data: Data,
        for provider: AIUsageProvider,
        now: Date = Date()
    ) throws -> AIUsageSnapshot {
        guard let root = jsonObject(data) else { throw AIUsageError.invalidResponse }
        switch provider {
        case .claude:
            let week: TimeInterval = 7 * 86_400
            let definitions: [(String, String, TimeInterval)] = [
                ("five_hour", "5 hours", 5 * 3_600),
                ("seven_day", "7 days", week),
                ("seven_day_sonnet", "Sonnet · 7 days", week),
                ("seven_day_opus", "Opus · 7 days", week)
            ]
            let windows = definitions.compactMap { key, title, duration -> AIUsageWindow? in
                guard let window = root[key] as? [String: Any] else { return nil }
                return AIUsageWindow(
                    id: key,
                    title: title,
                    usedPercent: nonnegative(window["utilization"]),
                    resetsAt: isoDate(window["resets_at"]),
                    detail: nil,
                    duration: duration
                )
            }
            return AIUsageSnapshot(plan: nil, windows: windows, fetchedAt: now)
        case .codex:
            let limits = root["rate_limit"] as? [String: Any] ?? [:]
            let definitions = [("primary_window", "Primary window"), ("secondary_window", "Secondary window")]
            let windows = definitions.compactMap { key, fallback -> AIUsageWindow? in
                guard let window = limits[key] as? [String: Any] else { return nil }
                return AIUsageWindow(
                    id: key,
                    title: durationTitle(window["limit_window_seconds"]) ?? fallback,
                    usedPercent: nonnegative(window["used_percent"]),
                    resetsAt: epochDate(window["reset_at"]),
                    detail: nil,
                    duration: number(window["limit_window_seconds"]).flatMap { $0 > 0 ? $0 : nil }
                )
            }
            return AIUsageSnapshot(plan: displayText(root["plan_type"]), windows: windows, fetchedAt: now)
        case .cursor:
            return parseCursor(root, now: now)
        case .kiro:
            return parseKiro(root, now: now)
        }
    }

    private func makeRequest(for provider: AIUsageProvider, claudeProfile: ClaudeAccountProfile) async throws -> URLRequest {
        switch provider {
        case .claude:
            var request = try Self.usageRequest("https://api.anthropic.com/api/oauth/usage")
            request.setValue("Bearer \(try await claudeToken(for: claudeProfile))", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            return request
        case .codex:
            var request = try Self.usageRequest("https://chatgpt.com/backend-api/wham/usage")
            let credentials = try codexCredentials()
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            if let account = credentials.account {
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            return request
        case .cursor:
            var request = try Self.usageRequest("https://cursor.com/api/usage-summary")
            request.setValue(try cursorCookie(), forHTTPHeaderField: "Cookie")
            return request
        case .kiro:
            let credentials = try await kiroCredentials()
            var components = URLComponents()
            components.scheme = "https"
            components.host = "q.\(credentials.region).amazonaws.com"
            components.path = "/getUsageLimits"
            components.queryItems = [
                URLQueryItem(name: "origin", value: "AI_EDITOR"),
                URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")
            ] + (credentials.profileArn.map { [URLQueryItem(name: "profileArn", value: $0)] } ?? [])
            guard let endpoint = components.string else { throw AIUsageError.invalidResponse }
            var request = try Self.usageRequest(endpoint)
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    nonisolated private static func usageRequest(_ endpoint: String) throws -> URLRequest {
        guard let url = URL(string: endpoint) else { throw AIUsageError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func cacheKey(for profile: ClaudeAccountProfile) -> String {
        "\(profile.id)|\(profile.keychainService)"
    }

    private func claudeToken(for profile: ClaudeAccountProfile) async throws -> String {
        let key = cacheKey(for: profile)
        if let cached = claudeCache[key], cached.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return cached.token
        }
        let credentials = try await Self.readClaudeCredentials(for: profile)
        claudeCache[key] = credentials
        return credentials.token
    }

    nonisolated static func readClaudeCredentials(
        for profile: ClaudeAccountProfile,
        keychainReader: @Sendable (String) async throws -> Data? = { try await claudeKeychainItem(service: $0) }
    ) async throws -> (token: String, expiresAt: Date?) {
        var fileError: AIUsageError = .signInRequired(.claude)
        do {
            let data = try credentialFile(profile.configDirectory.appendingPathComponent(".credentials.json"), provider: .claude)
            return try Self.validateClaude(data)
        } catch let error as AIUsageError {
            fileError = error
        } catch {
            fileError = .credentialAccessDenied(.claude)
        }
        if let data = try await keychainReader(profile.keychainService) {
            return try Self.validateClaude(data)
        }
        throw fileError
    }

    /// Claude Code writes its keychain item with `/usr/bin/security`, and every
    /// rewrite (on each token refresh) resets the item's access list to trust
    /// only that tool. Reading through it therefore never shows a keychain
    /// prompt, whereas `SecItemCopyMatching` from this app would prompt again
    /// after every refresh or rebuild.
    nonisolated private static func claudeKeychainItem(service: String) async throws -> Data? {
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", service, "-w"],
                timeout: 10
            )
        } catch {
            throw AIUsageError.credentialAccessDenied(.claude)
        }
        // 44 is errSecItemNotFound's exit status.
        if output.exitCode == 44 { return nil }
        guard output.isSuccess else { throw AIUsageError.credentialAccessDenied(.claude) }
        return Data(output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private func codexCredentials() throws -> (token: String, account: String?) {
        let custom = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let home = directory(custom, defaultName: ".codex").resolvingSymlinksInPath().standardizedFileURL
        var fileError: AIUsageError = .signInRequired(.codex)
        do {
            let data = try Self.credentialFile(home.appendingPathComponent("auth.json"), provider: .codex)
            return try Self.validateCodex(data)
        } catch let error as AIUsageError {
            fileError = error
        } catch {
            fileError = .credentialAccessDenied(.codex)
        }
        let hash = SHA256.hash(data: Data(home.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let data = try keychain(service: "Codex Auth", account: "cli|\(hash.prefix(16))", provider: .codex) {
            return try Self.validateCodex(data)
        }
        throw fileError
    }

    private func directory(_ custom: String?, defaultName: String) -> URL {
        if let custom {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(defaultName, isDirectory: true)
    }

    nonisolated private static func credentialFile(_ url: URL, provider: AIUsageProvider) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw AIUsageError.signInRequired(provider)
        } catch {
            throw AIUsageError.credentialAccessDenied(provider)
        }
    }

    private func keychain(service: String, account: String?, provider: AIUsageProvider) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AIUsageError.credentialAccessDenied(provider)
        }
        return data
    }

    private func cursorCookie() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard result == SQLITE_OK, let database else {
            throw AIUsageError.credentialAccessDenied(.cursor)
        }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw AIUsageError.credentialAccessDenied(.cursor)
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { throw AIUsageError.signInRequired(.cursor) }
        guard step == SQLITE_ROW else { throw AIUsageError.credentialAccessDenied(.cursor) }
        let type = sqlite3_column_type(statement, 0)
        guard type == SQLITE_TEXT || type == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw AIUsageError.signInRequired(.cursor)
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 1_048_576 else { throw AIUsageError.signInRequired(.cursor) }
        let data = Data(bytes: bytes, count: count)
        let candidates = [String(data: data, encoding: .utf8), String(data: data, encoding: .utf16LittleEndian)]
        guard let token = candidates.compactMap({ $0 }).map({ value in
            value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\0"))
        }).first(where: { Self.jwtPayload($0) != nil }),
              let payload = Self.jwtPayload(token),
              let subject = payload["sub"] as? String,
              let user = subject.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init),
              Self.safeIdentifier(user),
              let expiry = Self.epochDate(payload["exp"]) else {
            throw AIUsageError.signInRequired(.cursor)
        }
        guard expiry > Date() else { throw AIUsageError.expiredCredentials(.cursor) }
        return "WorkosCursorSessionToken=\(user)%3A%3A\(token)"
    }

    nonisolated struct KiroCredentials: Sendable {
        let token: String
        let expiresAt: Date?
        let region: String
        let profileArn: String?
    }

    /// The access token lasts about an hour and Kiro CLI renews it only while
    /// it runs. Renewal is left to the CLI: refreshing here would rotate the
    /// refresh token behind its back and sign it out. `kiro-cli whoami` loads
    /// the saved login, which renews and saves an expired token.
    private func kiroCredentials() async throws -> KiroCredentials {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        let credentials = try Self.readKiroCredentials(database: database)
        if credentials.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return credentials
        }
        guard kiroRenewalAttemptedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true,
              let executable = Self.kiroExecutable() else {
            throw AIUsageError.expiredCredentials(.kiro)
        }
        kiroRenewalAttemptedAt = Date()
        _ = try? await ProcessRunner.run(
            executableURL: executable,
            arguments: ["whoami", "--format", "json"],
            timeout: 20
        )
        let renewed = try Self.readKiroCredentials(database: database)
        guard renewed.expiresAt.map({ $0 > Date() }) ?? true else {
            throw AIUsageError.expiredCredentials(.kiro)
        }
        return renewed
    }

    nonisolated private static func kiroExecutable() -> URL? {
        let files = FileManager.default
        let candidates = [
            files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kiro-cli"),
            URL(fileURLWithPath: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"),
            URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli"),
            URL(fileURLWithPath: "/usr/local/bin/kiro-cli")
        ] + (ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("kiro-cli") } ?? [])
        return candidates.first { files.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func readKiroCredentials(database url: URL) throws -> KiroCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AIUsageError.signInRequired(.kiro)
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard result == SQLITE_OK, let database else {
            throw AIUsageError.credentialAccessDenied(.kiro)
        }
        sqlite3_busy_timeout(database, 1000)

        // Each login method (IAM Identity Center, social, external IdP) saves
        // its token under its own key. Use the one that lasts longest.
        let tokens = try ["kirocli:odic:token", "kirocli:social:token", "kirocli:external-idp:token"]
            .compactMap { try kiroValue(database, table: "auth_kv", key: $0) }
            .compactMap { jsonObject($0) }
            .compactMap { root -> ([String: Any], String, Date?)? in
                guard let token = (root["access_token"] ?? root["accessToken"]) as? String,
                      safeKiroToken(token) else { return nil }
                let expiry = root["expires_at"] ?? root["expiresAt"]
                return (root, token, flexibleDate(expiry))
            }
        guard let best = tokens.max(by: {
            ($0.2 ?? .distantPast) < ($1.2 ?? .distantPast)
        }) else {
            throw AIUsageError.signInRequired(.kiro)
        }
        let (root, token, expiresAt) = best

        let profile = try kiroValue(database, table: "state", key: "api.codewhisperer.profile")
            .flatMap { jsonObject($0) }
        let profileArn = [root["profile_arn"], root["profileArn"], profile?["arn"]]
            .compactMap { $0 as? String }
            .first(where: safeArn)
        let arnRegion = profileArn.map { $0.split(separator: ":", omittingEmptySubsequences: false) }
            .flatMap { $0.count > 3 ? String($0[3]) : nil }
        let region = [arnRegion, root["region"] as? String].compactMap { $0 }.first(where: safeRegion) ?? "us-east-1"
        return KiroCredentials(token: token, expiresAt: expiresAt, region: region, profileArn: profileArn)
    }

    nonisolated private static func kiroValue(_ database: OpaquePointer, table: String, key: String) throws -> Data? {
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        // The table name is one of two constants; the key is bound.
        guard sqlite3_prepare_v2(database, "SELECT value FROM \(table) WHERE key = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            // A database from an older CLI may lack the table.
            return nil
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK else {
            throw AIUsageError.credentialAccessDenied(.kiro)
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw AIUsageError.credentialAccessDenied(.kiro) }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 1_048_576, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// AWS SSO access tokens are base64 segments joined by colons.
    nonisolated private static func safeKiroToken(_ text: String) -> Bool {
        let segments = text.split(separator: ":", omittingEmptySubsequences: false)
        return segments.count <= 8 && segments.allSatisfy { safeToken(String($0)) }
    }

    nonisolated private static func safeArn(_ text: String) -> Bool {
        text.hasPrefix("arn:aws") && text.utf8.count <= 256 && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || ":/-_.".utf8.contains($0)
        }
    }

    /// The region becomes part of the request host, so only plain region
    /// names such as `us-east-1` are accepted.
    nonisolated private static func safeRegion(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 32 && text.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        } && text.first?.isLetter == true
    }

    /// Kiro CLI writes ISO 8601 dates with microseconds, which
    /// `ISO8601DateFormatter` does not always accept.
    nonisolated private static func flexibleDate(_ value: Any?) -> Date? {
        if let date = epochDate(value) { return date }
        guard let text = value as? String else { return nil }
        if let date = isoDate(text) { return date }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoDate(trimmed)
    }

    nonisolated private static func validateClaude(_ data: Data) throws -> (token: String, expiresAt: Date?) {
        guard let root = jsonObject(data),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, safeToken(token) else {
            throw AIUsageError.signInRequired(.claude)
        }
        var expiresAt: Date?
        if let value = oauth["expiresAt"], !(value is NSNull) {
            guard let milliseconds = number(value),
                  let expiry = epochDate(milliseconds / 1000) else {
                throw AIUsageError.signInRequired(.claude)
            }
            guard expiry > Date() else { throw AIUsageError.expiredCredentials(.claude) }
            expiresAt = expiry
        }
        if let value = oauth["scopes"], !(value is NSNull) {
            let scopes: [String]
            if let list = value as? [String] {
                scopes = list
            } else if let text = value as? String {
                scopes = text.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                throw AIUsageError.missingScope
            }
            guard scopes.contains("user:profile") else { throw AIUsageError.missingScope }
        }
        return (token, expiresAt)
    }

    nonisolated private static func validateCodex(_ data: Data) throws -> (token: String, account: String?) {
        guard let root = jsonObject(data),
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, safeToken(token) else {
            throw AIUsageError.signInRequired(.codex)
        }
        if let payload = jwtPayload(token), let expiry = epochDate(payload["exp"]), expiry <= Date() {
            throw AIUsageError.expiredCredentials(.codex)
        }
        var account: String?
        if let value = tokens["account_id"], !(value is NSNull) {
            guard let text = value as? String, safeIdentifier(text) else {
                throw AIUsageError.signInRequired(.codex)
            }
            account = text
        }
        return (token, account)
    }

    nonisolated private static func safeIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    nonisolated private static func safeToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 65_536 && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || "-._~+/=".utf8.contains($0)
        }
    }

    nonisolated private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 65_536, parts.count == 3,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                  }
              }) else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return jsonObject(data)
    }

    nonisolated private static func parseCursor(_ root: [String: Any], now: Date) -> AIUsageSnapshot {
        let individual = root["individualUsage"] as? [String: Any] ?? [:]
        var windows: [AIUsageWindow] = []
        if let plan = individual["plan"] as? [String: Any] {
            let used = nonnegative(plan["used"])
            let limit = nonnegative(plan["limit"])
            let remaining = nonnegative(plan["remaining"])
            let total = nonnegative(plan["totalPercentUsed"])
            let derived = used.flatMap { used in
                limit.flatMap { limit -> Double? in
                    guard limit > 0 else { return nil }
                    let percent = used / limit * 100
                    return percent.isFinite ? percent : nil
                }
            }
            let reset = isoDate(root["billingCycleEnd"])
            let cycle = isoDate(root["billingCycleStart"]).flatMap { start in
                reset.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil }
            }
            var details: [String] = []
            if boolean(plan["enabled"]) == false { details.append("Plan usage is disabled") }
            if let used { details.append("\(money(used)) used") }
            if let limit { details.append("\(money(limit)) limit") }
            if let remaining { details.append("\(money(remaining)) remaining") }
            if (boolean(plan["isUnlimited"]) ?? boolean(root["isUnlimited"])) == true && limit == nil {
                details.append("Unlimited plan usage")
            }
            windows.append(AIUsageWindow(
                id: "plan",
                title: "Billing cycle",
                usedPercent: total ?? derived,
                resetsAt: reset,
                detail: details.isEmpty ? nil : details.joined(separator: " · "),
                duration: cycle
            ))
            for (key, title) in [("autoPercentUsed", "Auto"), ("apiPercentUsed", "API")] {
                if let percent = nonnegative(plan[key]) {
                    windows.append(AIUsageWindow(id: key, title: title, usedPercent: percent, resetsAt: reset, detail: nil, duration: cycle))
                }
            }
        }
        return AIUsageSnapshot(plan: displayText(root["membershipType"]), windows: windows, fetchedAt: now)
    }

    /// Kiro bills in credits per monthly cycle. A free trial and bonus credits
    /// are separate pools with their own expiry dates.
    nonisolated private static func parseKiro(_ root: [String: Any], now: Date) -> AIUsageSnapshot {
        let fallbackReset = epochDate(root["nextDateReset"])
        let overage = root["overageConfiguration"] as? [String: Any]
        let breakdowns = (root["usageBreakdownList"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var windows: [AIUsageWindow] = []
        for (index, item) in breakdowns.enumerated() {
            let suffix = index == 0 ? "" : "_\(index)"
            let plural = displayText(item["displayNamePlural"])
                ?? displayText(item["displayName"]).map { "\($0)s" }
                ?? "Credits"
            let reset = epochDate(item["nextDateReset"]) ?? fallbackReset
            var extra: [String] = []
            if let over = kiroAmount(item, "currentOverages"), over > 0 {
                extra.append("\(kiroNumber(over)) over the limit")
            }
            if let charges = nonnegative(item["overageCharges"]), charges > 0 {
                extra.append("\(money(charges * 100)) overage charges")
            }
            if index == 0, displayText(overage?["overageStatus"]) == "ENABLED" {
                extra.append("Overages enabled")
            }
            if let window = kiroWindow(
                item,
                id: "credits\(suffix)",
                title: plural,
                unit: plural.lowercased(),
                resetsAt: reset,
                duration: reset.flatMap(monthBefore),
                extra: extra
            ) {
                windows.append(window)
            }

            if let trial = item["freeTrialInfo"] as? [String: Any],
               displayText(trial["freeTrialStatus"]).map({ $0 == "ACTIVE" }) ?? true,
               let window = kiroWindow(
                   trial,
                   id: "free_trial\(suffix)",
                   title: "Free trial",
                   unit: plural.lowercased(),
                   resetsAt: epochDate(trial["freeTrialExpiry"]) ?? epochDate(trial["expiresAt"]),
                   duration: nil,
                   extra: []
               ) {
                windows.append(window)
            }

            let bonuses = (item["bonuses"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            for (bonusIndex, bonus) in bonuses.enumerated() {
                if let status = displayText(bonus["status"]), status != "ACTIVE" { continue }
                if let window = kiroWindow(
                    bonus,
                    id: "bonus\(suffix)_\(bonusIndex)",
                    title: displayText(bonus["displayName"]) ?? "Bonus",
                    unit: plural.lowercased(),
                    resetsAt: epochDate(bonus["expiresAt"]) ?? epochDate(bonus["expiryDate"]),
                    duration: nil,
                    extra: []
                ) {
                    windows.append(window)
                }
            }
        }
        let subscription = root["subscriptionInfo"] as? [String: Any]
        let plan = displayText(subscription?["subscriptionTitle"]).map { title in
            // The API sends titles such as "KIRO POWER".
            title == title.uppercased() ? title.capitalized : title
        }
        return AIUsageSnapshot(plan: plan, windows: windows, fetchedAt: now)
    }

    nonisolated private static func kiroWindow(
        _ item: [String: Any],
        id: String,
        title: String,
        unit: String,
        resetsAt: Date?,
        duration: TimeInterval?,
        extra: [String]
    ) -> AIUsageWindow? {
        guard let limit = kiroAmount(item, "usageLimit"), limit > 0 else { return nil }
        let used = kiroAmount(item, "currentUsage") ?? 0
        let percent = used / limit * 100
        return AIUsageWindow(
            id: id,
            title: title,
            usedPercent: percent.isFinite ? percent : nil,
            resetsAt: resetsAt,
            detail: (["\(kiroNumber(used)) of \(kiroNumber(limit)) \(unit) used"] + extra).joined(separator: " · "),
            duration: duration
        )
    }

    /// Prefers the fractional value: credits are spent in fractions.
    nonisolated private static func kiroAmount(_ item: [String: Any], _ key: String) -> Double? {
        nonnegative(item["\(key)WithPrecision"]) ?? nonnegative(item[key])
    }

    nonisolated private static func kiroNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Kiro reports only the reset date. The cycle is the calendar month
    /// before it, in UTC.
    nonisolated private static func monthBefore(_ reset: Date) -> TimeInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        return reset.timeIntervalSince(start)
    }

    nonisolated private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard data.count <= 4_194_304 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    nonisolated private static func nonnegative(_ value: Any?) -> Double? {
        number(value).flatMap { $0 >= 0 ? $0 : nil }
    }

    nonisolated private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    nonisolated private static func displayText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    nonisolated private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = nonnegative(value), seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    nonisolated private static func durationTitle(_ value: Any?) -> String? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        for (unit, name) in [(86_400.0, "day"), (3_600.0, "hour"), (60.0, "minute"), (1.0, "second")] {
            if seconds.truncatingRemainder(dividingBy: unit) == 0 {
                let count = seconds / unit
                return "\(String(format: "%.0f", count)) \(name)\(count == 1 ? "" : "s")"
            }
        }
        return "\(seconds) seconds"
    }

    nonisolated private static func money(_ cents: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), cents / 100)
    }

    nonisolated private static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(value), seconds.isFinite, seconds >= 0,
               seconds <= 253_402_300_799 - now.timeIntervalSince1970 {
                return now.addingTimeInterval(seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return max(now, date) }
            }
        }
        return now.addingTimeInterval(300)
    }
}

private nonisolated final class AIUsageRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
