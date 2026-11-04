import XCTest
@testable import Nc2ShellCore
@testable import Nc2Shell

final class SFTPPipelineIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "流水线测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        for _ in 0..<150 {
            if session.state == .connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(session.state, .connected)
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, root)
    }

    private func configure(_ root: URL, _ options: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: options).write(to: root.appendingPathComponent(".nc2-pipeline.json"))
    }

    @MainActor
    func testDelayedPayloadResponsesDoNotSerializeEveryBlock() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<(64 * 32768 + 13)).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("source")
        try data.write(to: source)
        try configure(root, ["delay": 0.04])
        for upload in [true, false] {
            var durations: [TimeInterval] = []
            for window in [1, 16] {
                let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath), requestWindow: window)
                defer { client.cancel() }
                let target = root.appendingPathComponent("\(upload)-\(window)")
                let started = Date()
                if upload { _ = try await client.upload(local: source, remote: target.path) }
                else { try await client.download(remote: source.path, local: target) }
                durations.append(Date().timeIntervalSince(started))
                XCTAssertEqual(try Data(contentsOf: target), data)
            }
            print("PIPELINE \(upload ? "upload" : "download"): window1=\(durations[0])s window16=\(durations[1])s")
            XCTAssertLessThan(durations[1], durations[0] * 0.6, "延迟链路应从请求窗口获益")
        }
    }

    @MainActor
    func testOutOfOrderAndShortReadsProduceExactContentAndDrainBeforeMetadata() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let data = Data((0..<600_019).map { UInt8($0 % 239) })
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
        try data.write(to: source)
        try configure(root, ["reorder": true, "shortRead": 7001])
        _ = try await client.upload(local: source, remote: remote.path)
        try await client.download(remote: remote.path, local: local)
        XCTAssertEqual(try Data(contentsOf: remote), data)
        XCTAssertEqual(try Data(contentsOf: local), data)
        let listing = try await client.list(path: root.path)
        XCTAssertTrue(listing.files.contains { $0.name == "remote" })
    }

    @MainActor
    func testFailedWriteNeverInstallsTargetAndDrainsRemainingAcknowledgements() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("remote")
        try Data(repeating: 17, count: 600_019).write(to: source)
        try configure(root, ["reorder": true, "failWriteOffset": 65536])
        do { _ = try await client.upload(local: source, remote: remote.path); XCTFail("失败不能安装目标") }
        catch { XCTAssertTrue(error.localizedDescription.contains(".nc2shell-upload-")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        let listing = try await client.list(path: root.path)
        XCTAssertTrue(listing.files.contains { $0.name == "source" }, "状态失败之后通道仍应与请求对应")
    }

    @MainActor
    func testPrematureEOFDoesNotInstallFileWithMissingMiddleBlock() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 23, count: 600_019).write(to: source)
        try configure(root, ["reorder": true, "eofOffset": 65536])
        do { try await client.download(remote: source.path, local: target); XCTFail("中途 EOF 不能安装截短目标") }
        catch { XCTAssertTrue(error.localizedDescription.contains("长度")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let listing = try await client.list(path: root.path)
        XCTAssertTrue(listing.files.contains { $0.name == "source" })
        XCTAssertFalse(listing.files.contains { $0.name.hasPrefix(".nc2shell-download-") })
    }

    @MainActor
    func testGrowingDownloadSourceCannotInstallSilentlyTruncatedFile() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 29, count: 600_019).write(to: source)
        do {
            try await client.download(remote: source.path, local: target, progress: { bytes in
                if bytes == 32768 {
                    do {
                        let file = try FileHandle(forWritingTo: source)
                        defer { try? file.close() }
                        _ = try file.seekToEnd(); try file.write(contentsOf: Data(repeating: 30, count: 100))
                    } catch { XCTFail("构造真实增长来源失败：\(error)") }
                }
            })
            XCTFail("按初始大小读取后必须复核来源，不能静默安装截短文件")
        } catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testReorderedCancellationCheckpointsOnlyContiguousConfirmedPrefixAndResumes() async throws {
        for upload in [true, false] {
            let (session, root) = try await connected()
            defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
            defer { client.cancel() }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            let data = Data((0..<700_019).map { UInt8($0 % 241) })
            try data.write(to: source)
            try configure(root, ["reorder": true])
            let checkpointURL = root.appendingPathComponent("checkpoint.json")
            let checkpoint = try TransferCheckpoint(fileURL: checkpointURL)
            let progress: SFTPClient.Progress = { bytes in if bytes == 65536 { client.cancel() } }
            do {
                if upload { _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: progress) }
                else { _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: progress) }
                XCTFail("取消不能成功")
            } catch {}
            let record = try XCTUnwrap(TransferCheckpoint(fileURL: checkpointURL).records.first)
            XCTAssertEqual(record.offset, 65536)
            let partial = try Data(contentsOf: URL(fileURLWithPath: record.temporary))
            XCTAssertEqual(partial.prefix(Int(record.offset)), data.prefix(Int(record.offset)))
            if !upload { XCTAssertEqual(partial.count, 65536, "乱序响应只能按连续顺序写入安全暂存") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
            defer { second.cancel() }
            let restored = try TransferCheckpoint(fileURL: checkpointURL)
            if upload { _ = try await second.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: restored) }
            else { _ = try await second.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: restored) }
            XCTAssertEqual(try Data(contentsOf: target), data)
        }
    }

    @MainActor
    func testUnknownResponseIDInvalidatesChannelWithoutInstallingTarget() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 31, count: 600_019).write(to: source)
        try configure(root, ["reorder": true, "wrongIDOffset": 65536])
        do { try await client.download(remote: source.path, local: target); XCTFail("错误 ID 不能写入目标") }
        catch { XCTAssertTrue(error.localizedDescription.contains("序号")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        do { _ = try await client.list(path: root.path); XCTFail("失去响应边界后必须拒绝复用通道") }
        catch {}
    }

    @MainActor
    func testTwoRealClientsShareDirectionalPayloadLimits() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let data = Data((0..<98304).map { UInt8($0 % 251) })
        try data.write(to: source)
        for upload in [true, false] {
            let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: upload ? 131072 : 0, downloadBytesPerSecond: upload ? 0 : 131072)
            let first = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath), bandwidthLimiter: limiter)
            let second = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath), bandwidthLimiter: limiter)
            defer { first.cancel(); second.cancel() }
            let targets = [root.appendingPathComponent("\(upload)-first"), root.appendingPathComponent("\(upload)-second")]
            let started = Date()
            async let a: Void = limitedTransfer(first, source: source, target: targets[0], upload: upload)
            async let b: Void = limitedTransfer(second, source: source, target: targets[1], upload: upload)
            _ = try await (a, b)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThan(elapsed, 1.1, "两个客户端必须共享额度，不能各得到一份上限")
            XCTAssertLessThan(elapsed, 4, "本地链路不应长时间低于配置额度")
            for target in targets { XCTAssertEqual(try Data(contentsOf: target), data) }
        }
    }

    private func limitedTransfer(_ client: SFTPClient, source: URL, target: URL, upload: Bool) async throws {
        if upload { _ = try await client.upload(local: source, remote: target.path) }
        else { try await client.download(remote: source.path, local: target) }
    }

    @MainActor
    func testCancelWakesBandwidthWaitWithoutInstallingTarget() async throws {
        let (session, root) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for mode in 0..<6 {
            let upload = mode.isMultiple(of: 2)
            let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: upload ? 1024 : 0, downloadBytesPerSecond: upload ? 0 : 1024)
            let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath), bandwidthLimiter: limiter)
            defer { client.cancel() }
            let source = root.appendingPathComponent("source-\(mode)"), destination = root.appendingPathComponent("destination-\(mode)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try Data(repeating: 41, count: 300_000).write(to: source)
            let listing = try await client.list(path: root.path)
            let sourceItem = try XCTUnwrap(listing.files.first { $0.name == source.lastPathComponent })
            let checkpoint = try TransferCheckpoint(fileURL: root.appendingPathComponent("checkpoint-\(mode).json"))
            let entered = expectation(description: "首块有进度"), finished = expectation(description: "取消释放限速等待")
            let transfer = Task {
                do {
                    let progress: SFTPClient.Progress = { bytes in if bytes == 32768 { entered.fulfill() } }
                    switch mode {
                    case 0: _ = try await client.upload(local: source, remote: target.path, progress: progress)
                    case 1: try await client.download(remote: source.path, local: target, progress: progress)
                    case 2: _ = try await client.upload(local: source, remote: target.path, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: progress)
                    case 3: _ = try await client.download(remote: source.path, local: target, resolveConflict: { _ in .cancel }, checkpoint: checkpoint, progress: progress)
                    default: _ = try await client.copy(sourceItem, from: root.path, toDirectory: destination.path, resolveConflict: { _ in .cancel }, progress: progress)
                    }
                    XCTFail("取消不能成功")
                } catch {}
                finished.fulfill()
            }
            await fulfillment(of: [entered], timeout: 3)
            client.cancel()
            await fulfillment(of: [finished], timeout: 2)
            await transfer.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source), Data(repeating: 41, count: 300_000))
        }
    }
}
