import SwiftUI

/// The editable commit message plus the Commit & Push / Commit actions.
struct CommitComposer: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: RepositoryState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                SectionLabel(text: "Commit message")
                Spacer()
                generateButton
            }

            messageEditor

            if let note = state.generationNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                        .scaleEffect(0.55)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5))
                }
                Text(state.isGeneratingMessage ? "Generating…" : "Generate")
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
        .controlSize(.small)
        .disabled(!canGenerate)
        .help("Write a Conventional Commit message from the current changes — \(model.generatorEngineDescription)")
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
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .frame(height: 54)

            if state.commitMessage.isEmpty {
                Text("feat(scope): describe the change")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.commit(state, push: true) }
                } label: {
                    HStack(spacing: 5) {
                        if state.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: 9, height: 9)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 11))
                        }
                        Text(state.activity ?? "Commit & Push")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canPush)
                .keyboardShortcut(.return, modifiers: .command)

                Button("Commit") {
                    Task { await model.commit(state, push: false) }
                }
                .font(.system(size: 12))
                .disabled(!state.canCommit)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Commit without pushing (⇧⌘↩)")
            }

            if let reason = disabledReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Explains a disabled Commit & Push button so the UI is never silently inert.
    private var disabledReason: String? {
        guard !state.isBusy else { return nil }
        guard let status = state.status else { return nil }

        if let blocker = status.commitBlocker {
            if case .nothingToCommit = blocker { return nil }
            return blocker.message
        }
        if state.trimmedCommitMessage.isEmpty {
            return "Enter or generate a message to enable committing."
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
