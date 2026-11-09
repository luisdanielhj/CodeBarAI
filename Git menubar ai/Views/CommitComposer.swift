import SwiftUI

/// The commit message editor plus Commit & Push and Commit.
struct CommitComposer: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: RepositoryState
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Message") {
                HStack(spacing: 2) {
                    generateButton
                    IconButton(systemImage: "gearshape", help: "Choose the AI that writes commit messages") {
                        withAnimation(.snappy(duration: 0.2)) { model.isShowingSettings = true }
                    }
                }
            }
            .padding(.leading, 2)

            messageEditor

            if let note = state.generationNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 2)
            }

            HStack(spacing: 6) {
                WideButton(
                    title: state.activity ?? "Commit & Push",
                    systemImage: "arrow.up",
                    style: .primary,
                    isWorking: state.isBusy
                ) {
                    Task { await model.commit(state, push: true) }
                }
                .disabled(!state.canPush)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Commit all changes and push (⌘↩)")

                WideButton(title: "Commit") {
                    Task { await model.commit(state, push: false) }
                }
                .frame(width: 92)
                .disabled(!state.canCommit)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Commit without pushing (⇧⌘↩)")
            }

            if let reason = disabledReason {
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(Theme.edge)
    }

    // MARK: Generate

    private var generateButton: some View {
        Button {
            Task { await model.generateCommitMessage(for: state) }
        } label: {
            HStack(spacing: 4) {
                if state.isGeneratingMessage {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(state.isGeneratingMessage ? "Writing…" : "Generate")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(canGenerate ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.accentColor.opacity(canGenerate ? 0.1 : 0.0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate)
        .help("Write a Conventional Commit message from the current changes with \(model.generatorEngineDescription)")
    }

    private var canGenerate: Bool {
        guard let status = state.status else { return false }
        return !status.changes.isEmpty && !state.isGeneratingMessage && !state.isBusy
    }

    // MARK: Editor

    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $state.commitMessage)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(height: 84)

            if state.commitMessage.isEmpty {
                Text("Describe the change, or press Generate")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(editorFocused ? 0.5 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: editorFocused)
    }

    /// Explains a disabled Commit & Push button so the UI is never silently inert.
    private var disabledReason: String? {
        guard !state.isBusy, let status = state.status else { return nil }
        if let blocker = status.commitBlocker {
            if case .nothingToCommit = blocker { return nil }
            return blocker.message
        }
        return nil
    }
}

/// Confirmation shown before a commit that would include credentials or keys.
struct SensitiveFileWarning: View {
    @Environment(AppModel.self) private var model
    let pending: PendingCommit

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.3))
                .onTapGesture { model.cancelPendingCommit() }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("Sensitive files detected")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("git add -A would include these in the commit:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(pending.files) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.path)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Text(file.reason)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .syncScrollerAppearance()
                }
                .frame(maxHeight: 110)

                Text("Add them to .gitignore if they should stay on this machine.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack {
                    Button("Cancel") { model.cancelPendingCommit() }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button(pending.push ? "Commit & Push Anyway" : "Commit Anyway") {
                        Task { await model.confirmPendingCommit() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35))
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .padding(16)
        }
    }
}
