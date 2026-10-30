import AppKit
import SwiftUI

@main
struct CodeBarAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(model)
        } label: {
            MenuBarLabel(
                usage: model.usage,
                changedFileCount: model.totalChangedFileCount
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item itself. Installed AI providers show the percentage left in
/// their session and weekly limits in the user's chosen order. The repository
/// status is the fallback when no installed account is selected for display.
struct MenuBarLabel: View {
    let usage: AIUsageModel
    let changedFileCount: Int

    private var usageStates: [AIUsageState] {
        usage.menuBarStates
            .filter { $0.isInstalled || $0.isEnabled }
    }

    var body: some View {
        // Read the observable state here, in the label's own body, so changes
        // re-render the status item image.
        let claudeAccounts = usage.claudeAccounts
        let accountNumbers = Dictionary(uniqueKeysWithValues: claudeAccounts.enumerated().map {
            ($0.element.id, $0.offset + 1)
        })
        let summaries = usageStates.map {
            ProviderLimitSummary(state: $0, accountNumber: claudeAccounts.count > 1 ? accountNumbers[$0.id] : nil)
        }
        if !summaries.isEmpty, let image = Self.render(summaries) {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel(summaries.map(\.accessibilityDescription).joined(separator: "; "))
                .help(summaries.map(\.accessibilityDescription).joined(separator: "\n"))
        } else {
            repositoryLabel
        }
    }

    private var repositoryLabel: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 16)
            if changedFileCount > 0 {
                Text("\(changedFileCount)")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .accessibilityLabel(
            changedFileCount > 0
                ? "CodeBarAI, \(changedFileCount) changed files"
                : "CodeBarAI, no changes"
        )
    }

    /// A status item label only displays a single image and title, so the
    /// stacked layout is drawn into a template image the menu bar can tint.
    private static func render(_ summaries: [ProviderLimitSummary]) -> NSImage? {
        let renderer = ImageRenderer(content: UsageStatusStrip(summaries: summaries))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        )
        image.isTemplate = true
        return image
    }
}

/// Plain values for one provider's entry, copied out of the observable state.
private struct ProviderLimitSummary: Identifiable {
    struct Limit {
        let title: String
        let percentLeft: Int?
    }

    let id: String
    let title: String
    let logoName: String
    let accountNumber: Int?
    /// The session limit, or Auto for Cursor.
    let top: Limit
    /// The weekly limit, or API for Cursor.
    let bottom: Limit

    init(state: AIUsageState, accountNumber: Int?) {
        let windows = state.snapshot?.windows ?? []
        let top: (id: String, title: String)
        let bottom: (id: String, title: String)
        switch state.provider {
        case .claude:
            top = ("five_hour", "Session")
            bottom = ("seven_day", "Weekly")
        case .codex:
            top = ("primary_window", "Session")
            bottom = ("secondary_window", "Weekly")
        case .cursor:
            // Cursor reports no session or weekly limits, only per-cycle pools.
            top = ("autoPercentUsed", "Auto")
            bottom = ("apiPercentUsed", "API")
        }

        id = state.id
        title = state.title
        logoName = state.provider.logoName
        self.accountNumber = accountNumber
        self.top = Self.limit(windows.first { $0.id == top.id }, fallbackTitle: top.title)
        self.bottom = Self.limit(windows.first { $0.id == bottom.id }, fallbackTitle: bottom.title)
    }

    private static func limit(_ window: AIUsageWindow?, fallbackTitle: String) -> Limit {
        Limit(
            title: window.flatMap { $0.title.isEmpty ? nil : $0.title } ?? fallbackTitle,
            percentLeft: window?.usedPercent.map { Int((100 - min(max($0, 0), 100)).rounded()) }
        )
    }

    var accessibilityDescription: String {
        let limits = [top, bottom].map { limit in
            guard let left = limit.percentLeft else { return "\(limit.title) usage unavailable" }
            return "\(limit.title) \(left) percent left"
        }
        let accountTitle = accountNumber.map { "\(title), account \($0)" } ?? title
        return ([accountTitle] + limits).joined(separator: ", ")
    }
}

/// Each provider's logo beside the percentage left in its two main limits.
private struct UsageStatusStrip: View {
    let summaries: [ProviderLimitSummary]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(summaries) { summary in
                HStack(spacing: 4) {
                    MenuBarProviderLogo(logoName: summary.logoName, accountNumber: summary.accountNumber)

                    VStack(alignment: .trailing, spacing: 0) {
                        percentage(summary.top)
                        percentage(summary.bottom)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                }
            }
        }
        .foregroundStyle(.black)
        .padding(.vertical, 0.5)
    }

    private func percentage(_ limit: ProviderLimitSummary.Limit) -> some View {
        Text(limit.percentLeft.map { "\($0)%" } ?? "—")
            .frame(height: 10)
    }
}
