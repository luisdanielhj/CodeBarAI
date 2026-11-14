import Foundation

/// Calls the OpenAI and Anthropic HTTP APIs: list models and write one reply.
///
/// Uses an ephemeral session with no cookies or caches and refuses redirects,
/// so the API key is only ever sent to the provider's own host.
nonisolated enum CloudModelClient {
    private static let anthropicVersion = "2023-06-01"

    // MARK: - Listing models

    /// Models the key can use, best first. Also the cheapest way to check that a key works.
    static func listModels(for provider: CommitAIProvider, apiKey: String) async throws -> [CommitAIModelOption] {
        switch provider {
        case .apple:
            return []
        case .openAI:
            let request = try makeRequest(provider, path: "/v1/models", apiKey: apiKey, method: "GET")
            let root = try await send(request, provider: provider, timeout: 20)
            return openAIModels(from: root)
        case .anthropic:
            let request = try makeRequest(provider, path: "/v1/models?limit=100", apiKey: apiKey, method: "GET")
            let root = try await send(request, provider: provider, timeout: 20)
            return anthropicModels(from: root)
        }
    }

    /// OpenAI lists every model the account can reach, including embeddings,
    /// speech and image models. Keep the text models, newest first, and hide a
    /// dated snapshot when its undated alias is also listed.
    static func openAIModels(from root: [String: Any]) -> [CommitAIModelOption] {
        let entries = (root["data"] as? [[String: Any]]) ?? []
        let excluded = [
            "audio", "realtime", "tts", "transcribe", "whisper", "image", "dall-e", "embedding",
            "moderation", "search", "instruct", "babbage", "davinci", "computer-use", "sora"
        ]
        let candidates: [(id: String, created: Double)] = entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let lowercased = id.lowercased()
            let isTextFamily = lowercased.hasPrefix("gpt-") || lowercased.hasPrefix("chatgpt-")
                || (lowercased.first == "o" && lowercased.dropFirst().first?.isNumber == true)
            guard isTextFamily, !excluded.contains(where: lowercased.contains) else { return nil }
            return (id, (entry["created"] as? NSNumber)?.doubleValue ?? 0)
        }
        let ids = Set(candidates.map(\.id))
        return candidates
            .filter { candidate in
                guard let alias = undatedAlias(of: candidate.id) else { return true }
                return !ids.contains(alias)
            }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created > $1.created }
            .map { CommitAIModelOption(id: $0.id, name: $0.id) }
    }

    /// Anthropic already lists the newest models first.
    static func anthropicModels(from root: [String: Any]) -> [CommitAIModelOption] {
        let entries = (root["data"] as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CommitAIModelOption(id: id, name: name)
        }
    }

    /// The model to select when the user has not picked one yet.
    static func defaultModel(for provider: CommitAIProvider, in options: [CommitAIModelOption]) -> String? {
        switch provider {
        case .apple:
            return nil
        case .openAI:
            return options.first?.id
        case .anthropic:
            // Sonnet balances quality and speed; a commit message needs no more.
            return options.first { $0.id.contains("sonnet") }?.id ?? options.first?.id
        }
    }

    /// `gpt-5.5-2026-04-23` → `gpt-5.5`.
    private static func undatedAlias(of id: String) -> String? {
        let parts = id.split(separator: "-")
        guard parts.count > 3,
              parts.suffix(3).allSatisfy({ $0.allSatisfy(\.isNumber) }),
              parts[parts.count - 3].count == 4 else { return nil }
        return parts.dropLast(3).joined(separator: "-")
    }

    // MARK: - Writing a reply

    /// Sends one system instruction and one user message, returning the reply text.
    static func complete(
        provider: CommitAIProvider,
        model: String,
        apiKey: String,
        instructions: String,
        prompt: String
    ) async throws -> String {
        switch provider {
        case .apple:
            throw CloudModelError.emptyResponse(provider)
        case .openAI:
            var request = try makeRequest(provider, path: "/v1/responses", apiKey: apiKey, method: "POST")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "instructions": instructions,
                "input": prompt,
                // Leaves room for reasoning models to think before answering.
                "max_output_tokens": 8_000,
                // Don't keep the diff on OpenAI's servers.
                "store": false
            ] as [String: Any])
            let root = try await send(request, provider: provider, timeout: 120)
            return try openAIText(from: root)
        case .anthropic:
            var request = try makeRequest(provider, path: "/v1/messages", apiKey: apiKey, method: "POST")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                // Thinking counts against this limit, so leave headroom.
                "max_tokens": 8_000,
                "system": instructions,
                "messages": [["role": "user", "content": prompt]]
            ] as [String: Any])
            let root = try await send(request, provider: provider, timeout: 120)
            return try anthropicText(from: root)
        }
    }

    static func openAIText(from root: [String: Any]) throws -> String {
        let output = (root["output"] as? [[String: Any]]) ?? []
        let text = output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let reason = (root["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw reason == "max_output_tokens" ? CloudModelError.truncated(.openAI) : CloudModelError.emptyResponse(.openAI)
        }
        return text
    }

    static func anthropicText(from root: [String: Any]) throws -> String {
        let content = (root["content"] as? [[String: Any]]) ?? []
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw (root["stop_reason"] as? String) == "max_tokens"
                ? CloudModelError.truncated(.anthropic)
                : CloudModelError.emptyResponse(.anthropic)
        }
        return text
    }

    // MARK: - HTTP

    private static func makeRequest(
        _ provider: CommitAIProvider,
        path: String,
        apiKey: String,
        method: String
    ) throws -> URLRequest {
        let host = provider == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com"
        guard let url = URL(string: host + path) else { throw CloudModelError.emptyResponse(provider) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        default:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func send(
        _ request: URLRequest,
        provider: CommitAIProvider,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
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
            case .timedOut: throw CloudModelError.timedOut(provider)
            case .cancelled: throw CancellationError()
            default: throw CloudModelError.networkUnavailable(provider)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw CloudModelError.emptyResponse(provider) }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = errorMessage(in: root)

        switch http.statusCode {
        case 200..<300:
            return root
        case 300..<400:
            throw CloudModelError.redirectRejected(provider)
        case 401, 403:
            throw CloudModelError.keyRejected(provider)
        case 404:
            throw CloudModelError.modelUnavailable(provider, message)
        case 429:
            throw CloudModelError.rateLimited(provider, message)
        case 400..<500:
            throw CloudModelError.requestRejected(provider, message)
        default:
            throw CloudModelError.serviceUnavailable(provider, message)
        }
    }

    /// Both APIs put a readable explanation at `error.message`.
    private static func errorMessage(in root: [String: Any]) -> String? {
        guard let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
    }
}

/// Keeps a bearer token from following a redirect to another host.
nonisolated final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated enum CloudModelError: LocalizedError {
    case missingKey(CommitAIProvider)
    case missingModel(CommitAIProvider)
    case keyRejected(CommitAIProvider)
    case modelUnavailable(CommitAIProvider, String?)
    case rateLimited(CommitAIProvider, String?)
    case requestRejected(CommitAIProvider, String?)
    case serviceUnavailable(CommitAIProvider, String?)
    case networkUnavailable(CommitAIProvider)
    case timedOut(CommitAIProvider)
    case redirectRejected(CommitAIProvider)
    case emptyResponse(CommitAIProvider)
    case truncated(CommitAIProvider)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "Add your \(provider.title) API key in Settings first."
        case .missingModel(let provider):
            return "Pick a \(provider.title) model in Settings first."
        case .keyRejected(let provider):
            return "\(provider.title) rejected the API key. Check it in Settings, or create a new one."
        case .modelUnavailable(let provider, let detail):
            return with(detail, "\(provider.title) can't find that model. Pick another one in Settings.")
        case .rateLimited(let provider, let detail):
            return with(detail, "\(provider.title) is rate limiting requests, or the account is out of credit.")
        case .requestRejected(let provider, let detail):
            return with(detail, "\(provider.title) rejected the request.")
        case .serviceUnavailable(let provider, let detail):
            return with(detail, "\(provider.title) is having problems. Try again in a moment.")
        case .networkUnavailable(let provider):
            return "Could not reach \(provider.title). Check your internet connection."
        case .timedOut(let provider):
            return "\(provider.title) took too long to answer. Try again."
        case .redirectRejected(let provider):
            return "\(provider.title) asked to redirect the request. It was blocked to protect your API key."
        case .emptyResponse(let provider):
            return "\(provider.title) returned an empty answer. Try again or pick another model."
        case .truncated(let provider):
            return "\(provider.title) ran out of output space before writing the message. Try another model."
        }
    }

    private func with(_ detail: String?, _ summary: String) -> String {
        guard let detail else { return summary }
        return "\(summary) \(detail)"
    }
}
