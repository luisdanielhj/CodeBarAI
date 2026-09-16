import Foundation
import Security
import SQLite3
import CryptoKit

nonisolated enum AIUsageProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, cursor, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }

    var logoName: String {
        switch self {
        case .claude: return "ClaudeLogo"
        case .cursor: return "CursorLogo"
        case .codex: return "CodexLogo"
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

actor AIUsageService {
    func load(_ provider: AIUsageProvider) async throws -> AIUsageSnapshot {
        do {
            try Task.checkCancellation()
            let request = try makeRequest(for: provider)
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
            let definitions = [
                ("five_hour", "5 hours"),
                ("seven_day", "7 days"),
                ("seven_day_sonnet", "Sonnet · 7 days"),
                ("seven_day_opus", "Opus · 7 days")
            ]
            let windows = definitions.compactMap { key, title -> AIUsageWindow? in
                guard let window = root[key] as? [String: Any] else { return nil }
                return AIUsageWindow(
                    id: key,
                    title: title,
                    usedPercent: nonnegative(window["utilization"]),
                    resetsAt: isoDate(window["resets_at"]),
                    detail: nil
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
                    detail: nil
                )
            }
            return AIUsageSnapshot(plan: displayText(root["plan_type"]), windows: windows, fetchedAt: now)
        case .cursor:
            return parseCursor(root, now: now)
        }
    }

    private func makeRequest(for provider: AIUsageProvider) throws -> URLRequest {
        let endpoint: String
        switch provider {
        case .claude: endpoint = "https://api.anthropic.com/api/oauth/usage"
        case .cursor: endpoint = "https://cursor.com/api/usage-summary"
        case .codex: endpoint = "https://chatgpt.com/backend-api/wham/usage"
        }
        guard let url = URL(string: endpoint) else { throw AIUsageError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .claude:
            request.setValue("Bearer \(try claudeToken())", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        case .codex:
            let credentials = try codexCredentials()
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            if let account = credentials.account {
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case .cursor:
            request.setValue(try cursorCookie(), forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func claudeToken() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let home = directory(custom, defaultName: ".claude")
        var fileError: AIUsageError = .signInRequired(.claude)
        do {
            let data = try credentialFile(home.appendingPathComponent(".credentials.json"), provider: .claude)
            return try Self.validateClaude(data)
        } catch let error as AIUsageError {
            fileError = error
        } catch {
            fileError = .credentialAccessDenied(.claude)
        }
        guard custom == nil else { throw fileError }
        do {
            if let data = try keychain(service: "Claude Code-credentials", account: nil, provider: .claude) {
                return try Self.validateClaude(data)
            }
        } catch let error as AIUsageError {
            throw error
        }
        throw fileError
    }

    private func codexCredentials() throws -> (token: String, account: String?) {
        let custom = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let home = directory(custom, defaultName: ".codex").resolvingSymlinksInPath().standardizedFileURL
        var fileError: AIUsageError = .signInRequired(.codex)
        do {
            let data = try credentialFile(home.appendingPathComponent("auth.json"), provider: .codex)
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

    private func credentialFile(_ url: URL, provider: AIUsageProvider) throws -> Data {
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

    nonisolated private static func validateClaude(_ data: Data) throws -> String {
        guard let root = jsonObject(data),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, safeToken(token) else {
            throw AIUsageError.signInRequired(.claude)
        }
        if let value = oauth["expiresAt"], !(value is NSNull) {
            guard let milliseconds = number(value),
                  let expiry = epochDate(milliseconds / 1000) else {
                throw AIUsageError.signInRequired(.claude)
            }
            guard expiry > Date() else { throw AIUsageError.expiredCredentials(.claude) }
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
        return token
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
                detail: details.isEmpty ? nil : details.joined(separator: " · ")
            ))
            for (key, title) in [("autoPercentUsed", "Auto"), ("apiPercentUsed", "API")] {
                if let percent = nonnegative(plan[key]) {
                    windows.append(AIUsageWindow(id: key, title: title, usedPercent: percent, resetsAt: reset, detail: nil))
                }
            }
        }
        return AIUsageSnapshot(plan: displayText(root["membershipType"]), windows: windows, fetchedAt: now)
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
