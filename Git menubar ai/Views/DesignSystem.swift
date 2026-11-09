import AppKit
import SwiftUI

/// Shared measurements so every screen lines up on the same grid.
enum Theme {
    static let windowWidth: CGFloat = 360
    /// Inset from the window edge to cards and rows.
    static let edge: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 8

    static let hoverFill = Color.primary.opacity(0.06)
    static let cardFill = Color.primary.opacity(0.035)
    static let cardStroke = Color.primary.opacity(0.07)
}

// MARK: - Containers

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke)
            )
    }
}

extension View {
    /// The quiet filled card used for limits, banners and the commit editor.
    func card() -> some View {
        modifier(CardBackground())
    }
}

/// A scroll view that is exactly as tall as its content, up to `maxHeight`.
/// Inside a `MenuBarExtra` window a plain `ScrollView` has no ideal height
/// and can collapse to nothing.
struct FittedScrollView<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat

    init(maxHeight: CGFloat, estimatedHeight: CGFloat = 120, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
        _contentHeight = State(initialValue: estimatedHeight)
    }

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .syncScrollerAppearance()
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

// MARK: - Controls

/// A borderless row that highlights on hover, like Spotlight results.
struct HoverRow<Content: View>: View {
    private let action: () -> Void
    private let content: (Bool) -> Content
    @State private var isHovering = false

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping (_ isHovering: Bool) -> Content) {
        self.action = action
        self.content = content
    }

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = { _ in content() }
    }

    var body: some View {
        Button(action: action) {
            content(isHovering)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .fill(isHovering ? Theme.hoverFill : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A small icon-only button with a hover highlight.
struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Theme.hoverFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.primary : tint)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An icon-only menu that matches `IconButton`.
struct IconMenu<Items: View>: View {
    var systemImage = "ellipsis"
    let help: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A spinner sized to sit where an `IconButton` would.
struct InlineSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.6)
            .frame(width: 24, height: 24)
    }
}

/// Segmented tabs drawn as text with a sliding highlight.
struct TabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    HStack(spacing: 4) {
                        Text(title(tab))
                        if let badge = badge(tab) {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? .secondary : .tertiary)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

/// A full-width segmented control with equal segments and a sliding thumb.
struct SegmentedControl<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A full-width button used for the main actions on a screen.
struct WideButton: View {
    enum Style { case primary, secondary }

    let title: String
    var systemImage: String?
    var style: Style = .secondary
    var isWorking = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        style == .primary ? Color(nsColor: .windowBackgroundColor) : .primary
    }

    private var background: Color {
        switch style {
        case .primary: return .primary.opacity(isHovering && isEnabled ? 0.8 : 0.9)
        case .secondary: return .primary.opacity(isHovering && isEnabled ? 0.1 : 0.06)
        }
    }
}

// MARK: - Content

/// Project artwork from the repository's `.ico` file, or its initial.
struct ProjectIcon: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.07))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A small rounded label used for counts and states.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.13)))
    }
}

/// Section title, optionally with a count or action on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Severity of an inline message.
enum BannerKind {
    case error, warning, success, info

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
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// Inline message. Used instead of alerts, which would dismiss the menu bar window.
struct InlineBanner: View {
    let kind: BannerKind
    let title: String
    var detail: String?
    var hint: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(kind.tint)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(10)
        .background(kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Centered placeholder for an empty list.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Formatting

enum DurationText {
    /// Two most significant units, e.g. `4h 18m`, `6d 23h`, `12m`.
    static func short(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded(.up)))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(max(mins, 1))m"
    }
}
