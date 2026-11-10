import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class NavigationIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, RemoteFilesModel, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("navigation-\(UUID())")
        for name in ["a", "b", "c", "d"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let profile = ConnectionProfile(name: "导航验收", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start()
        try await eventually { session.state == .connected }
        let model = RemoteFilesModel()
        model.connect(profile: profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("a").path)
        try await eventually { model.canTransfer }
        return (session, model, root)
    }

    @MainActor
    func testHistoryTracksFollowAndManualNavigationWithoutRefreshDuplicates() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a").path, b = root.appendingPathComponent("b").path
        XCTAssertFalse(model.canGoBack)
        model.follow(b)
        try await eventually { model.locationValidated && model.path == b }
        XCTAssertTrue(model.canGoBack)
        model.refresh()
        try await eventually { model.canTransfer }
        model.goBack()
        try await eventually { model.locationValidated && model.path == a }
        XCTAssertFalse(model.following)
        XCTAssertFalse(model.canGoBack, "刷新不能多出重复的历史项")
        XCTAssertTrue(model.canGoForward)
        model.goForward()
        try await eventually { model.locationValidated && model.path == b }
        model.goBack()
        try await eventually { model.locationValidated && model.path == a }
        let d = root.appendingPathComponent("d").path
        model.browse(d)
        try await eventually { model.locationValidated && model.path == d }
        XCTAssertFalse(model.canGoForward, "从历史节点打开新路径应丢弃旧前进分支")
    }

    @MainActor
    func testFailedHistoryNavigationDoesNotCommitAndReconnectClearsHistory() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), moved = root.appendingPathComponent("moved")
        let b = root.appendingPathComponent("b").path
        model.browse(b)
        try await eventually { model.locationValidated && model.path == b }
        try FileManager.default.moveItem(at: a, to: moved)
        model.goBack()
        try await eventually { !model.isLoading && model.error != nil }
        XCTAssertEqual(model.path, b)
        XCTAssertTrue(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
        try FileManager.default.moveItem(at: moved, to: a)
        model.goBack()
        try await eventually { model.locationValidated && model.path == a.path }
        XCTAssertTrue(model.canGoForward)
        model.disconnect()
        XCTAssertFalse(model.canGoBack); XCTAssertFalse(model.canGoForward)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("c").path)
        try await eventually { model.canTransfer }
        XCTAssertFalse(model.canGoBack); XCTAssertFalse(model.canGoForward)
    }

    @MainActor
    func testSupersededRequestDoesNotPolluteHistory() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        model.browse(root.appendingPathComponent("b").path)
        model.browse(root.appendingPathComponent("c").path)
        try await eventually { model.locationValidated && model.path == root.appendingPathComponent("c").path }
        model.goBack()
        try await eventually { model.locationValidated && model.path == root.appendingPathComponent("a").path }
        XCTAssertFalse(model.canGoBack)
    }

    @MainActor
    func testRepeatedLogicalDirectoryReportsKeepSelectionValid() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("b"), alias = root.appendingPathComponent("alias")
        try Data("fixture".utf8).write(to: target.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        model.follow(alias.path)
        try await eventually { model.canTransfer && model.path == target.path }
        let revision = model.locationRevision, connection = model.connectionID
        let files = model.files
        for _ in 0..<3 { model.follow(alias.path) }
        XCTAssertFalse(model.isLoading, "相同逻辑目录不能重复清空已验证的列表")
        XCTAssertEqual(model.files, files)
        XCTAssertEqual(model.locationRevision, revision)
        let source = root.appendingPathComponent("confirmed-upload.txt")
        try Data("fixture".utf8).write(to: source)
        model.upload([source], expectedPath: target.path, connectionID: connection, revision: revision)
        XCTAssertEqual(model.transferItems.count, 1, "重复目录报告不应使已捕获的上传确认失效")
        if let item = model.transferItems.first {
            try await eventually { item.state.isFinished }
            XCTAssertEqual(item.state, .completed)
        }

        model.refresh()
        XCTAssertNotEqual(model.locationRevision, revision, "显式刷新仍须使旧确认失效")
        try await eventually { model.canTransfer }
        model.browse(root.appendingPathComponent("c").path)
        try await eventually { model.canTransfer && model.path.hasSuffix("/c") }
        model.setFollowing(true)
        try await eventually { model.canTransfer && model.path == target.path }
        let resumedRevision = model.locationRevision
        model.follow(alias.path)
        XCTAssertEqual(model.locationRevision, resumedRevision)
    }

    @MainActor
    func testFailedLogicalDirectoryCanBeRetriedAndReconnectRevalidatesIt() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("b"), alias = root.appendingPathComponent("later-alias")
        model.follow(alias.path)
        try await eventually { !model.isLoading && model.error != nil }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        model.follow(alias.path)
        try await eventually { model.canTransfer && model.path == target.path }
        model.disconnect()
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: alias.path)
        try await eventually { model.canTransfer && model.path == target.path }
        let revision = model.locationRevision
        model.follow(alias.path)
        XCTAssertEqual(model.locationRevision, revision, "初始目录也应保留已验证的逻辑路径")
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError("等待导航结果超时")
    }
}
