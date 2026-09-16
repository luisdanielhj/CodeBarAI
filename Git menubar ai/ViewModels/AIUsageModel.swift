import Foundation
import Observation

@Observable
final class AIUsageState: Identifiable {
    let provider: AIUsageProvider
    var id: String { provider.id }
    var isInstalled: Bool
    var isEnabled: Bool
    var isRefreshing = false
    var snapshot: AIUsageSnapshot?
    var failure: String?
    var nextRefreshAt = Date.distantPast
    var generation = UUID()

    init(provider: AIUsageProvider, isInstalled: Bool, isEnabled: Bool) {
        self.provider = provider
        self.isInstalled = isInstalled
        self.isEnabled = isEnabled
    }
}

@Observable
final class AIUsageModel {
    let states: [AIUsageState]
    private let service = AIUsageService()
    private let defaults: UserDefaults
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        states = AIUsageProvider.allCases.map { provider in
            let key = "usage.enabled.\(provider.rawValue)"
            let isInstalled = provider.isInstalled
            let isEnabled = defaults.object(forKey: key) == nil
                ? isInstalled
                : defaults.bool(forKey: key)
            return AIUsageState(
                provider: provider,
                isInstalled: isInstalled,
                isEnabled: isEnabled
            )
        }
    }

    func connect(_ state: AIUsageState) async {
        state.isEnabled = true
        defaults.set(true, forKey: "usage.enabled.\(state.provider.rawValue)")
        await refresh(state)
    }

    func disconnect(_ state: AIUsageState) {
        state.generation = UUID()
        state.isEnabled = false
        state.isRefreshing = false
        state.snapshot = nil
        state.failure = nil
        state.nextRefreshAt = .distantPast
        defaults.set(false, forKey: "usage.enabled.\(state.provider.rawValue)")
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
            let isInstalled = state.provider.isInstalled
            state.isInstalled = isInstalled

            let key = "usage.enabled.\(state.provider.rawValue)"
            if defaults.object(forKey: key) == nil {
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
            let snapshot = try await service.load(state.provider)
            guard state.isEnabled, state.generation == generation else { return }
            state.snapshot = snapshot
            state.failure = nil
            state.nextRefreshAt = Date().addingTimeInterval(300)
        } catch {
            guard state.isEnabled, state.generation == generation else { return }
            state.failure = (error as? AIUsageError)?.errorDescription ?? "Usage is temporarily unavailable."
            state.nextRefreshAt = (error as? AIUsageError)?.retryAt ?? Date().addingTimeInterval(60)
        }
    }
}
