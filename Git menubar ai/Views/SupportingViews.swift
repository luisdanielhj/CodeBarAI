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

/// Compact artwork loaded from a repository's `.ico` file.
struct RepositoryIconView: View {
    let data: Data?
    var size: CGFloat = 18

    @ViewBuilder
    var body: some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

/// A borderless row that highlights on hover, the way list rows behave in
/// Spotlight-style panels.
struct HoverRow<Content: View>: View {
    private let action: () -> Void
    private let content: Content
    @State private var isHovering = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.07) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A compact icon-only toolbar button for the header.
struct HeaderButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A small rounded label used for branch names and counts.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

/// Severity of an inline message.
enum BannerKind {
    case error
    case warning
    case success
    case info

    var tint: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .info: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// Inline message card. Used instead of alerts, which would dismiss the menu bar window.
struct InlineBanner: View {
    let kind: BannerKind
    let title: String
    var detail: String?
    var hint: String?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }

                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(kind.tint)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(kind.tint.opacity(0.1))
        )
    }
}

/// Uppercase section label.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
