import Foundation

/// Runs on synthetic data only; never reads the user's Keychain, the
/// installed Antigravity binaries, or contacts Google.
@main
nonisolated struct AntigravityUsageTests {
    static func main() throws {
        try credentials()
        try usage()
        try clientSecrets()
        print("PASS: Antigravity; saved sign-in formats, client from ID token, model family quotas, exhausted quotas, plan name, and client secret discovery")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func credentials() throws {
        let client = "123-abc.apps.googleusercontent.com"
        let payload = Data(#"{"aud":"\#(client)","iss":"https://accounts.google.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let json = #"{"token":{"access_token":"ya29.synthetic","token_type":"Bearer","refresh_token":"1//synthetic-refresh","expiry":"2026-10-15T05:50:38.505457-06:00"},"auth_method":"consumer","id_token":"eyJhbGciOiJSUzI1NiJ9.\#(payload).c2ln"}"#

        let base64 = Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString()).utf8)
        let saved = try AIUsageService.parseAntigravityCredentials(base64)
        expect(saved.accessToken == "ya29.synthetic", "Read the access token behind go-keyring's base64 prefix")
        expect(saved.refreshToken == "1//synthetic-refresh", "Read the refresh token")
        expect(saved.clientID == client, "Name the OAuth client from the ID token's audience")
        let expected = ISO8601DateFormatter().date(from: "2026-10-15T11:50:38Z")!
        expect(saved.expiresAt.map { abs($0.timeIntervalSince(expected)) < 1 } == true, "Parse Go's microsecond expiry with an offset")

        let hex = Data(("go-keyring-encoded:" + Data(json.utf8).map { String(format: "%02x", $0) }.joined()).utf8)
        let decoded = try AIUsageService.parseAntigravityCredentials(hex)
        expect(decoded.refreshToken == "1//synthetic-refresh", "Read go-keyring's hex format")

        let plain = try AIUsageService.parseAntigravityCredentials(Data(#"{"access_token":"ya29.plain","expiry":"0001-01-01T00:00:00Z"}"#.utf8))
        expect(plain.accessToken == "ya29.plain" && plain.expiresAt == nil && plain.clientID == nil, "A zero Go time means no expiry")

        for bad in ["go-keyring-base64:!!!", "{}", "not json", #"{"token":{"access_token":"bad token\n"}}"#] {
            do {
                _ = try AIUsageService.parseAntigravityCredentials(Data(bad.utf8))
                preconditionFailure("Reject an unusable sign-in: \(bad)")
            } catch AIUsageError.signInRequired(.antigravity) { }
        }
    }

    static func usage() throws {
        let reset = "2026-11-26T18:01:57Z"
        let response: [String: Any] = [
            "models": [
                "gemini-3.8-flash-high": ["displayName": "Gemini 3.8 Flash (High)", "quotaInfo": ["remainingFraction": 0.4, "resetTime": reset]],
                "gemini-3.8-flash-low": ["displayName": "Gemini 3.8 Flash (Low)", "quotaInfo": ["remainingFraction": 0.9, "resetTime": reset]],
                "claude-opus-5-5-high": ["displayName": "Claude Opus 5.5 (High)", "quotaInfo": ["resetTime": reset]],
                "claude-opus-5-5-low": ["displayName": "Claude Opus 5.5 (Low)", "quotaInfo": ["remainingFraction": 1, "resetTime": reset]],
                "gpt-oss-120b-medium": ["displayName": "GPT-OSS 120B (Medium)", "quotaInfo": ["remainingFraction": 1, "resetTime": reset]],
                "chat_20706": ["isInternal": true, "quotaInfo": ["remainingFraction": 1]],
                "tab_flash_lite_preview": ["quotaInfo": ["remainingFraction": 1]]
            ],
            "groupedModels": [
                "gemini-3.8-flash": ["displayName": "Gemini 3.8 Flash"]
            ],
            "agentModelSorts": [[
                "displayName": "Recommended",
                "groups": [["modelIds": ["gemini-3.8-flash-high", "gemini-3.8-flash-low", "claude-opus-5-5-low", "claude-opus-5-5-high", "gpt-oss-120b-medium", "missing-model"]]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let now = Date()
        let snapshot = try AIUsageService.parse(data, for: .antigravity, now: now)
        expect(snapshot.windows.map(\.title) == ["Gemini 3.8 Flash", "Claude Opus 5.5", "GPT-OSS 120B"], "One window per model family, in model picker order, without internal models")
        expect(snapshot.windows.map(\.id) == ["model_gemini_3_8_flash", "model_claude_opus_5_5", "model_gpt_oss_120b"], "Stable ASCII window IDs")
        expect(abs((snapshot.windows[0].usedPercent ?? 0) - 60) < 0.001, "A family shows its most used thinking level")
        expect(snapshot.windows[1].usedPercent == 100, "An exhausted quota omits its zero fraction but is fully used")
        expect(snapshot.windows[2].usedPercent == 0, "An untouched quota is unused")
        expect(snapshot.windows.map(\.isProminent) == [true, true, false], "The first two families get full cards")
        expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: reset), "Keep the reset time")
        expect(snapshot.windows.allSatisfy { $0.duration == nil }, "Antigravity reports no window length, so none is invented")

        var unsorted = response
        unsorted["agentModelSorts"] = nil
        unsorted["groupedModels"] = nil
        let fallback = try AIUsageService.parse(try JSONSerialization.data(withJSONObject: unsorted), for: .antigravity, now: now)
        expect(fallback.windows.map(\.title) == ["Claude Opus 5.5", "Gemini 3.8 Flash", "GPT-OSS 120B"], "Without a model picker order, group by thinking level and sort by name")

        let plan = #"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#
        expect(AIUsageService.parseAntigravityPlan(Data(plan.utf8)) == "Google AI Pro", "Prefer the paid plan's name")
        expect(AIUsageService.parseAntigravityPlan(Data(#"{"currentTier":{"name":"Antigravity"}}"#.utf8)) == "Antigravity", "Fall back to the current tier")
    }

    static func clientSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codebar-antigravity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Assembled at run time so the fixture never looks like a real secret.
        let prefix = "GOCS" + "PX-"
        let first = prefix + String(repeating: "a", count: 27) + "1"
        let second = prefix + String(repeating: "B", count: 27) + "_"
        let packed = prefix + String(repeating: "c", count: 28)
        let tooShort = prefix + "short"
        var binary = Data([0, 1, 2])
        for text in [first, tooShort, second, first] {
            binary.append(contentsOf: Array(text.utf8) + [0, 0x7f])
        }
        // Go packs strings with no separator: the secret runs into the next one.
        binary.append(contentsOf: Array((packed + "unrelated_string").utf8))
        let url = directory.appendingPathComponent("language_server")
        try binary.write(to: url)

        let missing = directory.appendingPathComponent("missing")
        expect(AIUsageService.antigravityClientSecrets(binaries: [missing, url]) == [first, second, packed], "Find each well-formed secret once, in order, including one packed against the next string")
        expect(AIUsageService.antigravityClientSecrets(binaries: [missing]).isEmpty, "No installed binary means no secret")
    }
}
