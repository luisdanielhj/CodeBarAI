import Foundation

/// Runs with synthetic credentials and a fake usage service; never reads the
/// user's Keychain, launches Claude, or contacts a provider.
@main
nonisolated struct ClaudeAccountsTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codebar-accounts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try profileIdentity()
        try await credentials(in: root)
        try await modelLifecycle(in: root)
        try await menuBarOrganization(in: root)
        try await disconnectedMigration(in: root)
        try await inFlightRemoval(in: root)
        try await launchSelection(in: root)
        print("PASS: account identity, scoped credentials, discovery, persistence, menu bar visibility/order/migration, independent usage/backoff, disconnect, in-flight removal, and shell account selection")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func profileIdentity() throws {
        let home = URL(fileURLWithPath: "/tmp/codebar-home", isDirectory: true)
        let original = ClaudeAccountProfile.current(home: home, environment: [:])
        expect(original.id == "claude", "Keep the existing default preference identity")
        expect(original.keychainService == "Claude Code-credentials", "Keep the default Keychain service")
        expect(original.usesDefaultConfigDirectory, "Default launch must leave CLAUDE_CONFIG_DIR unset")
        let work = ClaudeAccountProfile(directory: URL(fileURLWithPath: "/tmp/claude-work"))
        expect(work.keychainService == "Claude Code-credentials-bfc1769a", "Match Claude's scoped Keychain hash")
        let equivalent = ClaudeAccountProfile(directory: URL(fileURLWithPath: "/tmp/unused/../claude-work/"))
        expect(work.id == equivalent.id, "Equivalent paths must not duplicate accounts")
        let customDefault = ClaudeAccountProfile.current(home: home, environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-work"])
        expect(customDefault.keychainService == work.keychainService, "Honor an inherited config directory")
        let override = ClaudeAccountProfile.current(home: home, environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/claude-work", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""
        ])
        expect(override.keychainService == original.keychainService, "An empty storage override means unscoped storage")
        let decomposed = ClaudeAccountProfile(directory: URL(fileURLWithPath: "/tmp/cafe\u{301}"))
        let composed = ClaudeAccountProfile(directory: URL(fileURLWithPath: "/tmp/caf\u{e9}"))
        expect(decomposed.id == composed.id, "Normalize Unicode as Claude does")
        let encoded = try JSONEncoder().encode(work)
        let decoded = try JSONDecoder().decode(ClaudeAccountProfile.self, from: encoded)
        expect(decoded == work, "Profile metadata round-trips")
    }

    static func tokenData(_ token: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": token, "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            "scopes": ["user:profile"]
        ]])
    }

    static func credentials(in root: URL) async throws {
        let first = ClaudeAccountProfile(directory: root.appendingPathComponent(".claude-first"))
        let second = ClaudeAccountProfile(directory: root.appendingPathComponent(".claude-second"))
        try FileManager.default.createDirectory(at: first.configDirectory, withIntermediateDirectories: true)
        try tokenData("synthetic-first").write(to: first.configDirectory.appendingPathComponent(".credentials.json"))
        let fileCredential = try await AIUsageService.readClaudeCredentials(for: first) { _ in
            preconditionFailure("A valid account file should not need Keychain access")
        }
        expect(fileCredential.token == "synthetic-first", "Read the selected account's credential file")
        let keychainData = try tokenData("synthetic-second")
        let keychainCredential = try await AIUsageService.readClaudeCredentials(for: second) { service in
            expect(service == second.keychainService, "Only request this account's scoped Keychain entry")
            return keychainData
        }
        expect(keychainCredential.token == "synthetic-second", "Use scoped Keychain when the file is absent")
        do {
            _ = try await AIUsageService.readClaudeCredentials(for: second) { service in
                // A default credential exists, but this account must not use it.
                service == "Claude Code-credentials" ? keychainData : nil
            }
            preconditionFailure("Missing scoped credentials must never use the default account")
        } catch AIUsageError.signInRequired(.claude) { }
    }

    @MainActor
    static func testDefaults() -> (UserDefaults, String) {
        let suite = "CodeBarAI.AccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "usage.enabled.cursor")
        defaults.set(false, forKey: "usage.enabled.codex")
        return (defaults, suite)
    }

    @MainActor
    static func modelLifecycle(in root: URL) async throws {
        let home = root.appendingPathComponent("model-home")
        let work = home.appendingPathComponent(".claude-account-2")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: work.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-backup"), withIntermediateDirectories: true)
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeUsageService()
        let model = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        expect(model.claudeAccounts.count == 2, "Discover profiles but skip unrelated folders")
        let original = model.claudeAccounts[0]
        let second = model.claudeAccounts[1]
        expect(model.addClaudeAccount(directory: work) === second, "Adding an existing folder must not duplicate it")
        model.renameClaudeAccount(second, to: "Work")
        model.selectClaudeAccount(second)
        model.setMenuBarVisibility(original, isVisible: false)
        model.setMenuBarVisibility(second, isVisible: true)
        expect(model.menuBarStates.filter { $0.provider == .claude }.map(\.id) == [second.id], "Only the chosen Claude account appears in the status item")
        await model.refreshAll()
        expect(original.snapshot?.plan == "Default", "Default usage stays on the default card")
        expect(second.snapshot?.plan == "Work", "Second account usage stays on its card")
        let restored = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        expect(restored.selectedClaudeAccount?.claudeProfile?.name == "Work", "Persist selection and labels across launches")
        expect(restored.claudeAccounts.count == 2, "Saved and discovered accounts must be deduplicated")

        let retry = Date().addingTimeInterval(900)
        await service.fail(second.id, until: retry)
        second.nextRefreshAt = .distantPast
        original.nextRefreshAt = .distantPast
        await model.refreshAll()
        expect(second.failure != nil && second.nextRefreshAt == retry, "Account rate limits keep their own retry time")
        expect(original.failure == nil && original.snapshot?.plan == "Default", "One account's error does not affect another")
        let calls = await service.callCount(for: second.id)
        await model.refresh(second)
        let callsAfterRetry = await service.callCount(for: second.id)
        expect(calls == callsAfterRetry, "Respect Retry-After for just the affected account")
        model.disconnect(second)
        expect(!second.isEnabled && original.isEnabled, "Disconnect only the chosen account")
        expect(second.snapshot == nil && second.failure == nil, "Disconnect clears stale data")
        model.removeClaudeAccount(second)
        model.discoverClaudeAccounts()
        expect(model.claudeAccounts.count == 1, "Removed discovered accounts must stay removed")
        expect(model.selectedClaudeAccountID == original.id, "Removing the selected account restores a valid default")
        expect(FileManager.default.fileExists(atPath: work.path), "Removing an account must not touch Claude's files")
        _ = model.addClaudeAccount(directory: work)
        expect(model.claudeAccounts.count == 2, "A removed account can be added again")
    }

    @MainActor
    static func menuBarOrganization(in root: URL) async throws {
        let home = root.appendingPathComponent("organizer-home")
        let work = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: work.appendingPathComponent(".claude.json"))
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let workID = ClaudeAccountProfile(directory: work).id
        defaults.set(workID, forKey: "usage.claude.selectedAccount")
        let service = FakeUsageService()
        let model = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        let original = model.claudeAccounts[0]
        let second = model.claudeAccounts[1]
        let codex = model.states.first { $0.provider == .codex }!
        let cursor = model.states.first { $0.provider == .cursor }!
        expect(model.menuBarStates.map(\.id) == [second.id, codex.id, cursor.id], "Upgrade must keep the previously displayed Claude account and provider order")
        model.setMenuBarVisibility(original, isVisible: true)
        expect(model.menuBarStates.filter { $0.provider == .claude }.count == 2, "Multiple Claude accounts can be displayed together")
        model.setMenuBarVisibility(cursor, isVisible: false)
        model.moveMenuBarAccount(second, by: -1)
        model.moveMenuBarAccount(codex, by: -1)
        model.moveMenuBarAccount(codex, by: -1)
        let expectedOrder = [codex.id, second.id, original.id]
        expect(model.menuBarStates.map(\.id) == expectedOrder, "The menu bar must honor account order across providers")
        model.moveMenuBarAccount(codex, by: -1)
        model.moveMenuBarAccount(cursor, by: 1)
        expect(model.menuBarStates.map(\.id) == expectedOrder, "Boundary moves must leave the order intact")
        model.renameClaudeAccount(second, to: "Work Account")
        await model.connect(original)
        let fetchedAt = original.snapshot?.fetchedAt
        model.setMenuBarVisibility(original, isVisible: false)
        expect(original.isEnabled && original.snapshot?.fetchedAt == fetchedAt, "Hiding an account must preserve its connection and usage")
        model.setMenuBarVisibility(original, isVisible: true)
        await model.refreshAll()
        expect(model.menuBarStates.map(\.id) == expectedOrder, "Background discovery must not change the chosen layout")

        let restored = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        expect(restored.menuBarStates.map(\.id) == expectedOrder, "Visibility and order must survive relaunch")
        expect(restored.menuBarAccountStates.first { $0.id == second.id }?.claudeProfile?.name == "Work Account", "Renaming must keep the same layout identity")
        for state in restored.states { restored.setMenuBarVisibility(state, isVisible: false) }
        let allHidden = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        expect(allHidden.menuBarStates.isEmpty, "An intentionally empty menu bar selection must survive relaunch")

        let extraDirectory = home.appendingPathComponent(".claude-new")
        try FileManager.default.createDirectory(at: extraDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extraDirectory.appendingPathComponent(".claude.json"))
        allHidden.discoverClaudeAccounts()
        let extraID = ClaudeAccountProfile(directory: extraDirectory).id
        guard let extra = allHidden.claudeAccounts.first(where: { $0.id == extraID }) else {
            preconditionFailure("Newly discovered accounts must be available in the organizer")
        }
        expect(allHidden.menuBarStates.isEmpty && !allHidden.isShownInMenuBar(extra), "Discovering an account must not change the user's visible selection")
        expect(allHidden.menuBarAccountStates.last?.id == extra.id, "New accounts must be appended to the organizer without disturbing existing order")
        allHidden.setMenuBarVisibility(extra, isVisible: true)
        allHidden.removeClaudeAccount(extra)
        expect(allHidden.menuBarStates.isEmpty && !allHidden.menuBarAccountOrder.contains(extra.id), "Removing an account clears only its own display preferences")

        defaults.set(["cursor", "missing", "claude", "cursor"], forKey: "usage.menuBar.accountOrder")
        defaults.set(["missing", "claude"], forKey: "usage.menuBar.visibleAccounts")
        let repaired = AIUsageModel(defaults: defaults, service: service, home: home, environment: [:])
        expect(repaired.menuBarAccountOrder == ["cursor", "claude", second.id, "codex"], "Ignore stale and duplicate saved entries while keeping the user's order")
        expect(repaired.menuBarStates.map(\.id) == ["claude"], "Discard only unavailable accounts from a saved selection")
    }

    @MainActor
    static func disconnectedMigration(in root: URL) async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "usage.enabled.claude")
        let service = FakeUsageService()
        let model = AIUsageModel(defaults: defaults, service: service, home: root.appendingPathComponent("model-home"), environment: [:])
        await model.refreshAll()
        expect(model.claudeAccounts.allSatisfy { !$0.isEnabled }, "Discovery must honor a preexisting Claude disconnect")
        let count = await service.totalCalls()
        expect(count == 0, "Disabled accounts must not read credentials or request usage")
    }

    @MainActor
    static func inFlightRemoval(in root: URL) async throws {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PausedUsageService()
        let model = AIUsageModel(defaults: defaults, service: service, home: root, environment: [:])
        let account = model.addClaudeAccount(directory: root.appendingPathComponent("manual-profile"))
        let refresh = Task { await model.refresh(account) }
        await service.waitForStart()
        model.removeClaudeAccount(account)
        await service.finish()
        await refresh.value
        expect(account.snapshot == nil && !account.isRefreshing, "A late request must not restore a removed account's data")
    }

    static func launchSelection(in root: URL) async throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("claude")
        try Data(#"""
#!/bin/sh
printf '%s\n%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" "${CLAUDE_SECURESTORAGE_CONFIG_DIR-UNSET}"
[ -z "${ANTHROPIC_API_KEY-}${ANTHROPIC_AUTH_TOKEN-}${CLAUDE_CODE_OAUTH_TOKEN-}${CLAUDE_CODE_USE_BEDROCK-}${CLAUDE_CODE_USE_VERTEX-}${CLAUDE_CODE_USE_FOUNDRY-}" ] || exit 9
"""#.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let tricky = root.appendingPathComponent("work 'quoted'; $(false)")
        let profile = ClaudeAccountProfile(directory: tricky)
        let startup = "export CLAUDE_CONFIG_DIR=/wrong; export CLAUDE_SECURESTORAGE_CONFIG_DIR=/wrong; "
            + "export ANTHROPIC_API_KEY=synthetic CLAUDE_CODE_OAUTH_TOKEN=synthetic CLAUDE_CODE_USE_BEDROCK=1; "
            + "function claude() { echo WRONG; }; "
        let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path]
        let chosen = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", startup + SystemIntegration.claudeCommand(for: profile)], environment: environment)
        expect(chosen.isSuccess && chosen.standardOutput == "\(profile.configDirectory.path)\n\(profile.keychainDirectory!)\n", "Shell functions and special characters must not override the selected account")
        let original = ClaudeAccountProfile.current(home: root, environment: [:])
        let defaultLaunch = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", startup + SystemIntegration.claudeCommand(for: original)], environment: environment)
        expect(defaultLaunch.isSuccess && defaultLaunch.standardOutput == "UNSET\n\n", "Default launches must retain the original config and unscoped Keychain lookup")
    }
}

actor FakeUsageService: AIUsageLoading {
    private var calls: [String: Int] = [:]
    private var failures: [String: Date] = [:]

    func load(_ provider: AIUsageProvider, claudeProfile: ClaudeAccountProfile?) async throws -> AIUsageSnapshot {
        let id = claudeProfile?.id ?? provider.id
        calls[id, default: 0] += 1
        if let retry = failures[id] { throw AIUsageError.rateLimited(retry) }
        return AIUsageSnapshot(plan: claudeProfile?.name, windows: [], fetchedAt: Date())
    }

    func fail(_ id: String, until retry: Date) { failures[id] = retry }
    func callCount(for id: String) -> Int { calls[id, default: 0] }
    func totalCalls() -> Int { calls.values.reduce(0, +) }
}

actor PausedUsageService: AIUsageLoading {
    private var response: CheckedContinuation<AIUsageSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func load(_ provider: AIUsageProvider, claudeProfile: ClaudeAccountProfile?) async throws -> AIUsageSnapshot {
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForStart() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        response?.resume(returning: AIUsageSnapshot(plan: "Late result", windows: [], fetchedAt: Date()))
        response = nil
    }
}
