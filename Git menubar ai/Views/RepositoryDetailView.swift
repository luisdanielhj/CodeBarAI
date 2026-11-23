import AppKit
import SwiftUI

/// One project: where it stands, what changed, and the commit composer.
struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState
    let maxHeight: CGFloat
    @State private var showsCommits = false

    /// Room the sync card takes from the changed-file list.
    private var syncCardHeight: CGFloat {
        guard state.status?.remotes.isEmpty == false else { return 0 }
        return showsCommits ? 190 : 56
    }

    /// Reloads the branch and stash menus when HEAD, the branch or the stash moves.
    private var refsKey: String {
        guard let status = state.status else { return "" }
        return "\(status.branch ?? "")|\(status.headOID ?? "")|\(status.stashCount)|\(state.lastFetchedAt?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 10) {
                OpenInRow(state: state)
                SyncCard(state: state, showsCommits: $showsCommits)
                OperationCard(state: state)
                notices
            }
            .padding(.horizontal, Theme.edge)
            .padding(.bottom, 10)

            ChangedFilesSection(state: state, maxHeight: max(120, maxHeight - 326 - syncCardHeight))

            Divider().opacity(0.5)

            CommitComposer(state: state)
        }
        .overlay {
            if let pending = model.pendingCommit, pending.repositoryID == state.id {
                SensitiveFileWarning(pending: pending)
            }
        }
        .task(id: state.lastSuccess) {
            // Success needs no action, so it clears itself.
            guard state.lastSuccess != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { state.lastSuccess = nil }
        }
        .task(id: refsKey) {
            await model.loadRefs(for: state)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemImage: "chevron.left", help: "All projects") {
                withAnimation(.snappy(duration: 0.2)) { model.selectedRepositoryID = nil }
            }

            ProjectIcon(image: state.projectIcon, name: state.repository.name, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.repository.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(state.repository.displayPath)
                branchLine
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if state.isRefreshing {
                InlineSpinner()
            } else {
                IconButton(systemImage: "arrow.clockwise", help: "Refresh and check the remote") {
                    Task { await model.fetch(state) }
                }
            }

            IconMenu(help: "More actions") {
                SyncMenuItems(state: state)
                Divider()
                Button("Show in Finder") { model.openInFinder(state) }
                Button("Open in Terminal") { Task { await model.openInTerminal(state) } }
                if model.usage.claudeAccounts.count > 1 {
                    Menu("Open in Claude Code") {
                        ClaudeAccountLaunchOptions(repository: state)
                    }
                }
                if let server = state.devServer {
                    Divider()
                    Button("Start Server (\(server.title))") {
                        Task { await model.startDevServer(state) }
                    }
                }
                Divider()
                Button("Remove from List", role: .destructive) { model.remove(state) }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var branchLine: some View {
        if let status = state.status {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                Text(status.branchDisplayName)
                if let upstream = status.upstream {
                    Text("→ \(upstream)")
                        .foregroundStyle(.tertiary)
                }
                if let divergence = status.divergenceSummary {
                    Text(divergence)
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
            }
            .help(state.repository.displayPath)
        } else {
            Text(state.repository.displayPath)
                .truncationMode(.head)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let failure = state.loadFailure {
            InlineBanner(kind: .error, title: failure.title, detail: failure.message, hint: failure.hint)
        }

        if let failure = state.operationFailure {
            InlineBanner(kind: .error, title: failure.title, detail: failure.message, hint: failure.hint) {
                state.operationFailure = nil
            }
        }

        if let success = state.lastSuccess {
            InlineBanner(kind: .success, title: success)
                .transition(.opacity)
        }

        if let notice = state.syncNotice {
            InlineBanner(kind: .warning, title: "Check your stashed changes", detail: notice) {
                state.syncNotice = nil
            }
        }

        if let status = state.status, !status.isClean, let blocker = status.pushBlocker {
            switch blocker {
            case .noUpstream(_, true), .operationInProgress, .conflicts:
                // The sync card offers Publish; the operation card covers the rest.
                EmptyView()
            default:
                InlineBanner(kind: .warning, title: "Push is blocked", detail: blocker.message)
            }
        }
    }
}

/// Fetch, pull, push, branches and stash, for the detail screen's ⋯ menu.
private struct SyncMenuItems: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        let status = state.status
        let hasRemote = status?.remotes.isEmpty == false

        if hasRemote {
            Button("Fetch") { Task { await model.fetch(state) } }
                .disabled(state.isBusy || state.isFetching)
            Button("Pull (\(model.sync.pullStrategy.title))") { Task { await model.pull(state) } }
                .disabled(!state.canPull)
            Button("Push") { Task { await model.push(state) } }
                .disabled(!state.canPushCommits)
            Button("Sync (Pull, then Push)") { Task { await model.syncNow(state) } }
                .disabled(!state.canPull)
        }

        Menu("Switch Branch") {
            let local = state.branches.filter { !$0.isRemote }
            let localNames = Set(local.map(\.name))
            let remoteOnly = state.branches.filter { $0.isRemote && !localNames.contains($0.localName) }
            ForEach(local.prefix(25)) { branch in
                let isCurrent = branch.name == status?.branch
                Button {
                    Task { await model.switchBranch(to: branch, in: state) }
                } label: {
                    if isCurrent {
                        Label(branch.name, systemImage: "checkmark")
                    } else {
                        Text(branch.name)
                    }
                }
                .disabled(isCurrent)
            }
            if !remoteOnly.isEmpty {
                Section("From other machines") {
                    ForEach(remoteOnly.prefix(25)) { branch in
                        Button(branch.name) {
                            Task { await model.switchBranch(to: branch, in: state) }
                        }
                    }
                }
            }
        }
        .disabled(state.isBusy || status?.operation != nil)

        Divider()

        Button("Stash Changes") { Task { await model.stashChanges(state) } }
            .disabled(state.isBusy || status?.isClean != false || status?.operation != nil)
        if !state.stashes.isEmpty {
            Menu("Stashed Changes (\(state.stashes.count))") {
                ForEach(state.stashes) { entry in
                    Menu(entry.message) {
                        Button("Restore and Remove") {
                            Task { await model.popStash(entry, in: state) }
                        }
                        Button("Delete", role: .destructive) {
                            Task { await model.dropStash(entry, in: state) }
                        }
                    }
                }
            }
            .disabled(state.isBusy)
        }
    }
}

/// Open the project in one of the coding tools.
private struct OpenInRow: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        HStack(spacing: 6) {
            OpenInButton(title: "Cursor", logo: "CursorLogo") {
                Task { await model.openInCursor(state) }
            }
            OpenInButton(title: "Claude", logo: "ClaudeLogo") {
                Task { await model.openInClaudeCode(state) }
            }
            .help(model.usage.claudeAccounts.count > 1
                  ? "Opens with \(model.usage.selectedClaudeAccount?.claudeProfile?.name ?? "the selected") account. Choose another from the ⋯ menu."
                  : "Open in Claude Code")
            OpenInButton(title: "Codex", logo: "CodexLogo") {
                Task { await model.openInCodex(state) }
            }
            OpenInButton(title: "Kiro", logo: "KiroLogo") {
                Task { await model.openInKiro(state) }
            }
            .help("Open in Kiro CLI")
        }
    }
}

private struct OpenInButton: View {
    let title: String
    let logo: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                Color.primary.opacity(isHovering ? 0.09 : 0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Shared by the project context menu and the detail menu, so choosing an
/// account always launches that profile without changing any other login.
struct ClaudeAccountLaunchOptions: View {
    @Environment(AppModel.self) private var model
    let repository: RepositoryState

    var body: some View {
        ForEach(model.usage.claudeAccounts) { account in
            Button(account.claudeProfile?.name ?? "Default") {
                Task { await model.openInClaudeCode(repository, account: account) }
            }
        }
    }
}

/// The changed files. Clicking one opens it in Cursor.
struct ChangedFilesSection: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Changes") {
                if let count = state.status?.changedFileCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.edge + 2)

            if let status = state.status {
                if status.changes.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Nothing to commit")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    FittedScrollView(maxHeight: maxHeight, estimatedHeight: CGFloat(min(status.changes.count, 6)) * 26) {
                        LazyVStack(spacing: 0) {
                            ForEach(status.changes) { change in
                                HStack(spacing: 2) {
                                    ChangedFileRow(change: change) {
                                        Task { await model.openInCursor(change, in: state) }
                                    }
                                    if change.kind == .conflicted {
                                        ConflictResolveMenu(change: change, state: state)
                                            .padding(.trailing, 6)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
            } else {
                Text("Reading status…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            }
        }
    }
}

/// A single changed file with a one-letter status badge.
struct ChangedFileRow: View {
    let change: GitFileChange
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) { isHovering in
            HStack(spacing: 8) {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(change.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .layoutPriority(1)

                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .help("\(change.kind.label): \(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)\nClick to open in Cursor")
    }

    private var badge: String {
        switch change.kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added, .untracked: return .green
        case .modified, .typeChanged: return .orange
        case .deleted, .conflicted: return .red
        case .renamed, .copied: return .blue
        }
    }
}
