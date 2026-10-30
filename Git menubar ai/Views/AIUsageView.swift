import SwiftUI

struct AIUsageView: View {
    let model: AIUsageModel

    /// Measure both the usage cards and the organizer to avoid empty space,
    /// with a height cap for long account lists.
    @State private var contentHeight: CGFloat = 126
    @State private var organizingMenuBar = false

    private let maximumHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(organizingMenuBar ? "Menu Bar Accounts" : "AI Usage")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(organizingMenuBar ? "Done" : "Organize Menu Bar…") {
                    organizingMenuBar.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

            ScrollView {
                VStack(spacing: 8) {
                    if organizingMenuBar {
                        MenuBarAccountsOrganizer(model: model)
                    } else {
                        ForEach(model.states) { state in
                            AIUsageProviderView(model: model, state: state)
                        }
                        Button {
                            guard let directory = SystemIntegration.chooseClaudeAccountFolder() else { return }
                            let state = model.addClaudeAccount(directory: directory)
                            Task { await model.connect(state) }
                        } label: {
                            Label("Add Claude Account…", systemImage: "person.badge.plus")
                                .font(.system(size: 10, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                // Matches the repository list's insets, so both sections line
                // their rows up against the same edges.
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .syncScrollerAppearance()
            }
            .frame(height: min(contentHeight, maximumHeight))
        }
        .padding(.vertical, 4)
    }
}

private struct MenuBarAccountsOrganizer: View {
    let model: AIUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check the accounts to show. Use the arrows to set their order from left to right.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.menuBarAccountStates) { state in
                HStack(spacing: 6) {
                    Toggle(state.title, isOn: Binding(
                        get: { model.isShownInMenuBar(state) },
                        set: { model.setMenuBarVisibility(state, isVisible: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .help(state.title)
                    Spacer(minLength: 0)
                    Button {
                        model.moveMenuBarAccount(state, by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 20, height: 20)
                    }
                    .disabled(model.menuBarAccountStates.first?.id == state.id)
                    .help("Move \(state.title) earlier")
                    .accessibilityLabel("Move \(state.title) earlier")
                    Button {
                        model.moveMenuBarAccount(state, by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                            .frame(width: 20, height: 20)
                    }
                    .disabled(model.menuBarAccountStates.last?.id == state.id)
                    .help("Move \(state.title) later")
                    .accessibilityLabel("Move \(state.title) later")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
        }
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AIUsageProviderView: View {
    let model: AIUsageModel
    let state: AIUsageState
    @State private var confirmingConnection = false
    @State private var renamingAccount = false
    @State private var accountName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(state.provider.logoName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .help(state.claudeProfile?.configDirectory.path ?? state.provider.title)
                if model.isShownInMenuBar(state) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Shown in the menu bar")
                }
                if let plan = state.snapshot?.plan {
                    Text(plan.capitalized)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else if !state.isEnabled {
                    Button("Connect") { confirmingConnection = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Menu {
                    Toggle("Show in Menu Bar", isOn: Binding(
                        get: { model.isShownInMenuBar(state) },
                        set: { model.setMenuBarVisibility(state, isVisible: $0) }
                    ))
                    if state.isEnabled {
                        Divider()
                        Button("Refresh Usage") { Task { await model.refresh(state) } }
                            .disabled(state.isRefreshing || Date() < state.nextRefreshAt)
                        Button("Disconnect", role: .destructive) { model.disconnect(state) }
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Usage options")
            }

            if state.isEnabled {
                if let snapshot = state.snapshot {
                    ForEach(snapshot.windows) { window in
                        AIUsageWindowView(window: window)
                    }
                    if snapshot.windows.isEmpty {
                        Text("No plan limits reported by this provider.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if state.isRefreshing {
                    Text("Reading subscription usage…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let failure = state.failure {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Next attempt: \(state.nextRefreshAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .alert("Connect \(state.provider.title)?", isPresented: $confirmingConnection) {
            Button("Cancel", role: .cancel) { }
            Button("Connect") { Task { await model.connect(state) } }
        } message: {
            Text("CodeBarAI will read this tool’s local sign-in credentials and send them only to its own usage service. Tokens are not saved by CodeBarAI. \(state.provider.connectionHint)")
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
}

private struct AIUsageWindowView: View {
    let window: AIUsageWindow

    private var percentLeft: Double? {
        window.usedPercent.map { 100 - min(max($0, 0), 100) }
    }

    private var tint: Color {
        guard let left = percentLeft else { return .secondary }
        return left <= 10 ? .red : left <= 30 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                Spacer()
                if let left = percentLeft {
                    Text("\(left.formatted(.number.precision(.fractionLength(0...1))))% left")
                        .monospacedDigit()
                } else {
                    Text("Usage unavailable")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if let left = percentLeft {
                ProgressView(value: left, total: 100)
                    .tint(tint)
                    .accessibilityLabel("\(window.title) usage left")
                    .accessibilityValue("\(left.formatted(.number.precision(.fractionLength(0...1)))) percent left")
            }
            if let reset = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 3) {
                        if reset > context.date {
                            Text("Resets")
                            Text(reset, style: .relative)
                        } else {
                            Text("Reset time passed · awaiting refresh")
                        }
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(reset.formatted(date: .abbreviated, time: .shortened))
            }
            if let detail = window.detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
