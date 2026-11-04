import AppKit
import SwiftUI

enum WorkspaceAppearance {
    static let headerHeight: CGFloat = 54
    static let terminal = NSColor(srgbRed: 14 / 255, green: 15 / 255, blue: 17 / 255, alpha: 1)
    static let sidebar = Color(red: 28 / 255, green: 30 / 255, blue: 33 / 255)
    static let panel = sidebar
    static let line = Color(red: 40 / 255, green: 43 / 255, blue: 47 / 255)
    static let text = Color(red: 234 / 255, green: 232 / 255, blue: 228 / 255)
    static let secondary = Color(red: 164 / 255, green: 170 / 255, blue: 180 / 255)
    static let orange = NSColor(srgbRed: 1, green: 132 / 255, blue: 92 / 255, alpha: 1)
    static let accent = Color(nsColor: orange)
    static let selected = Color.white.opacity(0.05)
    static let inputFill = Color.white.opacity(0.02)
    static let inputBorder = Color(red: 58 / 255, green: 62 / 255, blue: 68 / 255)
}

struct WorkspaceIconButton: ButtonStyle {
    var foreground: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, foreground: foreground)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let foreground: Color?
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(enabled ? (foreground ?? WorkspaceAppearance.text) : (foreground?.opacity(0.45) ?? WorkspaceAppearance.secondary.opacity(0.65)))
                .frame(width: 32, height: 32)
                .background(enabled && configuration.isPressed ? (foreground?.opacity(0.12) ?? Color.white.opacity(0.1)) :
                                enabled && hovered ? (foreground?.opacity(0.06) ?? WorkspaceAppearance.selected) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

struct WorkspaceDivider: View {
    @Binding var width: CGFloat
    let limits: ClosedRange<CGFloat>
    var trailing = false
    let label: String
    @State private var initialWidth: CGFloat?

    var body: some View {
        Rectangle().fill(WorkspaceAppearance.line).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if initialWidth == nil { initialWidth = width }
                        width = min(limits.upperBound, max(limits.lowerBound, (initialWidth ?? width) + value.translation.width * (trailing ? -1 : 1)))
                    }.onEnded { _ in initialWidth = nil })
            }
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                width = min(limits.upperBound, max(limits.lowerBound, width + (direction == .increment ? 16 : -16)))
            }
    }
}

/// 标题栏融入工作区；保留 macOS 原生窗口按钮和关闭委托。
struct WorkspaceWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var windowObservers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = WorkspaceAppearance.terminal
            window.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.async { [weak self] in self?.alignWindowButtons() }
            for notification in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) { [weak self] _ in
                    // AppKit 会在通知之后重新布局原生标题栏，等待这一轮布局完成再对齐。
                    DispatchQueue.main.async { self?.alignWindowButtons() }
                })
            }
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignWindowButtons() }
            })
        }

        private func alignWindowButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
            // 保留系统按钮及其动作，只把标题栏高度和按钮中心对齐工作区顶部。
            var frame = titlebar.frame
            frame.origin.y += frame.height - WorkspaceAppearance.headerHeight
            frame.size.height = WorkspaceAppearance.headerHeight
            if titlebar.frame != frame { titlebar.frame = frame }
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let origin = NSPoint(x: 18 + CGFloat(index) * 22,
                                     y: (WorkspaceAppearance.headerHeight - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// 连接列表保留原生选择/键盘行为，选中底色由行本身绘制。
struct ConnectionSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.style = .fullWidth
                    table.selectionHighlightStyle = .none
                    break
                }
                ancestor = view.superview
            }
        }
    }
}
