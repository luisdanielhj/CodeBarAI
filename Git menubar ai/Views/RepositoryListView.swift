import SwiftUI

/// The root list: every added repository with its branch and change count.
struct RepositoryListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if let gitFailure = model.gitFailure {
                InlineBanner(
                    kind: .error,
                    title: "Git is not available",
                    detail: gitFailure
                )
                .padding(10)
            }

            if let addFailure = model.addFailure {
                InlineBanner(kind: .warning, title: "Could not add repository", detail: addFailure)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }

            if let actionFailure = model.actionFailure {
                InlineBanner(
                    kind: .error,
                    title: actionFailure.title,
                    detail: actionFailure.message,
                    hint: actionFailure.hint
                )
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }

            if model.repositories.isEmpty {
                emptyState
            } else {
                repositoryList
            }

            Divider().opacity(0.5)
            AIUsageView(model: model.usage)
            Divider().opacity(0.5)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("CodeBarAI")
                .font(.system(size: 13, weight: .semibold))

            if model.totalChangedFileCount > 0 {
                Chip(text: "\(model.totalChangedFileCount) changed", tint: .orange)
            }

            Spacer()

            HeaderButton(systemImage: "arrow.clockwise", help: "Refresh all repositories") {
                Task { await model.refreshAll() }
            }
            HeaderButton(systemImage: "plus", help: "Add a repository") {
                Task { await model.addRepository() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var repositoryList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(model.displayedRepositories) { state in
                    RepositoryRow(state: state) {
                        model.selectedRepositoryID = state.id
                    }
                    .contextMenu {
                        Button("Open in Cursor") { Task { await model.openInCursor(state) } }
                        Button("Open in Claude Code") { Task { await model.openInClaudeCode(state) } }
                        Button("Open in Codex") { Task { await model.openInCodex(state) } }
                        if let server = state.devServer {
                            Divider()
                            Button("Start Server (\(server.title))") {
                                Task { await model.startDevServer(state) }
                            }
                        }
                        Divider()
                        Button("Open in Finder") { model.openInFinder(state) }
                        Button("Open in Terminal") { Task { await model.openInTerminal(state) } }
                        Divider()
                        Button("Remove from List") { model.remove(state) }
                    }
                }
            }
            .padding(6)
            .syncScrollerAppearance()
        }
        // A ScrollView has no useful ideal height inside a MenuBarExtra window,
        // so AppKit can collapse it to zero even though its rows exist. Reserve
        // one row of height per repository and start scrolling at eight rows.
        .frame(height: min(CGFloat(model.repositories.count) * 44 + 12, 400))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No repositories yet")
                .font(.system(size: 12, weight: .medium))

            Text("Add a local Git repository to commit and push without leaving the menu bar.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add Repository…") {
                Task { await model.addRepository() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Built by UpskyAI")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// One repository in the list: name, branch, and how many files changed.
struct RepositoryRow: View {
    let state: RepositoryState
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 9) {
                statusIndicator

                RepositoryIconView(data: state.projectIconData, size: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.repository.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if state.loadFailure != nil {
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        } else if let status = state.status {
                            Label(status.branchDisplayName, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if let divergence = status.divergenceSummary {
                                Text(divergence)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Loading…")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 4)

                trailingDetail
            }
        }
    }

    /// Dot showing at a glance whether the repository has uncommitted work.
    private var statusIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 7, height: 7)
    }

    private var indicatorColor: Color {
        if state.loadFailure != nil { return .red }
        guard let status = state.status else { return .secondary.opacity(0.4) }
        if !status.conflicts.isEmpty { return .red }
        if !status.isClean { return .orange }
        return .green.opacity(0.7)
    }

    @ViewBuilder
    private var trailingDetail: some View {
        HStack(spacing: 6) {
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else if let status = state.status {
                if !status.conflicts.isEmpty {
                    Chip(text: "\(status.conflicts.count) conflict", systemImage: "exclamationmark.triangle.fill", tint: .red)
                } else if status.changedFileCount > 0 {
                    Chip(text: "\(status.changedFileCount)", tint: .orange)
                } else {
                    Text("Clean")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}
