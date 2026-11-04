import XCTest
import Combine
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class AppRecoveryTests: XCTestCase {
    @MainActor
    func testSessionEndWaitsForAllRecoveryWritersAndNotifiesOnlyOnce() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-exit-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), recovery: manager,
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let profile = ConnectionProfile(name: "隔离服务器", host: "example.test", username: "nc")
        let first = try manager.register(.init(account: .init(profile: profile), name: "writer 1", direction: .upload,
                                               roots: [.init(localPath: "/local/a", remotePath: "/remote/a")]))
        let second = try manager.register(.init(account: .init(profile: profile), name: "writer 2", direction: .upload,
                                                roots: [.init(localPath: "/local/b", remotePath: "/remote/b")]))
        let session = model.connect(profile)
        XCTAssertFalse(model.hasRunningSessions)
        var callbacks = 0
        model.onAllSessionsEnded = {
            callbacks += 1
            XCTAssertTrue(manager.activeIDs.isEmpty, "退出回复必须等检查点写入完成并释放占用")
        }
        session.onEnded?()
        XCTAssertEqual(callbacks, 0)
        manager.finish(first, completed: false)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 0, "仍有一个 writer 时不能退出")
        manager.finish(second, completed: false)
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(model.onAllSessionsEnded)
        manager.refresh()
        session.onEnded?()
        session.onEnded?()
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1, "重复发布与迟到进程通知不能重复回复退出请求")
        XCTAssertEqual(try manager.store.load().count, 2, "正常退出保留未完成任务的恢复记录")
    }

    @MainActor
    func testRecoveryWriterCompletionWithoutAnySessionReleasesExitWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-exit-no-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), recovery: manager,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let profile = ConnectionProfile(name: "隔离服务器", host: "example.test")
        let ticket = try manager.register(.init(account: .init(profile: profile), name: "writer", direction: .download,
                                                roots: [.init(localPath: "/local/a", remotePath: "/remote/a")]))
        var callbacks = 0
        model.onAllSessionsEnded = { callbacks += 1 }
        model.disconnectAll()
        XCTAssertEqual(callbacks, 0)
        manager.finish(ticket, completed: false)
        XCTAssertEqual(callbacks, 0, "Published 的 willChange 发生时状态尚未提交")
        await drainMainQueue()
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(model.onAllSessionsEnded)
    }

    @MainActor
    func testWorkAlreadyEndedWhileQuitConfirmationWasOpenStillCompletesOnce() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-exit-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var callbacks = 0
        model.onAllSessionsEnded = { callbacks += 1 }
        model.disconnectAll()
        model.disconnectAll()
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(model.onAllSessionsEnded)
    }

    @MainActor
    func testRecoveryChangesReachAppObserversWithoutAnySession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-app-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), recovery: manager,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var notifications = 0
        let observer = model.objectWillChange.sink { notifications += 1 }
        let profile = ConnectionProfile(name: "隔离服务器", host: "example.test", username: "nc")
        let record = RecoverableTransfer(account: .init(profile: profile), name: "恢复文件", direction: .upload,
                                         roots: [.init(localPath: "/local/file", remotePath: "/remote/file")])
        try manager.store.save(record)
        manager.refresh()
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(model.recovery?.pendingRecords, [record])
        notifications = 0
        try manager.removeRecord(record.id)
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(model.recovery?.pendingRecords, [])
        withExtendedLifetime(observer) {}
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
