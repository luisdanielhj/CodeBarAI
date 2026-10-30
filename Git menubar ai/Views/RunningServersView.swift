import AppKit
import SwiftUI

struct RunningServersView: View {
    let model: RunningServersModel
    let projects: [Repository]
    @State private var contentHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Running Servers")
                    .font(.system(size: 10, weight: .semibold))
                if !model.servers.isEmpty {
                    Text("\(model.servers.count)")
                        .font(.system(size: 9))
                        .monospacedDigit()
                }
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await model.refresh(projects: projects) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .frame(width: 20, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh running servers")
                    .accessibilityLabel("Refresh running servers")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)

            ScrollView {
                VStack(spacing: 6) {
                    if let failure = model.failure {
                        Text(failure)
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                    }
                    if model.servers.isEmpty && model.failure == nil {
                        Text(model.hasLoaded ? "No development servers running." : "Looking for local development servers…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(model.servers) { server in
                            serverRow(server)
                        }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .syncScrollerAppearance()
            }
            .frame(height: min(contentHeight, 160))
        }
        .padding(.vertical, 4)
        .task {
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

    private func serverRow(_ server: RunningServer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text("\(server.runtime) · \(server.portDescription)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(server.runtime) · PID \(server.process.pid)\n\(server.workingDirectory ?? server.process.executable)\n\(server.portDescription)")
                Spacer(minLength: 0)
                if model.stopping.contains(server.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(model.needsForceStop.contains(server.id) ? "Force Stop" : "Stop") {
                        Task { await model.stop(server, force: model.needsForceStop.contains(server.id)) }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(model.needsForceStop.contains(server.id) ? "Force stop" : "Stop") \(server.title) on \(server.portDescription)")
                }
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Server options")
            }
            if let error = model.stopFailures[server.id] {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}
