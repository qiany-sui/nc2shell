import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class RemoteSearchIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "搜索验收", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start()
        try await eventually { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath)), root)
    }

    private func write(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("搜索原文".utf8).write(to: url)
        return url
    }

    @MainActor
    func testNestedNamesHiddenAndLinksUseFullPathsWithoutFollowingLinks() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = try write(root, "tree/a/中文 Match\n.txt"), b = try write(root, "tree/b/中文 Match\n.txt")
        let hidden = try write(root, "tree/.hidden/MATCH.txt")
        let dot = try write(root, "tree/.match")
        let outside = try write(root, "outside/Match.txt")
        let tree = root.appendingPathComponent("tree"), link = tree.appendingPathComponent("Match-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let result = try await client.search(directory: tree.path, query: "mAtCh", includeHidden: false)
        XCTAssertEqual(Set(result.matches.map(\.path)), Set([a.path, b.path, link.path]))
        XCTAssertEqual(result.matches.first { $0.path == link.path }?.file.kind, .symbolicLink)
        XCTAssertFalse(result.truncated); XCTAssertEqual(result.skippedCount, 0)
        let all = try await client.search(directory: tree.path, query: "match", includeHidden: true)
        XCTAssertEqual(Set(all.matches.map(\.path)), Set([a.path, b.path, link.path, hidden.path, dot.path]))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: outside), Data("搜索原文".utf8))
        do { _ = try await client.search(directory: link.path, query: "match", includeHidden: true); XCTFail("不能以链接为根递归") } catch {}
    }

    @MainActor
    func testChildPermissionFailureKeepsOtherResultsButRootFailureThrows() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let good = try write(root, "good/match"), denied = try write(root, "nc2-search-denied/match")
        _ = try write(root, "nc2-search-missing/match")
        let result = try await client.search(directory: root.path, query: "match", includeHidden: false)
        XCTAssertEqual(result.matches.map(\.path), [good.path])
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.issues.first?.path, denied.deletingLastPathComponent().path)
        do { _ = try await client.search(directory: denied.deletingLastPathComponent().path, query: "match", includeHidden: false); XCTFail("根目录无权访问必须报错") } catch {}
    }

    @MainActor
    func testInvalidProtocolListingStopsInsteadOfClaimingComplete() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "nc2-search-invalid/match")
        do { _ = try await client.search(directory: root.path, query: "match", includeHidden: true); XCTFail("无效响应不能变成成功") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重复文件名")) }
    }

    @MainActor
    func testActiveUploadContinuesWhileSearchWaitsForAnotherDirectory() async throws {
        let (session, client, root) = try await connected()
        let files = RemoteFilesModel()
        defer { client.cancel(); files.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "local-source")
        try Data(repeating: 7, count: 2 * 1_048_576).write(to: source)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        _ = try write(root, "nc2-estimate-delayed/match")
        let settings = TransferSettingsController(store: .init(fileURL: root.appendingPathComponent("settings.json")))
        XCTAssertTrue(settings.save(.init(maxConcurrentTransfers: 2, uploadLimitKiB: 128, downloadLimitKiB: 0)))
        files.configureTransferSettings(settings)
        files.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: target.path)
        try await eventually { files.canEnqueue }
        files.upload([source], expectedPath: target.path, connectionID: files.connectionID)
        let task = try XCTUnwrap(files.transferItems.first)
        try await eventually { task.state == .running && task.bytes > 0 }
        files.search.prepare(directory: root.appendingPathComponent("nc2-estimate-delayed").path, includeHidden: false)
        files.search.query = "match"; files.search.start()
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".nc2-estimate-started").path) }
        let before = task.bytes
        try await eventually { task.bytes >= before + 65_536 }
        XCTAssertEqual(task.state, .running)
        XCTAssertTrue(files.search.isRunning)
        files.search.cancel()
        try Data().write(to: root.appendingPathComponent(".nc2-estimate-release"))
        let after = task.bytes
        try await eventually { task.bytes > after }
        files.cancelQueuedTransfer(task.id)
        try await eventually { task.state == .cancelled }
    }

    @MainActor
    func testResultLimitAndDepthAreExplicitlyIncomplete() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let many = root.appendingPathComponent("many")
        for index in 0..<1001 { _ = try write(many, "match-\(index)") }
        let result = try await client.search(directory: many.path, query: "match", includeHidden: false)
        XCTAssertEqual(result.matches.count, 1000); XCTAssertTrue(result.truncated)
        let deep = root.appendingPathComponent("deep")
        _ = try write(deep, Array(repeating: "d", count: 65).joined(separator: "/") + "/match")
        let limited = try await client.search(directory: deep.path, query: "match", includeHidden: true)
        XCTAssertTrue(limited.matches.isEmpty)
        XCTAssertEqual(limited.skippedCount, 1)
        XCTAssertTrue(limited.issues.first?.reason.contains("64") == true)
    }

    @MainActor
    func testSearchKeepsCapturedRootWhileBrowsingAndOpensResultParent() async throws {
        let (session, client, root) = try await connected()
        let files = session.files
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let target = try write(root, "source/nested/.Match.txt")
        let elsewhere = try write(root, "elsewhere/keep").deletingLastPathComponent()
        files.browse(root.appendingPathComponent("source").path)
        try await eventually { files.locationValidated && files.path == root.appendingPathComponent("source").path }
        files.browser.showHidden = true
        XCTAssertTrue(files.prepareSearch())
        files.search.query = "match"
        files.search.start()
        files.browse(elsewhere.path)
        try await eventually { !files.search.isRunning && files.path == elsewhere.path && files.locationValidated }
        let match = try XCTUnwrap(files.search.snapshot.matches.first)
        XCTAssertEqual(match.path, target.path)
        XCTAssertEqual(files.search.directory, root.appendingPathComponent("source").path)
        files.browser.query = "should-hide-result"; files.browser.showHidden = false
        XCTAssertTrue(files.openSearchResult(match))
        try await eventually { files.locationValidated && files.path == target.deletingLastPathComponent().path }
        XCTAssertFalse(files.following)
        XCTAssertTrue(files.browser.query.isEmpty); XCTAssertTrue(files.browser.showHidden)
        XCTAssertTrue(files.browser.visibleFiles(files.files).contains { $0.name == target.lastPathComponent })
    }

    @MainActor
    func testSearchCancellationAndLateRepliesDoNotCancelTransferOrReplaceNextQuery() async throws {
        let (session, client, root) = try await connected()
        let files = session.files
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let slow = try write(root, "nc2-estimate-delayed/old-match")
        let next = try write(root, "next/new-match")
        let uploadSource = try write(root, "upload-source")
        files.browse(root.path)
        try await eventually { files.locationValidated && files.path == root.path }
        files.upload([uploadSource], expectedPath: root.path, connectionID: files.connectionID)
        let task = try XCTUnwrap(files.transferItems.first)
        files.pauseTransfer(task.id)
        files.search.prepare(directory: slow.deletingLastPathComponent().path, includeHidden: false)
        files.search.query = "match"; files.search.start()
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".nc2-estimate-started").path) }
        files.search.cancel()
        XCTAssertEqual(task.state, .paused)
        files.search.prepare(directory: next.deletingLastPathComponent().path, includeHidden: false)
        files.search.query = "new"; files.search.start()
        try Data().write(to: root.appendingPathComponent(".nc2-estimate-release"))
        try await eventually { !files.search.isRunning }
        XCTAssertEqual(files.search.snapshot.matches.map(\.path), [next.path])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(files.search.snapshot.matches.map(\.path), [next.path])
        XCTAssertEqual(task.state, .paused)
        files.cancelQueuedTransfer(task.id)
        try await eventually { task.state == .cancelled }
    }

    @MainActor
    func testDisconnectInvalidatesSearchResultsAndReconnectClearsThem() async throws {
        let (session, client, root) = try await connected()
        let files = session.files
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "match")
        files.browse(root.path)
        try await eventually { files.locationValidated && files.path == root.path }
        XCTAssertTrue(files.prepareSearch())
        files.search.query = "match"; files.search.start()
        try await eventually { !files.search.isRunning }
        let match = try XCTUnwrap(files.search.snapshot.matches.first)
        files.disconnect()
        XCTAssertFalse(files.search.isConnected)
        XCTAssertFalse(files.openSearchResult(match))
        files.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        XCTAssertTrue(files.search.snapshot.matches.isEmpty)
        XCTAssertFalse(files.openSearchResult(match))
    }

    @MainActor
    func testCancelOrDisconnectStopsSearchWithoutTouchingFiles() async throws {
        for disconnect in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let source = try write(root, "nc2-estimate-delayed/match")
            let search = Task { try await client.search(directory: source.deletingLastPathComponent().path, query: "match", includeHidden: true) }
            try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".nc2-estimate-started").path) }
            if disconnect { session.disconnect() } else { client.cancel() }
            do { _ = try await search.value; XCTFail("不能把取消或断线显示为搜索完成") } catch {}
            try Data().write(to: root.appendingPathComponent(".nc2-estimate-release"))
            XCTAssertEqual(try Data(contentsOf: source), Data("搜索原文".utf8))
        }
    }

    func testInvalidQueryIsRejectedBeforeConnecting() async throws {
        let client = try SFTPClient(profile: .init(name: "test", host: "invalid.example"), controlPath: "/tmp/not-connected")
        defer { client.cancel() }
        for query in ["", "a\0b"] {
            do { _ = try await client.search(directory: "/", query: query, includeHidden: false); XCTFail("应拒绝无效查询") }
            catch { XCTAssertTrue(error.localizedDescription.contains("搜索名称")) }
        }
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProfileError("等待搜索状态超时")
    }
}
