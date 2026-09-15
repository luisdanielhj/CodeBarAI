import SwiftUI

/// Root of the menu bar window. Switches between the repository list and one
/// repository's detail view, and owns the periodic refresh.
struct MenuBarRootView: View {
    @Environment(AppModel.self) private var model

    /// Backstop poll interval. File system events handle everything local; this
    /// only catches state changed by other tools in ways FSEvents misses.
    private let pollInterval: Duration = .seconds(60)

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(width: 390)
        .task {
            model.start()
            await model.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { break }
                await model.refreshAll()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selected = model.selectedRepository {
            RepositoryDetailView(state: selected)
        } else {
            RepositoryListView()
        }
    }
}
