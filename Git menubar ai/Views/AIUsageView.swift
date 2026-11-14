import SwiftUI

/// Usage limits for every connected AI provider, one card per limit window.
struct LimitsView: View {
    let model: AIUsageModel
    @Binding var organizingMenuBar: Bool
    let maxHeight: CGFloat

    private var connected: [AIUsageState] { model.states.filter(\.isEnabled) }
    private var disconnected: [AIUsageState] { model.states.filter { !$0.isEnabled } }

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                if organizingMenuBar {
                    MenuBarAccountsOrganizer(model: model)
                } else {
                    if connected.isEmpty {
                        EmptyState(
                            systemImage: "gauge.with.dots.needle.33percent",
                            title: "No providers connected",
                            message: "Connect Claude Code, Codex, Cursor or Kiro CLI below to track your plan limits."
                        )
                    }
                    ForEach(connected) { state in
                        ProviderLimitsSection(model: model, state: state)
                    }
                    if !disconnected.isEmpty {
                        DisconnectedProviders(model: model, states: disconnected)
                    }
                }
            }
    }
}

/// The three views of AI usage.
enum UsageSection: String, CaseIterable, Identifiable {
    case limits, cost, tokens

    var id: Self { self }

    var title: String {
        switch self {
        case .limits: return "Limits"
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }
}

/// The Usage tab: plan limits, API-equivalent cost and token counts.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isMenuWindowVisible) private var isMenuWindowVisible
    @Binding var section: UsageSection
    @Binding var organizingMenuBar: Bool
    let maxHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if !organizingMenuBar {
                SegmentedControl(items: UsageSection.allCases, selection: $section, title: \.title)
                    .padding(.horizontal, Theme.edge)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            FittedScrollView(maxHeight: maxHeight - 40, estimatedHeight: 380) {
                Group {
                    switch section {
                    case .limits:
                        LimitsView(model: model.usage, organizingMenuBar: $organizingMenuBar, maxHeight: maxHeight)
                    case .cost:
                        UsageReportView(model: model.tokens, metric: .cost)
                    case .tokens:
                        UsageReportView(model: model.tokens, metric: .tokens)
                    }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, 12)
            }
        }
        .task(id: ScanTrigger(visible: isMenuWindowVisible, section: section)) {
            // Cost and tokens come from local logs. Read them only while one
            // of those screens is on screen, then once a minute.
            guard isMenuWindowVisible, section != .limits else { return }
            while !Task.isCancelled {
                await model.refreshTokenUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private struct ScanTrigger: Equatable {
        let visible: Bool
        let section: UsageSection
    }
}

// MARK: - Provider

private extension AIUsageProvider {
    /// Claude keeps its brand color. The others are monochrome, like their logos.
    var brandColor: Color? {
        self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : nil
    }

    var barTint: Color {
        brandColor?.opacity(0.45) ?? Color.primary.opacity(0.26)
    }
}

private struct ProviderLogo: View {
    let provider: AIUsageProvider
    var size: CGFloat = 13

    var body: some View {
        Image(provider.logoName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(provider.brandColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
    }
}

private struct ProviderLimitsSection: View {
    let model: AIUsageModel
    let state: AIUsageState
    @State private var renamingAccount = false
    @State private var accountName = ""
    /// The reset picked from the menu, waiting for confirmation.
    @State private var confirmingReset: AIUsageResetCredit?

    private var primaryWindows: [AIUsageWindow] {
        state.snapshot?.windows.filter(\.isPrimary) ?? []
    }

    private var otherWindows: [AIUsageWindow] {
        state.snapshot?.windows.filter { !$0.isPrimary } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let failure = state.failure {
                InlineBanner(
                    kind: .warning,
                    title: failure,
                    detail: "Retrying at \(state.nextRefreshAt.formatted(date: .omitted, time: .shortened))."
                )
            }

            if state.needsKeychainApproval {
                KeychainApprovalCard(isRequesting: state.isRequestingKeychainAccess) {
                    Task { await model.allowKeychainAccess(for: state) }
                }
            }

            if let snapshot = state.snapshot {
                if snapshot.windows.isEmpty {
                    Text("This plan reports no usage limits.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .card()
                }
                ForEach(primaryWindows) { window in
                    LimitCard(window: window, tint: state.provider.barTint)
                }
                if !otherWindows.isEmpty {
                    VStack(spacing: 9) {
                        ForEach(otherWindows) { window in
                            CompactLimitRow(window: window, tint: state.provider.barTint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .card()
                }
            } else if state.failure == nil {
                LimitPlaceholder()
            }

            if let notice = state.resetNotice {
                InlineBanner(
                    kind: notice.succeeded ? .success : .warning,
                    title: notice.message,
                    onDismiss: { model.dismissResetNotice(for: state) }
                )
            }
            if let credit = confirmingReset ?? redeemingReset {
                LimitResetConfirmation(
                    credit: credit,
                    weeklyResetsAt: weeklyResetsAt,
                    isRedeeming: state.redeemingResetID == credit.id,
                    onCancel: { confirmingReset = nil },
                    onConfirm: {
                        confirmingReset = nil
                        Task { await model.redeemReset(credit, for: state) }
                    }
                )
            }
        }
        // Right-clicking anywhere on the account opens the same options.
        .contentShape(Rectangle())
        .contextMenu { options }
        .onChange(of: state.snapshot?.resets.map(\.id) ?? []) { _, ids in
            if let confirmingReset, !ids.contains(confirmingReset.id) { self.confirmingReset = nil }
        }
        .alert("Rename Claude Account", isPresented: $renamingAccount) {
            TextField("Account name", text: $accountName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { model.renameClaudeAccount(state, to: accountName) }
                .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name such as Personal or Work.")
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderLogo(provider: state.provider)
            Text(state.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .help(state.claudeProfile?.configDirectory.path ?? state.kiroProfile?.database.path ?? state.provider.title)
            if let plan = state.snapshot?.plan {
                Text(plan.capitalized)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            IconMenu(help: "\(state.title) options") {
                options
            }
            .padding(.trailing, -6)
        }
        .padding(.leading, 2)
    }

    /// Items for both the options button and the right-click menu.
    @ViewBuilder private var options: some View {
        Toggle("Show in Menu Bar", isOn: Binding(
            get: { model.isShownInMenuBar(state) },
            set: { model.setMenuBarVisibility(state, isVisible: $0) }
        ))
        Button("Refresh Now") { Task { await model.refresh(state) } }
            .disabled(state.isRefreshing || Date() < state.nextRefreshAt)
        if let resets = state.snapshot?.resets, !resets.isEmpty {
            Divider()
            Menu("Limit Resets (\(resets.count))") {
                ForEach(resets) { credit in
                    Button(resetMenuTitle(credit)) { confirmingReset = credit }
                        .disabled(!credit.isUsable || state.redeemingResetID != nil)
                }
            }
        }
        if let profile = state.claudeProfile {
            Divider()
            Button("Rename Account…") {
                accountName = profile.name
                renamingAccount = true
            }
            if !profile.isDefault {
                Button("Remove from CodeBarAI", role: .destructive) {
                    model.removeClaudeAccount(state)
                }
            }
        }
        Divider()
        Button("Disconnect", role: .destructive) { model.disconnect(state) }
    }

    private func resetMenuTitle(_ credit: AIUsageResetCredit) -> String {
        var title = "Use \(credit.title)"
        if credit.count > 1 { title += " (×\(credit.count))" }
        if let reason = credit.unavailableReason {
            title += " · \(reason)"
        } else if let expiresAt = credit.expiresAt {
            title += "… · expires in \(DurationText.short(expiresAt.timeIntervalSinceNow))"
        } else {
            title += "…"
        }
        return title
    }

    /// The reset being used, kept on screen until the request finishes.
    private var redeemingReset: AIUsageResetCredit? {
        state.redeemingResetID.flatMap { id in state.snapshot?.resets.first { $0.id == id } }
    }

    /// When the weekly limit would reset without using a reset.
    private var weeklyResetsAt: Date? {
        state.snapshot?.windows.first { window in
            window.isPrimary && window.duration.map { abs($0 - 7 * 86_400) < 3_600 } == true
        }?.resetsAt
    }
}

// MARK: - Limit card

private extension AIUsageWindow {
    /// The windows that get a full card. Everything else is a compact row.
    var isPrimary: Bool {
        ["five_hour", "seven_day", "primary_window", "secondary_window", "plan", "credits"].contains(id)
    }

    var displayTitle: String {
        switch id {
        case "plan": return "Billing cycle"
        case "seven_day_sonnet": return "Sonnet weekly"
        case "seven_day_opus": return "Opus weekly"
        default: break
        }
        guard let duration else { return title }
        if duration <= 86_400 { return "Session" }
        if abs(duration - 7 * 86_400) < 3_600 { return "Weekly" }
        return title
    }
}

/// Derived numbers for one window at one moment.
private struct LimitMetrics {
    /// 0...100, or nil when the provider did not report usage.
    let percentLeft: Double?
    /// Share of the window still to run, 0...1. Drawn as the marker.
    let timeLeftFraction: Double?
    let timeUntilReset: TimeInterval?
    /// Time until the limit runs out at the current pace, set only when that
    /// happens before the reset.
    let runsOutIn: TimeInterval?

    init(window: AIUsageWindow, now: Date) {
        let left = window.usedPercent.map { 100 - min(max($0, 0), 100) }
        percentLeft = left

        let remaining = window.resetsAt.map { $0.timeIntervalSince(now) }.flatMap { $0 > 0 ? $0 : nil }
        timeUntilReset = remaining

        guard let remaining, let duration = window.duration, duration > 0 else {
            timeLeftFraction = nil
            runsOutIn = nil
            return
        }
        timeLeftFraction = min(max(remaining / duration, 0), 1)

        let elapsed = duration - remaining
        if let left, left < 100, elapsed > 300 {
            let ratePerSecond = (100 - left) / elapsed
            let toEmpty = left / ratePerSecond
            runsOutIn = toEmpty < remaining ? toEmpty : nil
        } else {
            runsOutIn = nil
        }
    }

    var isUnused: Bool { (percentLeft ?? 0) >= 99.5 }
    var isLow: Bool { (percentLeft ?? 100) <= 10 }

    var paceSymbol: String {
        if isUnused { return "gauge.with.dots.needle.0percent" }
        return runsOutIn == nil ? "arrow.down.right" : "flame.fill"
    }

    var paceColor: Color {
        runsOutIn == nil ? Color.secondary.opacity(0.7) : .orange
    }

    var summary: String {
        guard let percentLeft else { return "Usage unavailable" }
        var parts = ["\(Int(percentLeft.rounded()))% left"]
        if let timeUntilReset { parts.append("resets in \(DurationText.short(timeUntilReset))") }
        if let runsOutIn {
            parts.append("at this pace it runs out in \(DurationText.short(runsOutIn))")
        } else if timeLeftFraction != nil, !isUnused {
            parts.append("on pace to last until the reset")
        }
        return parts.joined(separator: ", ")
    }
}

private struct LimitCard: View {
    let window: AIUsageWindow
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let metrics = LimitMetrics(window: window, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(window.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(metrics.percentLeft.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(.system(size: 22, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(metrics.isLow ? Color.red : Color.primary)
                                .fixedSize()
                            Text("left")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Image(systemName: metrics.paceSymbol)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(metrics.paceColor)
                        }
                    }
                    .frame(width: 102, alignment: .leading)

                    LimitBar(
                        fractionLeft: metrics.percentLeft.map { $0 / 100 },
                        markerFraction: metrics.timeLeftFraction,
                        resetIn: metrics.timeUntilReset,
                        tint: metrics.isLow ? Color.red.opacity(0.5) : tint
                    )
                }

                if let runsOutIn = metrics.runsOutIn {
                    Label("At this pace it runs out in \(DurationText.short(runsOutIn))", systemImage: "flame.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if let detail = window.detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .card()
            .help(helpText(metrics))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.displayTitle): \(metrics.summary)")
        }
    }

    private func helpText(_ metrics: LimitMetrics) -> String {
        var lines = [metrics.summary.prefix(1).uppercased() + metrics.summary.dropFirst() + "."]
        if let reset = window.resetsAt {
            lines.append("Resets \(reset.formatted(date: .abbreviated, time: .shortened)).")
        }
        if metrics.timeLeftFraction != nil {
            lines.append("The marker shows how much of the window is left.")
        }
        return lines.joined(separator: "\n")
    }
}

/// The remaining share as a solid fill, the used share hatched, and a marker
/// at the share of time left. Fill to the right of the marker means usage is
/// on pace to last until the reset.
private struct LimitBar: View {
    let fractionLeft: Double?
    let markerFraction: Double?
    let resetIn: TimeInterval?
    let tint: Color

    private let height: CGFloat = 20
    private let radius: CGFloat = 6
    private let estimatedChipWidth: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = width * min(max(fractionLeft ?? 0, 0), 1)
            let markerX: CGFloat? = markerFraction.map { min(max(width * CGFloat($0), 1), width - 1) }

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    HatchFill()
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    if fill > 0 {
                        // An opaque base keeps the stripes from showing
                        // through the translucent tint.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint)
                            )
                            .frame(width: max(fill, radius * 2))
                    }
                    if let markerX {
                        // Cut a gap around the marker so it reads on any fill.
                        Rectangle()
                            .frame(width: 5, height: height)
                            .offset(x: markerX - 2.5)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()

                if let markerX {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: markerX - 1)
                }

                if let resetIn {
                    ResetChip(text: DurationText.short(resetIn))
                        .offset(x: chipX(width: width, fill: fill, markerX: markerX))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
        .animation(.easeOut(duration: 0.35), value: fractionLeft)
    }

    /// Leading x of the reset chip: at the end of the fill when it fits, after
    /// the fill when it doesn't, and always beside the marker, never over it.
    private func chipX(width: CGFloat, fill: CGFloat, markerX: CGFloat?) -> CGFloat {
        let chip = estimatedChipWidth
        let maxX = max(width - chip - 3, 3)
        var x = fill >= chip + 6 ? fill - chip - 3 : fill + 3
        if let markerX, markerX > x - 3, markerX < x + chip + 3 {
            // Prefer the side of the marker that stays on the fill.
            x = markerX - chip - 4 >= 3 ? markerX - chip - 4 : markerX + 4
        }
        return min(max(x, 3), maxX)
    }
}

private struct ResetChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 2.5) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 7.5, weight: .bold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
    }
}

/// Diagonal stripes for the used part of a limit.
private struct HatchFill: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.03)))
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(stripes, with: .color(.primary.opacity(0.13)), lineWidth: 1)
        }
    }
}

/// One line for secondary limits such as model-specific weekly caps.
private struct CompactLimitRow: View {
    let window: AIUsageWindow
    let tint: Color

    var body: some View {
        let metrics = LimitMetrics(window: window, now: .now)
        HStack(spacing: 10) {
            Text(window.displayTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 102, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(metrics.isLow ? Color.red.opacity(0.5) : tint)
                        .frame(width: geometry.size.width * (metrics.percentLeft ?? 0) / 100)
                }
            }
            .frame(height: 6)
            Text(metrics.percentLeft.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .help(metrics.summary)
    }
}

// MARK: - Limit resets

/// Asks before reading Cursor's Keychain key. The macOS prompt that follows
/// names "security", the Apple tool that reads the key.
private struct KeychainApprovalCard: View {
    let isRequesting: Bool
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cursor keeps its sign-in encrypted with a key in your Keychain. macOS will ask whether “security” may use “Cursor Safe Storage”. Choose Always Allow so it doesn't ask again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isRequesting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Waiting for Keychain access")
                } else {
                    Button("Allow Keychain Access", action: onAllow)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card()
    }
}

/// Confirms a reset picked from the account's menu. Shown only on request.
private struct LimitResetConfirmation: View {
    let credit: AIUsageResetCredit
    let weeklyResetsAt: Date?
    let isRedeeming: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Use \(credit.title)?")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let expiresAt = credit.expiresAt {
                    Text("Expires in \(DurationText.short(expiresAt.timeIntervalSinceNow))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Text(confirmation(now: .now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isRedeeming {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Using reset")
                } else {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    Button("Use Reset", action: onConfirm)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card()
        .help(credit.label ?? credit.detail)
    }

    private func confirmation(now: Date) -> String {
        var parts = ["\(credit.detail) right away."]
        if let weeklyResetsAt, weeklyResetsAt > now {
            parts.append("Without it, your weekly limit resets in \(DurationText.short(weeklyResetsAt.timeIntervalSince(now))).")
        }
        parts.append(credit.warning)
        return parts.joined(separator: " ")
    }
}

/// Shown while the first usage read is in flight.
private struct LimitPlaceholder: View {
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).frame(width: 46, height: 8)
                RoundedRectangle(cornerRadius: 4).frame(width: 64, height: 18)
            }
            .frame(width: 102, alignment: .leading)
            RoundedRectangle(cornerRadius: 6).frame(height: 20)
        }
        .foregroundStyle(Color.primary.opacity(0.06))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .card()
        .accessibilityLabel("Reading usage")
    }
}

// MARK: - Not connected

private struct DisconnectedProviders: View {
    let model: AIUsageModel
    let states: [AIUsageState]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Not connected")
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    if index > 0 { Divider().opacity(0.5).padding(.leading, 34) }
                    DisconnectedRow(model: model, state: state)
                }
            }
            .card()
        }
    }
}

private struct DisconnectedRow: View {
    let model: AIUsageModel
    let state: AIUsageState
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 9) {
            ProviderLogo(provider: state.provider)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 12, weight: .medium))
                if !state.isInstalled {
                    Text("Not found on this Mac")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button("Connect") { confirming = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert("Connect \(state.provider.title)?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Connect") { Task { await model.connect(state) } }
        } message: {
            Text("CodeBarAI will read this tool’s local sign-in credentials and send them only to its own usage service. Tokens are not saved by CodeBarAI. \(state.provider.connectionHint)")
        }
    }
}

// MARK: - Menu bar organizer

private struct MenuBarAccountsOrganizer: View {
    let model: AIUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Menu bar")
                .padding(.leading, 2)
            Text("Choose which accounts appear in the menu bar, and their order from left to right.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(Array(model.menuBarAccountStates.enumerated()), id: \.element.id) { index, state in
                    if index > 0 { Divider().opacity(0.5).padding(.leading, 34) }
                    HStack(spacing: 9) {
                        Toggle(isOn: Binding(
                            get: { model.isShownInMenuBar(state) },
                            set: { model.setMenuBarVisibility(state, isVisible: $0) }
                        )) {
                            HStack(spacing: 7) {
                                ProviderLogo(provider: state.provider, size: 12)
                                Text(state.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                        IconButton(systemImage: "chevron.up", help: "Move \(state.title) left") {
                            model.moveMenuBarAccount(state, by: -1)
                        }
                        .disabled(model.menuBarAccountStates.first?.id == state.id)
                        IconButton(systemImage: "chevron.down", help: "Move \(state.title) right") {
                            model.moveMenuBarAccount(state, by: 1)
                        }
                        .disabled(model.menuBarAccountStates.last?.id == state.id)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                }
            }
            .card()
        }
    }
}
