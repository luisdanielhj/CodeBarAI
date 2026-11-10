import Foundation
import Observation

@Observable
final class AIUsageState: Identifiable {
    let provider: AIUsageProvider
    var claudeProfile: ClaudeAccountProfile?
    var id: String { claudeProfile?.id ?? provider.id }
    var title: String {
        claudeProfile.map { "Claude · \($0.name)" } ?? provider.title
    }
    var isInstalled: Bool
    var isEnabled: Bool
    var isRefreshing = false
    var snapshot: AIUsageSnapshot?
    var failure: String?
    /// The saved sign-in is encrypted and the user has not yet let this app
    /// read the Keychain key for it.
    var needsKeychainApproval = false
    var isRequestingKeychainAccess = false
    var nextRefreshAt = Date.distantPast
    var generation = UUID()
    /// The reset being used right now.
    var redeemingResetID: String?
    /// Outcome of the last reset, shown until dismissed.
    var resetNotice: AIUsageResetNotice?
    /// Request IDs of attempts that ended without an answer, kept so a retry
    /// cannot use a second reset.
    var pendingResetRequestIDs: [String: String] = [:]

    init(provider: AIUsageProvider, isInstalled: Bool, isEnabled: Bool, claudeProfile: ClaudeAccountProfile? = nil) {
        self.provider = provider
        self.claudeProfile = claudeProfile
        self.isInstalled = isInstalled
        self.isEnabled = isEnabled
    }
}

struct AIUsageResetNotice: Equatable {
    let succeeded: Bool
    let message: String
}

@Observable
final class AIUsageModel {
    private(set) var states: [AIUsageState]
    private(set) var selectedClaudeAccountID: String
    private(set) var menuBarAccountOrder: [String]
    private(set) var menuBarVisibleAccountIDs: Set<String>
    private let service: any AIUsageLoading
    private let defaults: UserDefaults
    private let home: URL
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        service: any AIUsageLoading = AIUsageService(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.service = service
        self.home = home
        selectedClaudeAccountID = defaults.string(forKey: "usage.claude.selectedAccount") ?? "claude"
        menuBarAccountOrder = defaults.stringArray(forKey: "usage.menuBar.accountOrder") ?? []
        menuBarVisibleAccountIDs = Set(defaults.stringArray(forKey: "usage.menuBar.visibleAccounts") ?? [])
        states = AIUsageProvider.allCases.map { provider in
            let key = "usage.enabled.\(provider.rawValue)"
            let isInstalled = provider.isInstalled
            let isEnabled = defaults.object(forKey: key) == nil
                ? isInstalled
                : defaults.bool(forKey: key)
            return AIUsageState(
                provider: provider,
                isInstalled: isInstalled,
                isEnabled: isEnabled,
                claudeProfile: provider == .claude ? .current(home: home, environment: environment) : nil
            )
        }
        let saved = defaults.data(forKey: "usage.claude.accounts")
            .flatMap { try? JSONDecoder().decode([ClaudeAccountProfile].self, from: $0) } ?? []
        for profile in saved where !profile.isDefault {
            appendClaudeAccount(profile)
        }
        discoverClaudeAccounts()
        if !claudeAccounts.contains(where: { $0.id == selectedClaudeAccountID }) {
            selectedClaudeAccountID = "claude"
        }
        // Preserve the previous single-Claude layout when upgrading. An empty
        // saved selection is intentional and leaves the repository icon visible.
        if defaults.object(forKey: "usage.menuBar.visibleAccounts") == nil {
            menuBarVisibleAccountIDs = Set(states.filter {
                $0.provider != .claude || $0.id == selectedClaudeAccountID
            }.map(\.id))
        }
        menuBarVisibleAccountIDs.formIntersection(states.map(\.id))
        saveMenuBarPreferences()
    }

    var claudeAccounts: [AIUsageState] { states.filter { $0.provider == .claude } }

    var selectedClaudeAccount: AIUsageState? {
        claudeAccounts.first { $0.id == selectedClaudeAccountID } ?? claudeAccounts.first
    }

    /// The organizer includes hidden accounts so they can be shown again
    /// without reconnecting or changing a Claude launch preference.
    var menuBarAccountStates: [AIUsageState] {
        let accounts = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        return menuBarAccountOrder.compactMap { accounts[$0] }
    }

    var menuBarStates: [AIUsageState] {
        menuBarAccountStates.filter { isShownInMenuBar($0) }
    }

    func isShownInMenuBar(_ state: AIUsageState) -> Bool {
        menuBarVisibleAccountIDs.contains(state.id)
    }

    func setMenuBarVisibility(_ state: AIUsageState, isVisible: Bool) {
        guard states.contains(where: { $0 === state }) else { return }
        if isVisible {
            menuBarVisibleAccountIDs.insert(state.id)
        } else {
            menuBarVisibleAccountIDs.remove(state.id)
        }
        saveMenuBarPreferences()
    }

    func moveMenuBarAccount(_ state: AIUsageState, by offset: Int) {
        guard states.contains(where: { $0 === state }),
              let index = menuBarAccountOrder.firstIndex(of: state.id) else { return }
        let destination = index + offset
        guard menuBarAccountOrder.indices.contains(destination) else { return }
        menuBarAccountOrder.remove(at: index)
        menuBarAccountOrder.insert(state.id, at: destination)
        saveMenuBarPreferences()
    }

    private func synchronizeMenuBarOrder() {
        let providerOrder: [AIUsageProvider: Int] = [.claude: 0, .codex: 1, .cursor: 2, .kiro: 3]
        let standardOrder = states.enumerated().sorted { lhs, rhs in
            let lhsOrder = providerOrder[lhs.element.provider, default: .max]
            let rhsOrder = providerOrder[rhs.element.provider, default: .max]
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map { $0.element.id }
        let available = Set(standardOrder)
        var seen = Set<String>()
        let order = (menuBarAccountOrder + standardOrder).filter {
            available.contains($0) && seen.insert($0).inserted
        }
        // This runs on every auto refresh. Reassigning an unchanged order would
        // still re-render the status item image.
        guard order != menuBarAccountOrder else { return }
        menuBarAccountOrder = order
        defaults.set(menuBarAccountOrder, forKey: "usage.menuBar.accountOrder")
    }

    private func saveMenuBarPreferences() {
        defaults.set(menuBarAccountOrder, forKey: "usage.menuBar.accountOrder")
        defaults.set(menuBarAccountOrder.filter { menuBarVisibleAccountIDs.contains($0) },
                     forKey: "usage.menuBar.visibleAccounts")
    }

    func selectClaudeAccount(_ state: AIUsageState) {
        guard state.provider == .claude, states.contains(where: { $0 === state }) else { return }
        selectedClaudeAccountID = state.id
        defaults.set(state.id, forKey: "usage.claude.selectedAccount")
    }

    func renameClaudeAccount(_ state: AIUsageState, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, state.claudeProfile != nil else { return }
        state.claudeProfile?.name = String(name.prefix(60))
        if state.claudeProfile?.isDefault == true {
            defaults.set(state.claudeProfile?.name, forKey: "usage.claude.defaultName")
        }
        saveClaudeAccounts()
    }

    @discardableResult
    func addClaudeAccount(directory: URL) -> AIUsageState {
        let profile = ClaudeAccountProfile(directory: directory)
        let state = appendClaudeAccount(profile)
        var hidden = defaults.stringArray(forKey: "usage.claude.hiddenAccounts") ?? []
        hidden.removeAll { $0 == profile.id }
        defaults.set(hidden, forKey: "usage.claude.hiddenAccounts")
        synchronizeMenuBarOrder()
        saveClaudeAccounts()
        return state
    }

    func removeClaudeAccount(_ state: AIUsageState) {
        guard let profile = state.claudeProfile, !profile.isDefault else { return }
        disconnect(state)
        states.removeAll { $0 === state }
        menuBarVisibleAccountIDs.remove(state.id)
        synchronizeMenuBarOrder()
        saveMenuBarPreferences()
        var hidden = defaults.stringArray(forKey: "usage.claude.hiddenAccounts") ?? []
        if !hidden.contains(profile.id) { hidden.append(profile.id) }
        defaults.set(hidden, forKey: "usage.claude.hiddenAccounts")
        if selectedClaudeAccountID == state.id, let fallback = claudeAccounts.first {
            selectClaudeAccount(fallback)
        }
        saveClaudeAccounts()
    }

    func discoverClaudeAccounts() {
        let hidden = Set(defaults.stringArray(forKey: "usage.claude.hiddenAccounts") ?? [])
        for profile in ClaudeAccountProfile.discover(home: home) where !hidden.contains(profile.id) {
            appendClaudeAccount(profile)
        }
        if let name = defaults.string(forKey: "usage.claude.defaultName"),
           let account = claudeAccounts.first(where: { $0.claudeProfile?.isDefault == true }),
           account.claudeProfile?.name != name {
            account.claudeProfile?.name = name
        }
        synchronizeMenuBarOrder()
        saveClaudeAccounts()
    }

    @discardableResult
    private func appendClaudeAccount(_ profile: ClaudeAccountProfile) -> AIUsageState {
        if let existing = claudeAccounts.first(where: {
            $0.claudeProfile?.configDirectory == profile.configDirectory
                && $0.claudeProfile?.keychainService == profile.keychainService
        }) { return existing }
        let key = "usage.enabled.\(profile.id)"
        let enabled = defaults.object(forKey: key) == nil
            ? (defaults.object(forKey: "usage.enabled.claude") == nil || defaults.bool(forKey: "usage.enabled.claude"))
            : defaults.bool(forKey: key)
        let state = AIUsageState(provider: .claude, isInstalled: true, isEnabled: enabled, claudeProfile: profile)
        defaults.set(enabled, forKey: key)
        let insertionIndex = states.lastIndex { $0.provider == .claude }.map { $0 + 1 } ?? 0
        states.insert(state, at: insertionIndex)
        return state
    }

    private func saveClaudeAccounts() {
        let profiles = claudeAccounts.compactMap(\.claudeProfile).filter { !$0.isDefault }
        if let data = try? JSONEncoder().encode(profiles),
           data != defaults.data(forKey: "usage.claude.accounts") {
            defaults.set(data, forKey: "usage.claude.accounts")
        }
    }

    func connect(_ state: AIUsageState) async {
        state.isEnabled = true
        defaults.set(true, forKey: "usage.enabled.\(state.id)")
        await refresh(state)
    }

    func disconnect(_ state: AIUsageState) {
        state.generation = UUID()
        state.isEnabled = false
        state.isRefreshing = false
        state.snapshot = nil
        state.failure = nil
        state.needsKeychainApproval = false
        state.nextRefreshAt = .distantPast
        state.redeemingResetID = nil
        state.resetNotice = nil
        state.pendingResetRequestIDs = [:]
        defaults.set(false, forKey: "usage.enabled.\(state.id)")
    }

    /// Uses one saved reset, then reads usage again to show the new limits.
    func redeemReset(_ credit: AIUsageResetCredit, for state: AIUsageState) async {
        guard state.isEnabled, state.redeemingResetID == nil, credit.isUsable,
              states.contains(where: { $0 === state }),
              state.snapshot?.resets.contains(where: { $0.id == credit.id }) == true else { return }
        let generation = state.generation
        let requestID = state.pendingResetRequestIDs[credit.id] ?? UUID().uuidString.lowercased()
        state.pendingResetRequestIDs[credit.id] = requestID
        state.redeemingResetID = credit.id
        state.resetNotice = nil

        let notice: AIUsageResetNotice
        var mayRefresh = true
        do {
            let result = try await service.redeemReset(
                credit,
                provider: state.provider,
                claudeProfile: state.claudeProfile,
                requestID: requestID
            )
            guard state.generation == generation else { return }
            state.pendingResetRequestIDs[credit.id] = nil
            notice = AIUsageResetNotice(succeeded: result.restored, message: result.message)
        } catch {
            guard state.generation == generation else { return }
            let reason = (error as? AIUsageError)?.errorDescription ?? "The reset service is unavailable."
            mayRefresh = (error as? AIUsageError)?.retryAt == nil
            notice = AIUsageResetNotice(
                succeeded: false,
                message: "Couldn't confirm the reset. \(reason) Trying again won't use a second reset."
            )
        }
        state.redeemingResetID = nil
        state.resetNotice = notice
        // Read the new limits and the remaining resets right away, unless the
        // service asked to wait.
        guard mayRefresh else { return }
        state.nextRefreshAt = .distantPast
        await refresh(state)
    }

    func dismissResetNotice(for state: AIUsageState) {
        state.resetNotice = nil
    }

    /// Lets the service read the Keychain key the provider's sign-in is
    /// encrypted with. macOS asks the user first, which is why this runs only
    /// from a button.
    func allowKeychainAccess(for state: AIUsageState) async {
        guard state.isEnabled, !state.isRequestingKeychainAccess else { return }
        let generation = state.generation
        state.isRequestingKeychainAccess = true
        defer {
            if state.generation == generation { state.isRequestingKeychainAccess = false }
        }
        do {
            try await service.allowKeychainAccess(for: state.provider)
        } catch {
            guard state.generation == generation else { return }
            state.failure = (error as? AIUsageError)?.errorDescription ?? "Could not read the Keychain."
            return
        }
        guard state.generation == generation else { return }
        state.nextRefreshAt = .distantPast
        await refresh(state)
    }

    /// Keeps usage current for the status item, which has no view lifecycle of
    /// its own to run a refresh loop from. Idempotent.
    func startAutoRefresh(every interval: Duration = .seconds(60)) {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refreshAll() async {
        discoverClaudeAccounts()
        refreshInstalledProviders()
        await withTaskGroup(of: Void.self) { group in
            for state in states where state.isEnabled {
                group.addTask { @MainActor in
                    await self.refresh(state)
                }
            }
        }
    }

    private func refreshInstalledProviders() {
        for state in states {
            let isInstalled = state.claudeProfile.map {
                FileManager.default.fileExists(atPath: $0.configDirectory.path) || state.provider.isInstalled
            } ?? state.provider.isInstalled
            if state.isInstalled != isInstalled { state.isInstalled = isInstalled }

            let key = "usage.enabled.\(state.id)"
            if defaults.object(forKey: key) == nil, state.isEnabled != isInstalled {
                state.isEnabled = isInstalled
            }
        }
    }

    func refresh(_ state: AIUsageState) async {
        guard state.isEnabled, !state.isRefreshing, Date() >= state.nextRefreshAt else { return }
        let generation = state.generation
        state.isRefreshing = true
        defer {
            if state.generation == generation { state.isRefreshing = false }
        }
        do {
            let snapshot = try await service.load(state.provider, claudeProfile: state.claudeProfile)
            guard state.isEnabled, state.generation == generation else { return }
            state.snapshot = snapshot
            state.failure = nil
            state.needsKeychainApproval = false
            state.nextRefreshAt = Date().addingTimeInterval(300)
        } catch {
            guard state.isEnabled, state.generation == generation else { return }
            state.failure = (error as? AIUsageError)?.errorDescription ?? "Usage is temporarily unavailable."
            if case .keychainApprovalRequired = error as? AIUsageError {
                state.needsKeychainApproval = true
            } else {
                state.needsKeychainApproval = false
            }
            state.nextRefreshAt = (error as? AIUsageError)?.retryAt ?? Date().addingTimeInterval(60)
        }
    }
}
