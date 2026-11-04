import XCTest
import Combine
import Nc2ShellCore
@testable import Nc2Shell

final class ParallelTransferIntegrationTests: XCTestCase {
    @MainActor
    private func connected(conflictPresenter: TransferConflictPrompt.Presenter? = nil) async throws -> (TerminalSession, RemoteFilesModel, TransferSettingsController, TransferRecoveryManager, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "并行验收", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start(); try await eventually { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("parallel-app-\(UUID())")
        for name in ["local", "remote", "downloads", "second"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let settings = TransferSettingsController(store: .init(fileURL: root.appendingPathComponent("settings.json")))
        var preferences = settings.preferences; preferences.uploadLimitKiB = 512
        XCTAssertTrue(settings.save(preferences))
        let recovery = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let model = RemoteFilesModel(conflictPresenter: conflictPresenter ?? { _, _, reply in reply(.skip, false); return {} })
        model.configureTransferSettings(settings)
        model.configureRecovery(recovery, profile: profile)
        model.connect(profile: profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        return (session, model, settings, recovery, root)
    }

    @MainActor
    func testTwoUploadsAdvanceAndCancellingOneDoesNotStopOther() async throws {
        let (session, model, _, recovery, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("local/a.bin"), b = root.appendingPathComponent("local/b.bin")
        let data = Data(repeating: 7, count: 1_048_576)
        try data.write(to: a); try data.write(to: b)
        model.upload([a], expectedPath: model.path, connectionID: model.connectionID)
        model.upload([b], expectedPath: model.path, connectionID: model.connectionID)
        let first = model.transferItems[0], second = model.transferItems[1]
        try await eventually { first.bytes > 0 && second.bytes > 0 && !first.state.isFinished && !second.state.isFinished }
        model.cancelQueuedTransfer(first.id)
        try await eventually { first.state == .cancelled && second.state == .completed && recovery.activeIDs.isEmpty }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/b.bin")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/a.bin").path))
        XCTAssertEqual(recovery.pendingRecords.count, 1)
    }

    @MainActor
    func testConcurrencyChangeKeepsRunningSlotsAndPausedTask() async throws {
        let (session, model, settings, _, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            let source = root.appendingPathComponent("local/" + name)
            try Data([1, 2, 3]).write(to: source)
            model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
            if name != "c" { model.pauseTransfer(try XCTUnwrap(model.transferItems.last).id) }
        }
        XCTAssertEqual(model.transferItems.map(\.state), [.paused, .paused, .queued])
        var preferences = settings.preferences; preferences.maxConcurrentTransfers = 1
        XCTAssertTrue(settings.save(preferences))
        model.resumeTransfer(model.transferItems[0].id)
        try await eventually { model.transferItems[0].state == .completed }
        XCTAssertEqual(model.transferItems[1].state, .paused)
        XCTAssertEqual(model.transferItems[2].state, .queued)
        preferences.maxConcurrentTransfers = 2; XCTAssertTrue(settings.save(preferences))
        try await eventually { model.transferItems[2].state == .completed }
        XCTAssertEqual(model.transferItems[1].state, .paused)
        model.cancelQueuedTransfer(model.transferItems[1].id)
        try await eventually { model.canTransfer }
    }

    @MainActor
    func testAnotherModelCannotWriteSameTargetUntilFirstStops() async throws {
        let (session, model, settings, recovery, root) = try await connected()
        let other = RemoteFilesModel(conflictPresenter: { _, _, reply in reply(.skip, false); return {} })
        other.configureTransferSettings(settings); other.configureRecovery(recovery, profile: session.profile)
        other.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: model.path)
        defer { other.disconnect(); model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await eventually { other.canTransfer }
        let a = root.appendingPathComponent("local/same.txt"), b = root.appendingPathComponent("second/same.txt")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        model.upload([a], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(model.transferItems[0].id)
        other.upload([b], expectedPath: other.path, connectionID: other.connectionID)
        XCTAssertEqual(other.transferItems[0].state, .queued)
        model.cancelQueuedTransfer(model.transferItems[0].id)
        try await eventually { other.transferItems[0].state == .completed }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/same.txt")), Data([2]))
    }

    @MainActor
    func testFinderBatchCanFinishWhileIndependentUploadIsPaused() async throws {
        let (session, model, _, recovery, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent("remote/" + name)) }
        model.refresh(); try await eventually { model.canTransfer }
        let promises = try model.files.map { try XCTUnwrap(model.promiseProvider(for: $0) as? RemoteDownloadPromise) }
        RemoteDownloadPromise.group(promises)
        let source = root.appendingPathComponent("local/block.bin"); try Data([4]).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(model.transferItems[0].id)
        var callbacks = [0, 0]
        for (index, promise) in promises.enumerated() {
            promise.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("downloads/\(index).txt")) { error in
                XCTAssertNil(error); callbacks[index] += 1
            }
        }
        try await eventually { callbacks == [1, 1] }
        XCTAssertEqual(model.transferItems[0].state, .paused)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads/0.txt")), Data("a.txt".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads/1.txt")), Data("b.txt".utf8))
        model.cancelQueuedTransfer(model.transferItems[0].id)
        try await eventually { recovery.activeIDs.isEmpty }
        XCTAssertEqual(callbacks, [1, 1])
    }

    @MainActor
    func testDisconnectCancelsBothAndLateCompletionDoesNotCancelNewTask() async throws {
        let (session, model, _, recovery, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.bin", "b.bin"] {
            let source = root.appendingPathComponent("local/" + name)
            try Data(repeating: 5, count: 1_048_576).write(to: source)
            model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        }
        try await eventually { model.transferItems.allSatisfy { $0.bytes > 0 && !$0.state.isFinished } }
        model.disconnect()
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canEnqueue }
        let source = root.appendingPathComponent("local/new.txt"); try Data([9]).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { model.transferItems.last?.state == .completed && recovery.activeIDs.isEmpty }
        XCTAssertEqual(Array(model.transferItems.prefix(2)).map(\.state), [.failed, .failed])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/new.txt")), Data([9]))
    }

    @MainActor
    func testFileManagementWaitsForAnotherModelsWriterToFinish() async throws {
        let (session, model, settings, _, root) = try await connected()
        let other = RemoteFilesModel()
        other.configureTransferSettings(settings)
        other.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: model.path)
        defer { other.disconnect(); model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await eventually { other.canManageFiles }
        let source = root.appendingPathComponent("local/a.txt"); try Data([1]).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(model.transferItems[0].id)
        XCTAssertFalse(other.canManageFiles)
        other.createDirectory("blocked", expectedPath: other.path, connectionID: other.connectionID, revision: other.locationRevision)
        XCTAssertNotNil(other.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/blocked").path))
        model.cancelQueuedTransfer(model.transferItems[0].id)
        try await eventually { other.canManageFiles }
        other.createDirectory("allowed", expectedPath: other.path, connectionID: other.connectionID, revision: other.locationRevision)
        try await eventually { other.canManageFiles }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/allowed").path))
    }

    @MainActor
    func testParallelConflictsPresentInOrderAndCancelOnlyTheirOwnTask() async throws {
        var presented: [TransferConflict] = []
        var replies: [(TransferConflictChoice, Bool) -> Void] = []
        let (session, model, _, recovery, root) = try await connected(conflictPresenter: { _, conflict, reply in
            presented.append(conflict); replies.append(reply); return {}
        })
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] {
            let source = root.appendingPathComponent("local/" + name)
            try Data("new".utf8).write(to: source)
            try Data("old".utf8).write(to: root.appendingPathComponent("remote/" + name))
            model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        }
        try await eventually { model.transferItems.allSatisfy(\.isWaitingForConflict) }
        XCTAssertEqual(presented.count, 1)
        let firstName = URL(fileURLWithPath: try XCTUnwrap(presented.first).sourcePath).lastPathComponent
        let first = try XCTUnwrap(model.transferItems.first { $0.name == firstName })
        model.cancelQueuedTransfer(first.id)
        try await eventually { presented.count == 2 && first.state == .cancelled }
        replies[1](.keepBoth, false)
        try await eventually { model.transferItems.allSatisfy { $0.state.isFinished } && recovery.activeIDs.isEmpty }
        let secondName = URL(fileURLWithPath: presented[1].sourcePath).lastPathComponent
        XCTAssertEqual(model.transferItems.first { $0.name == secondName }?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/" + firstName)), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/" + secondName)), Data("old".utf8))
        let kept = (secondName as NSString).deletingPathExtension + " (2).txt"
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/" + kept)), Data("new".utf8))
    }

    @MainActor
    func testDisconnectedRowsCannotReleaseRecoveryOrFinderBeforeWritersFinish() async throws {
        let (session, model, settings, recovery, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        var preferences = settings.preferences; preferences.uploadLimitKiB = 64; preferences.downloadLimitKiB = 64
        XCTAssertTrue(settings.save(preferences))
        let data = Data(repeating: 1, count: 1_048_576)
        try data.write(to: root.appendingPathComponent("local/upload.bin"))
        try data.write(to: root.appendingPathComponent("remote/download.bin"))
        model.refresh(); try await eventually { model.canTransfer }
        let file = try XCTUnwrap(model.files.first { $0.name == "download.bin" })
        let promise = try XCTUnwrap(model.promiseProvider(for: file) as? RemoteDownloadPromise)
        var callbacks = 0
        promise.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("downloads/download.bin")) { error in
            XCTAssertNotNil(error); callbacks += 1
        }
        model.upload([root.appendingPathComponent("local/upload.bin")], expectedPath: model.path, connectionID: model.connectionID)
        try await eventually { model.transferItems.count == 2 && model.transferItems.allSatisfy { $0.bytes > 0 && !$0.state.isFinished } }
        let items = model.transferItems
        let recoveryIDs = Set(items.compactMap(\.recoveryID))
        XCTAssertEqual(recovery.activeIDs, recoveryIDs)
        model.disconnect()
        for item in items {
            model.pauseTransfer(item.id)
            model.resumeTransfer(item.id)
            model.cancelQueuedTransfer(item.id)
        }
        // 同一个主线程回合尚未归还异步操作，任何行操作都不能提前宣告清理结束。
        XCTAssertEqual(recovery.activeIDs, recoveryIDs)
        XCTAssertEqual(callbacks, 0)
        try await eventually { recovery.activeIDs.isEmpty && callbacks == 1 && items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(items.map(\.state), [.failed, .failed])
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "等待条件超时")
        if !condition() { throw ProfileError("等待条件超时") }
    }
}
