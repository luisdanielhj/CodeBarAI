import Foundation

/// Estimates the tokens behind Kiro's credits, and what they would cost at API
/// list prices.
///
/// Kiro logs the credits each prompt used but no token counts. Before each
/// main-agent request it does log how full the context window is, which gives
/// the prompt size. Subagents log no context size, so their prompts are rebuilt
/// from the text in their own logs.
///
/// Prompt caching is assumed, as Anthropic bills it: a request within five
/// minutes of the previous one reads the earlier context from the cache and
/// writes only what is new. Output is counted from the reply and tool-call text
/// in the log. Kiro does not log all thinking, so output runs low.
nonisolated enum KiroUsageEstimator {
    static let charactersPerToken = 4
    static let cacheLifetime: TimeInterval = 5 * 60
    /// Stand-in for a subagent's system prompt and tools when the session has
    /// not logged a fresh context size to measure them by.
    static let defaultBaseContext = 20_000

    struct SubSession: Codable, Sendable {
        let id: String
        /// Length of the task the parent gave it, which starts its context.
        let promptCharacters: Int
    }

    /// Estimates for one prompt still in progress.
    struct Turn: Codable, Sendable {
        var tokens = TokenCounts()
        /// Main-agent requests with a logged context size.
        var requests = 0
        var model: String?
        var subSessions: [SubSession] = []
    }

    /// Context carried between requests in one session log.
    struct Context: Codable, Sendable {
        var tokens: Int?
        var date: Date?
        /// Smallest context seen, close to the system prompt and tools alone.
        var smallest: Int?
    }

    struct Estimate {
        var tokens = TokenCounts()
        /// `nil` when none of the models involved has an API price, as with Auto.
        var apiCost: Double?

        mutating func add(_ other: Estimate) {
            tokens += other.tokens
            if let cost = other.apiCost { apiCost = (apiCost ?? 0) + cost }
        }
    }

    /// Kiro's context window for a model id such as `claude-opus-5.5`. Most
    /// current models have 1M; older ones, and Auto, have 200K.
    static func contextWindow(for model: String) -> Int {
        let id = model.lowercased()
        if id.hasPrefix("deepseek") { return 128_000 }
        if id.hasPrefix("qwen3-coder") { return 256_000 }
        let small = ["auto", "claude-opus-4.5", "claude-sonnet-4.5", "claude-sonnet-4.0", "claude-haiku-4.5", "minimax", "glm-5"]
        return id == "claude-sonnet-4" || small.contains { id.hasPrefix($0) } ? 200_000 : 1_000_000
    }

    /// Adds one main-agent request, from the context-window percentage Kiro
    /// logged for it.
    static func addRequest(percent: Double, date: Date?, model: String, to turn: inout Turn, context: inout Context) {
        guard percent > 0 else { return }
        let size = Int(percent / 100 * Double(contextWindow(for: model)))
        if let previous = context.tokens, size >= previous,
           let last = context.date, let date, date.timeIntervalSince(last) <= cacheLifetime {
            turn.tokens.cacheRead += previous
            turn.tokens.cacheWrite += size - previous
        } else {
            // First request, a cache that expired, or a context that was compacted.
            turn.tokens.cacheWrite += size
        }
        turn.requests += 1
        context.tokens = size
        context.date = date
        context.smallest = min(context.smallest ?? size, size)
    }

    /// Characters of text in a log value: strings, and strings nested in
    /// arrays and objects.
    static func textLength(_ value: Any?) -> Int {
        switch value {
        case let text as String: return text.utf8.count
        case let array as [Any]: return array.reduce(0) { $0 + textLength($1) }
        case let object as [String: Any]: return object.values.reduce(0) { $0 + textLength($1) }
        default: return 0
        }
    }

    static func tokens(characters: Int) -> Int { characters / charactersPerToken }

    /// What the tokens would cost on the API, or `nil` without a price.
    static func apiCost(_ tokens: TokenCounts, requests: Int, model: String) -> Double? {
        // Kiro writes versions with dots (`claude-opus-5.5`); the price table uses dashes.
        let id = model.lowercased().replacingOccurrences(of: ".", with: "-")
        let averagePrompt = tokens.prompt / max(requests, 1)
        return ModelPricing.price(for: id, promptTokens: averagePrompt)?.cost(of: tokens)
    }

    /// Estimates the subagents one prompt started, from their logs.
    ///
    /// A new request starts at the first reply or tool call after tool results.
    /// Its prompt is the base context plus all text so far. When Kiro's request
    /// count says the subagents made `requests` calls, the prompt tokens are
    /// scaled to match it.
    static func subagents(
        _ sessions: [SubSession],
        directory: URL,
        requests: Int,
        baseContext: Int,
        fallbackModel: String
    ) -> Estimate {
        struct Log {
            var prompts: [Int] = []
            var output = 0
            var model: String?
        }

        var logs: [Log] = []
        for session in sessions {
            let url = directory.appendingPathComponent("\(session.id).jsonl")
            guard let data = try? Data(contentsOf: url) else { continue }
            var log = Log()
            var characters = session.promptCharacters
            var startsRequest = true
            for line in data.split(separator: 0x0A) {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String
                else { continue }
                switch type {
                case "assistant", "tool_call":
                    if startsRequest {
                        log.prompts.append(baseContext + tokens(characters: characters))
                        startsRequest = false
                    }
                    let length = textLength(type == "assistant" ? payload["content"] : payload["args"])
                    log.output += length
                    characters += length
                    if let model = payload["reasoningModelId"] as? String, !model.isEmpty {
                        log.model = model.components(separatedBy: "::").last
                    }
                case "tool_result":
                    characters += textLength(payload["content"])
                    startsRequest = true
                case "steering_inclusion":
                    characters += textLength(payload["documents"])
                default:
                    continue
                }
            }
            if !log.prompts.isEmpty { logs.append(log) }
        }

        let counted = logs.reduce(0) { $0 + $1.prompts.count }
        guard counted > 0 else { return Estimate() }
        let scale = requests > 0 ? Double(requests) / Double(counted) : 1

        var estimate = Estimate()
        for log in logs {
            var tokens = TokenCounts()
            var previous: Int?
            for prompt in log.prompts {
                if let previous, prompt >= previous {
                    tokens.cacheRead += previous
                    tokens.cacheWrite += prompt - previous
                } else {
                    tokens.cacheWrite += prompt
                }
                previous = prompt
            }
            tokens.cacheRead = Int(Double(tokens.cacheRead) * scale)
            tokens.cacheWrite = Int(Double(tokens.cacheWrite) * scale)
            tokens.output = self.tokens(characters: log.output)
            let requests = max(1, Int((Double(log.prompts.count) * scale).rounded()))
            estimate.add(Estimate(
                tokens: tokens,
                apiCost: apiCost(tokens, requests: requests, model: log.model ?? fallbackModel)
            ))
        }
        return estimate
    }
}
