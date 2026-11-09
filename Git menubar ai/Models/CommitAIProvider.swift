import Foundation

/// Which AI writes commit messages.
nonisolated enum CommitAIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple
    case openAI = "openai"
    case anthropic

    var id: Self { self }

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Cloud providers need an API key and receive the diff over the network.
    var isCloud: Bool { self != .apple }

    var keyPlaceholder: String {
        switch self {
        case .apple: return ""
        case .openAI: return "sk-…"
        case .anthropic: return "sk-ant-…"
        }
    }

    /// Where to create an API key.
    var keysURL: URL? {
        switch self {
        case .apple: return nil
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        }
    }
}

/// One model the user can pick for a cloud provider.
nonisolated struct CommitAIModelOption: Identifiable, Hashable, Codable, Sendable {
    /// The API model ID, e.g. `claude-sonnet-5-5`.
    var id: String
    /// What the picker shows. The provider's display name when it has one.
    var name: String
}

/// Everything one generation needs, resolved at the moment Generate is pressed.
nonisolated struct CommitAIConfiguration: Sendable {
    var provider: CommitAIProvider
    /// Required for cloud providers.
    var model: String?
    /// Required for cloud providers. Read from the keychain, never stored elsewhere.
    var apiKey: String?
    /// Add bullet points under the subject line.
    var includeDescription: Bool
}
