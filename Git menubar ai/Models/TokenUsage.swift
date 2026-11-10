import Foundation

/// Which coding tool a request came from.
nonisolated enum UsageSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex, kiro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .kiro: return "Kiro"
        }
    }

    var provider: AIUsageProvider {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .kiro: return .kiro
        }
    }
}

/// Token counts for one or more requests. The buckets do not overlap:
/// `input` excludes cached and cache-write tokens, so the total is their sum.
nonisolated struct TokenCounts: Codable, Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    /// Writes to Claude's 5-minute cache, or to OpenAI's prompt cache.
    var cacheWrite: Int = 0
    /// Writes to Claude's 1-hour cache, which cost more.
    var cacheWriteLong: Int = 0

    var total: Int { input + output + cacheRead + cacheWrite + cacheWriteLong }
    /// Everything sent to the model, for the long-prompt price tiers.
    var prompt: Int { input + cacheRead + cacheWrite + cacheWriteLong }

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheWriteLong: lhs.cacheWriteLong + rhs.cacheWriteLong
        )
    }

    static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// One model response read from a local log. Only counts and the model name
/// are kept, never prompt or response content.
nonisolated struct UsageEntry: Codable, Sendable {
    /// Identifies the response across files, so a resumed session that copies
    /// earlier messages is not counted twice.
    let key: String
    let date: Date
    let source: UsageSource
    let model: String
    var tokens: TokenCounts
    /// Claude requests pinned to US-only inference cost 1.1x.
    var isUSOnly: Bool = false
    /// Kiro bills each prompt in credits and logs no token counts. For Kiro,
    /// `tokens` is an estimate.
    var credits: Double?
    /// Model requests behind this entry. Kiro logs one entry per prompt, which
    /// can take many requests. `nil` means one.
    var requestCount: Int?
    /// Kiro only: what the estimated tokens would cost at API list prices.
    /// `nil` when the model has no API price, as with Auto.
    var estimatedAPICost: Double?
}

/// The rolling windows shown on the Cost and Tokens screens.
nonisolated enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, quarter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        }
    }

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    var duration: TimeInterval { TimeInterval(days) * 86_400 }
}

/// Cost and tokens for one slice of a period (a model, a tool, an hour, a day).
nonisolated struct UsageTotals: Sendable, Equatable {
    var cost: Double = 0
    var tokens = TokenCounts()
    /// Tokens from models with no known API price, left out of `cost`.
    var unpricedTokens = 0
    var requests = 0
    /// Kiro credits. Kiro's `cost` is its estimated API price, not credits.
    var credits: Double = 0
    /// Tokens estimated rather than counted, which is all of Kiro's.
    var estimatedTokens = 0
    /// Kiro credits whose model has no API price, left out of `cost`.
    var creditsWithoutAPIPrice: Double = 0

    mutating func add(_ entry: UsageEntry, cost entryCost: Double?) {
        tokens += entry.tokens
        requests += entry.requestCount ?? 1
        if let entryCredits = entry.credits {
            credits += entryCredits
            estimatedTokens += entry.tokens.total
            if entryCost == nil { creditsWithoutAPIPrice += entryCredits }
        }
        if let entryCost { cost += entryCost } else { unpricedTokens += entry.tokens.total }
    }
}

nonisolated struct ModelUsage: Identifiable, Sendable, Equatable {
    let model: String
    let source: UsageSource
    var totals = UsageTotals()
    var isPriced = true

    var id: String { "\(source.rawValue):\(model)" }
}

/// One bar of the chart: an hour for the 24-hour view, otherwise a day.
nonisolated struct UsageBucket: Identifiable, Sendable, Equatable {
    let start: Date
    var bySource: [UsageSource: UsageTotals] = [:]

    var id: Date { start }
    var cost: Double { bySource.values.reduce(0) { $0 + $1.cost } }
    var tokens: Int { bySource.values.reduce(0) { $0 + $1.tokens.total } }
}

nonisolated struct PeriodReport: Sendable, Equatable {
    var totals = UsageTotals()
    var bySource: [UsageSource: UsageTotals] = [:]
    var models: [ModelUsage] = []
    var buckets: [UsageBucket] = []
    /// Length of one bucket, so the chart can label it.
    var bucketLength: Calendar.Component = .day
}

nonisolated struct UsageReport: Sendable, Equatable {
    var periods: [UsagePeriod: PeriodReport] = [:]
    var generatedAt = Date()
    /// Tools whose logs were found on this Mac.
    var sourcesFound: Set<UsageSource> = []

    subscript(period: UsagePeriod) -> PeriodReport {
        periods[period] ?? PeriodReport()
    }
}
