import XCTest
import AppKit
import UniformTypeIdentifiers
import Nc2ShellCore
@testable import Nc2Shell

final class TransferQueueTests: XCTestCase {
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
    func testAcceptsAnotherUploadWhileConflictWaitsAndKeepsCapturedTarget() async throws {
        var reply: TransferConflictPrompt.Reply?
        let (session, model, root) = try await connected { _, _, respond in reply = respond; return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("local/first.txt")
        let second = root.appendingPathComponent("local/second.txt")
        try Data("first new".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("old".utf8).write(to: root.appendingPathComponent("remote/first.txt"))
        model.upload([first], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { reply != nil }
        model.upload([second], expectedPath: model.path, connectionID: model.connectionID)
        model.follow(root.appendingPathComponent("next").path)
        try XCTUnwrap(reply)(.skip, false)
        try await eventually { model.canTransfer }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/second.txt").path), "传输期间新任务必须被排队执行")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next/second.txt").path))
    }

    @MainActor
    func testPauseResumeAndNavigationKeepQueuedPathsAndAllowNewDirectoryUploads() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("local/a.bin"), b = root.appendingPathComponent("local/b.txt"), c = root.appendingPathComponent("local/c.txt")
        try Data(repeating: 7, count: 1_048_576).write(to: a)
        try Data([2]).write(to: b); try Data([3]).write(to: c)
        model.upload([a], expectedPath: model.path, connectionID: model.connectionID)
        let first = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(first.id)
        model.upload([b], expectedPath: model.path, connectionID: model.connectionID)
        XCTAssertTrue(model.canEnqueue); XCTAssertFalse(model.canTransfer)
        XCTAssertEqual(model.transferItems.map(\.state), [.paused, .queued])
        model.browse(root.appendingPathComponent("next").path)
        try await eventually { model.canEnqueue }
        model.upload([c], expectedPath: model.path, connectionID: model.connectionID)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(first.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/a.bin").path))
        model.resumeTransfer(first.id)
        try await eventually { model.canTransfer }
        XCTAssertEqual(model.transferItems.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/a.bin")), Data(repeating: 7, count: 1_048_576))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/b.txt")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("next/c.txt")), Data([3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next/b.txt").path))
    }

    @MainActor
    func testFailedRetryIsNewTaskKeepsOriginalTargetAndReconnectCannotRetryOldWork() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/missing.txt")
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { model.canTransfer }
        let failed = try XCTUnwrap(model.transferItems.first)
        XCTAssertEqual(failed.state, .failed)
        try Data("recovered".utf8).write(to: source)
        model.browse(root.appendingPathComponent("next").path)
        try await eventually { model.canTransfer }
        model.retryTransfer(failed.id)
        try await eventually { model.canTransfer }
        XCTAssertEqual(model.transferItems.map(\.state), [.failed, .completed])
        XCTAssertNotEqual(model.transferItems[0].id, model.transferItems[1].id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("remote/missing.txt")), "recovered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next/missing.txt").path))
        model.disconnect()
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        XCTAssertFalse(model.canRetry(failed))
        model.retryTransfer(failed.id)
        XCTAssertEqual(model.transferItems.count, 2)
    }

    @MainActor
    func testCancelQueuedFinderGroupCompletesEveryCallbackOnceWithoutReusingPromise() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data([1]).write(to: root.appendingPathComponent("remote/" + name)) }
        let source = root.appendingPathComponent("local/block.bin")
        try Data(repeating: 2, count: 1_048_576).write(to: source)
        model.refresh(); try await eventually { model.canTransfer }
        let promises = try model.files.map { try XCTUnwrap(model.promiseProvider(for: $0) as? RemoteDownloadPromise) }
        RemoteDownloadPromise.group(promises)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        let upload = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(upload.id)
        var callbacks = [0, 0]
        for (index, promise) in promises.enumerated() {
            promise.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("local/finder-\(index).txt")) { error in
                XCTAssertNotNil(error); callbacks[index] += 1
            }
        }
        try await eventually { model.transferItems.count == 2 }
        let waiting = model.transferItems[1]
        model.cancelQueuedTransfer(waiting.id)
        try await eventually { callbacks == [1, 1] }
        XCTAssertEqual(waiting.state, .cancelled); XCTAssertFalse(model.canRetry(waiting))
        model.resumeTransfer(upload.id)
        try await eventually { model.canTransfer }
        XCTAssertEqual(callbacks, [1, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local/finder-0.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local/finder-1.txt").path))
    }

    @MainActor
    func testDisconnectWakesPausedTaskAndFailsWaitingTasksWithoutResumingOnReconnect() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/a.bin")
        try Data(repeating: 2, count: 1_048_576).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(try XCTUnwrap(model.transferItems.first).id)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        model.disconnect()
        try await eventually { model.transferItems.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(model.transferItems.map(\.state), [.failed, .failed])
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/a.bin").path))
        XCTAssertFalse(model.transferItems.contains { model.canRetry($0) })
    }

    @MainActor
    func testDropParsingRejectsDirectoryRoundTripWhileAnotherTransferIsPaused() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/drop.txt")
        try Data([2]).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        let first = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(first.id)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { completion(source.dataRepresentation, nil) }
            return nil
        }
        XCTAssertTrue(model.uploadDroppedItems([provider]))
        model.browse(root.appendingPathComponent("next").path)
        try await eventually { model.locationValidated }
        model.browse(root.appendingPathComponent("remote").path)
        try await eventually { model.locationValidated && !model.isPreparingUpload }
        XCTAssertEqual(model.transferItems.count, 1, "拖入解析尚未完成时目录切走再切回也必须拒绝")
        XCTAssertNotNil(model.error)
        model.cancelQueuedTransfer(first.id)
        try await eventually { model.canTransfer }
    }

    @MainActor
    func testRunningPauseStopsProgressAndCancelAllowsNextQueuedTask() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("local/large.bin"), next = root.appendingPathComponent("local/next.txt")
        try Data(repeating: 5, count: 8 * 1_048_576).write(to: large); try Data([8]).write(to: next)
        model.upload([large], expectedPath: model.path, connectionID: model.connectionID)
        let first = try XCTUnwrap(model.transferItems.first)
        try await eventually { first.bytes > 0 }
        model.pauseTransfer(first.id)
        model.upload([next], expectedPath: model.path, connectionID: model.connectionID)
        try await Task.sleep(nanoseconds: 200_000_000)
        let pausedBytes = first.bytes
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(first.bytes, pausedBytes); XCTAssertEqual(first.bytesPerSecond, 0)
        model.cancelQueuedTransfer(first.id)
        try await eventually { model.canTransfer }
        XCTAssertEqual(model.transferItems.map(\.state), [.cancelled, .completed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/large.bin").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/next.txt")), Data([8]))
        XCTAssertTrue(first.detail?.contains(".nc2shell-upload-") == true)
    }

    @MainActor
    func testQueuedPauseDoesNotBlockOtherModelAndCancellingHeadStartsNext() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        let other = RemoteFilesModel()
        defer { other.disconnect(); model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        other.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("next").path)
        try await eventually { other.canTransfer }
        let a = root.appendingPathComponent("local/a.txt"), b = root.appendingPathComponent("local/b.txt"), c = root.appendingPathComponent("local/c.txt")
        for source in [a, b, c] { try Data([1]).write(to: source) }
        model.upload([a], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(try XCTUnwrap(model.transferItems.first).id)
        model.upload([b], expectedPath: model.path, connectionID: model.connectionID)
        let head = model.transferItems[1]
        model.pauseTransfer(head.id)
        model.upload([c], expectedPath: model.path, connectionID: model.connectionID)
        other.upload([a], expectedPath: other.path, connectionID: other.connectionID)
        try await eventually { other.canTransfer }
        XCTAssertEqual(other.transferItems[0].state, .completed)
        model.resumeTransfer(model.transferItems[0].id)
        try await eventually { model.transferItems[0].state == .completed }
        XCTAssertFalse(model.canTransfer)
        model.createDirectory("must-not-create", expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/must-not-create").path))
        model.cancelQueuedTransfer(head.id)
        try await eventually { model.canTransfer }
        XCTAssertEqual(model.transferItems.map(\.state), [.completed, .cancelled, .completed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/b.txt").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/c.txt")), Data([1]))
    }

    @MainActor
    func testRelocateUsesFileOperationLockAndReportsSkippedItemsAccurately() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.skip, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data([4]).write(to: root.appendingPathComponent("remote/" + name)) }
        try Data([9]).write(to: root.appendingPathComponent("next/a.txt"))
        model.refresh(); try await eventually { model.canTransfer }
        let oldRevision = model.locationRevision, selected = model.files, source = model.path
        model.refresh(); try await eventually { model.canTransfer }
        model.relocate(selected, toDirectory: root.appendingPathComponent("next").path, copy: true,
                       expectedPath: source, connectionID: model.connectionID, revision: oldRevision)
        XCTAssertFalse(model.isManagingFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next/b.txt").path))
        model.relocate(model.files, toDirectory: root.appendingPathComponent("next").path, copy: true,
                       expectedPath: source, connectionID: model.connectionID, revision: model.locationRevision)
        XCTAssertTrue(model.isManagingFiles); XCTAssertFalse(model.canEnqueue)
        model.follow(root.appendingPathComponent("next").path)
        try await eventually { model.canTransfer }
        XCTAssertTrue(model.message?.contains("已处理 2/2") == true)
        XCTAssertTrue(model.message?.contains("跳过 1") == true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("next/a.txt")), Data([9]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("next/b.txt")), Data([4]))
        XCTAssertEqual(model.path, root.appendingPathComponent("next").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/b.txt").path))
    }

    @MainActor
    func testConflictCancelIsCancelledForOrdinaryTransferAndFinderWithoutRetry() async throws {
        let (session, model, root) = try await connected { _, _, reply in reply(.cancel, false); return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/a.txt"), remote = root.appendingPathComponent("remote/a.txt")
        try Data([1]).write(to: source); try Data([2]).write(to: remote)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { model.canTransfer }
        let upload = try XCTUnwrap(model.transferItems.first)
        XCTAssertEqual(upload.state, .cancelled, "用户在冲突框取消不应显示为失败")
        XCTAssertFalse(model.canRetry(upload))
        let file = try XCTUnwrap(model.files.first { $0.name == "a.txt" })
        let promise = try XCTUnwrap(model.promiseProvider(for: file) as? RemoteDownloadPromise)
        var callbacks = 0
        promise.filePromiseProvider(promise, writePromiseTo: source) { error in
            XCTAssertNotNil(error); callbacks += 1
        }
        try await eventually { callbacks == 1 && model.canTransfer }
        XCTAssertEqual(model.transferItems.last?.state, .cancelled)
        XCTAssertFalse(model.canRetry(try XCTUnwrap(model.transferItems.last)))
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
        XCTAssertEqual(try Data(contentsOf: remote), Data([2]))
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
