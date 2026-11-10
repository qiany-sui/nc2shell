import AppKit
import SwiftUI
import SwiftTerm

struct TerminalWorkspaceView: View {
    @ObservedObject var model: AppModel
    let workspace: TerminalWorkspace
    @Binding var showFiles: Bool
    let showTransfers: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let minimumTerminal: CGFloat = workspace.secondarySessionID != nil && workspace.axis == .columns ? 480 : 300
            let panelWidth = showFiles ? min(model.filePanelWidth, max(300, geometry.size.width - minimumTerminal - 1)) : 0
            HStack(spacing: 0) {
                panes.frame(minWidth: minimumTerminal, maxWidth: .infinity)
                if showFiles {
                    WorkspaceDivider(width: $model.filePanelWidth, limits: 300...550, trailing: true, label: "调整文件面板宽度")
                }
                if let focused = model.selectedSession {
                    // 收起只改变宽度，保留列表选择与正在编辑的路径。
                    RemoteFilesView(session: focused, model: focused.files,
                                    close: { showFiles = false }, showTransfers: showTransfers)
                        .id(focused.id).frame(width: panelWidth)
                        .opacity(showFiles ? 1 : 0).clipped().allowsHitTesting(showFiles).accessibilityHidden(!showFiles)
                }
            }
        }
        .onChange(of: showFiles) { _, visible in
            // 隐藏原生输入框不会自动释放 field editor，必须把键盘交回当前终端。
            if !visible { model.focus(workspace.focusedSessionID) }
        }
    }

    @ViewBuilder private var panes: some View {
        if let first = model.session(workspace.primarySessionID) {
            if let second = model.session(workspace.secondarySessionID) {
                GeometryReader { geometry in
                    let columns = workspace.axis == .columns
                    let available = max(1, (columns ? geometry.size.width : geometry.size.height) - 1)
                    let minimum = min(available / 2, columns ? 220 : 160)
                    let minimumFraction = Double(minimum / available)
                    let firstLength = min(available - minimum, max(minimum, available * CGFloat(workspace.splitFraction)))
                    let layout = columns ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    // 共用视图树，切换方向与比例只调整尺寸，不拆走终端或输入焦点。
                    layout {
                        pane(first).frame(width: columns ? firstLength : nil, height: columns ? nil : firstLength)
                        TerminalPaneDivider(columns: columns, length: available, limits: minimumFraction ... (1 - minimumFraction),
                                            fraction: Binding(get: { Double(firstLength / available) }, set: { model.resizeSplit(workspace.id, fraction: $0) }))
                            .zIndex(1)
                        pane(second).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else { pane(first) }
        }
    }

    private func pane(_ session: TerminalSession) -> some View {
        SessionPane(session: session, split: workspace.secondarySessionID != nil, selected: workspace.focusedSessionID == session.id,
                    focus: { model.focus(session.id, requestResponder: false) },
                    activate: { model.focus(session.id) }, close: { model.close(session) })
            .frame(minWidth: 220, minHeight: 160)
    }
}

private struct TerminalPaneDivider: View {
    let columns: Bool
    let length: CGFloat
    let limits: ClosedRange<Double>
    @Binding var fraction: Double
    @State private var initialFraction: Double?
    @State private var hovered = false

    var body: some View {
        Rectangle().fill(hovered || initialFraction != nil ? WorkspaceAppearance.accent.opacity(0.55) : WorkspaceAppearance.line)
            .frame(width: columns ? 1 : nil, height: columns ? nil : 1)
            .overlay {
                Color.clear.frame(width: columns ? 9 : nil, height: columns ? nil : 9).contentShape(Rectangle())
                    .onHover { value in
                        hovered = value
                        (value ? (columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if initialFraction == nil { initialFraction = fraction }
                        let translation = columns ? value.translation.width : value.translation.height
                        setFraction((initialFraction ?? fraction) + Double(translation / length))
                    }.onEnded { _ in initialFraction = nil })
            }
            .accessibilityLabel(columns ? "调整左右分屏比例" : "调整上下分屏比例")
            .accessibilityAdjustableAction { setFraction(fraction + ($0 == .increment ? 0.05 : -0.05)) }
            .onDisappear { if hovered { NSCursor.arrow.set() } }
    }

    private func setFraction(_ value: Double) { fraction = min(limits.upperBound, max(limits.lowerBound, value)) }
}

private struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    let split: Bool
    let selected: Bool
    let focus: () -> Void
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if split {
            HStack(spacing: 4) {
                Button(action: activate) {
                    HStack(spacing: 6) {
                        Circle().fill(selected ? WorkspaceAppearance.accent : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                        Text(session.profile.destination).lineLimit(1).truncationMode(.middle)
                    }
                }.buttonStyle(.plain).help("将焦点切到此终端，菜单与文件面板跟随此会话")
                Spacer(minLength: 2)
                Menu {
                    Button("查找终端内容") { focus(); session.showFind() }
                    Button(session.logURL == nil ? "开始会话日志…" : "停止会话日志") { session.toggleLogging() }
                        .disabled(session.state != .connected)
                    Divider()
                    if session.state == .reconnecting {
                        Button("取消自动重连", action: session.disconnect)
                    } else if session.isRunning {
                        Button("断开") {
                            if AppModel.confirm(title: "断开当前连接？", detail: "前台运行的远程任务可能中断。", action: "断开") { session.disconnect() }
                        }.disabled(session.state == .disconnecting && session.process?.running == true)
                    } else {
                        Button("重新连接") { session.start() }
                        Button("手动认证重新连接") { session.start(useRememberedPassword: false) }
                    }
                    Button("关闭此窗格", action: close)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("当前窗格操作")
                    .tint(Color(nsColor: session.theme.foreground))
            }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: session.theme.foreground).opacity(selected ? 0.9 : 0.6))
                .padding(.horizontal, 12).frame(height: 28)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: session.theme.foreground).opacity(0.07)).frame(height: 1) }
            }
            if session.state == .connecting || session.state == .reconnecting || session.state == .failed {
                connectionFeedback
            }
            if let url = session.logURL {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("记录中：\(url.lastPathComponent)").lineLimit(1).truncationMode(.middle).help(url.path)
                    Spacer()
                    Button("停止", action: session.stopLogging)
                }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }
            if let error = session.logError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button { session.logError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(8)
            }
            if session.searchVisible { TerminalSearchBar(session: session, selected: selected, onFocus: focus) }
            TerminalHost(session: session, focused: selected && !session.searchVisible, onFocus: focus)
                .id(ObjectIdentifier(session.terminal)).padding(.horizontal, split ? 14 : 20).padding(.top, split ? 8 : 20).padding(.bottom, 8)

        }
        .foregroundStyle(Color(nsColor: session.theme.foreground))
        .background(Color(nsColor: session.theme.background))
        .environment(\.colorScheme, session.theme == .light ? .light : .dark)
    }

    private var connectionFeedback: some View {
        HStack(alignment: .top, spacing: 10) {
            if session.state == .failed {
                Image(systemName: "exclamationmark.circle").foregroundStyle(WorkspaceAppearance.accent)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.state == .failed ? "连接出现异常" : session.state == .reconnecting ? "等待自动重连…" : "正在连接…")
                    .font(.system(size: 13, weight: .medium))
                Text(session.state == .failed || session.state == .reconnecting ? session.statusText : "如需密码或确认主机指纹，请在下方终端完成。")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: session.theme.foreground).opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if session.state == .failed {
                Button("重新连接") { session.start() }
            } else {
                Button("取消连接") {
                    // 点击时重新确认状态，避免认证恰好完成后中断已连接的会话。
                    guard session.state == .connecting || session.state == .reconnecting else { return }
                    session.disconnect()
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: session.theme.foreground).opacity(0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: session.theme.foreground).opacity(0.08)).frame(height: 1) }
    }
}

private struct TerminalSearchBar: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let onFocus: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                TextField("搜索输出", text: $session.searchText)
                    .textFieldStyle(.plain).focused($editing).frame(minWidth: 40)
                    .onSubmit { session.showFind(.next) }
                    .onExitCommand { session.closeSearch() }
                    .accessibilityLabel("查找当前终端内容")
                    .font(.system(size: 14)).padding(.horizontal, 10).frame(height: 36)
                    .background(Color(nsColor: session.theme.foreground).opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(editing ? WorkspaceAppearance.accent.opacity(0.65) : Color(nsColor: session.theme.foreground).opacity(0.15)))
                Button { session.showFind(.previous) } label: { Image(systemName: "chevron.up").font(.system(size: 13)) }
                    .help("上一项").accessibilityLabel("上一项")
                Button { session.showFind(.next) } label: { Image(systemName: "chevron.down").font(.system(size: 13)) }
                    .help("下一项").accessibilityLabel("下一项")
                Menu {
                    Toggle("区分大小写", isOn: $session.searchOptions.caseSensitive)
                    Toggle("正则表达式", isOn: $session.searchOptions.regex)
                    Toggle("匹配整词", isOn: $session.searchOptions.wholeWord)
                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 26, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("查找选项")
                    .tint(Color(nsColor: session.theme.foreground))
                Button { session.closeSearch() } label: { Image(systemName: "xmark").font(.system(size: 13)) }
                    .help("关闭查找").accessibilityLabel("关闭查找")
            }.buttonStyle(WorkspaceIconButton(foreground: Color(nsColor: session.theme.foreground)))
            if !session.searchSummary.isEmpty {
                Text(session.searchSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .onAppear { requestEditing() }
            .onChange(of: session.searchFocusRequest) { _, _ in requestEditing() }
            .onChange(of: editing) { _, value in if value { onFocus() } }
    }

    private func requestEditing() {
        // 等输入框加入窗口，避免原输入框的焦点同步覆盖这次请求。
        DispatchQueue.main.async { if selected && session.searchVisible { editing = true } }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let focused: Bool
    let onFocus: () -> Void

    func makeNSView(context: Context) -> TerminalFocusContainer {
        let container = TerminalFocusContainer(terminal: session.terminal)
        container.onFocus = onFocus
        container.setFocused(focused)
        return container
    }

    func updateNSView(_ nsView: TerminalFocusContainer, context: Context) {
        nsView.onFocus = onFocus
        nsView.setFocused(focused)
    }
}

/// 观察 AppKit 的真实 responder（包括查找框的 field editor），不拦截终端按键。
final class TerminalFocusContainer: NSView {
    let terminal: TerminalView
    var onFocus: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var focused = false
    private var reported = false
    private weak var scrollIndicator: NSScroller?
    private var scrollIndicatorTracking: NSTrackingArea?
    private var scrollAvailability: NSKeyValueObservation?
    private var hoveringScrollIndicator = false
    private var pointerObserver: Any?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)
        // SwiftTerm 的独立 NSScroller 不由 NSScrollView 管理淡出。
        // 只改变透明度，保留原来的命中区域、列数、滚动和拖动行为。
        scrollIndicator = terminal.subviews.compactMap { $0 as? NSScroller }.first
        scrollIndicator?.alphaValue = 0
        scrollAvailability = scrollIndicator?.observe(\.isEnabled, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateScrollIndicator() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard let scrollIndicator else { return }
        let rect = convert(scrollIndicator.bounds, from: scrollIndicator)
        // 每次显示更新都重建区域会丢失 mouseExited，导致滚动槽悬停后常驻。
        if let scrollIndicatorTracking, scrollIndicatorTracking.rect == rect { return }
        if let scrollIndicatorTracking { removeTrackingArea(scrollIndicatorTracking) }
        hoveringScrollIndicator = false
        updateScrollIndicator()
        let area = NSTrackingArea(rect: rect,
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        scrollIndicatorTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === scrollIndicatorTracking { hoveringScrollIndicator = true; updateScrollIndicator() }
        else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === scrollIndicatorTracking { hoveringScrollIndicator = false; updateScrollIndicator() }
        else { super.mouseExited(with: event) }
    }

    private func updateScrollIndicator() {
        scrollIndicator?.alphaValue = hoveringScrollIndicator && scrollIndicator?.isEnabled == true ? 1 : 0
    }

    func setFocused(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        if value && !containsFirstResponder { requestFocusAfterAttach() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let pointerObserver { NSEvent.removeMonitor(pointerObserver); self.pointerObserver = nil }
        guard let window else { return }
        // 点击可能没有前置的 mouseExited（例如辅助功能触发），按事件位置同步显隐。
        // 原样返回事件，不接管终端输入、选择或滚轮处理。
        pointerObserver = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self, weak window] event in
            if let self, let indicator = self.scrollIndicator {
                self.hoveringScrollIndicator = event.window === window && indicator.bounds.contains(indicator.convert(event.locationInWindow, from: nil))
                self.updateScrollIndicator()
            }
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeFocus() }
        }
        if focused { requestFocusAfterAttach() }
    }

    private func requestFocusAfterAttach() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focused, !self.containsFirstResponder, let window = self.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    private var containsFirstResponder: Bool {
        let responder = window?.firstResponder
        let view: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
        else { view = responder as? NSView }
        return view?.isDescendant(of: terminal) == true || view === terminal
    }

    func observeFocus() {
        let inside = containsFirstResponder
        if inside && !reported { onFocus?() }
        reported = inside
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let pointerObserver { NSEvent.removeMonitor(pointerObserver) }
    }
}
