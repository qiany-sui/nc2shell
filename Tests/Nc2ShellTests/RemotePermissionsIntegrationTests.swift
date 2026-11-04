import XCTest
import Darwin
import Nc2ShellCore
@testable import Nc2Shell

final class RemotePermissionsIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, SFTPClient, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 scripts/integration-smoke.py 启用隔离 SSH 联调")
        }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "权限测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] +
                (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        try await wait { session.state == .connected }
        let client = try SFTPClient(profile: profile, controlPath: XCTUnwrap(session.controlPath))
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("permissions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (session, client, root)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待权限测试条件超时")
        throw SFTPError.message("测试超时")
    }

    private func item(_ client: SFTPClient, _ url: URL) async throws -> RemoteFile {
        let listing = try await client.list(path: url.deletingLastPathComponent().path)
        return try XCTUnwrap(listing.files.first { $0.name == url.lastPathComponent })
    }

    private func mode(_ url: URL) throws -> UInt32 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return UInt32(info.st_mode) & 0o7777
    }

    @MainActor
    func testPermissionWritePreservesContentTimeChildrenAndSpecialBits() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("中文 '文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("文件\nname")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(chmod(folder.path, 0o1755), 0)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        let original = try await item(client, file)
        try await client.setPermissions(original, in: folder.path, permissions: 0o604)
        XCTAssertEqual(try mode(file), 0o604)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        let updated = try await item(client, file)
        XCTAssertEqual(updated.modifiedTime, original.modifiedTime)
        try await client.setPermissions(try await item(client, folder), in: root.path, permissions: 0o750)
        XCTAssertEqual(try mode(folder), 0o1750)
        XCTAssertEqual(try mode(file), 0o604, "目录权限不可递归影响子项")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }

    @MainActor
    func testInvalidInputChangedSnapshotAndSymbolicAliasCannotChangePermissions() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let original = try await item(client, file)
        do { try await client.setPermissions(original, in: root.path, permissions: 0o4755); XCTFail("不能设置特殊位") } catch {}
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        do { try await client.setPermissions(original, in: root.path, permissions: 0o777); XCTFail("属性变化必须拒绝") } catch {}
        XCTAssertEqual(try mode(file), 0o640)
        let originalAgain = try await item(client, file)
        let target = root.appendingPathComponent("target")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        for selected in [originalAgain, try await item(client, file)] {
            do { try await client.setPermissions(selected, in: root.path, permissions: 0o777); XCTFail("不能修改链接目标") } catch {}
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        do { try await client.setPermissions(try await item(client, target), in: alias.path, permissions: 0o777); XCTFail("拒绝父目录别名") } catch {}
        XCTAssertEqual(try mode(target), 0o640)
    }

    @MainActor
    func testDeniedOrIgnoredPermissionWriteNeverReportsSuccess() async throws {
        let (session, client, root) = try await connected()
        defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["nc2-permissions-denied", "nc2-permissions-ignored"] {
            let file = root.appendingPathComponent(name)
            try Data([9]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            do { try await client.setPermissions(try await item(client, file), in: root.path, permissions: 0o644); XCTFail("不能误报成功") }
            catch { XCTAssertTrue(error.localizedDescription.contains(file.path)) }
            XCTAssertEqual(try mode(file), 0o600)
            XCTAssertEqual(try Data(contentsOf: file), Data([9]))
            // 无变化时不应发送 SETSTAT，服务器拒绝写入也不影响此操作。
            try await client.setPermissions(try await item(client, file), in: root.path, permissions: 0o600)
        }
    }

    @MainActor
    func testCancelAndDisconnectAfterActualChangeReportUnknownResult() async throws {
        for disconnect in [false, true] {
            let (session, client, root) = try await connected()
            defer { client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("nc2-permissions-delay")
            try Data([9]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            let selected = try await item(client, file)
            let task = Task { try await client.setPermissions(selected, in: root.path, permissions: 0o644) }
            try await wait { (try? self.mode(file)) == 0o644 }
            if disconnect { session.disconnect() } else { client.cancel() }
            do { try await task.value; XCTFail("响应丢失不能显示成功") }
            catch { XCTAssertTrue(error.localizedDescription.contains("可能已生效")); XCTAssertTrue(error.localizedDescription.contains(file.path)) }
            XCTAssertEqual(try mode(file), 0o644)
            XCTAssertEqual(try Data(contentsOf: file), Data([9]))
        }
    }

    @MainActor
    func testModelRejectsStaleConfirmationInvalidInputAndOtherOperations() async throws {
        let (session, client, root) = try await connected()
        let model = RemoteFilesModel()
        defer { model.disconnect(); client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.txt")
        try Data([4]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        try await wait { model.canManageFiles }
        let selected = try XCTUnwrap(model.files.first { $0.name == "model.txt" })
        let oldRevision = model.locationRevision
        model.refresh(); try await wait { model.canManageFiles }
        for (directory, connection, revision) in [(root.path, model.connectionID, oldRevision),
                                                   (root.path + "/other", model.connectionID, model.locationRevision),
                                                   (root.path, UUID(), model.locationRevision)] {
            model.setPermissions(selected, to: "777", expectedPath: directory, connectionID: connection, revision: revision)
            XCTAssertFalse(model.isManagingFiles); XCTAssertNotNil(model.error)
            XCTAssertEqual(try mode(file), 0o600)
        }
        model.setPermissions(selected, to: "888", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        XCTAssertFalse(model.isManagingFiles); XCTAssertNotNil(model.error)
        let otherOperation = UUID()
        XCTAssertTrue(TransferPathReservations.shared.acquireExclusive(id: otherOperation))
        model.setPermissions(selected, to: "777", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        XCTAssertFalse(model.isManagingFiles); XCTAssertEqual(try mode(file), 0o600)
        TransferPathReservations.shared.release(id: otherOperation)
        model.setPermissions(selected, to: "640", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await wait { model.canManageFiles }
        XCTAssertNil(model.error); XCTAssertEqual(try mode(file), 0o640)
        XCTAssertEqual(model.files.first?.mode ?? 0, 0o100640)
    }

    @MainActor
    func testModelKeepsPermissionFailureVisibleAfterRefresh() async throws {
        let (session, client, root) = try await connected()
        let model = RemoteFilesModel()
        defer { model.disconnect(); client.cancel(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nc2-permissions-denied")
        try Data([4]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        try await wait { model.canManageFiles }
        model.setPermissions(try XCTUnwrap(model.files.first), to: "644", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await wait { model.canManageFiles }
        XCTAssertNotNil(model.error); XCTAssertNil(model.message)
        XCTAssertTrue(model.error?.contains(file.path) == true)
        XCTAssertEqual(try mode(file), 0o600)
    }
}
