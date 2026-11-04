import XCTest
import Darwin
@testable import Nc2ShellCore
@testable import Nc2Shell

final class TransferMetadataIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "传输属性测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start(); try await wait { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath)), root)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("等待属性测试条件超时"); throw SFTPError.message("测试超时")
    }

    private func write(_ root: URL, _ name: String, _ data: Data = Data([1, 2, 3])) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func attributes(_ url: URL, mode: mode_t, time: Int) throws {
        XCTAssertEqual(chmod(url.path, mode), 0)
        var times = [timeval(tv_sec: 1_500_000_000, tv_usec: 0), timeval(tv_sec: time, tv_usec: 0)]
        XCTAssertEqual(utimes(url.path, &times), 0)
    }

    private func stat(_ url: URL) throws -> Darwin.stat {
        var result = Darwin.stat()
        guard lstat(url.path, &result) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return result
    }

    private func checkpoint(_ root: URL, _ name: String = "checkpoint.json",
                            options: TransferAttributeOptions = .init(preservePermissions: true, preserveModificationTime: true)) throws -> TransferCheckpoint {
        try TransferCheckpoint(fileURL: root.appendingPathComponent(name), attributes: options)
    }

    @MainActor
    func testBothDirectionsPreserveNestedAttributesAfterContentAndStripSpecialBits() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "source/子目录/中文.txt")
        let source = root.appendingPathComponent("source")
        try attributes(file, mode: 0o4751, time: 1_700_000_123)
        try attributes(file.deletingLastPathComponent(), mode: 0o750, time: 1_700_000_124)
        try attributes(source, mode: 0o1755, time: 1_700_000_125)
        for upload in [true, false] {
            let destination = root.appendingPathComponent(upload ? "upload" : "download")
            let cp = try checkpoint(root, upload ? "up.json" : "down.json")
            if upload { _ = try await client.upload(local: source, remote: destination.path, resolveConflict: { _ in .cancel }, checkpoint: cp) }
            else { _ = try await client.download(remote: source.path, local: destination, resolveConflict: { _ in .cancel }, checkpoint: cp) }
            for (path, mode, time) in [("", 0o755, 1_700_000_125), ("子目录", 0o750, 1_700_000_124), ("子目录/中文.txt", 0o751, 1_700_000_123)] {
                let actual = try stat(destination.appendingPathComponent(path))
                XCTAssertEqual(Int(actual.st_mode & 0o7777), mode)
                XCTAssertEqual(actual.st_mtimespec.tv_sec, time)
            }
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("子目录/中文.txt")), Data([1, 2, 3]))
            XCTAssertEqual(try stat(file).st_mode & 0o7777, 0o4751)
        }
    }

    @MainActor
    func testSelectedAttributesAreIndependentAndCompletedRootCanBeReused() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.txt")
        try attributes(source, mode: 0o751, time: 1_700_000_123)
        for permissions in [true, false] {
            let destination = root.appendingPathComponent(permissions ? "mode.txt" : "time.txt")
            let options = TransferAttributeOptions(preservePermissions: permissions, preserveModificationTime: !permissions)
            let cp = try checkpoint(root, permissions ? "mode.json" : "time.json", options: options)
            _ = try await client.upload(local: source, remote: destination.path, resolveConflict: { _ in .cancel }, checkpoint: cp)
            let info = try stat(destination)
            XCTAssertEqual(info.st_mode & 0o7777, permissions ? 0o751 : 0o600)
            if permissions { XCTAssertNotEqual(info.st_mtimespec.tv_sec, 1_700_000_123) }
            else { XCTAssertEqual(info.st_mtimespec.tv_sec, 1_700_000_123) }
            let inode = info.st_ino
            let restored = try TransferCheckpoint(fileURL: cp.fileURL, attributes: options)
            let reused = try await client.upload(local: source, remote: destination.path, resolveConflict: { _ in XCTFail("完成项不重问冲突"); return .cancel }, checkpoint: restored)
            XCTAssertEqual(reused.bytes, 3); XCTAssertEqual(try stat(destination).st_ino, inode)
        }
    }

    @MainActor
    func testMergePreservesExistingDirectoryAndSkippedItemAttributes() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/skip").deletingLastPathComponent()
        _ = try write(source, "new")
        let target = try write(root, "target/skip", Data([9])).deletingLastPathComponent()
        try attributes(source, mode: 0o755, time: 123)
        try attributes(source.appendingPathComponent("new"), mode: 0o740, time: 456)
        try attributes(target.appendingPathComponent("skip"), mode: 0o640, time: 1_600_000_000)
        try attributes(target, mode: 0o710, time: 1_600_000_001)
        let result = try await client.upload(local: source, remote: target.path, resolveConflict: { $0.sourceIsDirectory ? .merge : .skip }, checkpoint: checkpoint(root))
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o710)
        XCTAssertNotEqual(try stat(target).st_mtimespec.tv_sec, 123, "合并目录不强制覆盖为源时间")
        XCTAssertEqual(try stat(target.appendingPathComponent("skip")).st_mtimespec.tv_sec, 1_600_000_000)
        XCTAssertEqual(try stat(target.appendingPathComponent("skip")).st_mode & 0o7777, 0o640)
        XCTAssertEqual(try stat(target.appendingPathComponent("new")).st_mtimespec.tv_sec, 456)
        XCTAssertEqual(try stat(target.appendingPathComponent("new")).st_mode & 0o7777, 0o740)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("skip")), Data([9]))
    }

    private func policy(_ root: URL, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(".nc2-metadata.json"), options: .atomic)
    }

    @MainActor
    func testAttributeFailurePreservesInstalledTreeAndRestartOnlyCompletesAttributes() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/a").deletingLastPathComponent()
        _ = try write(source, "b", Data([4, 5]))
        try attributes(source.appendingPathComponent("a"), mode: 0o640, time: 123)
        try attributes(source.appendingPathComponent("b"), mode: 0o750, time: 456)
        let target = root.appendingPathComponent("target")
        let cp = try checkpoint(root)
        try policy(root, ["denyName": "b"])
        do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: cp); XCTFail("属性失败不能成功") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("内容传输阶段已完成")); XCTAssertTrue(error.localizedDescription.contains(target.path))
            XCTAssertTrue(error.localizedDescription.contains(target.appendingPathComponent("b").path), "子项属性失败必须能定位实际目标")
            XCTAssertFalse(error.localizedDescription.contains("\n暂存："), "内容已安装，不能列出已经不存在的暂存/备份路径")
            XCTAssertFalse(error.localizedDescription.contains("\n备份："))
        }
        let first = try stat(target.appendingPathComponent("a")), second = try stat(target.appendingPathComponent("b"))
        XCTAssertEqual(first.st_mode & 0o7777, 0o640); XCTAssertEqual(first.st_mtimespec.tv_sec, 123)
        XCTAssertEqual(second.st_mode & 0o7777, 0o600)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("b")), Data([4, 5]))
        try policy(root, [:])
        let restored = try TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes)
        let result = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in XCTFail("只补属性不重传"); return .cancel }, checkpoint: restored)
        XCTAssertEqual(result.bytes, 5)
        XCTAssertEqual(try stat(target.appendingPathComponent("a")).st_ino, first.st_ino)
        XCTAssertEqual(try stat(target.appendingPathComponent("b")).st_ino, second.st_ino)
        XCTAssertEqual(try stat(target.appendingPathComponent("b")).st_mode & 0o7777, 0o750)
        XCTAssertEqual(try stat(target.appendingPathComponent("b")).st_mtimespec.tv_sec, 456)
        let events = try String(contentsOf: root.appendingPathComponent(".nc2-metadata-events.jsonl")).split(separator: "\n")
        let entries = try events.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(entries.allSatisfy { $0["atimePreserved"] as? Bool == true })
        XCTAssertEqual(entries.filter { $0["path"] as? String == target.appendingPathComponent("a").path }.count, 1)
    }

    @MainActor
    func testPartialAttributeWriteAndLostReplyAreVerifiedBeforeRetry() async throws {
        for failure in ["partialName", "delayName", "ignoreName"] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "source")
            try attributes(source, mode: 0o750, time: 1_700_000_123)
            let target = root.appendingPathComponent("target")
            let cp = try checkpoint(root)
            try policy(root, [failure: "target"])
            let transfer = Task { try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: cp) }
            if failure == "delayName" {
                try await wait { (try? self.stat(target).st_mtimespec.tv_sec) == 1_700_000_123 }
                client.cancel()
            }
            do { _ = try await transfer.value; XCTFail("属性未确认不能成功") }
            catch { XCTAssertTrue(error.localizedDescription.contains("内容传输阶段已完成")) }
            let inode = try stat(target).st_ino
            XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
            try policy(root, [:])
            let replacement = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
            defer { replacement.cancel() }
            _ = try await replacement.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel },
                                             checkpoint: TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes))
            XCTAssertEqual(try stat(target).st_ino, inode)
            XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o750)
            XCTAssertEqual(try stat(target).st_mtimespec.tv_sec, 1_700_000_123)
        }
    }

    @MainActor
    func testChangedCompletedContentAndSourceModeStopAttributeRecovery() async throws {
        for changeSource in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "source")
            try attributes(source, mode: 0o750, time: 123)
            let target = root.appendingPathComponent("target"), cp = try checkpoint(root)
            try policy(root, ["denyName": "target"])
            do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: cp); XCTFail("应失败") } catch {}
            if changeSource { XCTAssertEqual(chmod(source.path, 0o700), 0) }
            else {
                let before = try stat(target)
                try Data([9, 9, 9]).write(to: target)
                try attributes(target, mode: 0o600, time: before.st_mtimespec.tv_sec)
            }
            try policy(root, [:])
            do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes)); XCTFail("变化内容不能补写") } catch {}
            XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o600)
            XCTAssertEqual(try Data(contentsOf: target), changeSource ? Data([1, 2, 3]) : Data([9, 9, 9]))
        }
    }

    @MainActor
    func testUnreadablePreservedPermissionNeverCausesAutomaticPermissionExpansion() async throws {
        for directory in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let content = try write(root, directory ? "source/child" : "source")
            let source = directory ? content.deletingLastPathComponent() : content
            let target = root.appendingPathComponent("target")
            let installedContent = directory ? target.appendingPathComponent("child") : target
            defer { _ = chmod(target.path, directory ? 0o700 : 0o600) }
            // 模拟通过服务器 ACL 仍可读取、普通 rwx 为 000 的来源；不伪装为真实 ACL 验收。
            try policy(root, ["sourceName": "source", "sourceMode": 0])
            let cp = try checkpoint(root)
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: cp)
            XCTAssertEqual(try stat(target).st_mode & 0o7777, 0)
            let checkpointBefore = try Data(contentsOf: cp.fileURL)
            do { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes)); XCTFail("无法读校验必须停止") } catch {}
            XCTAssertEqual(try stat(target).st_mode & 0o7777, 0)
            XCTAssertEqual(try Data(contentsOf: cp.fileURL), checkpointBefore, "无法遍历时不能推进属性状态")
            XCTAssertEqual(chmod(target.path, directory ? 0o700 : 0o600), 0)
            XCTAssertEqual(try Data(contentsOf: installedContent), Data([1, 2, 3]))
        }
    }

    @MainActor
    private func model(_ session: TerminalSession, root: URL) async throws -> (RemoteFilesModel, TransferSettingsController, TransferRecoveryManager) {
        let directory = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = TransferSettingsController(store: .init(fileURL: root.appendingPathComponent("settings.json")))
        XCTAssertTrue(settings.save(.init(attributes: .init(preservePermissions: true, preserveModificationTime: true))))
        let manager = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let model = RemoteFilesModel(conflictPresenter: { _, _, reply in reply(.cancel, false); return {} })
        model.configureTransferSettings(settings); model.configureRecovery(manager, profile: session.profile)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: directory.path)
        try await wait { model.canEnqueue }
        return (model, settings, manager)
    }

    @MainActor
    func testQueuedTaskKeepsCapturedAttributesAfterSettingsChange() async throws {
        let (session, client, root) = try await connected()
        let (model, settings, manager) = try await model(session, root: root)
        defer { model.disconnect(); client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "local/a.txt")
        try attributes(source, mode: 0o750, time: 123)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        let item = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(item.id)
        let record = try XCTUnwrap(manager.store.load().first)
        XCTAssertTrue(record.attributes.preservePermissions); XCTAssertTrue(record.attributes.preserveModificationTime)
        XCTAssertEqual(try TransferCheckpoint(fileURL: manager.store.checkpointURL(for: record.id)).attributes, record.attributes)
        XCTAssertTrue(settings.save(.init()))
        model.resumeTransfer(item.id)
        try await wait { item.state.isFinished && model.canTransfer }
        XCTAssertEqual(item.state, .completed)
        let target = root.appendingPathComponent("remote/a.txt")
        XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o750)
        XCTAssertEqual(try stat(target).st_mtimespec.tv_sec, 123)
    }

    @MainActor
    func testBatchFailureStopsLaterRootsAndNewModelRecoversOriginalOptions() async throws {
        let (session, client, root) = try await connected()
        let (model, settings, manager) = try await model(session, root: root)
        let replacement = RemoteFilesModel(conflictPresenter: { _, _, reply in reply(.cancel, false); return {} })
        defer { replacement.disconnect(); model.disconnect(); client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = try write(root, "local/a"), b = try write(root, "local/b", Data([4]))
        try attributes(a, mode: 0o750, time: 123); try attributes(b, mode: 0o640, time: 456)
        try policy(root, ["denyName": "a"])
        model.upload([a, b], expectedPath: model.path, connectionID: model.connectionID)
        let failed = try XCTUnwrap(model.transferItems.first)
        try await wait { failed.state.isFinished && model.canTransfer }
        XCTAssertEqual(failed.state, .failed)
        guard failed.state == .failed else { return }
        let target = root.appendingPathComponent("remote/a"), second = root.appendingPathComponent("remote/b")
        let inode = try stat(target).st_ino
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        let record = try XCTUnwrap(manager.pendingRecords.first)
        model.disconnect()
        XCTAssertTrue(settings.save(.init()))
        try policy(root, [:])
        let restored = TransferRecoveryManager(store: manager.store)
        replacement.configureTransferSettings(settings); replacement.configureRecovery(restored, profile: session.profile)
        replacement.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await wait { replacement.canEnqueue }
        replacement.recoverTransfer(record.id)
        let retried = try XCTUnwrap(replacement.transferItems.first)
        try await wait { retried.state.isFinished && replacement.canTransfer }
        XCTAssertEqual(retried.state, .completed)
        XCTAssertTrue(restored.pendingRecords.isEmpty)
        XCTAssertEqual(try stat(target).st_ino, inode)
        XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o750)
        XCTAssertEqual(try stat(second).st_mtimespec.tv_sec, 456)
        XCTAssertEqual(try Data(contentsOf: second), Data([4]))
    }

    @MainActor
    func testFinderPromisePreservesAttributesAtSystemDestinationOnce() async throws {
        let (session, client, root) = try await connected()
        let (model, _, _) = try await model(session, root: root)
        defer { model.disconnect(); client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "remote/finder.txt")
        try attributes(source, mode: 0o640, time: 123)
        model.refresh(); try await wait { model.canEnqueue }
        let selected = try XCTUnwrap(model.files.first { $0.name == "finder.txt" })
        let promise = try XCTUnwrap(model.promiseProvider(for: selected) as? RemoteDownloadPromise)
        let target = root.appendingPathComponent("Finder renamed.txt")
        var callbacks = 0
        promise.filePromiseProvider(promise, writePromiseTo: target) { error in XCTAssertNil(error); callbacks += 1 }
        try await wait { callbacks == 1 && model.canTransfer }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o640)
        XCTAssertEqual(try stat(target).st_mtimespec.tv_sec, 123)
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    @MainActor
    func testAttributeRecoveryRetainsOriginalRenamePolicyAndKnownSourceRequirement() async throws {
        for unknownSize in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "source"), target = root.appendingPathComponent("target")
            if unknownSize { try policy(root, ["sourceName": "source", "unknownSize": true]) }
            let cp = try checkpoint(root)
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: cp)
            let inode = try stat(target).st_ino
            do {
                _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel },
                                              allowRootRename: unknownSize, checkpoint: TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes))
                XCTFail("属性恢复不能绕过原有来源完整性与改名策略")
            } catch {}
            XCTAssertEqual(try stat(target).st_ino, inode)
        }
    }

    @MainActor
    func testReplaceAndKeepBothApplyAttributesOnlyToInstalledDestination() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.txt")
        try attributes(source, mode: 0o640, time: 123)
        for upload in [true, false] {
            for keepBoth in [true, false] {
                let base = root.appendingPathComponent(UUID().uuidString)
                let target = try write(base, "file.txt", Data([9]))
                try attributes(target, mode: 0o700, time: 50)
                let cp = try checkpoint(root, UUID().uuidString + ".json")
                let resolver: TransferConflictResolver = { _ in keepBoth ? .keepBoth : .replace }
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: resolver, checkpoint: cp) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: resolver, checkpoint: cp) }
                let installed = keepBoth ? base.appendingPathComponent("file (2).txt") : target
                XCTAssertEqual(try stat(installed).st_mode & 0o7777, 0o640)
                XCTAssertEqual(try stat(installed).st_mtimespec.tv_sec, 123)
                XCTAssertEqual(try Data(contentsOf: installed), Data([1, 2, 3]))
                if keepBoth {
                    XCTAssertEqual(try Data(contentsOf: target), Data([9]))
                    XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o700)
                    XCTAssertEqual(try stat(target).st_mtimespec.tv_sec, 50)
                }
            }
        }
    }

    private func completeContentOnly(_ client: SFTPClient, source: URL, target: URL, checkpoint: TransferCheckpoint) async throws {
        // 在真实内容安装和属性阶段之间施加外部变化，不在产品中增加测试钩子。
        try await client.perform {
            try checkpoint.begin(); defer { checkpoint.end() }
            try checkpoint.bindRoot(source: source.path, requested: target.path, upload: false, resolvedSource: source.path, resolvedTarget: target.path)
            var bytes: UInt64 = 0, skipped = 0
            try client.resumeNode(source: source.path, requested: target.path, upload: false, canKeepBoth: true,
                                  checkpoint: checkpoint, resolver: { _ in .cancel }, bytes: &bytes, skipped: &skipped, progress: { _ in }, depth: 0)
        }
    }

    @MainActor
    func testLocalHardLinkAndSymbolicReplacementCannotReceiveAttributeWrites() async throws {
        for symbolic in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "source"), target = root.appendingPathComponent("target")
            try attributes(source, mode: 0o750, time: 123)
            let cp = try checkpoint(root)
            try await completeContentOnly(client, source: source, target: target, checkpoint: cp)
            let original = try stat(target)
            let alias = root.appendingPathComponent("alias")
            if symbolic {
                try FileManager.default.moveItem(at: target, to: alias)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: alias)
            } else { try FileManager.default.linkItem(at: target, to: alias) }
            do { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: cp); XCTFail("不能通过链接修改属性") } catch {}
            XCTAssertEqual(try stat(alias).st_mode & 0o7777, original.st_mode & 0o7777)
            XCTAssertEqual(try stat(alias).st_mtimespec.tv_sec, original.st_mtimespec.tv_sec)
            XCTAssertEqual(try Data(contentsOf: alias), Data([1, 2, 3]))
            if !symbolic {
                try FileManager.default.removeItem(at: alias)
                _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: cp.fileURL, attributes: cp.attributes))
                XCTAssertEqual(try stat(target).st_ino, original.st_ino)
                XCTAssertEqual(try stat(target).st_mode & 0o7777, 0o750)
            }
        }
    }

    @MainActor
    func testCleanupOfAttributeFailurePreservesCompletedContentAndBindsOptions() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source"), target = root.appendingPathComponent("target")
        try attributes(source, mode: 0o750, time: 123)
        let cp = try checkpoint(root)
        try policy(root, ["partialName": "target"])
        do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: cp); XCTFail("属性应失败") } catch {}
        let task = RecoverableTransfer(account: .init(profile: session.profile), name: "attributes", direction: .upload,
                                       roots: [.init(localPath: source.path, remotePath: target.path)], attributes: cp.attributes)
        let plan = try await client.inspectCleanup(task: task, checkpoint: cp)
        XCTAssertTrue(plan.items.isEmpty)
        let mismatched = RecoverableTransfer(id: task.id, account: task.account, name: task.name, direction: task.direction, roots: task.roots)
        do { _ = try await client.inspectCleanup(task: mismatched, checkpoint: cp); XCTFail("检查点选项必须与任务绑定") } catch {}
        try await client.executeCleanup(task: task, checkpoint: cp, expectedPlan: plan)
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        let restored = try TransferCheckpoint(fileURL: cp.fileURL)
        XCTAssertThrowsError(try restored.requireResumable())
        let continued = try await client.inspectCleanup(task: task, checkpoint: restored)
        XCTAssertTrue(continued.items.isEmpty)
    }
}
