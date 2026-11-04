import XCTest
@testable import Nc2ShellCore

final class TransferRecoveryStoreTests: XCTestCase {
    func testMissingStoreIsReadOnlyUntilFirstSave() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        XCTAssertEqual(try store.load(), [])
        let id = UUID()
        XCTAssertEqual(store.checkpointURL(for: id), root.appendingPathComponent(id.uuidString).appendingPathComponent("checkpoint.json"))
        try store.remove(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMultipleTasksRoundTripAcrossStoreInstancesWithoutCredentialFields() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let profile = ConnectionProfile(name: "服务器", host: "example.test", port: 2222, username: "nc", identityFile: "/private/key-must-not-persist", rememberPassword: true)
        let first = transfer(profile: profile, localPath: "/本地/a \"\n.txt", remotePath: "/远程/a \"\n.txt", createdAt: Date(timeIntervalSince1970: 1))
        let second = RecoverableTransfer(account: first.account, name: "下载目录", direction: .download,
                                         roots: [.init(localPath: "/目标/目录", remotePath: "/来源/目录", allowRootRename: false),
                                                 .init(localPath: "/目标/b", remotePath: "/来源/b")],
                                         requiresDestinationConfirmation: true, createdAt: Date(timeIntervalSince1970: 2))
        try store.save(second)
        try store.save(first)
        XCTAssertEqual(try TransferRecoveryStore(directoryURL: root).load(), [first, second])
        let json = try String(contentsOf: taskURL(first.id, in: root), encoding: .utf8)
        for secretField in ["identityFile", "rememberPassword", "key-must-not-persist", "password"] {
            XCTAssertFalse(json.contains(secretField))
        }
        let updated = RecoverableTransfer(id: second.id, account: second.account, name: second.name,
                                          direction: .download, roots: second.roots,
                                          requiresDestinationConfirmation: false, createdAt: second.createdAt)
        try store.save(updated)
        XCTAssertEqual(try store.load(), [first, updated])
    }

    func testAccountMatchRequiresConnectionIDHostPortAndUsername() {
        let profile = ConnectionProfile(name: "服务器", host: "example.test", username: "nc")
        let account = TransferRecoveryAccount(profile: profile)
        var renamed = profile
        renamed.name = "新名称"
        renamed.identityFile = "/new/key"
        renamed.rememberPassword = true
        XCTAssertTrue(account.matches(renamed))
        var changed = profile
        changed.id = UUID()
        XCTAssertFalse(account.matches(changed))
        changed = profile
        changed.host = "other.test"
        XCTAssertFalse(account.matches(changed))
        changed = profile
        changed.port = 2222
        XCTAssertFalse(account.matches(changed))
        changed = profile
        changed.username = "other"
        XCTAssertFalse(account.matches(changed))
    }

    func testInvalidLocalAndRemotePathsCannotReplaceExistingTask() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let original = transfer()
        try store.save(original)
        for path in ["", "relative/file", " /wrong", "/bad\0path", "/safe/../other", "/safe/./file"] {
            let badLocal = transfer(id: original.id, localPath: path)
            let badRemote = transfer(id: original.id, remotePath: path)
            XCTAssertThrowsError(try store.save(badLocal), path)
            XCTAssertThrowsError(try store.save(badRemote), path)
            XCTAssertEqual(try store.load(), [original])
        }
    }

    func testInvalidAccountAndEmptyRootsAreRejected() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        for profile in [ConnectionProfile(name: "服务器", host: "-host"),
                        ConnectionProfile(name: "服务器", host: "example.test", port: 0),
                        ConnectionProfile(name: "服务器", host: "example.test", username: "bad user")] {
            XCTAssertThrowsError(try store.save(transfer(profile: profile)))
        }
        let empty = RecoverableTransfer(account: transfer().account, name: "空任务", direction: .upload, roots: [])
        XCTAssertThrowsError(try store.save(empty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMalformedOrSemanticallyInvalidTaskCannotBeOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let original = transfer()
        try store.save(original)
        let file = taskURL(original.id, in: root)
        let malformedPath = try JSONEncoder().encode(transfer(id: original.id, remotePath: "/safe/../outside"))
        let wrongID = try JSONEncoder().encode(transfer())
        for data in [Data("broken json".utf8), malformedPath, wrongID] {
            try data.write(to: file)
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertTrue(error.localizedDescription.contains(file.path))
            }
            XCTAssertThrowsError(try store.save(original))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testUnreadableTaskCannotBeOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let value = transfer()
        try store.save(value)
        let file = taskURL(value.id, in: root)
        let bytes = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(value))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testWriteFailureIsReportedWithoutLosingSavedRecord() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let value = transfer()
        try store.save(value)
        let folder = taskURL(value.id, in: root).deletingLastPathComponent()
        let before = try Data(contentsOf: taskURL(value.id, in: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try store.save(value))
        XCTAssertEqual(try Data(contentsOf: taskURL(value.id, in: root)), before)
    }

    func testRemoveOnlyDeletesDescriptorAndPreservesCheckpointAndLocalFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root.appendingPathComponent("records"))
        let local = root.appendingPathComponent("user-file")
        let value = transfer(localPath: local.path)
        try store.save(value)
        let bytes = Data("用户内容".utf8)
        let checkpoint = Data("checkpoint-owned-by-another-module".utf8)
        try bytes.write(to: local)
        try checkpoint.write(to: store.checkpointURL(for: value.id))
        try store.remove(value.id)
        try store.remove(value.id)
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try Data(contentsOf: store.checkpointURL(for: value.id)), checkpoint)
    }

    func testSymlinkedTaskDirectoryOrDescriptorCannotRedirectStorage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root.appendingPathComponent("records"))
        let value = transfer()
        try store.save(value)
        let file = taskURL(value.id, in: store.directoryURL)
        let outside = root.appendingPathComponent("outside.json")
        let bytes = try Data(contentsOf: file)
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(value))
        XCTAssertThrowsError(try store.remove(value.id))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        let outsideDirectory = root.appendingPathComponent("outside-directory")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try bytes.write(to: outsideDirectory.appendingPathComponent("task.json"))
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: outsideDirectory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(value))
        XCTAssertThrowsError(try store.remove(value.id))
        XCTAssertEqual(try Data(contentsOf: outsideDirectory.appendingPathComponent("task.json")), bytes)
    }

    private func transfer(id: UUID = UUID(), profile: ConnectionProfile = ConnectionProfile(name: "服务器", host: "example.test", username: "nc"),
                          localPath: String = "/local/file", remotePath: String = "/remote/file", createdAt: Date = Date(timeIntervalSince1970: 1)) -> RecoverableTransfer {
        RecoverableTransfer(id: id, account: TransferRecoveryAccount(profile: profile), name: "传输任务", direction: .upload,
                            roots: [.init(localPath: localPath, remotePath: remotePath)], createdAt: createdAt)
    }

    private func taskURL(_ id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("task.json")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-recovery-\(UUID().uuidString)")
    }
}
