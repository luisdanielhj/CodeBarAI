import Foundation
import Observation

/// The user's choice of AI for commit messages, their API keys and models.
///
/// Preferences live in `UserDefaults`. API keys live only in the keychain,
/// through `APIKeyStore`; this model remembers whether one is saved and its
/// last four characters, never the key itself.
@Observable
final class CommitAISettingsModel {
    enum KeyStatus: Equatable {
        case unknown
        case missing
        case saved(suffix: String)

        var isSaved: Bool {
            if case .saved = self { return true }
            return false
        }
    }

    var provider: CommitAIProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    var includeDescription: Bool {
        didSet { defaults.set(includeDescription, forKey: Keys.includeDescription) }
    }

    private(set) var keyStatus: [CommitAIProvider: KeyStatus] = [:]
    private(set) var models: [CommitAIProvider: [CommitAIModelOption]] = [:]
    private(set) var selectedModels: [CommitAIProvider: String] = [:]
    private(set) var busyProviders: Set<CommitAIProvider> = []
    /// Last problem saving a key or loading models, per provider.
    var errors: [CommitAIProvider: String] = [:]

    private let defaults: UserDefaults

    private enum Keys {
        static let provider = "commitAI.provider"
        static let includeDescription = "commitAI.includeDescription"
        static func model(_ provider: CommitAIProvider) -> String { "commitAI.model.\(provider.rawValue)" }
        static func models(_ provider: CommitAIProvider) -> String { "commitAI.models.\(provider.rawValue).v1" }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Keys.provider).flatMap(CommitAIProvider.init(rawValue:)) ?? .apple
        includeDescription = defaults.object(forKey: Keys.includeDescription) == nil
            ? true
            : defaults.bool(forKey: Keys.includeDescription)
        for provider in CommitAIProvider.allCases where provider.isCloud {
            selectedModels[provider] = defaults.string(forKey: Keys.model(provider))
            models[provider] = defaults.data(forKey: Keys.models(provider))
                .flatMap { try? JSONDecoder().decode([CommitAIModelOption].self, from: $0) } ?? []
        }
    }

    // MARK: - Reading

    func status(for provider: CommitAIProvider) -> KeyStatus {
        keyStatus[provider] ?? .unknown
    }

    func isBusy(_ provider: CommitAIProvider) -> Bool {
        busyProviders.contains(provider)
    }

    func modelOptions(for provider: CommitAIProvider) -> [CommitAIModelOption] {
        models[provider] ?? []
    }

    func selectedModel(for provider: CommitAIProvider) -> String? {
        selectedModels[provider]
    }

    func selectModel(_ id: String, for provider: CommitAIProvider) {
        selectedModels[provider] = id
        defaults.set(id, forKey: Keys.model(provider))
    }

    /// Shown in the Generate button's tooltip.
    var engineDescription: String {
        switch provider {
        case .apple:
            return CommitMessageGenerator.onDeviceUnavailableReason == nil
                ? "Apple Intelligence, on this Mac"
                : "local rules (Apple Intelligence is unavailable)"
        case .openAI, .anthropic:
            return selectedModels[provider].map { "\($0) (\(provider.title))" } ?? provider.title
        }
    }

    // MARK: - Keys

    /// Checks the keychain for every cloud provider's key.
    func loadKeyStatus() async {
        for provider in CommitAIProvider.allCases where provider.isCloud {
            do {
                let key = try await APIKeyStore.key(for: provider)
                keyStatus[provider] = key.map { .saved(suffix: String($0.suffix(4))) } ?? .missing
            } catch {
                keyStatus[provider] = .missing
                errors[provider] = error.localizedDescription
            }
        }
    }

    /// Verifies the key by listing the provider's models, then saves it.
    /// Returns `true` when the key was saved.
    @discardableResult
    func saveKey(_ rawKey: String, for provider: CommitAIProvider) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.isCloud, !key.isEmpty, !isBusy(provider) else { return false }
        guard !key.contains(where: \.isWhitespace) else {
            errors[provider] = "That doesn't look like an API key: it contains spaces or line breaks."
            return false
        }

        busyProviders.insert(provider)
        defer { busyProviders.remove(provider) }
        errors[provider] = nil

        do {
            let options = try await CloudModelClient.listModels(for: provider, apiKey: key)
            try await APIKeyStore.save(key, for: provider)
            keyStatus[provider] = .saved(suffix: String(key.suffix(4)))
            store(options, for: provider)
            return true
        } catch {
            errors[provider] = error.localizedDescription
            return false
        }
    }

    func removeKey(for provider: CommitAIProvider) async {
        guard provider.isCloud, !isBusy(provider) else { return }
        busyProviders.insert(provider)
        defer { busyProviders.remove(provider) }
        do {
            try await APIKeyStore.delete(for: provider)
            keyStatus[provider] = .missing
            errors[provider] = nil
        } catch {
            errors[provider] = error.localizedDescription
        }
    }

    // MARK: - Models

    func refreshModels(for provider: CommitAIProvider) async {
        guard provider.isCloud, !isBusy(provider) else { return }
        busyProviders.insert(provider)
        defer { busyProviders.remove(provider) }
        errors[provider] = nil
        do {
            guard let key = try await APIKeyStore.key(for: provider) else {
                keyStatus[provider] = .missing
                return
            }
            store(try await CloudModelClient.listModels(for: provider, apiKey: key), for: provider)
        } catch {
            errors[provider] = error.localizedDescription
        }
    }

    private func store(_ options: [CommitAIModelOption], for provider: CommitAIProvider) {
        models[provider] = options
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Keys.models(provider))
        }
        let current = selectedModels[provider]
        if current == nil || !options.contains(where: { $0.id == current }),
           let fallback = CloudModelClient.defaultModel(for: provider, in: options) {
            selectModel(fallback, for: provider)
        }
    }

    // MARK: - Generation

    /// Everything a generation needs. Reads the API key from the keychain.
    func configuration() async throws -> CommitAIConfiguration {
        var configuration = CommitAIConfiguration(
            provider: provider,
            model: nil,
            apiKey: nil,
            includeDescription: includeDescription
        )
        guard provider.isCloud else { return configuration }

        guard let key = try await APIKeyStore.key(for: provider) else {
            keyStatus[provider] = .missing
            throw CloudModelError.missingKey(provider)
        }
        guard let model = selectedModels[provider] else {
            throw CloudModelError.missingModel(provider)
        }
        configuration.apiKey = key
        configuration.model = model
        return configuration
    }
}
