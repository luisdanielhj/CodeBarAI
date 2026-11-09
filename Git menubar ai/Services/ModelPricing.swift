import Foundation

/// Public API list prices in USD per million tokens.
///
/// Sources, checked November 2026:
/// - Claude: https://platform.claude.com/docs/en/about-claude/pricing
/// - GPT-6.1 Sol and GPT-6 family: OpenAI's model announcement and API pricing pages
///
/// Batch discounts, long-context surcharges on OpenAI models and fast-mode
/// premiums are not modeled, so figures are estimates of standard usage.
nonisolated struct ModelPrice: Sendable, Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
    /// Claude 5-minute cache write, or OpenAI cache write.
    let cacheWrite: Double
    /// Claude 1-hour cache write.
    let cacheWriteLong: Double

    func cost(of tokens: TokenCounts) -> Double {
        (Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheRead) * cacheRead
            + Double(tokens.cacheWrite) * cacheWrite
            + Double(tokens.cacheWriteLong) * cacheWriteLong) / 1_000_000
    }
}

nonisolated enum ModelPricing {
    private static func claude(_ input: Double, _ write: Double, _ writeLong: Double, _ read: Double, _ output: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: read, cacheWrite: write, cacheWriteLong: writeLong)
    }

    private static func openAI(_ input: Double, cached: Double, output: Double, cacheWrite: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: cached,
                   cacheWrite: cacheWrite ?? input, cacheWriteLong: cacheWrite ?? input)
    }

    /// Longest, most specific prefix first, so `claude-opus-5-5` never falls
    /// through to `claude-opus-5`.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", claude(10, 12.5, 20, 0.25, 50)),
        ("claude-mythos-5-1", claude(10, 12.5, 20, 0.25, 50)),
        ("claude-fable-5", claude(10, 12.5, 20, 1, 50)),
        ("claude-mythos-5", claude(10, 12.5, 20, 1, 50)),
        ("claude-opus-5-5", claude(4, 5, 8, 0.2, 20)),
        ("claude-opus-5", claude(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-8", claude(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-7", claude(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-6", claude(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-5", claude(5, 6.25, 10, 0.5, 25)),
        ("claude-opus-4-1", claude(15, 18.75, 30, 1.5, 75)),
        ("claude-opus-4", claude(15, 18.75, 30, 1.5, 75)),
        ("claude-sonnet-5-5", claude(2, 2.5, 4, 0.1, 10)),
        ("claude-sonnet-5", claude(2, 2.5, 4, 0.2, 10)),
        ("claude-sonnet-4-6", claude(3, 3.75, 6, 0.3, 15)),
        ("claude-sonnet-4-5", claude(3, 3.75, 6, 0.3, 15)),
        ("claude-sonnet-4", claude(3, 3.75, 6, 0.3, 15)),
        ("claude-3-7-sonnet", claude(3, 3.75, 6, 0.3, 15)),
        ("claude-haiku-4-5", claude(1, 1.25, 2, 0.1, 5)),
        ("claude-3-5-haiku", claude(0.8, 1, 1.6, 0.08, 4)),
        ("gpt-6-astra", openAI(10, cached: 1, output: 50)),
        ("gpt-6.1-sol", openAI(2, cached: 0.1, output: 10, cacheWrite: 2.5)),
        ("gpt-6-sol", openAI(2, cached: 0.2, output: 10)),
        ("gpt-5-mini", openAI(0.25, cached: 0.025, output: 2)),
        ("gpt-5-nano", openAI(0.05, cached: 0.005, output: 0.4)),
        ("gpt-5", openAI(1.25, cached: 0.125, output: 10))
    ]

    /// Claude Haiku 5.5 doubles back to a higher rate above 100K prompt tokens.
    private static let haiku55Short = claude(0.1, 0.125, 0.2, 0.01, 0.5)
    private static let haiku55Long = claude(0.5, 0.625, 1, 0.05, 2.5)

    static func price(for model: String, promptTokens: Int) -> ModelPrice? {
        let id = model.lowercased()
        if id.hasPrefix("claude-haiku-5-5") {
            return promptTokens > 100_000 ? haiku55Long : haiku55Short
        }
        return table.first { id.hasPrefix($0.prefix) }?.price
    }

    /// `nil` when the model has no published API price, such as Codex's
    /// auto-review agent or a bare alias like `sonnet`.
    static func cost(of entry: UsageEntry) -> Double? {
        guard let price = price(for: entry.model, promptTokens: entry.tokens.prompt) else { return nil }
        var cost = price.cost(of: entry.tokens)
        // Claude 4.6 and later bill US-only inference at 1.1x.
        if entry.isUSOnly, entry.source == .claude { cost *= 1.1 }
        return cost
    }

    /// Short display name, e.g. `claude-opus-5-5-20261001` → `Opus 5.5`.
    static func displayName(for model: String) -> String {
        let id = model.lowercased()
        if id == "codex-auto-review" { return "Codex auto-review" }
        if id.hasPrefix("gpt-") {
            // gpt-6.1-sol → GPT-6.1 Sol
            let parts = id.split(separator: "-").map(String.init)
            guard parts.count >= 2 else { return model }
            let name = parts.dropFirst(2).map(\.capitalized).joined(separator: " ")
            return "GPT-\(parts[1])" + (name.isEmpty ? "" : " \(name)")
        }
        guard id.hasPrefix("claude-") else { return model }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // Drop a trailing date stamp.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        // Legacy ids put the version first: claude-3-7-sonnet.
        if let first = parts.first, Int(first) != nil, let family = parts.last, Int(family) == nil {
            let version = parts.dropLast().joined(separator: ".")
            return "\(family.capitalized) \(version)"
        }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
