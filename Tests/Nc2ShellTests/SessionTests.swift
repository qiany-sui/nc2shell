import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class SessionTests: XCTestCase {
    @MainActor
    func testSessionsUseIsolatedBookmarks() throws {
        let profile = ConnectionProfile(name: "隔离收藏", host: "example.test")
        let first = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks())
        let second = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks())
        XCTAssertNil(first.directoryBookmarks.readError)
        XCTAssertNil(second.directoryBookmarks.readError)
        XCTAssertFalse(first.directoryBookmarks === second.directoryBookmarks)
        // 隔离失效时不能继续向共享存储写测试数据。
        guard first.directoryBookmarks !== second.directoryBookmarks,
              first.directoryBookmarks.readError == nil, second.directoryBookmarks.readError == nil else { return }
        XCTAssertTrue(first.directoryBookmarks.bookmarks.isEmpty)
        XCTAssertTrue(second.directoryBookmarks.bookmarks.isEmpty)
        try first.directoryBookmarks.toggle("/isolated-first", profile: profile)
        XCTAssertEqual(first.directoryBookmarks.paths(for: profile), ["/isolated-first"])
        XCTAssertEqual(second.directoryBookmarks.paths(for: profile), [])
        try second.directoryBookmarks.toggle("/isolated-second", profile: profile)
        XCTAssertEqual(first.directoryBookmarks.paths(for: profile), ["/isolated-first"])
        XCTAssertEqual(second.directoryBookmarks.paths(for: profile), ["/isolated-second"])
        let next = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks())
        XCTAssertNil(next.directoryBookmarks.readError)
        XCTAssertTrue(next.directoryBookmarks.bookmarks.isEmpty, "新会话不能读到前面测试会话落盘的收藏")
    }

    @MainActor
    func testWorkspaceActionsUseActiveSavedProfileDespiteSidebarSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var current = ConnectionProfile(name: "current", host: "current.test", identityFile: "/nonexistent/nc2shell-ui-key")
        let other = ConnectionProfile(name: "other", host: "other.test", identityFile: "/nonexistent/nc2shell-ui-key")
        model.save(current); model.save(other)
        _ = model.connect(current)
        model.selectedProfileID = other.id
        XCTAssertEqual(model.workspaceProfile?.id, current.id)
        current.name = "updated"
        model.save(current)
        model.selectedProfileID = other.id
        XCTAssertEqual(model.workspaceProfile?.name, "updated", "编辑应使用最新保存配置而非会话旧快照")
        model.deleteConfirmed(current)
        XCTAssertNil(model.workspaceProfile, "已删除的当前连接不能回退到另一台服务器或被编辑入口重新保存")
        model.closeWorkspace(try XCTUnwrap(model.selectedWorkspace))
        model.selectedProfileID = other.id
        XCTAssertEqual(model.workspaceProfile?.id, other.id, "没有会话时使用左侧所选配置")
    }

    @MainActor
    func testDuplicateTabTitlesRemainDistinctAfterClosingAndSplitting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let profile = ConnectionProfile(name: "same", host: "unused.test", identityFile: "/nonexistent/nc2shell-ui-key")
        _ = model.connect(profile); _ = model.connect(profile); _ = model.connect(profile)
        XCTAssertEqual(model.workspaces.map { model.workspaceTitle($0) }, ["same · 1", "same · 2", "same · 3"])
        model.closeWorkspace(model.workspaces[0])
        XCTAssertEqual(model.workspaces.map { model.workspaceTitle($0) }, ["same · 2", "same · 3"])
        _ = model.split(.columns)
        XCTAssertEqual(model.workspaces.map { model.workspaceTitle($0) }, ["same · 2", "same · 3"], "分屏不创建新标签编号")
        model.selectWorkspace(model.workspaces[0].id)
        XCTAssertEqual(model.workspaceTitle(try XCTUnwrap(model.selectedWorkspace)), "same · 2")
    }

    @MainActor
    func testTemporaryFollowSuspensionDoesNotOverrideManualPause() async {
        let files = RemoteFilesModel()
        files.connect(profile: .init(name: "Test", host: "alias"), controlPath: "/tmp/no-nc2-socket", initialDirectory: "/first")
        files.suspendFollowing(reason: "身份未知")
        files.follow("/must-not-follow")
        XCTAssertTrue(files.following)
        XCTAssertEqual(files.reportedPath, "/first")
        XCTAssertEqual(files.followSuspension, "身份未知")
        files.setFollowing(false)
        files.resumeFollowing(path: "/verified")
        XCTAssertFalse(files.following)
        XCTAssertNil(files.followSuspension)
        XCTAssertEqual(files.reportedPath, "/verified")
        files.disconnect()
        XCTAssertNil(files.followSuspension)
    }

    @MainActor
    func testShellContextIsCapturedWithoutReplacingDisplayedDirectory() async {
        let session = TerminalSession(profile: ConnectionProfile(name: "Test", host: "alias"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.terminal.feed(text: "\u{1b}]7;file://actual-host/home/nc\u{7}")
        session.terminal.feed(text: "\u{1b}]7;file://context-\(session.directoryToken)/123/501/dev/ttys001\u{7}")
        XCTAssertEqual(session.shellContext?.pid, 123)
        XCTAssertEqual(session.remoteDirectory?.path, "/home/nc")
        session.terminal.feed(text: "\u{1b}]7;file://context-\(session.directoryToken)/124/0/dev/ttys002\u{7}")
        XCTAssertEqual(session.shellContext?.pid, 123, "同连接不能被后来的Shell重新定义原身份")
        XCTAssertEqual(session.shellContext?.uid, 501)
    }

    @MainActor
    func testFilePanelDefaultsToFollowingAndPreservesEarlyDirectoryReport() async {
        let files = RemoteFilesModel()
        files.connect(profile: .init(name: "Test", host: "alias"), controlPath: "/tmp/nc2-no-socket", initialDirectory: "/first/prompt")
        XCTAssertTrue(files.following)
        XCTAssertEqual(files.reportedPath, "/first/prompt")
        files.setFollowing(false)
        files.follow("/next/prompt")
        XCTAssertFalse(files.following)
        XCTAssertEqual(files.reportedPath, "/next/prompt")
        files.disconnect()
    }

    @MainActor
    func testMissingPrivateKeyFailsBeforeLaunchingSSH() async {
        let session = TerminalSession(profile: ConnectionProfile(name: "Test", host: "127.0.0.1", identityFile: "/nonexistent/nc2shell-key"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.start()
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.statusText.contains("私钥"))
    }

    @MainActor
    func testDirectoryDisplayPreservesReportingHostAndClearsInvalidReport() async {
        let session = TerminalSession(profile: ConnectionProfile(name: "Test", host: "alias"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.terminal.feed(text: "\u{1b}]7;file://actual-host/home/nc/My%20Files\u{7}")
        XCTAssertEqual(session.remoteDirectory, RemoteDirectory(host: "actual-host", path: "/home/nc/My Files"))
        session.terminal.feed(text: "\u{1b}]7;not-a-directory\u{7}")
        XCTAssertNil(session.remoteDirectory)
    }

    @MainActor
    func testRemoteTerminalCannotReadLocalClipboard() async {
        let session = TerminalSession(profile: ConnectionProfile(name: "Test", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        XCTAssertNil(session.terminal.terminalDelegate?.clipboardRead(source: session.terminal))
    }

    @MainActor
    func testRefusedConnectionTransitionsToFailedAndCanRestart() async throws {
        let session = TerminalSession(profile: ConnectionProfile(name: "Test", host: "127.0.0.1", port: 1), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.start()
        try await waitUntil { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        session.start()
        try await waitUntil { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("等待会话状态超时")
    }
}
