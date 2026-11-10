import Charts
import SwiftUI

/// What the Cost and Tokens screens measure.
enum UsageMetric {
    case cost, tokens
}

enum UsageFormat {
    static func cost(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        let digits = value >= 1_000 ? 0 : 2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
    }

    /// Whole dollars for chart ticks, cents only below a dollar.
    static func axisCost(_ value: Double) -> String {
        let digits = value < 1 && value > 0 ? 2 : 0
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1_000_000_000...: return compact(number / 1_000_000_000, "B")
        case 1_000_000...: return compact(number / 1_000_000, "M")
        case 1_000...: return compact(number / 1_000, "K")
        default: return "\(value)"
        }
    }

    private static func compact(_ value: Double, _ unit: String) -> String {
        let digits = value >= 100 ? 0 : 1
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US"))) + unit
    }

    static func value(_ totals: UsageTotals, _ metric: UsageMetric) -> String {
        metric == .cost ? cost(totals.cost) : tokens(totals.tokens.total)
    }

    static func credits(_ value: Double) -> String {
        let digits = value >= 100 ? 0 : 1
        let number = value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
        return number + (number == "1" || number == "1.0" ? " credit" : " credits")
    }

    /// Token count for the cost screens' detail text, or credits for Kiro,
    /// whose cost comes from its credits.
    static func costDetail(_ totals: UsageTotals, source: UsageSource) -> String {
        source == .kiro ? credits(totals.credits) : tokens(totals.tokens.total)
    }
}

extension UsageSource {
    /// Matches the bar colors on the Limits screen. Kiro gets its brand purple
    /// so its bars stay distinct from Codex's gray.
    var chartColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color.primary.opacity(0.45)
        case .kiro: return Color(red: 0.56, green: 0.33, blue: 0.96)
        }
    }

    /// Kiro logs no token counts, so its tokens are estimated.
    var tokensAreEstimated: Bool { self == .kiro }
}

/// The Cost or Tokens screen: four period totals, a chart for the selected
/// period, and breakdowns by tool and model.
struct UsageReportView: View {
    let model: TokenUsageModel
    let metric: UsageMetric
    @AppStorage("ui.usagePeriod") private var period: UsagePeriod = .week

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report = model.report {
                if report.sourcesFound.isEmpty {
                    EmptyState(
                        systemImage: "doc.text.magnifyingglass",
                        title: "No usage logs found",
                        message: "Cost and tokens are read from Claude Code, Codex and Kiro session logs on this Mac."
                    )
                } else {
                    PeriodGrid(report: report, metric: metric, selection: $period)
                    let current = report[period]
                    UsageChart(report: current, metric: metric, period: period)
                    if metric == .tokens {
                        TokenTypeBreakdown(tokens: current.totals.tokens)
                    }
                    SourceBreakdown(report: current, metric: metric, sourcesFound: report.sourcesFound)
                    if metric == .cost, report.sourcesFound.contains(.kiro) {
                        KiroCostBreakdown(totals: current.bySource[.kiro] ?? UsageTotals())
                    }
                    ModelBreakdown(report: current, metric: metric)
                    footnote(current, sourcesFound: report.sourcesFound)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading local session logs…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("The first scan can take a few seconds.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    private func footnote(_ report: PeriodReport, sourcesFound: Set<UsageSource>) -> some View {
        var text = metric == .cost
            ? "Estimated at standard API list prices from your local Claude Code and Codex logs. Plans bill differently, so this is what the same usage would cost on the API."
            : "Counted from your local Claude Code and Codex logs. Cache reads are prompt tokens served from the cache."
        if metric == .cost, report.totals.unpricedTokens > 0 {
            text += " \(UsageFormat.tokens(report.totals.unpricedTokens)) tokens from models without a public API price are not included."
        }
        if sourcesFound.contains(.kiro) {
            text += metric == .cost
                ? " Kiro logs no token counts, so its API price is estimated from the context-window usage it logs, assuming prompt caching. Its credits and plan rate are in the Kiro section."
                : " Kiro logs no token counts. Its tokens are estimated from the context-window usage it logs, assuming prompt caching, and miss thinking Kiro does not record."
        }
        text += " Cursor keeps no local usage log."
        return Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

// MARK: - Period grid

private struct PeriodGrid: View {
    let report: UsageReport
    let metric: UsageMetric
    @Binding var selection: UsagePeriod

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(UsagePeriod.allCases) { period in
                PeriodCard(
                    period: period,
                    totals: report[period].totals,
                    metric: metric,
                    isSelected: period == selection
                ) {
                    withAnimation(.snappy(duration: 0.2)) { selection = period }
                }
            }
        }
    }
}

private struct PeriodCard: View {
    let period: UsagePeriod
    let totals: UsageTotals
    let metric: UsageMetric
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var perDay: String? {
        guard period != .day else { return nil }
        let days = Double(period.days)
        switch metric {
        case .cost:
            guard totals.cost > 0 else { return nil }
            return "\(UsageFormat.cost(totals.cost / days))/day"
        case .tokens:
            guard totals.tokens.total > 0 else { return nil }
            return "\(UsageFormat.tokens(Int(Double(totals.tokens.total) / days)))/day"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(UsageFormat.value(totals, metric))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(perDay ?? (period == .day ? "\(totals.requests) requests" : " "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(isSelected ? 0.07 : (isHovering ? 0.05 : 0.035)),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.35) : Theme.cardStroke,
                                  lineWidth: isSelected ? 1.2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Chart

private struct UsageChart: View {
    let report: PeriodReport
    let metric: UsageMetric
    let period: UsagePeriod

    private struct Point: Identifiable {
        let start: Date
        let source: UsageSource
        let value: Double
        var id: String { "\(start.timeIntervalSince1970)-\(source.rawValue)" }
    }

    private var points: [Point] {
        report.buckets.flatMap { bucket in
            UsageSource.allCases.map { source in
                let totals = bucket.bySource[source] ?? UsageTotals()
                return Point(
                    start: bucket.start,
                    source: source,
                    value: metric == .cost ? totals.cost : Double(totals.tokens.total)
                )
            }
        }
    }

    private var unit: Calendar.Component { report.bucketLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: period == .day ? "By hour" : (period == .quarter ? "By week" : "By day"))
                .padding(.leading, 2)

            Chart(points) { point in
                BarMark(
                    x: .value("Time", point.start, unit: unit),
                    y: .value(metric == .cost ? "Cost" : "Tokens", point.value)
                )
                .foregroundStyle(by: .value("Tool", point.source.title))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(
                domain: UsageSource.allCases.map(\.title),
                range: UsageSource.allCases.map(\.chartColor)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric == .cost ? UsageFormat.axisCost(number) : UsageFormat.tokens(Int(number)))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: xFormat)
                        .font(.system(size: 9))
                }
            }
            .frame(height: 110)
            .padding(12)
            .card()
        }
    }

    private var xFormat: Date.FormatStyle {
        switch period {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month, .quarter: return .dateTime.month(.abbreviated).day()
        }
    }
}

// MARK: - Breakdowns

/// A label, a value and a thin bar showing its share.
private struct ShareRow<Leading: View>: View {
    let value: String
    var detail: String?
    let share: Double
    let tint: Color
    @ViewBuilder var leading: Leading

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(max(share, 0), 1))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct SourceBreakdown: View {
    let report: PeriodReport
    let metric: UsageMetric
    let sourcesFound: Set<UsageSource>

    var body: some View {
        let sources = UsageSource.allCases.filter { sourcesFound.contains($0) }
        let total = metric == .cost ? report.totals.cost : Double(report.totals.tokens.total)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "By tool")
                .padding(.leading, 2)
            VStack(spacing: 12) {
                ForEach(sources) { source in
                    let totals = report.bySource[source] ?? UsageTotals()
                    let value = metric == .cost ? totals.cost : Double(totals.tokens.total)
                    ShareRow(
                        value: UsageFormat.value(totals, metric),
                        detail: metric == .cost
                            ? UsageFormat.costDetail(totals, source: source)
                            : (source.tokensAreEstimated ? "est." : nil),
                        share: total > 0 ? value / total : 0,
                        tint: source.chartColor
                    ) {
                        HStack(spacing: 7) {
                            Image(source.provider.logoName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12, height: 12)
                                .foregroundStyle(source == .claude ? source.chartColor : .primary)
                            Text(source.title)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(12)
            .card()
        }
    }
}

private struct ModelBreakdown: View {
    let report: PeriodReport
    let metric: UsageMetric
    @State private var showingAll = false

    private let collapsedCount = 4

    var body: some View {
        let models = metric == .cost
            ? report.models
            : report.models.sorted { $0.totals.tokens.total > $1.totals.tokens.total }
        let visible = showingAll ? models : Array(models.prefix(collapsedCount))
        let total = metric == .cost ? report.totals.cost : Double(report.totals.tokens.total)

        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "By model") {
                    if models.count > collapsedCount {
                        Button(showingAll ? "Show less" : "Show all \(models.count)") {
                            withAnimation(.snappy(duration: 0.2)) { showingAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)

                VStack(spacing: 12) {
                    ForEach(visible) { usage in
                        let value = metric == .cost ? usage.totals.cost : Double(usage.totals.tokens.total)
                        ShareRow(
                            value: metric == .cost && !usage.isPriced && usage.totals.cost == 0
                                ? "No API price"
                                : UsageFormat.value(usage.totals, metric),
                            detail: metric == .cost
                                ? UsageFormat.costDetail(usage.totals, source: usage.source)
                                : (usage.source.tokensAreEstimated ? "est. · " : "") + "\(usage.totals.requests) req",
                            share: total > 0 ? value / total : 0,
                            tint: usage.source.chartColor
                        ) {
                            // Kiro serves the same Claude models as Claude Code, so name the tool.
                            Text(ModelPricing.displayName(for: usage.model)
                                 + (usage.source == .kiro ? " · Kiro" : ""))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .help(usage.model)
                        }
                    }
                }
                .padding(12)
                .card()
            }
        }
    }
}

/// Kiro's estimated API price, which is its cost everywhere on this screen,
/// next to its credits and what they cost at the plan rate.
private struct KiroCostBreakdown: View {
    let totals: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Kiro")
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 10) {
                row("API price", detail: "estimate", value: UsageFormat.cost(totals.cost))
                    .help("What the same work would cost at API list prices. Kiro logs no token counts, so tokens are estimated from the context-window usage it logs, assuming prompt caching. Thinking Kiro does not record is missed, so the real figure is likely higher.")
                row("Credits used", value: UsageFormat.credits(totals.credits))
                row("At plan rate",
                    detail: "\(UsageFormat.cost(ModelPricing.kiroCreditPrice))/credit",
                    value: UsageFormat.cost(totals.credits * ModelPricing.kiroCreditPrice))
                if totals.creditsWithoutAPIPrice > 0 {
                    Text("\(UsageFormat.credits(totals.creditsWithoutAPIPrice)) used on Auto have no single API price and are left out of the API price.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .card()
        }
    }

    private func row(_ title: String, detail: String? = nil, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }
}

private struct TokenTypeBreakdown: View {
    let tokens: TokenCounts

    var body: some View {
        let rows: [(String, Int, Double)] = [
            ("Input", tokens.input, 0.9),
            ("Output", tokens.output, 0.7),
            ("Cache read", tokens.cacheRead, 0.35),
            ("Cache write", tokens.cacheWrite + tokens.cacheWriteLong, 0.5)
        ]
        let total = Double(max(tokens.total, 1))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "By type")
                .padding(.leading, 2)
            VStack(spacing: 12) {
                ForEach(rows, id: \.0) { title, count, opacity in
                    ShareRow(
                        value: UsageFormat.tokens(count),
                        detail: Double(count) / total >= 0.001
                            ? (Double(count) / total).formatted(.percent.precision(.fractionLength(0...1)))
                            : nil,
                        share: Double(count) / total,
                        tint: Color.primary.opacity(opacity * 0.5)
                    ) {
                        Text(title)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(12)
            .card()
        }
    }
}
