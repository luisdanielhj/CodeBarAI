import SwiftUI

/// Recent projects first. Five are shown until the list is expanded.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ui.showAllProjects") private var showingAll = false
    let maxHeight: CGFloat

    private let recentLimit = 5

    private var visibleRepositories: [RepositoryState] {
        let recent = model.displayedRepositories
        return showingAll ? recent : Array(recent.prefix(recentLimit))
    }

    var body: some View {
        FittedScrollView(maxHeight: maxHeight, estimatedHeight: 260) {
            VStack(spacing: 6) {
                banners

                if model.repositories.isEmpty {
                    EmptyState(
                        systemImage: "folder.badge.plus",
                        title: "No projects yet",
                        message: "Add a Git repository to see its changes and commit from the menu bar."
                    ) {
                        WideButton(title: "Add Repository…", systemImage: "plus", style: .primary) {
                            Task { await model.addRepository() }
                        }
                        .frame(width: 170)
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(visibleRepositories) { state in
                            ProjectRow(state: state) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    model.selectedRepositoryID = state.id
                                }
                            }
                            .contextMenu { ProjectContextMenu(state: state) }
                        }
                    }

                    if model.repositories.count > recentLimit {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showingAll.toggle() }
                        } label: {
                            Text(showingAll ? "Show recent only" : "Show all \(model.repositories.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var banners: some View {
        Group {
            if let gitFailure = model.gitFailure {
                InlineBanner(kind: .error, title: "Git is not available", detail: gitFailure)
            }
            if let addFailure = model.addFailure {
                InlineBanner(kind: .warning, title: "Could not add repository", detail: addFailure) {
                    model.addFailure = nil
                }
            }
            if let actionFailure = model.actionFailure {
                InlineBanner(
                    kind: .error,
                    title: actionFailure.title,
                    detail: actionFailure.message,
                    hint: actionFailure.hint
                ) {
                    model.actionFailure = nil
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Right-click actions for a project row.
private struct ProjectContextMenu: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        Button("Open in Cursor") { Task { await model.openInCursor(state) } }
        if model.usage.claudeAccounts.count > 1 {
            Menu("Open in Claude Code") {
                ClaudeAccountLaunchOptions(repository: state)
            }
        } else {
            Button("Open in Claude Code") { Task { await model.openInClaudeCode(state) } }
        }
        Button("Open in Codex") { Task { await model.openInCodex(state) } }
        Button("Open in Kiro") { Task { await model.openInKiro(state) } }
        if let server = state.devServer {
            Divider()
            Button("Start Server (\(server.title))") {
                Task { await model.startDevServer(state) }
            }
        }
        Divider()
        Button("Show in Finder") { model.openInFinder(state) }
        Button("Open in Terminal") { Task { await model.openInTerminal(state) } }
        Divider()
        Button("Remove from List", role: .destructive) { model.remove(state) }
    }
}

/// One project: artwork, name, branch, and how many files changed.
struct ProjectRow: View {
    let state: RepositoryState
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) { isHovering in
            HStack(spacing: 10) {
                ProjectIcon(image: state.projectIcon, name: state.repository.name, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.repository.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    subtitle
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                trailing

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows changes and the commit composer")
    }

    @ViewBuilder
    private var subtitle: some View {
        if state.loadFailure != nil {
            Text("Unavailable")
                .foregroundStyle(.red)
        } else if let status = state.status {
            HStack(spacing: 5) {
                Text(status.branchDisplayName)
                if let divergence = status.divergenceSummary {
                    Text(divergence).monospacedDigit()
                }
                if let operation = status.operationInProgress {
                    Text("· \(operation) in progress")
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
        } else {
            Text("Loading…")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let status = state.status {
            if !status.conflicts.isEmpty {
                Chip(text: "\(status.conflicts.count)", systemImage: "exclamationmark.triangle.fill", tint: .red)
                    .help("\(status.conflicts.count) conflicted files")
            } else if status.changedFileCount > 0 {
                Chip(text: "\(status.changedFileCount)", tint: .orange)
                    .help("\(status.changedFileCount) changed files")
            }
        } else if state.isRefreshing {
            // Only before the first status. Later refreshes stay silent so the
            // list does not flicker on every file change.
            ProgressView()
                .controlSize(.mini)
        }
    }
}
