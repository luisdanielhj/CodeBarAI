import SwiftUI

struct AIUsageView: View {
    let model: AIUsageModel

    /// Measured so the section is exactly as tall as the cards it holds; the
    /// height only ever reaches the cap when every provider is connected.
    @State private var contentHeight: CGFloat = 126

    private let maximumHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.states) { state in
                    AIUsageProviderView(model: model, state: state)
                }
            }
            // Matches the repository list's insets, so both sections line their
            // rows up against the same edges.
            .padding(6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .syncScrollerAppearance()
        }
        .frame(height: min(contentHeight, maximumHeight))
        .padding(.vertical, 4)
    }
}

private struct AIUsageProviderView: View {
    let model: AIUsageModel
    let state: AIUsageState
    @State private var confirmingConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(state.provider.logoName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
                Text(state.provider.title)
                    .font(.system(size: 11, weight: .semibold))
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
                if state.isEnabled {
                    Menu {
                        Button("Refresh Usage") { Task { await model.refresh(state) } }
                            .disabled(state.isRefreshing || Date() < state.nextRefreshAt)
                        Button("Disconnect", role: .destructive) { model.disconnect(state) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Usage options")
                }
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
