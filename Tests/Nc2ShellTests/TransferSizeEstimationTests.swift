import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferSizeEstimationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 scripts/integration-smoke.py 才会启用隔离 SSH 联调")
        }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "传输大小测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] +
                (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        try await eventually { session.state == .connected }
        let client = try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("estimate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, client, root)
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待估算状态超时")
        throw SFTPError.message("测试等待超时")
    }

    private func write(_ root: URL, _ name: String, count: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: count).write(to: url)
        return url
    }

    @MainActor
    func testMixedSourcesIncludeNestedHiddenAndEmptyContentsWithoutWritingTargets() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let single = try write(root, "独立文件", count: 7)
        let nested = try write(root, "目录/nested/中文 '\n.bin", count: 3)
        _ = try write(root, "目录/.hidden", count: 5)
        _ = try write(root, "目录/empty", count: 0)
        let emptyDirectory = root.appendingPathComponent("目录/empty-directory")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
        let folder = root.appendingPathComponent("目录")
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        let upload = try await client.estimateUploadBytes([single, folder])
        let download = try await client.estimateDownloadBytes([single.path, folder.path])
        XCTAssertEqual(upload, 15)
        XCTAssertEqual(download, 15)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: nested), Data([42, 42, 42]))

        let emptyUpload = try await client.estimateUploadBytes([folder.appendingPathComponent("empty"), emptyDirectory])
        let emptyDownload = try await client.estimateDownloadBytes([emptyDirectory.path, folder.appendingPathComponent("empty").path])
        XCTAssertEqual(emptyUpload, 0)
        XCTAssertEqual(emptyDownload, 0)
    }

    @MainActor
    func testLinksAndMissingSourcesYieldUnknownWithoutFollowingOrChangingThem() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let content = try write(root, "outside/keep", count: 9)
        let tree = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let link = tree.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: content.deletingLastPathComponent())
        let missing = root.appendingPathComponent("missing")
        for source in [link, tree, missing] {
            let upload = try await client.estimateUploadBytes([source])
            let download = try await client.estimateDownloadBytes([source.path])
            XCTAssertNil(upload)
            XCTAssertNil(download)
        }
        let aliasedRemote = try await client.estimateDownloadBytes([link.appendingPathComponent("keep").path])
        XCTAssertNil(aliasedRemote)
        XCTAssertEqual(try Data(contentsOf: content), Data(repeating: 42, count: 9))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), content.deletingLastPathComponent().path)
    }

    @MainActor
    func testUnknownRemoteAttributesPermissionsAndOverflowDoNotBecomeZeroOrBlockLaterTransfer() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let unknown = try write(root, "nc2-estimate-unknown-size", count: 3)
        let denied = try write(root, "nc2-estimate-denied", count: 4)
        let large = try write(root, "overflow/nc2-estimate-max-size", count: 1)
        let one = try write(root, "overflow/one", count: 1)
        for paths in [[unknown.path], [denied.path], [large.path, one.path], [large.deletingLastPathComponent().path]] {
            let estimate = try await client.estimateDownloadBytes(paths)
            XCTAssertNil(estimate)
        }
        let maximum = try await client.estimateDownloadBytes([large.path])
        XCTAssertEqual(maximum, UInt64.max)
        let target = root.appendingPathComponent("download")
        try await client.download(remote: unknown.path, local: target)
        XCTAssertEqual(try Data(contentsOf: target), Data([42, 42, 42]))
    }

    @MainActor
    func testPauseBeforeScanningKeepsBothDirectionsPendingAndResumeProducesTotal() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "file", count: 3)
        for upload in [true, false] {
            client.setPaused(true)
            var finished = false
            let scan = Task { () throws -> UInt64? in
                defer { finished = true }
                if upload { return try await client.estimateUploadBytes([source]) }
                return try await client.estimateDownloadBytes([source.path])
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(finished)
            client.setPaused(false)
            let bytes = try await scan.value
            XCTAssertEqual(bytes, 3)
        }
    }

    @MainActor
    func testPauseDuringRemoteScanWaitsAtRequestBoundaryAndResumeCompletes() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "nc2-estimate-delayed/file", count: 6)
        var finished = false
        let scan = Task { () throws -> UInt64? in
            defer { finished = true }
            return try await client.estimateDownloadBytes([file.deletingLastPathComponent().path])
        }
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".nc2-estimate-started").path) }
        client.setPaused(true)
        try Data().write(to: root.appendingPathComponent(".nc2-estimate-release"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(finished)
        client.setPaused(false)
        let bytes = try await scan.value
        XCTAssertEqual(bytes, 6)
    }

    @MainActor
    func testCancelAndDisconnectDuringPausedRemoteScanThrowInsteadOfReturningUnknown() async throws {
        for disconnect in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let file = try write(root, "nc2-estimate-delayed/file", count: 6)
            let finished = expectation(description: "取消唤醒扫描")
            let scan = Task {
                defer { finished.fulfill() }
                do {
                    _ = try await client.estimateDownloadBytes([file.deletingLastPathComponent().path])
                    XCTFail("取消或断线必须抛出错误，不能返回未知总量")
                } catch {}
            }
            try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".nc2-estimate-started").path) }
            client.setPaused(true)
            try Data().write(to: root.appendingPathComponent(".nc2-estimate-release"))
            if disconnect { session.disconnect() } else { client.cancel() }
            await fulfillment(of: [finished], timeout: 3)
            await scan.value
            XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 42, count: 6))
        }
    }

    @MainActor
    func testExcessiveDepthReturnsUnknownWithoutEnteringUnsupportedTransfer() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let relative = Array(repeating: "d", count: 65).joined(separator: "/")
        _ = try write(root, relative + "/file", count: 1)
        let upload = try await client.estimateUploadBytes([root])
        let download = try await client.estimateDownloadBytes([root.path])
        XCTAssertNil(upload)
        XCTAssertNil(download)
    }
}
