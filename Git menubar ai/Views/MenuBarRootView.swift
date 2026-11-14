import AppKit
import SwiftUI

/// The sections of the menu bar window.
enum MenuTab: String, CaseIterable, Identifiable {
    case projects, limits, servers, deployments

    var id: Self { self }

    var title: String {
        switch self {
        case .projects: return "Projects"
        case .limits: return "Usage"
        case .servers: return "Servers"
        case .deployments: return "Deploys"
        }
    }
}

/// Root of the menu bar window: tabs on top, the selected section, and a
/// one-line footer. Opening a project replaces the tabs with its detail view.
/// Also owns the periodic refresh.
struct MenuBarRootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ui.selectedTab") private var tab: MenuTab = .projects
    @AppStorage("ui.usageSection") private var usageSection: UsageSection = .limits
    @State private var organizingMenuBar = false
    @State private var choosingDeploymentTeams = false

    /// Backstop poll interval. File system events handle everything local; this
    /// only catches state changed by other tools in ways FSEvents misses.
    private let pollInterval: Duration = .seconds(60)

    /// `MenuBarExtra` keeps this view alive after the window closes, so a plain
    /// `.task` loop would poll forever. Keying the task on visibility cancels
    /// the loop when the window closes and restarts it when it opens again.
    @State private var isWindowVisible = false

    /// Tallest the scrolling content may get before the window would run off
    /// a small screen.
    private var contentMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, max(260, screen - 160))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isShowingSettings {
                SettingsView(maxHeight: contentMaxHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let selected = model.selectedRepository {
                RepositoryDetailView(state: selected, maxHeight: contentMaxHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.5)
                    content
                    Divider().opacity(0.5)
                    footer
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: Theme.windowWidth)
        .environment(\.isMenuWindowVisible, isWindowVisible)
        .onWindowVisibilityChange { isWindowVisible = $0 }
        .task {
            // FSEvents keep the menu bar count current while the window is closed.
            model.start()
        }
        .task(id: isWindowVisible) {
            guard isWindowVisible else { return }
            await model.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { break }
                await model.refreshAll()
            }
        }
        .onChange(of: tab) {
            organizingMenuBar = false
            choosingDeploymentTeams = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            TabBar(
                tabs: MenuTab.allCases,
                selection: $tab,
                title: \.title,
                badge: badge(for:)
            )
            Spacer(minLength: 4)
            actions
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private func badge(for tab: MenuTab) -> String? {
        switch tab {
        case .projects:
            let count = model.totalChangedFileCount
            return count > 0 ? "\(count)" : nil
        case .servers:
            let count = model.servers.servers.count
            return count > 0 ? "\(count)" : nil
        case .deployments:
            // Builds in progress, so a finished one is noticeable without opening the tab.
            let count = model.deployments.inProgressCount
            return count > 0 ? "\(count)" : nil
        case .limits:
            return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch tab {
        case .projects:
            IconButton(systemImage: "arrow.clockwise", help: "Refresh all projects") {
                Task { await model.refreshAll() }
            }
            IconButton(systemImage: "plus", help: "Add a repository") {
                Task { await model.addRepository() }
            }
        case .limits where usageSection != .limits && !organizingMenuBar:
            if model.tokens.isScanning {
                InlineSpinner()
            } else {
                IconButton(systemImage: "arrow.clockwise", help: "Rescan usage logs") {
                    Task { await model.refreshTokenUsage(force: true) }
                }
            }
        case .limits:
            if organizingMenuBar {
                Button("Done") { organizingMenuBar = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
            } else {
                IconMenu(help: "Limits options") {
                    Button("Arrange Menu Bar…") {
                        usageSection = .limits
                        organizingMenuBar = true
                    }
                    Button("Add Claude Account…") {
                        guard let directory = SystemIntegration.chooseClaudeAccountFolder() else { return }
                        let state = model.usage.addClaudeAccount(directory: directory)
                        Task { await model.usage.connect(state) }
                    }
                }
            }
        case .servers:
            if model.servers.isRefreshing {
                InlineSpinner()
            } else {
                IconButton(systemImage: "arrow.clockwise", help: "Refresh servers") {
                    Task { await model.servers.refresh(projects: model.repositories.map(\.repository)) }
                }
            }
        case .deployments where choosingDeploymentTeams:
            Button("Done") { choosingDeploymentTeams = false }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
        case .deployments:
            if model.deployments.isRefreshing {
                InlineSpinner()
            } else {
                IconButton(systemImage: "arrow.clockwise", help: "Refresh deployments") {
                    Task { await model.deployments.refresh() }
                }
            }
            IconMenu(help: "Deployments options") {
                Button("Choose Teams…") { choosingDeploymentTeams = true }
                Button("Open Vercel Dashboard") {
                    NSWorkspace.shared.open(URL(string: "https://vercel.com/dashboard")!)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .projects:
            ProjectsView(maxHeight: contentMaxHeight)
        case .limits:
            UsageView(section: $usageSection, organizingMenuBar: $organizingMenuBar, maxHeight: contentMaxHeight)
        case .servers:
            ServersView(
                model: model.servers,
                projects: model.repositories.map(\.repository),
                maxHeight: contentMaxHeight
            )
        case .deployments:
            DeploymentsView(
                model: model.deployments,
                maxHeight: contentMaxHeight,
                choosingTeams: $choosingDeploymentTeams
            ) {
                withAnimation(.snappy(duration: 0.2)) { model.isShowingSettings = true }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            footerSummary
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("Settings") {
                withAnimation(.snappy(duration: 0.2)) { model.isShowingSettings = true }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .keyboardShortcut(",")
            .help("Choose the AI that writes commit messages (⌘,)")
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .help("Quit CodeBarAI (⌘Q)")
        }
        .padding(.horizontal, Theme.edge + 2)
        .frame(height: 30)
    }

    @ViewBuilder
    private var footerSummary: some View {
        switch tab {
        case .projects:
            let changed = model.totalChangedFileCount
            let dirty = model.repositories.filter { ($0.status?.changedFileCount ?? 0) > 0 }.count
            if model.repositories.isEmpty {
                Text("CodeBarAI")
            } else if changed == 0 {
                Text("Everything is committed")
            } else {
                Text("\(changed) \(changed == 1 ? "change" : "changes") in \(dirty) \(dirty == 1 ? "project" : "projects")")
            }
        case .limits where usageSection != .limits:
            if model.tokens.isScanning && model.tokens.report == nil {
                Text("Reading session logs…")
            } else if let scanned = model.tokens.lastScan {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Scanned \(scanned, format: .relative(presentation: .named))")
                }
            } else {
                Text("CodeBarAI")
            }
        case .limits:
            if let updated = model.usage.states.compactMap(\.snapshot?.fetchedAt).max() {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                }
            } else {
                Text("CodeBarAI")
            }
        case .servers:
            let count = model.servers.servers.count
            Text(count == 0 ? "Checks every 5 seconds while open" : "\(count) running")
        case .deployments:
            deploymentsSummary
        }
    }

    @ViewBuilder
    private var deploymentsSummary: some View {
        let deployments = model.deployments
        let building = deployments.inProgressCount
        let failed = deployments.failedCount
        if building > 0 || failed > 0 {
            Text(
                [
                    building > 0 ? "\(building) building" : nil,
                    failed > 0 ? "\(failed) failed" : nil
                ].compactMap { $0 }.joined(separator: " · ")
            )
        } else if let updated = deployments.lastUpdated, !deployments.deployments.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("All ready · updated \(updated, format: .relative(presentation: .named))")
            }
        } else {
            Text("Latest deployment of each Vercel project")
        }
    }
}
