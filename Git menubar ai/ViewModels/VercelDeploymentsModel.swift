import Foundation
import Observation

/// The latest Vercel deployment of each project, which teams to show, and the
/// optional token saved in Settings.
@Observable
final class VercelDeploymentsModel {
    enum TokenStatus: Equatable {
        case unknown
        case missing
        case saved(suffix: String)
    }

    /// Every team the last refresh could see, in the API's order.
    private(set) var allTeams: [VercelTeam] = []
    /// Teams the user unchecked. Stored as hidden, not shown, so a team you
    /// join later appears without any setup.
    private(set) var hiddenTeamIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenTeamIDs).sorted(), forKey: Self.hiddenTeamsKey) }
    }
    private var allDeployments: [VercelDeployment] = []
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var failure: VercelError?
    private(set) var lastUpdated: Date?
    /// Which credential the last successful refresh used.
    private(set) var source: VercelCredentialSource?

    private(set) var tokenStatus: TokenStatus = .unknown
    private(set) var isSavingToken = false
    var tokenError: String?

    private static let hiddenTeamsKey = "vercel.hiddenTeamIDs"

    init() {
        hiddenTeamIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenTeamsKey) ?? [])
    }

    /// Latest deployments of the teams the user chose to show.
    var deployments: [VercelDeployment] {
        allDeployments.filter { !hiddenTeamIDs.contains($0.team.id) }
    }

    /// Projects with a recent deployment in `team`, counted whether or not it's shown.
    func projectCount(in team: VercelTeam) -> Int {
        allDeployments.count(where: { $0.team.id == team.id })
    }

    func isShown(_ team: VercelTeam) -> Bool { !hiddenTeamIDs.contains(team.id) }

    func setShown(_ team: VercelTeam, isShown: Bool) {
        if isShown { hiddenTeamIDs.remove(team.id) } else { hiddenTeamIDs.insert(team.id) }
    }

    /// Poll quickly while something is building so the result shows up soon after it lands.
    var pollInterval: Duration {
        inProgressCount > 0 ? .seconds(10) : .seconds(60)
    }

    var inProgressCount: Int { deployments.count(where: { $0.state.isInProgress }) }
    var failedCount: Int { deployments.count(where: { $0.state == .error }) }

    /// Teams in the order their newest deployment appears.
    var teams: [VercelTeam] {
        var seen = Set<String>()
        return deployments.map(\.team).filter { seen.insert($0.id).inserted }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var credential = try await VercelCredentials.resolve()
            let found: (teams: [VercelTeam], deployments: [VercelDeployment])
            do {
                found = try await VercelClient.latestDeployments(token: credential.token)
            } catch VercelError.tokenRejected where credential.source == .cli {
                // The CLI may have been signed out or its token revoked early.
                credential = try await VercelCredentials.resolve(forceCLIRefresh: true)
                found = try await VercelClient.latestDeployments(token: credential.token)
            }
            guard !Task.isCancelled else { return }
            allTeams = found.teams
            allDeployments = found.deployments
            source = credential.source
            failure = nil
            lastUpdated = .now
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            let failure = error as? VercelError ?? .serviceUnavailable(error.localizedDescription)
            self.failure = failure
            hasLoaded = true
            // Keep showing the last good list through network blips, not after a sign-out.
            if failure.needsSignIn {
                allDeployments = []
                allTeams = []
            }
        }
    }

    // MARK: - Token

    func loadTokenStatus() async {
        do {
            let token = try await APIKeyStore.vercelToken()
            tokenStatus = token.map { .saved(suffix: String($0.suffix(4))) } ?? .missing
        } catch {
            tokenStatus = .missing
            tokenError = error.localizedDescription
        }
    }

    /// Checks the token with Vercel, then saves it. Returns `true` when saved.
    @discardableResult
    func saveToken(_ rawToken: String) async -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isSavingToken else { return false }
        guard !token.contains(where: \.isWhitespace) else {
            tokenError = "That doesn't look like a Vercel token: it contains spaces or line breaks."
            return false
        }
        isSavingToken = true
        defer { isSavingToken = false }
        tokenError = nil
        do {
            try await VercelClient.verify(token: token)
            try await APIKeyStore.saveVercelToken(token)
            tokenStatus = .saved(suffix: String(token.suffix(4)))
        } catch {
            tokenError = error.localizedDescription
            return false
        }
        await refresh()
        return true
    }

    func removeToken() async {
        guard !isSavingToken else { return }
        isSavingToken = true
        defer { isSavingToken = false }
        do {
            try await APIKeyStore.deleteVercelToken()
            tokenStatus = .missing
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
            return
        }
        await refresh()
    }
}
