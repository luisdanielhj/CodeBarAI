import AppKit
import SwiftUI

/// Keeps AppKit's native scroller in step with SwiftUI's color scheme.
/// `MenuBarExtra` windows can otherwise leave the scroller using the appearance
/// from the previously active system theme.
private struct ScrollViewAppearanceSync: NSViewRepresentable {
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> AppearanceSyncView {
        let view = AppearanceSyncView()
        view.colorScheme = colorScheme
        return view
    }

    func updateNSView(_ nsView: AppearanceSyncView, context: Context) {
        nsView.colorScheme = colorScheme
        nsView.syncAppearance()
    }
}

private final class AppearanceSyncView: NSView {
    var colorScheme: ColorScheme = .light

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAppearance()
    }

    func syncAppearance() {
        let colorScheme = colorScheme

        // SwiftUI may update the representable just before AppKit attaches it
        // to the scroll view, so perform the lookup on the next main-loop pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.enclosingScrollView else { return }
            let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
            let appearance = NSAppearance(named: name)

            scrollView.appearance = appearance
            scrollView.verticalScroller?.appearance = appearance
            scrollView.horizontalScroller?.appearance = appearance
        }
    }
}

private struct SyncScrollerAppearanceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            ScrollViewAppearanceSync(colorScheme: colorScheme)
        }
    }
}

extension View {
    /// Apply to the content inside a SwiftUI `ScrollView`.
    func syncScrollerAppearance() -> some View {
        modifier(SyncScrollerAppearanceModifier())
    }
}

extension EnvironmentValues {
    /// Whether the menu bar window is on screen. Polling views use it to stop
    /// working while the window is closed.
    @Entry var isMenuWindowVisible = false
}

/// `MenuBarExtra` hides its window instead of closing it, so `onDisappear` never
/// fires and a view's `.task` keeps running after the menu closes. This reads
/// the hosting window's real visibility from AppKit instead.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            report(false)
            return
        }

        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // AppKit updates `isVisible` and the occlusion state after
                    // these notifications are posted, so read them next pass.
                    DispatchQueue.main.async { self?.evaluate() }
                }
            }
        }
        evaluate()
    }

    private func evaluate() {
        guard let window else {
            report(false)
            return
        }
        report(window.isVisible && (window.isKeyWindow || window.occlusionState.contains(.visible)))
    }

    private func report(_ isVisible: Bool) {
        guard isVisible != lastReported else { return }
        lastReported = isVisible
        onChange?(isVisible)
    }
}

extension View {
    /// Calls `action` when the hosting window appears on or leaves the screen.
    func onWindowVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        background { WindowVisibilityReader(onChange: action) }
    }
}
