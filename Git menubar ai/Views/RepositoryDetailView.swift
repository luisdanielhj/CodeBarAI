import AppKit
import SwiftUI

/// One repository in detail: branch state, changed files, and the commit composer.
struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            VStack(spacing: 9) {
                branchSummary
                notices
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)

            ChangedFilesSection(state: state)

            Divider().opacity(0.5)
            CommitComposer(state: state)

            Divider().opacity(0.5)
            footer
        }
        .overlay {
            if let pending = model.pendingCommit, pending.repositoryID == state.id {
                SensitiveFileWarning(pending: pending)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HeaderButton(systemImage: "chevron.left", help: "Back to all repositories") {
                model.selectedRepositoryID = nil
            }

            RepositoryIconView(data: state.projectIconData, size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.repository.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(state.repository.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 16, height: 16)
            } else {
                HeaderButton(systemImage: "arrow.clockwise", help: "Refresh") {
                    Task { await model.refresh(state) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    // MARK: Branch

    @ViewBuilder
    private var branchSummary: some View {
        if let status = state.status {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(status.branchDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let upstream = status.upstream {
                    Chip(text: upstream, tint: .secondary)
                }
                if let divergence = status.divergenceSummary {
                    Chip(text: divergence, tint: .blue)
                }

                Spacer(minLength: 4)

                if let operation = status.operationInProgress {
                    Chip(text: operation, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if let failure = state.loadFailure {
            InlineBanner(
                kind: .error,
                title: failure.title,
                detail: failure.message,
                hint: failure.hint
            )
        }

        if let failure = state.operationFailure {
            InlineBanner(
                kind: .error,
                title: failure.title,
                detail: failure.message,
                hint: failure.hint
            )
        }

        if let success = state.lastSuccess {
            InlineBanner(kind: .success, title: success)
        }

        if let status = state.status, let blocker = status.pushBlocker, !status.isClean {
            VStack(alignment: .leading, spacing: 7) {
                InlineBanner(kind: .warning, title: "Push is blocked", detail: blocker.message)

                if case .noUpstream(let branch, let canPublish) = blocker, canPublish {
                    Button {
                        Task { await model.publishBranch(for: state) }
                    } label: {
                        Label("Publish “\(branch)”", systemImage: "arrow.up.circle")
                    }
                    .controlSize(.small)
                    .disabled(state.isBusy)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            FooterButton(title: "Cursor", assetImage: "CursorLogo") {
                Task { await model.openInCursor(state) }
            }
            FooterButton(title: "Claude Code", assetImage: "ClaudeLogo") {
                Task { await model.openInClaudeCode(state) }
            }
            FooterButton(title: "Codex", assetImage: "CodexLogo") {
                Task { await model.openInCodex(state) }
            }

            Spacer()

            FooterButton(title: "Remove", systemImage: "trash", tint: .red) {
                model.remove(state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Text-and-icon button used in the detail footer.
struct FooterButton: View {
    let title: String
    var systemImage: String?
    var assetImage: String?
    var tint: Color = .secondary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let assetImage {
                    Image(assetImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
            }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isHovering ? tint.opacity(0.9) : tint)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The scrollable list of changed files.
struct ChangedFilesSection: View {
    @Environment(AppModel.self) private var model
    let state: RepositoryState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "Changed files", trailing: countLabel)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if let status = state.status {
                if status.changes.isEmpty {
                    Text("Working tree is clean.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(status.changes) { change in
                                ChangedFileRow(
                                    change: change
                                ) {
                                    Task { await model.openInCursor(change, in: state) }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .syncScrollerAppearance()
                    }
                    .frame(height: rowsHeight(for: status.changes.count))
                }
            } else {
                Text("Reading status…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }

    private var countLabel: String? {
        guard let count = state.status?.changedFileCount, count > 0 else { return nil }
        return "\(count)"
    }

    /// Grows with the change count up to a cap, so small change sets don't leave a gap.
    private func rowsHeight(for count: Int) -> CGFloat {
        let rowHeight: CGFloat = 29
        return min(CGFloat(count) * rowHeight + 6, 190)
    }
}

/// A single changed file. Clicking opens it in Cursor.
struct ChangedFileRow: View {
    let change: GitFileChange
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 7) {
                Image(systemName: change.kind.symbolName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tint)
                    .frame(width: 12)

                Text(change.fileName)
                    .font(.system(size: 11.5))
                    .lineLimit(1)

                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                Text(change.kind.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
            }
        }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    private var tint: Color {
        switch change.kind {
        case .added, .untracked: return .green
        case .modified, .typeChanged: return .orange
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .conflicted: return .red
        }
    }

}
