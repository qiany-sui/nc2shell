import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class ResumeTransferIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "续传测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        for _ in 0..<150 {
            if session.state == .connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(session.state, .connected)
        let client = try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("resume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, client, root)
    }

    @MainActor
    func testCancelledFilesResumeWithFreshClientAndCheckpointInBothDirections() async throws {
        for upload in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try Data().write(to: root.appendingPathComponent(".nc2-resume-trace-enabled"))
            let data = Data((0..<150_000).map { UInt8($0 % 251) })
            try data.write(to: source)
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            let checkpoint = try TransferCheckpoint(fileURL: checkpointURL)
            let stop: SFTPClient.Progress = { bytes in if bytes >= 65_536 { client.cancel() } }
            do {
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: stop) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: stop) }
                XCTFail("中断不能成功")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try Data().write(to: root.appendingPathComponent(".nc2-resume-trace.jsonl"))
            let reused = ResumeCounter()
            let restored = try TransferCheckpoint(fileURL: checkpointURL, onReusedBytes: { reused.add($0) })
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
            defer { second.cancel() }
            let result: TransferResult
            if upload { result = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in XCTFail("应保留原决定"); return .cancel }, checkpoint: restored) }
            else { result = try await second.download(remote: source.path, local: target, resolveConflict: { _ in XCTFail("应保留原决定"); return .cancel }, checkpoint: restored) }
            XCTAssertEqual(result.bytes, UInt64(data.count)); XCTAssertGreaterThan(reused.value, 0)
            XCTAssertEqual(try Data(contentsOf: target), data)
            let trace = try String(contentsOf: root.appendingPathComponent(".nc2-resume-trace.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            if upload {
                let writes = trace.filter { $0["operation"] as? String == "write" }
                XCTAssertEqual((writes.first?["offset"] as? NSNumber)?.uint64Value, 65536, "真实 WRITE 从保存偏移继续")
                XCTAssertFalse(trace.contains { $0["operation"] as? String == "read" && $0["path"] as? String == target.path }, "新上传不应为了记录完成状态把整个目标重新读回")
            } else {
                let reads = trace.filter { $0["operation"] as? String == "read" && $0["path"] as? String == source.path }
                let offsets = reads.compactMap { ($0["offset"] as? NSNumber)?.uint64Value }
                XCTAssertEqual(Set(offsets.prefix(2)), Set([UInt64(0), 32768]), "只读两个已完成边界块校验")
                XCTAssertEqual(offsets.dropFirst(2).first, 65536, "真实 READ 从保存偏移继续")
                XCTAssertTrue(offsets.dropFirst(2).allSatisfy { $0 >= 65536 })
            }
        }
    }

    @MainActor
    func testSourceChangeAndTemporaryContentChangeRefuseResume() async throws {
        for changeSource in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try Data(repeating: 1, count: 100_000).write(to: source)
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
            catch {}
            let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-upload-") })
            let changed = changeSource ? source : temporary
            let handle = try FileHandle(forWritingTo: changed); try handle.write(contentsOf: Data([99])); try handle.close()
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
            defer { second.cancel() }
            do {
                _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
                XCTFail("变化后禁止续传")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("变化") || error.localizedDescription.contains("校验"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(temporary.path), "拒绝恢复也必须保留准确暂存位置：\(error.localizedDescription)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @MainActor
    func testDirectoryAndBatchReuseCompletedItemsAcrossFreshContexts() async throws {
        for upload in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let first = Data(repeating: 3, count: 42), last = Data(repeating: 7, count: 100_000)
            try first.write(to: source.appendingPathComponent("a 中文")); try last.write(to: source.appendingPathComponent("z.bin"))
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            let stop: SFTPClient.Progress = { value in if value > 42 { client.cancel() } }
            do {
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: stop) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: stop) }
                XCTFail("应中断目录")
            } catch {}
            let staging = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-") })
            let completed = staging.appendingPathComponent("a 中文")
            let inode = try FileManager.default.attributesOfItem(atPath: completed.path)[.systemFileNumber] as? NSNumber
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
            let reused = ResumeCounter(), checkpoint = try TransferCheckpoint(fileURL: checkpointURL, onReusedBytes: { reused.add($0) })
            let result: TransferResult
            if upload { result = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: checkpoint) }
            else { result = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: checkpoint) }
            XCTAssertEqual(result.bytes, 100_042); XCTAssertGreaterThan(reused.value, 42)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a 中文")), first)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("z.bin")), last)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("a 中文").path)[.systemFileNumber] as? NSNumber, inode)
            let before = reused.value
            if upload { _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in XCTFail("完成根不再询问"); return .cancel }, checkpoint: checkpoint) }
            else { _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in XCTFail("完成根不再询问"); return .cancel }, checkpoint: checkpoint) }
            XCTAssertEqual(reused.value - before, 100_042)
        }
    }

    @MainActor
    func testConflictChoicesPersistForReplaceKeepBothMergeAndSkip() async throws {
        for upload in [true, false] {
            for choice in [TransferConflictChoice.replace, .keepBoth, .merge, .skip] {
                let (session, client, root) = try await connected()
                defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
                let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let data = Data(repeating: 8, count: 100_000)
                try data.write(to: source.appendingPathComponent("new")); try Data("keep".utf8).write(to: target.appendingPathComponent("old"))
                let checkpointURL = root.appendingPathComponent("checkpoint.json")
                let resolver: TransferConflictResolver = { _ in choice }
                let stop: SFTPClient.Progress = { _ in client.cancel() }
                do {
                    if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: resolver, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: stop) }
                    else { _ = try await client.download(remote: source.path, local: target, resolveConflict: resolver, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: stop) }
                    XCTAssertEqual(choice, .skip)
                } catch { XCTAssertNotEqual(choice, .skip) }
                let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
                let restored = try TransferCheckpoint(fileURL: checkpointURL)
                let noQuestion: TransferConflictResolver = { _ in XCTFail("恢复不能丢失同名决定"); return .cancel }
                let result: TransferResult
                if upload { result = try await second.upload(local: source, remote: target.path, resolveConflict: noQuestion, checkpoint: restored) }
                else { result = try await second.download(remote: source.path, local: target, resolveConflict: noQuestion, checkpoint: restored) }
                let final = choice == .keepBoth ? root.appendingPathComponent("target (2)") : target
                if choice == .skip { XCTAssertEqual(result.skippedCount, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: final.appendingPathComponent("new").path)) }
                else { XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("new")), data) }
                XCTAssertEqual(FileManager.default.fileExists(atPath: target.appendingPathComponent("old").path), choice != .replace)
            }
        }
    }

    @MainActor
    func testDefiniteInstallFailureRestoresOldTargetAndUncertainInstallNeverRunsAgain() async throws {
        for uncertain in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent(uncertain ? "nc2-delay-rename" : "nc2-denied-install")
            try Data("new".utf8).write(to: source)
            if !uncertain { try Data("precious old".utf8).write(to: target) }
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            let transfer = Task { () -> String in
                do {
                    _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
                    XCTFail("安装异常必须失败"); return ""
                } catch { return error.localizedDescription }
            }
            if uncertain {
                for _ in 0..<300 {
                    if FileManager.default.fileExists(atPath: target.path) { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path)); client.cancel()
            }
            let error = await transfer.value
            XCTAssertTrue(error.contains("暂存") && error.contains("备份"), error)
            if uncertain {
                let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
                do {
                    _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in XCTFail("不应再次询问覆盖"); return .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
                    XCTFail("未知安装不得自动再执行")
                } catch { XCTAssertTrue(error.localizedDescription.contains("结果不明"), error.localizedDescription) }
                XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
            } else { XCTAssertEqual(try Data(contentsOf: target), Data("precious old".utf8)) }
        }
    }

    @MainActor
    func testMergeRejectsUnrecordedTargetMembersAndChangedCompletedContent() async throws {
        for extraMember in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("first".utf8).write(to: source.appendingPathComponent("a"))
            try Data(repeating: 3, count: 100_000).write(to: source.appendingPathComponent("z"))
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            do {
                _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .merge }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { value in if value > 5 { client.cancel() } })
                XCTFail("应中断")
            } catch {}
            try Data("external".utf8).write(to: target.appendingPathComponent(extraMember ? "outside" : "a"))
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
            do {
                _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .merge }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
                XCTFail("外部目标变化必须拒绝")
            } catch { XCTAssertTrue(error.localizedDescription.contains("变化"), error.localizedDescription) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("z").path))
        }
    }

    @MainActor
    func testCheckpointWriteFailureStopsBeforeInstallingAndPreservesDamagedRecord() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 4, count: 150_000).write(to: source)
        try Data("old".utf8).write(to: target)
        let checkpointURL = root.appendingPathComponent("checkpoint.json"), saved = root.appendingPathComponent("saved.json")
        do {
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { bytes in
                if bytes == 32768 {
                    do {
                        try FileManager.default.moveItem(at: checkpointURL, to: saved)
                        try FileManager.default.createDirectory(at: checkpointURL, withIntermediateDirectories: false)
                    } catch { XCTFail("准备写失败：\(error)") }
                }
            })
            XCTFail("不能忽略检查点写失败")
        } catch { XCTAssertTrue(error.localizedDescription.contains("检查点"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: checkpointURL.path)[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: saved)))
        let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-download-") })
        XCTAssertLessThanOrEqual(try Data(contentsOf: partial).count, 65536)
        // 模拟修复保存位置后重新启动：最后一块已经落盘，但旧检查点仍只确认第一块。
        try FileManager.default.removeItem(at: checkpointURL)
        try FileManager.default.moveItem(at: saved, to: checkpointURL)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        let reused = ResumeCounter()
        let tail = try FileHandle(forWritingTo: partial)
        try tail.seek(toOffset: 32768); try tail.write(contentsOf: Data([99]))
        do {
            _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("未经确认尾部必须验证内容")
        } catch { XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8)) }
        try tail.seek(toOffset: 32768); try tail.write(contentsOf: Data([4])); try tail.close()
        _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in XCTFail("应保留覆盖决定"); return .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL, onReusedBytes: { reused.add($0) }))
        XCTAssertEqual(reused.value, 65536)
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 4, count: 150_000))
    }

    @MainActor
    func testSecondCheckpointInstanceCannotWriteWhileFirstTransferIsPaused() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 5, count: 100_000).write(to: source)
        let checkpointURL = root.appendingPathComponent("checkpoint.json"), entered = expectation(description: "已暂停")
        let task = Task {
            do {
                _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { bytes in
                    if bytes == 32768 { client.setPaused(true); entered.fulfill() }
                })
            } catch {}
        }
        await fulfillment(of: [entered], timeout: 5)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        do {
            _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("同一检查点不能并发写")
        } catch { XCTAssertTrue(error.localizedDescription.contains("使用"), error.localizedDescription) }
        client.cancel(); await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testUnknownRemoteAttributesAllowInitialTransferButRefuseResume() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("nc2-estimate-unknown-size")
        let data = Data(repeating: 6, count: 100_000); try data.write(to: source)
        let first = root.appendingPathComponent("first")
        _ = try await client.download(remote: source.path, local: first, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: root.appendingPathComponent("first.json")))
        XCTAssertEqual(try Data(contentsOf: first), data)
        let checkpointURL = root.appendingPathComponent("second.json"), target = root.appendingPathComponent("second")
        do { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
        catch {}
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        do {
            _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("未知源属性不能恢复")
        } catch { XCTAssertTrue(error.localizedDescription.contains("缺少"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testChangedDirectoryMembersAndSymlinkedTemporaryAreRejected() async throws {
        for symlink in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data(repeating: 3, count: 100_000).write(to: source.appendingPathComponent("file"))
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
            catch {}
            if symlink {
                let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-upload-") })
                try FileManager.default.moveItem(at: partial, to: root.appendingPathComponent("saved-staging"))
                try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: source)
            } else { try Data([8]).write(to: source.appendingPathComponent("new-member")) }
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
            do {
                _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
                XCTFail("变化后应拒绝")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("file")), Data(repeating: 3, count: 100_000))
        }
    }

    @MainActor
    func testCheckpointCannotRedirectTemporaryIdentifierOrFinalTarget() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 4, count: 100_000).write(to: source)
        let checkpointURL = root.appendingPathComponent("checkpoint.json")
        do { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
        catch {}
        let original = try Data(contentsOf: checkpointURL)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try XCTUnwrap(document["records"] as? [String: [String: Any]])
        let key = try XCTUnwrap(records.keys.first)
        records[key]?["id"] = UUID().uuidString; document["records"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: checkpointURL)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: checkpointURL), "暂存位置必须绑定当前任务与项目")
        document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        records = try XCTUnwrap(document["records"] as? [String: [String: Any]])
        let victim = root.appendingPathComponent("unrelated")
        try Data("precious".utf8).write(to: victim)
        records[key]?["choice"] = "keepBoth"; records[key]?["target"] = victim.path; document["records"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: checkpointURL)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        do {
            _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("不能重定向到另一目标")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: victim), Data("precious".utf8))
    }

    @MainActor
    func testLocalDirectoryAliasCannotRedirectResumedDownload() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), first = root.appendingPathComponent("first"), other = root.appendingPathComponent("other")
        try Data(repeating: 9, count: 100_000).write(to: source)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias"), target = alias.appendingPathComponent("target"), checkpointURL = root.appendingPathComponent("checkpoint.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        do { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
        catch {}
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        do {
            _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("原目标目录别名已改变，不能另建目标")
        } catch { XCTAssertTrue(error.localizedDescription.contains("目录") || error.localizedDescription.contains("路径"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("target").path))
    }

    @MainActor
    func testMasterConnectionLossThenNewLoginResumesPersistedFile() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), checkpointURL = root.appendingPathComponent("checkpoint.json")
        let data = Data(repeating: 11, count: 150_000); try data.write(to: source)
        let paused = expectation(description: "保存部分数据后暂停"), finished = expectation(description: "SSH 主连接断开释放等待")
        let transfer = Task {
            defer { finished.fulfill() }
            do {
                _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { bytes in
                    if bytes == 32768 { client.setPaused(true); paused.fulfill() }
                })
                XCTFail("真实主连接断开不能成功")
            } catch {}
        }
        await fulfillment(of: [paused], timeout: 5)
        session.disconnect()
        await fulfillment(of: [finished], timeout: 5); await transfer.value
        // SFTP 子通道先结束并不代表终端的主进程已回收；start 在 disconnecting 时会拒绝启动。
        for _ in 0..<150 { if session.state == .disconnected { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(session.state, .disconnected)
        session.start()
        for _ in 0..<150 { if session.state == .connected { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(session.state, .connected)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        let reused = ResumeCounter()
        _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL, onReusedBytes: { reused.add($0) }))
        XCTAssertEqual(reused.value, 32768)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    @MainActor
    func testNestedMergeKeepsSkippedAndRenamedChildrenAcrossResume() async throws {
        for upload in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            for directory in [source, target] { try FileManager.default.createDirectory(at: directory.appendingPathComponent("nested"), withIntermediateDirectories: true) }
            try Data("new skip".utf8).write(to: source.appendingPathComponent("a")); try Data("old skip".utf8).write(to: target.appendingPathComponent("a"))
            let data = Data(repeating: 12, count: 100_000)
            try data.write(to: source.appendingPathComponent("nested/item")); try Data("old item".utf8).write(to: target.appendingPathComponent("nested/item"))
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            let resolver: TransferConflictResolver = { conflict in
                if conflict.sourceIsDirectory { return .merge }
                return (conflict.sourcePath as NSString).lastPathComponent == "a" ? .skip : .keepBoth
            }
            do {
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: resolver, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: resolver, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
                XCTFail("应中断子文件")
            } catch {}
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
            let rejectQuestion: TransferConflictResolver = { _ in XCTFail("子项决定应保存"); return .cancel }
            let result: TransferResult
            if upload { result = try await second.upload(local: source, remote: target.path, resolveConflict: rejectQuestion, checkpoint: TransferCheckpoint(fileURL: checkpointURL)) }
            else { result = try await second.download(remote: source.path, local: target, resolveConflict: rejectQuestion, checkpoint: TransferCheckpoint(fileURL: checkpointURL)) }
            XCTAssertEqual(result.skippedCount, 1); XCTAssertEqual(result.bytes, 100_000)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a")), Data("old skip".utf8))
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("nested/item")), Data("old item".utf8))
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("nested/item (2)")), data)
        }
    }

    @MainActor
    func testChangedDestinationWithSameSizeAndTimestampCannotBeReplacedOnResume() async throws {
        for upload in [true, false] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            try Data(repeating: 6, count: 100_000).write(to: source); try Data("old".utf8).write(to: target)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            do {
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
            } catch {}
            let file = try FileHandle(forWritingTo: target); try file.write(contentsOf: Data("NEW".utf8)); try file.close()
            if let modified = attributes[.modificationDate] { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
            let changedAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual(changedAttributes[.size] as? NSNumber, attributes[.size] as? NSNumber)
            XCTAssertEqual(changedAttributes[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(changedAttributes[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
            do {
                if upload { _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL)) }
                else { _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .replace }, checkpoint: TransferCheckpoint(fileURL: checkpointURL)) }
                XCTFail("目标内容变化不能被覆盖")
            } catch { XCTAssertTrue(error.localizedDescription.contains("变化"), error.localizedDescription) }
            XCTAssertEqual(try Data(contentsOf: target), Data("NEW".utf8))
        }
    }

    @MainActor
    func testHardLinkedDownloadTemporaryCannotModifyUnrelatedFile() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), checkpointURL = root.appendingPathComponent("checkpoint.json")
        try Data(repeating: 15, count: 100_000).write(to: source)
        do { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL), progress: { _ in client.cancel() }) }
        catch {}
        let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-download-") })
        let original = try Data(contentsOf: partial), victim = root.appendingPathComponent("unrelated-victim")
        try original.write(to: victim)
        try FileManager.default.moveItem(at: partial, to: root.appendingPathComponent("original-staging"))
        try FileManager.default.linkItem(at: victim, to: partial)
        let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath)); defer { second.cancel() }
        do {
            _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: checkpointURL))
            XCTFail("同前缀硬链接替换暂存不能继续写")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: victim), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testHardLinkAddedAfterOpeningDownloadStopsFurtherWrites() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), victim = root.appendingPathComponent("unrelated-victim")
        try Data(repeating: 16, count: 100_000).write(to: source)
        do {
            _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: TransferCheckpoint(fileURL: root.appendingPathComponent("checkpoint.json")), progress: { bytes in
                if bytes == 32768 {
                    do {
                        let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".nc2shell-download-") })
                        try FileManager.default.linkItem(at: partial, to: victim)
                    } catch { XCTFail("准备打开后的硬链接：\(error)") }
                }
            })
            XCTFail("文件句柄打开后仍须检测新增硬链接")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: victim), Data(repeating: 16, count: 32768))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDamagedCheckpointDoesNotOverwriteRecord() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checkpoint.json"), bad = Data("broken".utf8)
        try bad.write(to: file)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: file))
        XCTAssertEqual(try Data(contentsOf: file), bad)
    }
}

private final class ResumeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    func add(_ bytes: UInt64) { lock.lock(); count += bytes; lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
}
