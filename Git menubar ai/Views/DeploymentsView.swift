import AppKit
import SwiftUI

/// The latest Vercel deployment of each project.
struct DeploymentsView: View {
    let model: VercelDeploymentsModel
    let maxHeight: CGFloat
    @Binding var choosingTeams: Bool
    let openSettings: () -> Void
    @Environment(\.isMenuWindowVisible) private var isMenuWindowVisible

    var body: some View {
        FittedScrollView(maxHeight: maxHeight, estimatedHeight: 200) {
            if choosingTeams {
                DeploymentTeamsChooser(model: model)
                    .padding(Theme.edge)
            } else {
                deploymentList
            }
        }
        .task(id: isMenuWindowVisible) {
            guard isMenuWindowVisible else { return }
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: model.pollInterval)
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
    }

    private var deploymentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let failure = model.failure {
                failureBanner(failure)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
            if model.deployments.isEmpty {
                emptyState
            } else {
                let teams = model.teams
                ForEach(teams) { team in
                    if teams.count > 1 {
                        SectionHeader(title: team.name)
                            .padding(.horizontal, 8)
                            .padding(.top, team == teams.first ? 2 : 10)
                            .padding(.bottom, 2)
                    }
                    ForEach(model.deployments.filter { $0.team == team }) { deployment in
                        DeploymentRow(deployment: deployment)
                    }
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
        } else if model.failure?.needsSignIn == true {
            EmptyState(
                systemImage: "triangle",
                title: "Connect Vercel",
                message: "Run vercel login in Terminal, or paste an access token in Settings."
            ) {
                HStack(spacing: 8) {
                    Button("Add Token…", action: openSettings)
                    Link("Create a Token", destination: URL(string: "https://vercel.com/account/settings/tokens")!)
                }
                .controlSize(.small)
            }
        } else if !model.allTeams.isEmpty, model.allTeams.allSatisfy({ !model.isShown($0) }) {
            EmptyState(
                systemImage: "eye.slash",
                title: "All teams are hidden",
                message: "Choose the teams whose deployments you want to see."
            ) {
                Button("Choose Teams…") { choosingTeams = true }
                    .controlSize(.small)
            }
        } else if model.failure == nil {
            EmptyState(
                systemImage: "triangle",
                title: "No deployments yet",
                message: "Projects you deploy to Vercel appear here."
            )
        }
    }

    private func failureBanner(_ failure: VercelError) -> some View {
        InlineBanner(
            kind: failure.needsSignIn ? .warning : .error,
            title: failure.needsSignIn ? "Not signed in to Vercel" : "Couldn't refresh deployments",
            detail: failure.errorDescription
        )
    }
}

/// Checkboxes for the teams whose deployments the tab shows, styled like the
/// Usage tab's menu bar organizer.
private struct DeploymentTeamsChooser: View {
    let model: VercelDeploymentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Teams")
                .padding(.leading, 2)
            Text("Choose which Vercel teams show their deployments here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            if model.allTeams.isEmpty {
                HStack {
                    Spacer()
                    if model.isRefreshing {
                        InlineSpinner()
                    } else {
                        Text("No teams loaded yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.allTeams.enumerated()), id: \.element.id) { index, team in
                        if index > 0 { Divider().opacity(0.5).padding(.leading, 34) }
                        Toggle(isOn: Binding(
                            get: { model.isShown(team) },
                            set: { model.setShown(team, isShown: $0) }
                        )) {
                            HStack(spacing: 6) {
                                Text(team.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                let count = model.projectCount(in: team)
                                Text(count == 1 ? "1 project" : "\(count) projects")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                        .padding(.vertical, 7)
                    }
                }
                .card()
            }
        }
    }
}

private struct DeploymentRow: View {
    let deployment: VercelDeployment
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            DeploymentStatusDot(state: deployment.state)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(deployment.projectName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if deployment.state != .ready {
                        Chip(text: deployment.state.title, tint: deployment.state.tint)
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let message = deployment.commitMessage {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(helpText)

            Spacer(minLength: 4)

            if let url = deployment.url, deployment.state == .ready {
                IconButton(systemImage: "arrow.up.right", help: "Open \(url.host() ?? "deployment")") {
                    NSWorkspace.shared.open(url)
                }
            }

            IconMenu(help: "Deployment options") {
                if let inspector = deployment.inspectorURL {
                    Button("Open in Vercel") { NSWorkspace.shared.open(inspector) }
                }
                if let url = deployment.url {
                    Button("Open Deployment") { NSWorkspace.shared.open(url) }
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isHovering ? Theme.hoverFill : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            if let inspector = deployment.inspectorURL { NSWorkspace.shared.open(inspector) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deployment.projectName), \(deployment.state.title), \(subtitle)")
    }

    private var subtitle: String {
        let age = deployment.createdAt.formatted(.relative(presentation: .named))
        return [deployment.environmentTitle, deployment.branch, age]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var helpText: String {
        var lines = ["\(deployment.state.title) · \(deployment.createdAt.formatted(date: .abbreviated, time: .shortened))"]
        if let host = deployment.url?.host() { lines.append(host) }
        if let message = deployment.commitMessage { lines.append(message) }
        return lines.joined(separator: "\n")
    }
}

/// A colored dot that pulses while the deployment is in progress.
private struct DeploymentStatusDot: View {
    let state: VercelDeploymentState
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .shadow(color: state.tint.opacity(state == .ready || state.isInProgress ? 0.6 : 0), radius: 3)
            .opacity(state.isInProgress && isPulsing ? 0.35 : 1)
            .animation(
                state.isInProgress ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear { isPulsing = state.isInProgress }
            .onChange(of: state) { isPulsing = state.isInProgress }
    }
}

extension VercelDeploymentState {
    var tint: Color {
        switch self {
        case .ready: return .green
        case .queued, .initializing, .building: return .orange
        case .error: return .red
        case .canceled, .deleted, .unknown: return .secondary
        }
    }
}
