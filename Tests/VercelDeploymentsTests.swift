import Foundation

/// Parses fixture responses only; never reads the keychain or contacts Vercel.
@main
nonisolated struct VercelDeploymentsTests {
    static func main() throws {
        let team = VercelTeam(id: "team_1", slug: "acme", name: "Acme")
        let other = VercelTeam(id: "team_2", slug: "side", name: "Side")

        let teams = try VercelResponseParser.teams(from: Data("""
        {"teams":[{"id":"team_1","slug":"acme","name":"Acme"},{"id":"team_2","slug":"side","name":""},{"slug":"no-id"}]}
        """.utf8))
        expect(teams.map(\.id) == ["team_1", "team_2"], "Keep teams that have an id")
        expect(teams[1].name == "side", "Fall back to the slug when a team has no name")

        let data = Data("""
        {"deployments":[
          {"uid":"dpl_new","name":"web","projectId":"prj_web","url":"web-abc.vercel.app","readyState":"BUILDING",
           "target":null,"createdAt":1779468999000,"inspectorUrl":"https://vercel.com/acme/web/abc",
           "meta":{"githubCommitRef":"feature/x","githubCommitMessage":"Add login\\n\\nLonger body"}},
          {"uid":"dpl_old","name":"web","projectId":"prj_web","url":"web-old.vercel.app","readyState":"READY",
           "target":"production","createdAt":1779468000000},
          {"uid":"dpl_api","name":"api","projectId":"prj_api","url":"api.vercel.app","state":"ERROR",
           "target":"production","created":1779468500000,"inspectorUrl":"http://insecure.example",
           "meta":{"gitlabCommitRef":"main"}},
          {"name":"missing-uid","createdAt":1}
        ]}
        """.utf8)
        let parsed = try VercelResponseParser.deployments(from: data, team: team)
        expect(parsed.count == 3, "Skip deployments without an id")

        let building = parsed[0]
        expect(building.state == .building && building.state.isInProgress, "Read readyState")
        expect(building.environmentTitle == "Preview", "A null target is a preview")
        expect(building.branch == "feature/x", "Read the GitHub branch")
        expect(building.commitMessage == "Add login", "Keep only the commit subject")
        expect(building.url?.absoluteString == "https://web-abc.vercel.app", "Build an https deployment URL")
        expect(building.createdAt == Date(timeIntervalSince1970: 1_779_468_999), "Convert milliseconds")

        let failed = parsed[2]
        expect(failed.state == .error, "Fall back to state when readyState is missing")
        expect(failed.environmentTitle == "Production", "Title-case the target")
        expect(failed.branch == "main", "Read GitLab metadata")
        expect(failed.inspectorURL == nil, "Ignore a non-https inspector link")
        expect(VercelDeploymentState(apiValue: "SOMETHING_NEW") == .unknown, "Tolerate new states")

        let sameProjectOtherTeam = try VercelResponseParser.deployments(from: Data("""
        {"deployments":[{"uid":"dpl_side","name":"web","projectId":"prj_web","readyState":"READY","createdAt":1779460000000}]}
        """.utf8), team: other)
        let latest = VercelResponseParser.latestPerProject(parsed + sameProjectOtherTeam)
        expect(latest.map(\.id) == ["dpl_new", "dpl_api", "dpl_side"], "Keep the newest deployment per project and team, newest first")

        do {
            _ = try VercelResponseParser.deployments(from: Data(#"{"error":{"message":"nope"}}"#.utf8), team: team)
            expect(false, "Reject a response without deployments")
        } catch let error as VercelError {
            expect(error == .invalidResponse, "Report an unreadable response")
        }
        expect(VercelError.cliLoginExpired.needsSignIn && !VercelError.rateLimited.needsSignIn, "Classify sign-in errors")

        print("PASS: Vercel teams, deployment parsing, git metadata, URLs, unknown states, and latest-per-project selection")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
