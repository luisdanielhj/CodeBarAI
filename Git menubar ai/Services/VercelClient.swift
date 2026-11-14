import Foundation

/// Where the token used for Vercel requests came from.
nonisolated enum VercelCredentialSource: Sendable {
    /// Pasted into Settings and kept in the keychain.
    case savedToken
    /// The Vercel CLI's own login (`vercel login`).
    case cli
}

nonisolated struct VercelCredential: Sendable {
    let token: String
    let source: VercelCredentialSource
}

/// Finds a Vercel token: one saved in Settings first, then the Vercel CLI's login.
///
/// CLI logins are short-lived OAuth tokens. When one has expired, running any
/// CLI command makes the CLI renew it with its refresh token, so this runs
/// `vercel whoami` through the user's shell and reads the file again. The app
/// never handles the refresh token itself.
nonisolated enum VercelCredentials {
    /// Renew a CLI token this close to expiry instead of using it.
    private static let expiryMargin: TimeInterval = 120

    static func resolve(forceCLIRefresh: Bool = false) async throws -> VercelCredential {
        if let token = try? await APIKeyStore.vercelToken() {
            return VercelCredential(token: token, source: .savedToken)
        }
        guard let login = cliLogin() else { throw VercelError.notSignedIn }
        if !forceCLIRefresh, login.isUsable(margin: expiryMargin) {
            return VercelCredential(token: login.token, source: .cli)
        }
        await renewCLILogin()
        guard let renewed = cliLogin(), renewed.isUsable(margin: 0) else {
            throw VercelError.cliLoginExpired
        }
        return VercelCredential(token: renewed.token, source: .cli)
    }

    /// Whether `vercel login` has written a token on this Mac.
    static var hasCLILogin: Bool { cliLogin() != nil }

    // MARK: CLI login file

    struct CLILogin {
        let token: String
        let expiresAt: Date?

        func isUsable(margin: TimeInterval) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > margin
        }
    }

    /// The CLI keeps its login in its data directory; older versions used `~/.vercel`.
    private static var authFileCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/com.vercel.cli/auth.json"),
            home.appending(path: ".local/share/com.vercel.cli/auth.json"),
            home.appending(path: ".vercel/auth.json")
        ]
    }

    static func cliLogin() -> CLILogin? {
        for file in authFileCandidates {
            guard let data = try? Data(contentsOf: file),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let token = (root["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { continue }
            let expiresAt = (root["expiresAt"] as? NSNumber).map { number -> Date in
                let value = number.doubleValue
                // Seconds today; accept milliseconds in case that changes.
                return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
            }
            return CLILogin(token: token, expiresAt: expiresAt)
        }
        return nil
    }

    /// The CLI is a Node script installed by npm, pnpm, bun or Homebrew, so the
    /// user's interactive shell is the only reliable way to find it and Node.
    private static func renewCLILogin() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        _ = try? await ProcessRunner.run(
            executableURL: URL(filePath: shell),
            arguments: ["-ilc", "vercel whoami"],
            timeout: 30
        )
    }
}

/// Reads teams and deployments from the Vercel REST API.
///
/// Like `CloudModelClient`, it uses an ephemeral session and refuses
/// redirects, so the token only ever goes to api.vercel.com.
nonisolated enum VercelClient {
    private static let host = "api.vercel.com"
    /// Enough history to find the latest deployment of every active project.
    private static let deploymentsPerTeam = 100

    /// Every team the token can see, and the newest deployment of each of their projects.
    static func latestDeployments(token: String) async throws -> (teams: [VercelTeam], deployments: [VercelDeployment]) {
        async let teamsRequest = get("/v2/teams", query: [URLQueryItem(name: "limit", value: "100")], token: token)
        async let userRequest = get("/v2/user", token: token)
        let teams = try VercelResponseParser.teams(from: try await teamsRequest)
        let user = (try? JSONSerialization.jsonObject(with: try await userRequest)) as? [String: Any]
        let defaultTeamID = (user?["user"] as? [String: Any])?["defaultTeamId"] as? String

        // Without a default team, requests with no `teamId` list the personal
        // account's own projects. With one, they repeat that team's.
        var scopes = teams
        if defaultTeamID == nil || teams.isEmpty { scopes.insert(.personal, at: 0) }

        let results = await withTaskGroup(of: Result<[VercelDeployment], Error>.self) { group in
            for team in scopes {
                group.addTask {
                    do { return .success(try await deployments(in: team, token: token)) } catch { return .failure(error) }
                }
            }
            var results: [Result<[VercelDeployment], Error>] = []
            for await result in group { results.append(result) }
            return results
        }

        let found = results.compactMap { try? $0.get() }
        // One team can refuse access (SAML, a removed membership) without
        // hiding the others. Only fail when nothing could be read.
        if found.isEmpty, let failure = results.lazy.compactMap({ result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }).first {
            throw failure
        }
        return (scopes, VercelResponseParser.latestPerProject(found.flatMap { $0 }))
    }

    private static func deployments(in team: VercelTeam, token: String) async throws -> [VercelDeployment] {
        var query = [URLQueryItem(name: "limit", value: "\(deploymentsPerTeam)")]
        if !team.id.isEmpty { query.append(URLQueryItem(name: "teamId", value: team.id)) }
        let data = try await get("/v6/deployments", query: query, token: token)
        return try VercelResponseParser.deployments(from: data, team: team)
    }

    private static func get(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw VercelError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw VercelError.timedOut
            case .cancelled: throw CancellationError()
            default: throw VercelError.networkUnavailable
            }
        }

        guard let http = response as? HTTPURLResponse else { throw VercelError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 300..<400:
            throw VercelError.redirectRejected
        case 401, 403:
            throw VercelError.tokenRejected
        case 429:
            throw VercelError.rateLimited
        default:
            throw VercelError.serviceUnavailable(errorMessage(in: data))
        }
    }

    /// Vercel puts a readable explanation at `error.message`.
    private static func errorMessage(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }

    /// Checks a token before it's saved.
    static func verify(token: String) async throws {
        _ = try await get("/v2/user", token: token)
    }
}
