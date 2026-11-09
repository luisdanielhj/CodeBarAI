import AppKit
import SwiftUI

/// Local development servers, with quick open and stop.
struct ServersView: View {
    let model: RunningServersModel
    let projects: [Repository]
    let maxHeight: CGFloat
    @Environment(\.isMenuWindowVisible) private var isMenuWindowVisible

    var body: some View {
        FittedScrollView(maxHeight: maxHeight, estimatedHeight: 160) {
            VStack(spacing: 2) {
                if let failure = model.failure {
                    InlineBanner(kind: .warning, title: failure)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
                if model.servers.isEmpty && model.failure == nil {
                    if model.hasLoaded {
                        EmptyState(
                            systemImage: "network.slash",
                            title: "No servers running",
                            message: "Dev servers you start from your projects appear here."
                        )
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                } else {
                    ForEach(model.servers) { server in
                        ServerRow(model: model, server: server)
                    }
                }
            }
            .padding(6)
        }
        .task(id: isMenuWindowVisible) {
            // Scanning every process is the most expensive poll in the app, so
            // it only runs while someone can see the result.
            guard isMenuWindowVisible else { return }
            await model.refresh(projects: projects)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
        .onChange(of: projects.map(\.id)) {
            Task { await model.refresh(projects: projects) }
        }
    }
}

private struct ServerRow: View {
    let model: RunningServersModel
    let server: RunningServer
    @State private var isHovering = false

    private var needsForce: Bool { model.needsForceStop.contains(server.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.6), radius: 3)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text("\(server.runtime) · \(server.portDescription)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .help("\(server.runtime) · PID \(server.process.pid)\n\(server.workingDirectory ?? server.process.executable)")

                Spacer(minLength: 4)

                if let port = server.ports.first, let url = server.localURL(port: port) {
                    IconButton(systemImage: "arrow.up.right", help: "Open localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                if model.stopping.contains(server.id) {
                    InlineSpinner()
                } else {
                    Button(needsForce ? "Force Stop" : "Stop") {
                        Task { await model.stop(server, force: needsForce) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.red.opacity(isHovering ? 0.14 : 0.09), in: Capsule())
                    .accessibilityLabel("\(needsForce ? "Force stop" : "Stop") \(server.title) on \(server.portDescription)")
                }

                IconMenu(help: "Server options") {
                    ForEach(server.ports, id: \.self) { port in
                        Button("Open localhost:\(port)") {
                            if let url = server.localURL(port: port) { NSWorkspace.shared.open(url) }
                        }
                    }
                    if let directory = server.workingDirectory {
                        Divider()
                        Button("Show Project Folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
                        }
                    }
                }
            }
            if let error = model.stopFailures[server.id] {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isHovering ? Theme.hoverFill : .clear)
        )
        .onHover { isHovering = $0 }
    }
}
