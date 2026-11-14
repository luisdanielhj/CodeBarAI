import Foundation

/// A Vercel team, or the personal scope when `id` is empty.
nonisolated struct VercelTeam: Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let name: String

    /// Requests without a `teamId` use the account's default scope.
    static let personal = VercelTeam(id: "", slug: "", name: "Personal")
}

/// `readyState` as the API reports it.
nonisolated enum VercelDeploymentState: String, Sendable {
    case queued = "QUEUED"
    case initializing = "INITIALIZING"
    case building = "BUILDING"
    case ready = "READY"
    case error = "ERROR"
    case canceled = "CANCELED"
    case deleted = "DELETED"
    case unknown

    init(apiValue: String?) {
        self = apiValue.flatMap { Self(rawValue: $0.uppercased()) } ?? .unknown
    }

    var isInProgress: Bool {
        self == .queued || self == .initializing || self == .building
    }

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .initializing: return "Initializing"
        case .building: return "Building"
        case .ready: return "Ready"
        case .error: return "Failed"
        case .canceled: return "Canceled"
        case .deleted: return "Deleted"
        case .unknown: return "Unknown"
        }
    }
}

nonisolated struct VercelDeployment: Identifiable, Hashable, Sendable {
    let id: String
    let projectName: String
    let projectID: String?
    /// The deployment's own `*.vercel.app` address.
    let url: URL?
    /// The deployment's page on vercel.com.
    let inspectorURL: URL?
    let state: VercelDeploymentState
    /// `production`, a custom environment, or `nil` for a preview.
    let target: String?
    let branch: String?
    /// First line of the commit message.
    let commitMessage: String?
    let createdAt: Date
    let team: VercelTeam

    var environmentTitle: String {
        guard let target, !target.isEmpty else { return "Preview" }
        return target.prefix(1).uppercased() + target.dropFirst()
    }
}

/// Turns Vercel REST API responses into models. Kept free of networking so it
/// can be tested with fixtures.
nonisolated enum VercelResponseParser {
    static func teams(from data: Data) throws -> [VercelTeam] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VercelError.invalidResponse
        }
        let entries = root["teams"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let slug = entry["slug"] as? String ?? id
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            return VercelTeam(id: id, slug: slug, name: name)
        }
    }

    static func deployments(from data: Data, team: VercelTeam) throws -> [VercelDeployment] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["deployments"] as? [[String: Any]] else {
            throw VercelError.invalidResponse
        }
        return entries.compactMap { deployment(from: $0, team: team) }
    }

    private static func deployment(from entry: [String: Any], team: VercelTeam) -> VercelDeployment? {
        guard let id = entry["uid"] as? String,
              let name = entry["name"] as? String,
              let created = number(entry["createdAt"]) ?? number(entry["created"]) else { return nil }
        let meta = entry["meta"] as? [String: Any] ?? [:]
        let host = (entry["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return VercelDeployment(
            id: id,
            projectName: name,
            projectID: entry["projectId"] as? String,
            url: host.flatMap { URL(string: "https://\($0)") },
            inspectorURL: (entry["inspectorUrl"] as? String).flatMap(httpsURL),
            state: VercelDeploymentState(apiValue: (entry["readyState"] ?? entry["state"]) as? String),
            target: entry["target"] as? String,
            branch: gitValue(in: meta, suffix: "CommitRef"),
            commitMessage: gitValue(in: meta, suffix: "CommitMessage")
                .flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) },
            createdAt: Date(timeIntervalSince1970: created / 1_000),
            team: team
        )
    }

    /// The newest deployment of each project, newest first.
    static func latestPerProject(_ deployments: [VercelDeployment]) -> [VercelDeployment] {
        var seen = Set<String>()
        return deployments
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert("\($0.team.id)/\($0.projectID ?? $0.projectName)").inserted }
    }

    /// GitHub, GitLab and Bitbucket each prefix the same keys with their name,
    /// e.g. `githubCommitRef`.
    private static func gitValue(in meta: [String: Any], suffix: String) -> String? {
        for provider in ["github", "gitlab", "bitbucket"] {
            if let value = meta["\(provider)\(suffix)"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }
}

nonisolated enum VercelError: LocalizedError, Equatable, Sendable {
    /// No saved token and no Vercel CLI login.
    case notSignedIn
    /// The CLI login expired and the CLI could not renew it.
    case cliLoginExpired
    case tokenRejected
    case rateLimited
    case networkUnavailable
    case timedOut
    case redirectRejected
    case serviceUnavailable(String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Run vercel login in Terminal, or add a Vercel token in Settings."
        case .cliLoginExpired:
            return "Your Vercel CLI login expired. Run vercel login in Terminal, or add a token in Settings."
        case .tokenRejected:
            return "Vercel rejected the token. Sign in again or replace the token in Settings."
        case .rateLimited:
            return "Vercel is rate limiting requests. Deployments will refresh shortly."
        case .networkUnavailable:
            return "Could not reach Vercel. Check your internet connection."
        case .timedOut:
            return "Vercel took too long to answer."
        case .redirectRejected:
            return "Vercel asked to redirect the request. It was blocked to protect your token."
        case .serviceUnavailable(let detail):
            return detail.map { "Vercel is having problems: \($0)" } ?? "Vercel is having problems. Try again in a moment."
        case .invalidResponse:
            return "Vercel sent a response CodeBarAI couldn't read."
        }
    }

    /// Signing in, rather than waiting, fixes these.
    var needsSignIn: Bool {
        self == .notSignedIn || self == .cliLoginExpired || self == .tokenRejected
    }
}
