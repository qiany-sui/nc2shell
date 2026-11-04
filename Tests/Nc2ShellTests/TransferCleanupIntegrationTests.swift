import XCTest
import CryptoKit
@testable import Nc2ShellCore
@testable import Nc2Shell

@MainActor
final class TransferCleanupIntegrationTests: XCTestCase {
    func testControllerHoldsLeaseAndExclusiveReservationThroughPreviewAndCancel() async throws {
        let f = try await interrupted(); defer { f.close() }
        let store = TransferRecoveryStore(directoryURL: f.root.appendingPathComponent("records"))
        let fresh = RecoverableTransfer(account: f.task.account, name: "未开始任务", direction: .upload, roots: f.task.roots)
        try store.save(fresh)
        let manager = TransferRecoveryManager(store: store)
        let reservations = TransferPathReservations()
        let controller = TransferCleanupController(reservations: reservations)
        controller.connect(profile: f.session.profile, makeClient: { try f.client() })
        controller.prepare(fresh.id, manager: manager)
        XCTAssertFalse(reservations.isIdle); XCTAssertTrue(manager.activeIDs.contains(fresh.id))
        for _ in 0..<200 { if controller.phase == .ready { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertThrowsError(try manager.acquire(fresh.id, profile: f.session.profile))
        XCTAssertFalse(reservations.acquireExclusive(id: UUID()))
        controller.cancel()
        XCTAssertTrue(reservations.isIdle); XCTAssertTrue(manager.activeIDs.isEmpty)
        XCTAssertNil(try store.load().first { $0.id == fresh.id }?.cleanupStartedAt)
        controller.prepare(fresh.id, manager: manager)
        controller.disconnect()
        XCTAssertFalse(reservations.isIdle, "在异步检查返回前不能提前释放")
        for _ in 0..<200 { if reservations.isIdle { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(reservations.isIdle); XCTAssertTrue(manager.activeIDs.isEmpty)
    }

    func testControllerConfirmsAbandonAndRemovesOnlyCompletedCleanupMetadata() async throws {
        let f = try await interrupted(); defer { f.close() }
        let store = TransferRecoveryStore(directoryURL: f.root.appendingPathComponent("records"))
        // 这里验证从未开始的任务，实际半成品删除由同类其余测试覆盖。
        try store.save(f.task)
        let manager = TransferRecoveryManager(store: store)
        let reservations = TransferPathReservations()
        let controller = TransferCleanupController(reservations: reservations)
        controller.connect(profile: f.session.profile, makeClient: { try f.client() })
        controller.prepare(f.task.id, manager: manager)
        for _ in 0..<200 { if controller.phase == .ready { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        controller.confirm()
        XCTAssertNotNil(try store.load().first?.cleanupStartedAt)
        for _ in 0..<200 { if !controller.isWorking { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .done, controller.error ?? "")
        XCTAssertTrue(try store.load().isEmpty); XCTAssertTrue(reservations.isIdle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointURL(for: f.task.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
    }

    @MainActor private struct Fixture {
        let session: TerminalSession
        let root: URL
        let source: URL
        let target: URL
        let task: RecoverableTransfer
        let checkpoint: TransferCheckpoint
        func client() throws -> SFTPClient { try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)) }
        func close() { session.disconnect(); try? FileManager.default.removeItem(at: root) }
    }

    private func interrupted(upload: Bool = true, directory: Bool = false, merge: Bool = false, completedName: String = "完成.txt") async throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let server = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "清理测试", host: "127.0.0.1", port: server.port, username: "key-test", identityFile: server.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(server.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        for _ in 0..<150 {
            if session.state == .connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(session.state, .connected)
        let root = URL(fileURLWithPath: server.directory).appendingPathComponent("cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let data = Data(repeating: 7, count: 150_000)
        if directory {
            try FileManager.default.createDirectory(at: source.appendingPathComponent("a/子目录"), withIntermediateDirectories: true)
            try Data("保留来源".utf8).write(to: source.appendingPathComponent("a/子目录").appendingPathComponent(completedName))
            try data.write(to: source.appendingPathComponent("z.bin"))
            if merge {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("目标独有".utf8).write(to: target.appendingPathComponent("独有.txt"))
            }
        } else { try data.write(to: source) }
        let task = RecoverableTransfer(account: .init(profile: profile), name: "清理测试", direction: upload ? .upload : .download,
                                      roots: [.init(localPath: (upload ? source : target).path, remotePath: (upload ? target : source).path)])
        let checkpoint = try TransferCheckpoint(fileURL: root.appendingPathComponent("checkpoint.json"))
        let fixture = Fixture(session: session, root: root, source: source, target: target, task: task, checkpoint: checkpoint)
        let client = try fixture.client(); defer { client.cancel() }
        do {
            let stop: SFTPClient.Progress = { bytes in if bytes >= 32_768 { client.cancel() } }
            if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in merge ? .merge : .cancel }, checkpoint: checkpoint, progress: stop) }
            else { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in merge ? .merge : .cancel }, checkpoint: checkpoint, progress: stop) }
            XCTFail("应产生真实半成品")
        } catch {}
        return fixture
    }

    func testFilesAndNestedDirectoriesCleanOnlyStagingInBothDirections() async throws {
        for upload in [true, false] {
            for directory in [false, true] {
                let f = try await interrupted(upload: upload, directory: directory); defer { f.close() }
                let client = try f.client(); defer { client.cancel() }
                let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
                XCTAssertFalse(plan.items.isEmpty); XCTAssertGreaterThan(plan.bytes, 0)
                for item in plan.items { XCTAssertTrue(FileManager.default.fileExists(atPath: item.path)) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
                try await client.executeCleanup(task: f.task, checkpoint: f.checkpoint, expectedPlan: plan)
                for item in plan.items { XCTAssertFalse(FileManager.default.fileExists(atPath: item.path)) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
                let restored = try TransferCheckpoint(fileURL: f.checkpoint.fileURL)
                do {
                    if upload { _ = try await client.upload(local: f.source, remote: f.target.path, resolveConflict: { _ in .cancel }, checkpoint: restored) }
                    else { _ = try await client.download(remote: f.source.path, local: f.target, resolveConflict: { _ in .cancel }, checkpoint: restored) }
                    XCTFail("清理后禁止续传")
                } catch { XCTAssertTrue(error.localizedDescription.contains("放弃续传"), error.localizedDescription) }
            }
        }
    }

    func testMergePreservesCompletedChildrenAndTargetOnlyContents() async throws {
        for upload in [true, false] {
            let f = try await interrupted(upload: upload, directory: true, merge: true); defer { f.close() }
            let client = try f.client(); defer { client.cancel() }
            let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
            XCTAssertEqual(plan.items.count, 1)
            try await client.executeCleanup(task: f.task, checkpoint: f.checkpoint, expectedPlan: plan)
            XCTAssertEqual(try String(contentsOf: f.target.appendingPathComponent("独有.txt"), encoding: .utf8), "目标独有")
            XCTAssertEqual(try String(contentsOf: f.target.appendingPathComponent("a/子目录/完成.txt"), encoding: .utf8), "保留来源")
        }
    }

    func testChangedSourceTemporaryBackupAndUnknownInstallingArePreserved() async throws {
        for change in ["source", "temporary", "backup", "installing"] {
            let f = try await interrupted(); defer { f.close() }
            let record = try XCTUnwrap(f.checkpoint.records.first)
            if change == "source" { try Data([99]).write(to: f.source) }
            if change == "temporary" { try Data([99]).write(to: URL(fileURLWithPath: record.temporary)) }
            if change == "backup" { try Data([99]).write(to: URL(fileURLWithPath: record.backup)) }
            if change == "installing" { var changed = record; changed.phase = "installing"; try f.checkpoint.save(changed, key: TransferCheckpoint.key(upload: true, source: record.source, requested: record.requested)) }
            let client = try f.client(); defer { client.cancel() }
            do { _ = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint); XCTFail(change) }
            catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.temporary), change)
        }
    }

    func testPreviewChangeOrLocalHardlinkRefusesDeletion() async throws {
        for hardlink in [false, true] {
            let f = try await interrupted(upload: false); defer { f.close() }
            let client = try f.client(); defer { client.cancel() }
            let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
            let item = try XCTUnwrap(plan.items.first)
            if hardlink { try FileManager.default.linkItem(atPath: item.path, toPath: f.root.appendingPathComponent("other-link").path) }
            else { let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: item.path)); try handle.write(contentsOf: Data([99])); try handle.close() }
            do { try await client.executeCleanup(task: f.task, checkpoint: f.checkpoint, expectedPlan: plan); XCTFail("变化后不能删除") } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
            XCTAssertNil(f.checkpoint.cleanupPlan)
        }
    }

    func testPersistedIntentAllowsMissingMembersAfterCrashButRejectsNewMembers() async throws {
        let f = try await interrupted(upload: false, directory: true); defer { f.close() }
        let client = try f.client(); defer { client.cancel() }
        let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
        try f.checkpoint.markCleanupStarted(plan)
        let file = try XCTUnwrap(plan.items.first { !$0.isDirectory })
        try FileManager.default.removeItem(atPath: file.path)
        let restored = try TransferCheckpoint(fileURL: f.checkpoint.fileURL)
        let remaining = try await client.inspectCleanup(task: f.task, checkpoint: restored)
        XCTAssertEqual(remaining.items.count, plan.items.count - 1)
        let directory = try XCTUnwrap(remaining.items.first { $0.isDirectory })
        let unrelated = URL(fileURLWithPath: directory.path).appendingPathComponent("新增内容")
        try Data([1]).write(to: unrelated)
        do { try await client.executeCleanup(task: f.task, checkpoint: restored, expectedPlan: remaining); XCTFail("新增内容保留") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        try FileManager.default.removeItem(at: unrelated)
        try await client.executeCleanup(task: f.task, checkpoint: restored, expectedPlan: remaining)
        for item in plan.items { XCTAssertFalse(FileManager.default.fileExists(atPath: item.path)) }
    }

    func testNewBackupAfterPersistedIntentStopsCleanup() async throws {
        let f = try await interrupted(); defer { f.close() }
        let client = try f.client(); defer { client.cancel() }
        let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
        try f.checkpoint.markCleanupStarted(plan)
        let record = try XCTUnwrap(f.checkpoint.records.first)
        try Data("结果不明".utf8).write(to: URL(fileURLWithPath: record.backup))
        do { _ = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint); XCTFail("新备份说明状态变化，必须停止") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.temporary))
    }

    func testActualRemovalWithLostReplyCanContinueAfterCancelOrDisconnect() async throws {
        for disconnect in [false, true] {
            let f = try await interrupted(directory: true, completedName: "nc2-delay-delete.txt"); defer { f.close() }
            let client = try f.client(); defer { client.cancel() }
            let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
            let delayed = try XCTUnwrap(plan.items.first { $0.path.hasSuffix("/nc2-delay-delete.txt") })
            let work = Task { try await client.executeCleanup(task: f.task, checkpoint: f.checkpoint, expectedPlan: plan) }
            for _ in 0..<1000 {
                if !FileManager.default.fileExists(atPath: delayed.path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: delayed.path))
            if disconnect { f.session.disconnect() } else { client.cancel() }
            do { try await work.value; XCTFail("回复丢失不能报完成") } catch {}
            if disconnect {
                for _ in 0..<200 { if !f.session.isRunning { break }; try await Task.sleep(nanoseconds: 20_000_000) }
                f.session.start()
                for _ in 0..<200 { if f.session.state == .connected { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            }
            let resumed = try f.client(); defer { resumed.cancel() }
            let restored = try TransferCheckpoint(fileURL: f.checkpoint.fileURL)
            let remaining = try await resumed.inspectCleanup(task: f.task, checkpoint: restored)
            XCTAssertLessThan(remaining.items.count, plan.items.count)
            try await resumed.executeCleanup(task: f.task, checkpoint: restored, expectedPlan: remaining)
            for item in plan.items { XCTAssertFalse(FileManager.default.fileExists(atPath: item.path)) }
            XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a/子目录/nc2-delay-delete.txt")), "保留来源")
        }
    }

    func testChangingOnlyPersistedManifestCannotAuthorizeReplacementContentOrIdentity() async throws {
        for mode in ["downloadIdentity", "uploadContent", "completedChild"] {
            let upload = mode != "downloadIdentity"
            let f = try await interrupted(upload: upload, directory: mode == "completedChild"); defer { f.close() }
            let client = try f.client(); defer { client.cancel() }
            let plan = try await client.inspectCleanup(task: f.task, checkpoint: f.checkpoint)
            try f.checkpoint.markCleanupStarted(plan)
            let selected = try XCTUnwrap(plan.items.first { !$0.isDirectory && (mode != "completedChild" || $0.path.hasSuffix("/完成.txt")) })
            let path = URL(fileURLWithPath: selected.path)
            let old = try Data(contentsOf: path)
            if mode == "downloadIdentity" {
                try FileManager.default.moveItem(at: path, to: f.root.appendingPathComponent("old-inode"))
                try old.write(to: path)
            } else { try Data(repeating: 99, count: old.count).write(to: path) }
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            var snapshot = selected.snapshot
            let modified = try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970
            snapshot.modified = upload ? floor(modified) : modified
            snapshot.inode = upload ? nil : (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            snapshot.digest = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
            if !upload { XCTAssertNotEqual(snapshot.inode, selected.snapshot.inode) }
            let changed = TransferCleanupPlan(taskID: plan.taskID, items: plan.items.map { item in
                item.path == path.path ? .init(path: item.path, remote: item.remote, snapshot: snapshot, localDevice: item.localDevice) : item
            })
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.checkpoint.fileURL)) as? [String: Any])
            json["cleanupPlan"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed))
            try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: f.checkpoint.fileURL)
            let restored = try TransferCheckpoint(fileURL: f.checkpoint.fileURL)
            do {
                let accepted = try await client.inspectCleanup(task: f.task, checkpoint: restored)
                try await client.executeCleanup(task: f.task, checkpoint: restored, expectedPlan: accepted)
                XCTFail("仅改manifest不能松绑原Record证据：\(mode)")
            } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), mode)
        }
    }
}
