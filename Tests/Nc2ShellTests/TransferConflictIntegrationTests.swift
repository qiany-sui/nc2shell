import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferConflictIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 scripts/integration-smoke.py 才会启用隔离 SSH 联调")
        }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "冲突测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] +
                (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        for _ in 0..<150 {
            if session.state == .connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(session.state, .connected)
        let client = try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("conflicts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, client, root)
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @MainActor
    func testReplaceStagesFilesAndWholeDirectoriesInBothDirections() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.txt", "new contents"), target = try write(root, "target.txt", "old")
        let result = try await client.upload(local: source, remote: target.path, resolveConflict: { conflict in
            XCTAssertEqual(conflict.sourcePath, source.path); XCTAssertEqual(conflict.destinationPath, target.path)
            XCTAssertFalse(conflict.sourceIsDirectory); XCTAssertFalse(conflict.destinationIsDirectory)
            return .replace
        })
        XCTAssertEqual(result.bytes, 12); XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(try read(target), "new contents")
        let download = try write(root, "download.txt", "old download")
        _ = try await client.download(remote: target.path, local: download, resolveConflict: { _ in .replace })
        XCTAssertEqual(try read(download), "new contents")
        _ = try write(root, "source-dir/new.txt", "directory content")
        _ = try write(root, "target-dir/old.txt", "must disappear")
        _ = try await client.upload(local: root.appendingPathComponent("source-dir"), remote: root.appendingPathComponent("target-dir").path, resolveConflict: { _ in .replace })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("target-dir").path), ["new.txt"])
        _ = try write(root, "download-dir/old.txt", "must disappear")
        _ = try await client.download(remote: root.appendingPathComponent("source-dir").path, local: root.appendingPathComponent("download-dir"), resolveConflict: { _ in .replace })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("download-dir").path), ["new.txt"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nc2shell-") })
    }

    @MainActor
    func testMergeAsksForNestedCollisionsAndSkipContinuesBothDirections() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["source", "target", "download"] { _ = try write(root, "\(name)/nested/collision.txt", name) }
        _ = try write(root, "source/z-new.txt", "new")
        _ = try write(root, "target/target-only.txt", "unique")
        _ = try write(root, "download/local-only.txt", "unique")
        let resolver: TransferConflictResolver = { conflict in conflict.sourceIsDirectory ? .merge : .skip }
        let uploaded = try await client.upload(local: root.appendingPathComponent("source"), remote: root.appendingPathComponent("target").path, resolveConflict: resolver)
        XCTAssertEqual(uploaded.skippedCount, 1); XCTAssertEqual(uploaded.bytes, 3)
        XCTAssertEqual(try read(root.appendingPathComponent("target/nested/collision.txt")), "target")
        XCTAssertEqual(try read(root.appendingPathComponent("target/target-only.txt")), "unique")
        XCTAssertEqual(try read(root.appendingPathComponent("target/z-new.txt")), "new")
        let downloaded = try await client.download(remote: root.appendingPathComponent("source").path, local: root.appendingPathComponent("download"), resolveConflict: resolver)
        XCTAssertEqual(downloaded.skippedCount, 1); XCTAssertEqual(downloaded.bytes, 3)
        XCTAssertEqual(try read(root.appendingPathComponent("download/nested/collision.txt")), "download")
        XCTAssertEqual(try read(root.appendingPathComponent("download/local-only.txt")), "unique")
        XCTAssertEqual(try read(root.appendingPathComponent("download/z-new.txt")), "new")
    }

    @MainActor
    func testKeepBothUsesAvailableNamesAndFinderRootCannotRename() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.txt", "new"), target = try write(root, "中文.txt", "old")
        _ = try write(root, "中文 (2).txt", "occupied")
        _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try read(root.appendingPathComponent("中文 (3).txt")), "new")
        _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try read(root.appendingPathComponent("中文 (4).txt")), "new")
        do {
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { conflict in
                XCTAssertFalse(conflict.canKeepBoth); return .keepBoth
            }, allowRootRename: false)
            XCTFail("Finder 根目标不能自行改名")
        } catch { XCTAssertEqual(try read(target), "old") }
        _ = try write(root, "folder.with.dot/item", "directory")
        let folder = root.appendingPathComponent("folder.with.dot")
        _ = try await client.download(remote: folder.path, local: folder, resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try read(root.appendingPathComponent("folder.with.dot (2)/item")), "directory")
    }

    @MainActor
    func testCrossTypeReplacementAndSymbolicLinkTargetsAreRejected() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.txt", "new")
        _ = try write(root, "target-dir/old.txt", "old")
        let target = root.appendingPathComponent("target-dir")
        do {
            _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .merge })
            XCTFail("跨类型不能合并")
        } catch { XCTAssertEqual(try read(target.appendingPathComponent("old.txt")), "old") }
        _ = try await client.upload(local: source, remote: target.path, resolveConflict: { conflict in
            XCTAssertFalse(conflict.sourceIsDirectory); XCTAssertTrue(conflict.destinationIsDirectory); return .replace
        })
        XCTAssertEqual(try read(target), "new")
        _ = try write(root, "source-dir/new.txt", "directory")
        _ = try await client.download(remote: root.appendingPathComponent("source-dir").path, local: target, resolveConflict: { _ in .replace })
        XCTAssertEqual(try read(target.appendingPathComponent("new.txt")), "directory")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for upload in [true, false] {
            do {
                if upload { _ = try await client.upload(local: source, remote: link.path, resolveConflict: { _ in XCTFail("链接不能询问覆盖"); return .replace }) }
                else { _ = try await client.download(remote: source.path, local: link, resolveConflict: { _ in XCTFail("链接不能询问覆盖"); return .replace }) }
                XCTFail("链接目标应拒绝")
            } catch { XCTAssertEqual(try read(source), "new") }
        }
    }

    @MainActor
    func testCancelledStagingAndInvalidSourcePreserveOldContents() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let target = try write(root, "target.txt", "old"), large = root.appendingPathComponent("large.bin")
        try Data(repeating: 42, count: 100_000).write(to: large)
        do {
            _ = try await client.upload(local: large, remote: target.path, resolveConflict: { _ in .replace }, progress: { _ in client.cancel() })
            XCTFail("取消不应成功")
        } catch {
            XCTAssertEqual(try read(target), "old")
            XCTAssertTrue(error.localizedDescription.contains(".nc2shell-upload-"))
        }
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { second.cancel() }
        _ = try write(root, "bad-source/ok.txt", "ok")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bad-source/link"), withDestinationURL: target)
        do {
            _ = try await second.upload(local: root.appendingPathComponent("bad-source"), remote: target.path, resolveConflict: { _ in .replace })
            XCTFail("源目录中的链接应拒绝")
        } catch { XCTAssertEqual(try read(target), "old") }
        do {
            _ = try await second.download(remote: large.path, local: target, resolveConflict: { _ in .cancel })
            XCTFail("选择取消不能返回成功")
        } catch { XCTAssertEqual(try read(target), "old") }
    }

    @MainActor
    func testCancelWakesResolverThatIgnoresTaskCancellation() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source", "new"), target = try write(root, "target", "old")
        let gate = ConflictTestGate()
        let entered = expectation(description: "等待冲突选择")
        let finished = expectation(description: "取消释放传输")
        let task = Task {
            do {
                _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in
                    entered.fulfill(); return await gate.wait()
                })
                XCTFail("取消不应成功")
            } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        client.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await gate.finish()
        await task.value
        XCTAssertEqual(try read(target), "old")
    }

    @MainActor
    func testFailedInstallRestoresOriginalAndInterruptedBackupReportsRecoveryLocation() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source", "new")
        let denied = try write(root, "nc2-denied-install", "old")
        do {
            _ = try await client.upload(local: source, remote: denied.path, resolveConflict: { _ in .replace })
            XCTFail("测试服务器拒绝安装时必须失败")
        } catch {
            XCTAssertEqual(try read(denied), "old")
            XCTAssertTrue(error.localizedDescription.contains("已恢复"), error.localizedDescription)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nc2shell-backup-") })
        }
        let delayed = try write(root, "nc2-delay-backup", "precious old contents")
        let transfer = Task { () -> String in
            do {
                _ = try await client.upload(local: source, remote: delayed.path, resolveConflict: { _ in .replace })
                XCTFail("备份后取消必须报告未完成"); return ""
            } catch { return error.localizedDescription }
        }
        var backup: URL?
        for _ in 0..<100 {
            backup = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-backup-") }
            if backup != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let saved = try XCTUnwrap(backup)
        client.cancel()
        let message = await transfer.value
        XCTAssertTrue(message.contains(saved.path), message)
        XCTAssertTrue(message.contains(".nc2shell-upload-"), message)
        XCTAssertEqual(try read(saved), "precious old contents")
    }

    @MainActor
    func testCancelledDownloadStagingAndChangedDestinationPreserveOriginal() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data(repeating: 8, count: 100_000).write(to: source)
        let target = try write(root, "target", "old")
        do {
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .replace }, progress: { _ in client.cancel() })
            XCTFail("取消下载不应成功")
        } catch {
            XCTAssertEqual(try read(target), "old")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nc2shell-download-") })
        }
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { second.cancel() }
        do {
            _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in
                try Data("changed outside application".utf8).write(to: target)
                return .replace
            })
            XCTFail("选择期间已改变目标不能覆盖")
        } catch { XCTAssertEqual(try read(target), "changed outside application") }
    }

    @MainActor
    func testMergeRejectsSourceDirectoryReplacedBySymbolicLinkWhileChoosing() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "source/original", "source")
        _ = try write(root, "elsewhere/unrelated", "must not transfer")
        _ = try write(root, "target/old", "old")
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        do {
            _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in
                try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original-source"))
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: root.appendingPathComponent("elsewhere"))
                return .merge
            })
            XCTFail("等待期间的源目录链接替换必须拒绝")
        } catch {
            // Foundation 的目录枚举拒绝作为根传入的链接；必须确认拒绝发生在来源处。
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.userInfo[NSFilePathErrorKey] as? String, source.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("unrelated").path))
        XCTAssertEqual(try read(root.appendingPathComponent("elsewhere/unrelated")), "must not transfer")
        XCTAssertEqual(try read(target.appendingPathComponent("old")), "old")
    }

    @MainActor
    func testFinderMergeKeepsRootNameAndCanRenameNestedConflicts() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "source/item.txt", "new")
        _ = try write(root, "finder-target/item.txt", "old")
        let result = try await client.download(remote: root.appendingPathComponent("source").path,
                                               local: root.appendingPathComponent("finder-target"), resolveConflict: { conflict in
            if conflict.sourceIsDirectory {
                XCTAssertFalse(conflict.canKeepBoth)
                return .merge
            }
            XCTAssertTrue(conflict.canKeepBoth)
            return .keepBoth
        }, allowRootRename: false)
        XCTAssertEqual(result.skippedCount, 0); XCTAssertEqual(result.bytes, 3)
        XCTAssertEqual(try read(root.appendingPathComponent("finder-target/item.txt")), "old")
        XCTAssertEqual(try read(root.appendingPathComponent("finder-target/item (2).txt")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("finder-target (2)").path))
    }

    @MainActor
    func testDisconnectedChannelWakesPendingConflict() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source", "new"), target = try write(root, "target", "old")
        let gate = ConflictTestGate(), entered = expectation(description: "已开始等待"), finished = expectation(description: "断线释放等待")
        let task = Task {
            do {
                _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in
                    entered.fulfill(); return await gate.wait()
                })
                XCTFail("连接断开不应成功")
            } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        session.disconnect()
        await fulfillment(of: [finished], timeout: 3)
        client.cancel()
        await gate.finish()
        await task.value
        XCTAssertEqual(try read(target), "old")
    }

    @MainActor
    func testSameSizeRemoteChangeWhileChoosingRefusesReplacement() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source", "NEW"), target = try write(root, "target", "OLD")
        let manager = FileManager.default
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
        let before = try manager.attributesOfItem(atPath: target.path)
        let previousSize = (before[.size] as? NSNumber)?.uint64Value
        let previousMode = (before[.posixPermissions] as? NSNumber)?.uint32Value
        let listing = try await client.list(path: root.path)
        XCTAssertEqual(listing.files.first { $0.name == "target" }?.modifiedTime, 1_700_000_000)
        do {
            _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in
                try Data("EXT".utf8).write(to: target)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_060)], ofItemAtPath: target.path)
                let changed = try FileManager.default.attributesOfItem(atPath: target.path)
                XCTAssertEqual((changed[.size] as? NSNumber)?.uint64Value, previousSize)
                XCTAssertEqual((changed[.posixPermissions] as? NSNumber)?.uint32Value, previousMode)
                XCTAssertEqual(changed[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_700_000_060))
                return .replace
            })
            XCTFail("同长度但修改时间变化的目标必须拒绝覆盖")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已变化"), error.localizedDescription) }
        XCTAssertTrue(try Data(contentsOf: target) == Data("EXT".utf8), "必须保留外部更新的内容")
    }

    @MainActor
    func testSameSizeRemoteChangeDuringStagingRefusesReplacement() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large-source")
        try Data(repeating: 42, count: 70_000).write(to: source)
        let target = try write(root, "target", "OLD")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
        do {
            _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, progress: { bytes in
                if bytes == 32_768 {
                    do {
                        try Data("EXT".utf8).write(to: target)
                        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_060)], ofItemAtPath: target.path)
                    } catch { XCTFail("无法准备外部修改：\(error)") }
                }
            })
            XCTFail("暂存期间的同长度目标变化必须拒绝覆盖")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已变化"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(".nc2shell-upload-"), error.localizedDescription)
        }
        XCTAssertEqual(try read(target), "EXT")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nc2shell-backup-") })
    }
}

private actor ConflictTestGate {
    private var continuation: CheckedContinuation<TransferConflictChoice, Never>?
    private var finished = false
    func wait() async -> TransferConflictChoice {
        if finished { return .replace }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(returning: .replace); continuation = nil }
}
