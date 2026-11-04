import SwiftUI
import AppKit

struct Nc2ShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(recovery: .shared, transferSettings: .shared)

    var body: some Scene {
        Window("Nc2Shell", id: "main") {
            ContentView(model: model)
                .background(WindowAttachment(delegate: delegate))
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { TerminalCommands(model: model) }
    }
}

private struct TerminalCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…", action: model.showSettings)
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model.editor != nil || model.settingsPresented)
        }
        CommandGroup(replacing: .newItem) {
            command(.newConnection)
            command(.connect)
        }
        CommandMenu("终端") {
            command(.splitColumns)
            command(.splitRows)
            command(.nextPane)
            Divider()
            command(.find)
            command(.findNext)
            command(.findPrevious)
            Divider()
            command(.increaseFont)
            command(.decreaseFont)
            command(.resetFont)
            Divider()
            command(.toggleLog)
            command(.closePane)
        }
    }
    private func command(_ action: TerminalAction) -> some View {
        let shortcut = model.preferences.shortcuts[action] ?? action.defaultShortcut
        return Button(action.title) { model.perform(action) }
            .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
            .disabled(!model.canPerform(action))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var closingApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard approveClosing() else { return false }
        closingApproved = true
        // 设置窗口可能仍然打开，不能依赖“最后一个窗口关闭”来触发 SSH 清理。
        NSApp.terminate(sender)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveWork else { return .terminateNow }
        guard closingApproved || approveClosing() else { return .terminateCancel }
        model.onAllSessionsEnded = { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        model.disconnectAll()
        return .terminateLater
    }

    private func approveClosing() -> Bool {
        guard let model, model.hasActiveWork else { return true }
        return AppModel.confirm(title: "退出 Nc2Shell？", detail: "所有 SSH 会话将断开，前台运行的远程任务可能中断。应用会等待传输停止并保存断点后退出。", action: "断开并退出")
    }
}

private struct WindowAttachment: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.owner = delegate
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        weak var owner: AppDelegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.delegate = owner
        }
    }
}
