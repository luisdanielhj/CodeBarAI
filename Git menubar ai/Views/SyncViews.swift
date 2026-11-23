import AppKit
import SwiftUI

/// Where this machine stands against the upstream, with the one action that
/// brings the two together: Pull, Push, Sync or Publish.
struct SyncCard: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState
    @Binding var showsCommits: Bool

    var body: some View {
        if let status = state.status, let content = content(for: status) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    icon(content)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        subtitle(content)
                            .font(.system(size: 10.5))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if hasCommits {
                        IconButton(
                            systemImage: showsCommits ? "chevron.up" : "chevron.down",
                            help: showsCommits ? "Hide commits" : "Show commits"
                        ) {
                            withAnimation(.snappy(duration: 0.2)) { showsCommits.toggle() }
                        }
                    }

                    if let action = content.action {
                        CapsuleButton(title: action.title) {
                            Task { await perform(action) }
                        }
                        .disabled(state.isBusy || state.isFetching)
                        .help(action.help(strategy: model.sync.pullStrategy))
                    } else if status.upstream != nil {
                        if state.isFetching {
                            InlineSpinner()
                        } else {
                            IconButton(systemImage: "arrow.triangle.2.circlepath", help: "Check the remote for new commits") {
                                Task { await model.fetch(state) }
                            }
                            .disabled(state.isBusy)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                if showsCommits && hasCommits {
                    Divider().opacity(0.5)
                    CommitList(incoming: state.incoming, outgoing: state.outgoing)
                }
            }
            .card()
        }
    }

    private var hasCommits: Bool {
        !state.incoming.isEmpty || !state.outgoing.isEmpty
    }

    // MARK: Content

    private enum Action {
        case pull, push, sync, publish

        var title: String {
            switch self {
            case .pull: return "Pull"
            case .push: return "Push"
            case .sync: return "Sync"
            case .publish: return "Publish"
            }
        }

        func help(strategy: PullStrategy) -> String {
            switch self {
            case .pull: return "git pull (\(strategy.title.lowercased())), keeping uncommitted work"
            case .push: return "git push"
            case .sync: return "Pull with \(strategy.title.lowercased()), then push"
            case .publish: return "git push --set-upstream"
            }
        }
    }

    private struct Content {
        var title: String
        var symbol: String
        var tint: Color
        var action: Action?
        var detail: String?
    }

    private func content(for status: GitStatus) -> Content? {
        // A merge or rebase has its own card.
        guard status.operation == nil, !status.isDetached, let branch = status.branch else { return nil }

        guard let upstream = status.upstream else {
            guard !status.remotes.isEmpty else { return nil }
            return Content(
                title: "“\(branch)” isn’t on the remote yet",
                symbol: "icloud.and.arrow.up",
                tint: .secondary,
                action: .publish,
                detail: "Publish it so your other machines can pull it."
            )
        }

        let ahead = status.ahead
        let behind = status.behind
        switch (ahead > 0, behind > 0) {
        case (true, true):
            return Content(
                title: "Both machines have new commits",
                symbol: "arrow.triangle.branch",
                tint: .orange,
                action: .sync,
                detail: "\(Self.commits(ahead)) here, \(Self.commits(behind)) on \(upstream). Sync \(model.sync.pullStrategy == .merge ? "merges them" : "puts yours on top"), then pushes."
            )
        case (false, true):
            return Content(
                title: "\(Self.commits(behind)) to pull from \(upstream)",
                symbol: "arrow.down.circle.fill",
                tint: .blue,
                action: .pull,
                detail: state.autoUpdateBlocked
                    ? "Your uncommitted changes touch the same files, so it wasn’t updated automatically."
                    : nil
            )
        case (true, false):
            return Content(
                title: "\(Self.commits(ahead)) not pushed",
                symbol: "arrow.up.circle.fill",
                tint: .blue,
                action: status.pushBlocker == nil ? .push : nil,
                detail: "Push so your other machines get \(ahead == 1 ? "it" : "them")."
            )
        case (false, false):
            return Content(
                title: "Up to date with \(upstream)",
                symbol: "checkmark.icloud.fill",
                tint: .green,
                action: nil,
                detail: nil
            )
        }
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    @ViewBuilder
    private func icon(_ content: Content) -> some View {
        Image(systemName: content.symbol)
            .font(.system(size: 13))
            .foregroundStyle(content.tint)
            .frame(width: 18)
    }

    @ViewBuilder
    private func subtitle(_ content: Content) -> some View {
        if let failure = state.fetchFailure {
            Text("Couldn’t check the remote. \(failure.hint ?? failure.message)")
                .foregroundStyle(.red)
                .help(failure.message)
        } else if let detail = content.detail {
            Text(detail)
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(freshness(now: context.date))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Pulled 2 commits from another machine 3 min ago" or "Checked just now".
    private func freshness(now: Date) -> String {
        if let update = state.lastAutoUpdate, now.timeIntervalSince(update.date) < 3600 {
            return "Pulled \(Self.commits(update.commitCount)) automatically \(Self.relative(update.date, now: now))"
        }
        if state.isFetching { return "Checking the remote…" }
        guard let last = state.lastFetchedAt else {
            return model.sync.fetchInterval == .off ? "Automatic checks are off" : "Not checked yet"
        }
        return "Checked \(Self.relative(last, now: now))"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func perform(_ action: Action) async {
        switch action {
        case .pull: await model.pull(state)
        case .push: await model.push(state)
        case .sync: await model.syncNow(state)
        case .publish: await model.publishBranch(for: state)
        }
    }
}

/// Commits waiting to come in, then commits waiting to go out.
private struct CommitList: View {
    let incoming: [GitCommitSummary]
    let outgoing: [GitCommitSummary]

    var body: some View {
        FittedScrollView(maxHeight: 130, estimatedHeight: CGFloat(min(incoming.count + outgoing.count, 5)) * 22 + 20) {
            VStack(alignment: .leading, spacing: 2) {
                if !incoming.isEmpty {
                    group(title: "Incoming", symbol: "arrow.down", commits: incoming)
                }
                if !outgoing.isEmpty {
                    group(title: "Not pushed", symbol: "arrow.up", commits: outgoing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func group(title: String, symbol: String, commits: [GitCommitSummary]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            ForEach(commits) { commit in
                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(commit.subject)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .help("\(commit.subject)\n\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

/// An interrupted merge or rebase: what happened and how to get out of it.
struct OperationCard: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        if let status = state.status, status.operation != nil || !status.conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(status))
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(explanation(status))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let operation = status.operation {
                    HStack(spacing: 6) {
                        CapsuleButton(title: "Abort", role: .destructive) {
                            Task { await model.abortOperation(state) }
                        }
                        .help("git \(operation.subcommand) --abort: go back to before it started")
                        if operation.canSkip {
                            CapsuleButton(title: "Skip Commit") {
                                Task { await model.skipCommit(state) }
                            }
                            .help("git \(operation.subcommand) --skip: drop the commit being applied")
                        }
                        Spacer(minLength: 4)
                        CapsuleButton(title: "Continue", isProminent: true) {
                            Task { await model.continueOperation(state) }
                        }
                        .disabled(!status.conflicts.isEmpty)
                        .help(status.conflicts.isEmpty
                              ? "git \(operation.subcommand) --continue"
                              : "Resolve every conflicted file first")
                    }
                    .disabled(state.isBusy)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    private func title(_ status: GitStatus) -> String {
        let count = status.conflicts.count
        let files = count == 1 ? "1 conflicted file" : "\(count) conflicted files"
        guard let operation = status.operation else { return files }
        return count > 0 ? "\(operation.title) paused · \(files)" : "\(operation.title) in progress"
    }

    private func explanation(_ status: GitStatus) -> String {
        if status.conflicts.isEmpty {
            return "Every conflict is resolved. Press Continue to finish."
        }
        if status.operation == nil {
            return "Your uncommitted changes and the pulled commits edited the same lines. Pick a version for each file from its menu, or edit it and mark it resolved."
        }
        return "These files changed on both sides. For each one, keep your version or theirs from its menu, or edit it and mark it resolved."
    }
}

/// The per-file menu on a conflicted file.
struct ConflictResolveMenu: View {
    @Environment(AppModel.self) private var model
    let change: GitFileChange
    let state: RepositoryState

    var body: some View {
        Menu {
            let fromStash = state.status?.operation == nil
            Button(fromStash ? "Keep My Uncommitted Version" : "Keep My Version") {
                Task { await model.resolveConflict(change, keeping: .mine, in: state) }
            }
            Button(fromStash ? "Keep the Pulled Version" : "Keep Their Version") {
                Task { await model.resolveConflict(change, keeping: .theirs, in: state) }
            }
            Divider()
            Button("Open in Cursor") {
                Task { await model.openInCursor(change, in: state) }
            }
            Button("Mark as Resolved") {
                Task { await model.markResolved(change, in: state) }
            }
        } label: {
            Text("Resolve")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Color.red.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.isBusy)
        .help("Mine is the version committed on this machine. Theirs came from the remote.")
    }
}

/// A compact pill-shaped action button.
struct CapsuleButton: View {
    let title: String
    var isProminent = false
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        if isProminent { return Color(nsColor: .windowBackgroundColor) }
        return role == .destructive ? .red : .primary
    }

    private var background: Color {
        if isProminent { return .primary.opacity(0.9) }
        return role == .destructive ? .red.opacity(0.1) : .primary.opacity(0.08)
    }
}
