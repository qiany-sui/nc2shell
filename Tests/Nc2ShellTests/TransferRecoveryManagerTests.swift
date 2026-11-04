import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferRecoveryManagerTests: XCTestCase {
    @MainActor
    func testAbandonedTaskCannotBeAcquiredForResume() throws {
        let (root, store, profile, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(record)
        try store.markCleanupStarted(record.id)
        let manager = TransferRecoveryManager(store: store)
        XCTAssertThrowsError(try manager.acquire(record.id, profile: profile))
        XCTAssertTrue(manager.activeIDs.isEmpty)
    }

    private func fixture() throws -> (URL, TransferRecoveryStore, ConnectionProfile, RecoverableTransfer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-recovery-manager-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = ConnectionProfile(name: "恢复测试", host: "example.test", username: "nc")
        let record = RecoverableTransfer(account: TransferRecoveryAccount(profile: profile), name: "资料", direction: .upload,
                                        roots: [.init(localPath: root.appendingPathComponent("资料").path, remotePath: "/srv/资料")])
        return (root, TransferRecoveryStore(directoryURL: root.appendingPathComponent("records")), profile, record)
    }

    @MainActor
    func testInterruptedRecordReloadsWithoutAutomaticallyClaimingOrExecuting() throws {
        let (root, store, profile, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TransferRecoveryManager(store: store)
        let ticket = try first.register(record)
        XCTAssertEqual(first.activeIDs, [record.id])
        XCTAssertTrue(first.pendingRecords.isEmpty)
        first.finish(ticket, completed: false)
        let relaunched = TransferRecoveryManager(store: store)
        XCTAssertEqual(relaunched.pendingRecords, [record])
        XCTAssertTrue(relaunched.activeIDs.isEmpty)
        let resumed = try relaunched.acquire(record.id, profile: profile)
        relaunched.finish(resumed, completed: true)
        XCTAssertTrue(try store.load().isEmpty)
    }

    @MainActor
    func testAccountAndLeasePreventDuplicateOrStaleRecovery() throws {
        let (root, store, profile, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TransferRecoveryManager(store: store)
        let first = try manager.register(record)
        XCTAssertThrowsError(try manager.acquire(record.id, profile: profile))
        XCTAssertThrowsError(try manager.removeRecord(record.id))
        manager.finish(first, completed: false)
        var other = profile; other.username = "different"
        XCTAssertThrowsError(try manager.acquire(record.id, profile: other))
        let second = try manager.acquire(record.id, profile: profile)
        manager.finish(first, completed: true)
        XCTAssertEqual(manager.activeIDs, [record.id], "旧回调不能释放新任务的占用或删除记录")
        XCTAssertEqual(try store.load(), [record])
        manager.finish(second, completed: true)
        XCTAssertTrue(manager.records.isEmpty)
    }

    @MainActor
    func testCorruptRecordIsVisibleAsErrorAndCannotBeClaimedOrOverwritten() throws {
        let (root, store, profile, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(record)
        let url = store.directoryURL.appendingPathComponent(record.id.uuidString).appendingPathComponent("task.json")
        try Data("broken".utf8).write(to: url)
        let manager = TransferRecoveryManager(store: store)
        XCTAssertNotNil(manager.error)
        XCTAssertThrowsError(try manager.acquire(record.id, profile: profile))
        XCTAssertThrowsError(try manager.register(record))
        XCTAssertEqual(try String(contentsOf: url), "broken")
        XCTAssertTrue(manager.activeIDs.isEmpty)
    }

    @MainActor
    func testRemoveRecoveryDescriptionKeepsUserFilesAndCheckpoint() throws {
        let (root, store, _, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TransferRecoveryManager(store: store)
        let ticket = try manager.register(record)
        manager.finish(ticket, completed: false)
        let source = URL(fileURLWithPath: record.roots[0].localPath)
        try Data("source".utf8).write(to: source)
        let checkpoint = store.checkpointURL(for: record.id)
        try Data("checkpoint".utf8).write(to: checkpoint)
        try manager.removeRecord(record.id)
        XCTAssertTrue(manager.pendingRecords.isEmpty)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: checkpoint), "checkpoint")
    }
}
