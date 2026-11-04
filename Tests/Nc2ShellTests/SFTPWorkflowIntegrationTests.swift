import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class SFTPWorkflowIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 scripts/integration-smoke.py 才会启用隔离 SSH 联调")
        }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "文件工作流测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
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
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, client, root)
    }

    private func write(_ root: URL, _ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func item(_ client: SFTPClient, _ url: URL) async throws -> RemoteFile {
        let listing = try await client.list(path: url.deletingLastPathComponent().path)
        return try XCTUnwrap(listing.files.first { $0.name == url.lastPathComponent })
    }

    @MainActor
    func testPauseStopsAtChunkBoundaryAndResumeCompletesUploadAndDownload() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 42, count: 131_073)
        let source = try write(root, "local/source.bin", content)
        let remote = root.appendingPathComponent("remote.bin")
        for upload in [true, false] {
            let paused = expectation(description: "第一块后暂停")
            let progress = WorkflowProgress()
            let local = root.appendingPathComponent("download.bin")
            let transfer = Task {
                let onProgress: SFTPClient.Progress = { bytes in
                    if progress.record(bytes) { client.setPaused(true); paused.fulfill() }
                }
                if upload { _ = try await client.upload(local: source, remote: remote.path, progress: onProgress) }
                else { try await client.download(remote: remote.path, local: local, progress: onProgress) }
            }
            await fulfillment(of: [paused], timeout: 5)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(progress.bytes, 32_768)
            XCTAssertFalse(FileManager.default.fileExists(atPath: (upload ? remote : local).path))
            client.setPaused(false)
            try await transfer.value
            XCTAssertEqual(try Data(contentsOf: upload ? remote : local), content)
        }
    }

    @MainActor
    func testCancelAndDisconnectWakePausedTransfers() async throws {
        for disconnect in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "source", Data(repeating: 7, count: 100_000))
            let target = root.appendingPathComponent("target")
            let paused = expectation(description: "暂停中"), finished = expectation(description: "中断唤醒")
            let progress = WorkflowProgress()
            let transfer = Task {
                do {
                    _ = try await client.upload(local: source, remote: target.path, progress: { bytes in
                        if progress.record(bytes) { client.setPaused(true); paused.fulfill() }
                    })
                    XCTFail("中断不能返回成功")
                } catch { XCTAssertTrue(error.localizedDescription.contains(".nc2shell-upload-")) }
                finished.fulfill()
            }
            await fulfillment(of: [paused], timeout: 5)
            if disconnect { session.disconnect() } else { client.cancel() }
            await fulfillment(of: [finished], timeout: 3)
            await transfer.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @MainActor
    func testRemoteCopyStreamsBinaryTreeAndMovePreservesNamesAndContents() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let content = Data((0..<100_003).map { UInt8($0 % 251) })
        let source = try write(root, "source/中文 '目录/line\nname.bin", content).deletingLastPathComponent()
        let target = root.appendingPathComponent("target"), moved = root.appendingPathComponent("moved")
        for url in [target, moved] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let file = try await item(client, source)
        let result = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: target.path, resolveConflict: { _ in XCTFail("没有冲突"); return .cancel })
        XCTAssertEqual(result.bytes, 100_003); XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("line\nname.bin")), content)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(source.lastPathComponent).appendingPathComponent("line\nname.bin")), content)
        _ = try await client.move(file, from: source.deletingLastPathComponent().path, toDirectory: moved.path, resolveConflict: { _ in .cancel })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(source.lastPathComponent).appendingPathComponent("line\nname.bin")), content)
    }

    @MainActor
    func testRemoteOperationsRejectSelfDescendantAndSymbolicAliasBeforeChanges() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/folder/nested/keep", Data([1])).deletingLastPathComponent().deletingLastPathComponent()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.appendingPathComponent("nested"))
        let file = try await item(client, source)
        for destination in [source.deletingLastPathComponent().path, source.path, source.appendingPathComponent("nested").path, alias.path,
                            source.appendingPathComponent("nested/..").path] {
            for copy in [true, false] {
                do {
                    if copy { _ = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: destination, resolveConflict: { _ in XCTFail("自路径应先拒绝"); return .replace }) }
                    else { _ = try await client.move(file, from: source.deletingLastPathComponent().path, toDirectory: destination, resolveConflict: { _ in XCTFail("自路径应先拒绝"); return .replace }) }
                    XCTFail("不能操作到自己或后代")
                } catch {}
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("nested/keep")), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["nested"])
    }

    @MainActor
    func testRemoteCopyKeepBothSkipReplaceAndMergeReuseConflictRules() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/a.txt", Data([1, 2, 3]))
        let target = try write(root, "target/a.txt", Data([9]))
        let file = try await item(client, source)
        let skipped = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .skip })
        XCTAssertEqual(skipped.skippedCount, 1); XCTAssertEqual(skipped.bytes, 0)
        _ = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/a (2).txt")), Data([1, 2, 3]))
        _ = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .replace })
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        let folder = try write(root, "source/folder/nested/same", Data([4])).deletingLastPathComponent().deletingLastPathComponent()
        _ = try write(root, "source/folder/new", Data([5]))
        _ = try write(root, "target/folder/nested/same", Data([8]))
        _ = try write(root, "target/folder/unique", Data([6]))
        let merged = try await client.copy(try await item(client, folder), from: folder.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { $0.sourceIsDirectory ? .merge : .skip })
        XCTAssertEqual(merged.skippedCount, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/nested/same")), Data([8]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/new")), Data([5]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/unique")), Data([6]))
    }

    @MainActor
    func testRemoteMoveMergeRetainsSkippedSourcesAndRemovesOnlyEmptySourceFolders() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, "source/folder/nested/same", Data([1])).deletingLastPathComponent().deletingLastPathComponent()
        _ = try write(root, "source/folder/move-me", Data([2]))
        _ = try write(root, "target/folder/nested/same", Data([9]))
        _ = try write(root, "target/folder/unique", Data([8]))
        let file = try await item(client, folder)
        let result = try await client.move(file, from: folder.deletingLastPathComponent().path, toDirectory: root.appendingPathComponent("target").path, resolveConflict: { $0.sourceIsDirectory ? .merge : .skip })
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("nested/same")), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("move-me").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/move-me")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/unique")), Data([8]))
        _ = try await client.move(try await item(client, folder), from: folder.deletingLastPathComponent().path, toDirectory: root.appendingPathComponent("target").path, resolveConflict: { $0.sourceIsDirectory ? .merge : .replace })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/nested/same")), Data([1]))
    }

    @MainActor
    func testRemoteCopyCancellationPreservesSourceAndOldDestination() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let content = Data(repeating: 42, count: 100_000)
        let source = try write(root, "source/file", content), target = try write(root, "target/file", Data([9]))
        do {
            _ = try await client.copy(try await item(client, source), from: source.deletingLastPathComponent().path,
                                      toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .replace }, progress: { _ in client.cancel() })
            XCTFail("取消不能成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(".nc2shell-copy-"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(source.path))
        }
        XCTAssertEqual(try Data(contentsOf: source), content)
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
    }

    @MainActor
    func testRemoteMoveRejectsNestedLinksAndChangedSourceDuringConflict() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/folder/keep", Data([1])).deletingLastPathComponent()
        let linked = try write(root, "elsewhere/keep", Data([8]))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: linked)
        let destination = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for copy in [true, false] {
            do {
                if copy { _ = try await client.copy(try await item(client, source), from: source.deletingLastPathComponent().path, toDirectory: destination.path, resolveConflict: { _ in .replace }) }
                else { _ = try await client.move(try await item(client, source), from: source.deletingLastPathComponent().path, toDirectory: destination.path, resolveConflict: { _ in .replace }) }
                XCTFail("嵌套链接必须拒绝")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("keep")), Data([1]))
        let file = try write(root, "source/item", Data([2]))
        let target = try write(root, "target/item", Data([9]))
        do {
            _ = try await client.move(try await item(client, file), from: file.deletingLastPathComponent().path, toDirectory: destination.path, resolveConflict: { _ in
                try Data([3, 4]).write(to: file)
                return .replace
            })
            XCTFail("冲突等待期间已变化的来源不能移动")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data([3, 4]))
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
    }

    @MainActor
    func testRemoteInstallFailureRestoresOldTargetAndKeepsSourceForCopyAndMove() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/nc2-denied-install", Data([1, 2]))
        let target = try write(root, "target/nc2-denied-install", Data([9]))
        let file = try await item(client, source)
        for copy in [true, false] {
            do {
                if copy { _ = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .replace }) }
                else { _ = try await client.move(file, from: source.deletingLastPathComponent().path, toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .replace }) }
                XCTFail("服务器拒绝安装必须失败")
            } catch { XCTAssertTrue(error.localizedDescription.contains("已恢复原目标"), error.localizedDescription) }
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: target), Data([9]))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).contains { $0.hasPrefix(".nc2shell-backup-") })
        }
    }

    @MainActor
    func testRemoteMoveCancelDuringMergeKeepsUnprocessedSourcesAndReportsPartialResult() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let folder = try write(root, "source/folder/a", Data([1])).deletingLastPathComponent()
        _ = try write(root, "source/folder/z", Data([2]))
        _ = try write(root, "target/folder/unique", Data([9]))
        do {
            _ = try await client.move(try await item(client, folder), from: folder.deletingLastPathComponent().path,
                                      toDirectory: root.appendingPathComponent("target").path, resolveConflict: { _ in .merge }, progress: { _ in client.cancel() })
            XCTFail("部分移动后取消不能返回成功")
        } catch { XCTAssertTrue(error.localizedDescription.contains("部分项目可能已生效")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a").path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("z")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/a")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/folder/unique")), Data([9]))
    }

    @MainActor
    func testRemoteWholeDirectoryReplacementRemovesDestinationOnlyChildrenAndCopyRetainsSource() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/folder/new", Data([1])).deletingLastPathComponent()
        _ = try write(root, "copy/folder/old", Data([9]))
        _ = try write(root, "move/folder/old", Data([8]))
        let file = try await item(client, source)
        _ = try await client.copy(file, from: source.deletingLastPathComponent().path, toDirectory: root.appendingPathComponent("copy").path, resolveConflict: { _ in .replace })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("copy/folder").path), ["new"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("new")), Data([1]))
        _ = try await client.move(file, from: source.deletingLastPathComponent().path, toDirectory: root.appendingPathComponent("move").path, resolveConflict: { _ in .replace })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("move/folder").path), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testRemoteMoveKeepBothPreservesOldTargetAndCancelledReplacementReportsBackup() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/a.txt", Data([1, 2]))
        let target = try write(root, "target/a.txt", Data([9]))
        _ = try await client.move(try await item(client, source), from: source.deletingLastPathComponent().path,
                                  toDirectory: target.deletingLastPathComponent().path, resolveConflict: { _ in .keepBoth })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/a (2).txt")), Data([1, 2]))
        let delayedSource = try write(root, "source/nc2-delay-backup", Data([3]))
        let delayedTarget = try write(root, "target/nc2-delay-backup", Data([8]))
        let file = try await item(client, delayedSource)
        let transfer = Task { () -> String in
            do {
                _ = try await client.move(file, from: delayedSource.deletingLastPathComponent().path,
                                          toDirectory: delayedTarget.deletingLastPathComponent().path, resolveConflict: { _ in .replace })
                XCTFail("备份后取消应报告不完整结果"); return ""
            } catch { return error.localizedDescription }
        }
        var backup: URL?
        for _ in 0..<150 {
            backup = try FileManager.default.contentsOfDirectory(at: delayedTarget.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-backup-") }
            if backup != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let saved = try XCTUnwrap(backup)
        client.cancel()
        let message = await transfer.value
        XCTAssertTrue(message.contains(saved.path), message)
        XCTAssertTrue(message.contains(delayedSource.path), message)
        XCTAssertEqual(try Data(contentsOf: saved), Data([8]))
        XCTAssertEqual(try Data(contentsOf: delayedSource), Data([3]))
    }

    @MainActor
    func testRemoteCopyAllowsListingWithoutOptionalSizeAndTimeButChecksKnownAttributes() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source/file", Data([1, 2, 3]))
        let destination = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let actual = try await item(client, source)
        // READDIR 的可选属性可以少于之后 LSTAT 的属性，未知值不能当作空文件或 epoch。
        let listed = RemoteFile(name: actual.name, size: 0, mode: actual.mode, hasSize: false)
        _ = try await client.copy(listed, from: source.deletingLastPathComponent().path,
                                  toDirectory: destination.path, resolveConflict: { _ in .cancel })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), Data([1, 2, 3]))
        let stale = RemoteFile(name: actual.name, size: 1, mode: actual.mode)
        do {
            _ = try await client.move(stale, from: source.deletingLastPathComponent().path,
                                      toDirectory: destination.path, resolveConflict: { _ in XCTFail("已知大小变化必须先拒绝"); return .replace })
            XCTFail("已知属性不匹配应拒绝")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }
}

private final class WorkflowProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var bytes: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ bytes: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = value == 0; value = bytes; return first
    }
}
