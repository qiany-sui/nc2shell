import AppKit
import SwiftUI
import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class WorkspaceUIIntegrationTests: XCTestCase {
    @MainActor
    func testSplitRatioChangesGeometryAndKeepsTerminalsAcrossDirections() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("布局测试不连接网络") } })
        let first = model.connect(.init(name: "布局", host: "example.test"))
        let second = try XCTUnwrap(model.split()), workspaceID = try XCTUnwrap(model.selectedWorkspace?.id)
        let terminals = [first.terminal, second.terminal]
        let visibility = FileVisibility(); visibility.files = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceHarness(model: model, visibility: visibility))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        model.focus(second.id)
        model.resizeSplit(workspaceID, fraction: 0.3)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(first.terminal.frame.height, second.terminal.frame.height * 0.65)
        _ = model.split(.columns)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(first.terminal.frame.width, second.terminal.frame.width * 0.65)
        XCTAssertTrue(first.terminal === terminals[0] && second.terminal === terminals[1])
        XCTAssertTrue(first.terminal.window === window && second.terminal.window === window)
        XCTAssertTrue(window.firstResponder === second.terminal)
        XCTAssertEqual(model.sessions.count, 2)
    }

    @MainActor
    func testCollapsingFilesReturnsFocusAndPreservesTerminalAndPathDraft() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("需要隔离 SSH 服务")
        }
        _ = NSApplication.shared
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("ui-focus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConnectionStore(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json"))) { profile in
            TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, socket in
                ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: socket))
            }
        }
        let session = model.connect(ConnectionProfile(name: "UI", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key))
        defer { session.disconnect() }
        for _ in 0..<150 {
            if session.files.isConnected && !session.files.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(session.state, .connected)
        let terminal = session.terminal, connection = session.files.connectionID
        let visibility = FileVisibility()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceHarness(model: model, visibility: visibility))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<50 {
            if window.firstResponder === terminal && fields(host).contains(where: { $0.placeholderString == "远程路径" }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 等首次布局的焦点同步结束，再模拟用户开始编辑。
        try await Task.sleep(nanoseconds: 150_000_000)
        let path = try XCTUnwrap(fields(host).first { $0.placeholderString == "远程路径" })
        XCTAssertTrue(window.makeFirstResponder(path))
        try await Task.sleep(nanoseconds: 100_000_000)
        let editor = try XCTUnwrap(path.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("/unsubmitted-path-draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(window.firstResponder === terminal)
        visibility.files = false
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(window.firstResponder === terminal, "收起后键盘必须回到终端，不能继续操作隐藏路径")
        visibility.files = true
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertEqual(session.files.connectionID, connection)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(path.stringValue, "/unsubmitted-path-draft", "收起保留尚未提交的路径，且不会导航")
        XCTAssertNotEqual(session.files.path, "/unsubmitted-path-draft")

        // Escape 应取消路径草稿，不能把未提交的文本继续显示成当前目录。
        let currentPath = session.files.path
        XCTAssertTrue(window.makeFirstResponder(path))
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try XCTUnwrap(path.currentEditor())
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(path.stringValue, currentPath)
        XCTAssertNil(path.currentEditor(), "取消后退出路径编辑")
        XCTAssertTrue(window.firstResponder === terminal, "取消路径编辑后应能直接继续操作当前终端")
        XCTAssertEqual(session.files.path, currentPath, "取消草稿不得触发导航")
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertEqual(session.files.connectionID, connection)
    }

    @MainActor
    func testFirstFindFromAnotherFieldTakesInputAndEscapeReturnsToTerminal() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let session = model.connect(ConnectionProfile(name: "UI", host: "unused.test", identityFile: "/nonexistent/nc2shell-ui-key"))
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        let other = try XCTUnwrap(fields(host).first { $0.placeholderString == "搜索连接" })
        for _ in 0..<2 {
            XCTAssertTrue(window.makeFirstResponder(other))
            try await Task.sleep(nanoseconds: 50_000_000)
            session.showFind()
            try await Task.sleep(nanoseconds: 150_000_000)
            let find = try XCTUnwrap(fields(host).first { $0.placeholderString == "搜索输出" })
            let editor = try XCTUnwrap(find.currentEditor() as? NSTextView, "首次打开查找必须从其他输入框接管焦点")
            editor.selectAll(nil)
            editor.insertText("find-only", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(session.searchText, "find-only")
            XCTAssertEqual(other.stringValue, "")
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.sendEvent(escape)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(session.searchVisible)
            XCTAssertTrue(window.firstResponder === session.terminal)
        }
    }

    @MainActor private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
}

@MainActor private final class FileVisibility: ObservableObject {
    @Published var files = true
}

private struct WorkspaceHarness: View {
    @ObservedObject var model: AppModel
    @ObservedObject var visibility: FileVisibility
    var body: some View {
        if let workspace = model.selectedWorkspace {
            TerminalWorkspaceView(model: model, workspace: workspace, showFiles: $visibility.files, showTransfers: {})
        }
    }
}
