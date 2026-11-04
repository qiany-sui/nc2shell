import Combine
import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferPresentationIntegrationTests: XCTestCase {
    @MainActor
    func testNestedQueueChangesUpdateGroupsAndClearingSuccessKeepsFailures() async throws {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json"))) { profile in
            TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, socket in
                ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: socket))
            }
        }
        let presentation = TransferQueuePresentation(model: app)
        let session = app.connect(.init(name: "UI", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key))
        defer { session.disconnect() }
        let files = session.files
        try await eventually { files.canTransfer }
        files.browse(root.appendingPathComponent("remote").path)
        try await eventually { files.canTransfer && files.path == root.appendingPathComponent("remote").path }
        let source = root.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        files.upload([source], expectedPath: files.path, connectionID: files.connectionID, revision: files.locationRevision)
        let item = try XCTUnwrap(files.transferItems.first)
        var notifications = 0
        let observer = presentation.objectWillChange.sink { notifications += 1 }
        defer { observer.cancel() }
        files.pauseTransfer(item.id)
        XCTAssertEqual(presentation.active.map(\.id), [item.id])
        XCTAssertGreaterThan(notifications, 0, "内部任务状态变化必须驱动面板刷新")
        files.cancelQueuedTransfer(item.id)
        try await eventually { item.state.isFinished && files.canTransfer }
        XCTAssertTrue(presentation.active.isEmpty)
        XCTAssertEqual(presentation.attention.map(\.id), [item.id])
        files.upload([source], expectedPath: files.path, connectionID: files.connectionID, revision: files.locationRevision)
        try await eventually { files.canTransfer }
        XCTAssertEqual(presentation.completed.count, 1)
        files.upload([root.appendingPathComponent("missing")], expectedPath: files.path, connectionID: files.connectionID, revision: files.locationRevision)
        try await eventually { files.canTransfer }
        XCTAssertEqual(presentation.attention.count, 2)
        files.clearCompletedTransfers()
        XCTAssertTrue(presentation.completed.isEmpty)
        XCTAssertEqual(presentation.attention.count, 2)
        session.disconnect()
        try await eventually { !session.isRunning }
        app.closeWorkspace(try XCTUnwrap(app.selectedWorkspace))
        XCTAssertTrue(presentation.entries.isEmpty)
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待传输状态超时")
    }
}
