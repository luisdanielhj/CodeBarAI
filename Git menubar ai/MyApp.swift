import SwiftUI

@main
struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(model)
        } label: {
            MenuBarLabel(changedFileCount: model.totalChangedFileCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item itself: a branch glyph, with a count once anything is uncommitted.
struct MenuBarLabel: View {
    let changedFileCount: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            if changedFileCount > 0 {
                Text("\(changedFileCount)")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .accessibilityLabel(
            changedFileCount > 0
                ? "Commit Bar, \(changedFileCount) changed files"
                : "Commit Bar, no changes"
        )
    }
}
