import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class TransferConflictModelTests: XCTestCase {
    @MainActor
    private func connected(present: @escaping TransferConflictPrompt.Presenter) async throws -> (TerminalSession, RemoteFilesModel, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "冲突面板测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start()
        try await eventually { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("conflict-model-\(UUID())")
        for name in ["remote", "local", "next"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let model = RemoteFilesModel(conflictPresenter: present)
        model.connect(profile: profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        return (session, model, root)
    }

    @MainActor
    func testBatchDownloadSkipsConflictsAndContinuesWithAccurateSummary() async throws {
        var prompts = 0
        let (session, model, root) = try await connected { _, _, reply in prompts += 1; reply(.skip, true); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt", "c.txt"] { try Data("remote".utf8).write(to: root.appendingPathComponent("remote/" + name)) }
        for name in ["a.txt", "b.txt"] { try Data("keep".utf8).write(to: root.appendingPathComponent("local/" + name)) }
        model.refresh(); try await eventually { model.canTransfer }
        model.download(model.files, into: root.appendingPathComponent("local"), expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { model.canTransfer && model.message?.contains("3/3") == true }
        XCTAssertNil(model.error); XCTAssertEqual(prompts, 1)
        XCTAssertTrue(model.message?.contains("跳过 2") == true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local/a.txt")), "keep")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local/b.txt")), "keep")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local/c.txt")), "remote")
    }

    @MainActor
    func testUploadConflictKeepsSourceDirectoryWhileFollowingChanges() async throws {
        var reply: TransferConflictPrompt.Reply?
        let (session, model, root) = try await connected { _, _, respond in reply = respond; return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/a.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: root.appendingPathComponent("remote/a.txt"))
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { reply != nil }
        model.follow(root.appendingPathComponent("next").path)
        try XCTUnwrap(reply)(.keepBoth, false)
        try await eventually { model.canTransfer }
        XCTAssertEqual(model.path, root.appendingPathComponent("next").path)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("remote/a.txt")), "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("remote/a (2).txt")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next/a.txt").path))
    }

    @MainActor
    func testFinderConflictKeepsGivenTargetAndDisconnectCompletesEachPromiseOnce() async throws {
        var reply: TransferConflictPrompt.Reply?
        var closes = 0
        let (session, model, root) = try await connected { _, conflict, respond in
            XCTAssertFalse(conflict.canKeepBoth)
            reply = respond
            return { closes += 1 }
        }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] {
            try Data("remote".utf8).write(to: root.appendingPathComponent("remote/" + name))
            try Data("local".utf8).write(to: root.appendingPathComponent("local/" + name))
        }
        model.refresh(); try await eventually { model.canTransfer }
        let promises = try model.files.map { try XCTUnwrap(model.promiseProvider(for: $0) as? RemoteDownloadPromise) }
        RemoteDownloadPromise.group(promises)
        var callbacks = [0, 0]
        for (index, promise) in promises.enumerated() {
            let name = index == 0 ? "a.txt" : "b.txt"
            promise.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("local/" + name)) { error in
                XCTAssertNotNil(error); callbacks[index] += 1
            }
        }
        try await eventually { reply != nil }
        let staleReply = try XCTUnwrap(reply)
        model.disconnect()
        try await eventually { callbacks == [1, 1] }
        staleReply(.replace, true)
        XCTAssertEqual(callbacks, [1, 1]); XCTAssertEqual(closes, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local/a.txt")), "local")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local/b.txt")), "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local/a (2).txt").path))
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Nc2Shell.ConflictModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待测试条件超时"])
    }
}
