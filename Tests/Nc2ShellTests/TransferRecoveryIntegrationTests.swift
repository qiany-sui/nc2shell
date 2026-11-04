import XCTest
import AppKit
import Combine
import Nc2ShellCore
@testable import Nc2Shell

final class TransferRecoveryIntegrationTests: XCTestCase {
    @MainActor
    private func connected() async throws -> (TerminalSession, RemoteFilesModel, TransferRecoveryManager, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "续传验收", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start(); try await eventually { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("recovery-app-\(UUID())")
        for name in ["local", "remote", "downloads"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let manager = TransferRecoveryManager(store: TransferRecoveryStore(directoryURL: root.appendingPathComponent("records")))
        let model = RemoteFilesModel(conflictPresenter: { _, _, reply in reply(.skip, false); return {} })
        model.configureRecovery(manager, profile: profile)
        model.connect(profile: profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        return (session, model, manager, root)
    }

    @MainActor
    func testQueuedMixedUploadSurvivesRecreatedModelAndIsOnlyExecutedOnce() async throws {
        let (session, model, manager, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("local/one.txt"), directory = root.appendingPathComponent("local/资料")
        try Data("one".utf8).write(to: a)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: directory.appendingPathComponent("二.txt"))
        model.upload([a, directory], expectedPath: model.path, connectionID: model.connectionID)
        let item = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(item.id)
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.roots.count, 2)
        XCTAssertThrowsError(try manager.acquire(record.id, profile: session.profile))
        model.disconnect()
        try await eventually { manager.activeIDs.isEmpty }
        let relaunched = TransferRecoveryManager(store: manager.store)
        let restored = RemoteFilesModel(conflictPresenter: { _, _, reply in reply(.skip, false); return {} })
        restored.configureRecovery(relaunched, profile: session.profile)
        restored.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        defer { restored.disconnect() }
        try await eventually { restored.canTransfer }
        restored.recoverTransfer(record.id)
        restored.recoverTransfer(record.id)
        XCTAssertEqual(restored.transferItems.count, 1)
        try await eventually { restored.transferItems.first?.state == .completed }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/one.txt")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/资料/二.txt")), Data("nested".utf8))
        XCTAssertTrue(try manager.store.load().isEmpty)
    }

    @MainActor
    func testActiveUploadDisconnectThenNewSessionResumesPartialContent() async throws {
        let (session, model, manager, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/large.bin")
        let content = Data(repeating: 0x6A, count: 2_097_152)
        try content.write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        let item = try XCTUnwrap(model.transferItems.first)
        var stopped = false
        let observation = item.$bytes.sink { bytes in
            if bytes > 0, !stopped { stopped = true; model.disconnect() }
        }
        defer { observation.cancel() }
        try await eventually { stopped && manager.activeIDs.isEmpty }
        XCTAssertEqual(item.state, .failed)
        let record = try XCTUnwrap(manager.pendingRecords.first)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        try await eventually { model.canTransfer }
        model.recoverTransfer(record.id)
        try await eventually { model.transferItems.last?.state == .completed }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/large.bin")), content)
        XCTAssertGreaterThan(try XCTUnwrap(model.transferItems.last).reusedBytes, 0)
    }

    @MainActor
    func testFinderRequestedPendingTargetsPersistAndRecoveryRequiresOriginalDestination() async throws {
        let (session, model, manager, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let blocking = root.appendingPathComponent("local/block.bin")
        try Data(repeating: 1, count: 1_048_576).write(to: blocking)
        for name in ["a.txt", "b.txt", "never-requested.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent("remote/" + name)) }
        model.refresh(); try await eventually { model.canTransfer }
        let files = model.files
        let promises = files.compactMap { model.promiseProvider(for: $0) as? RemoteDownloadPromise }
        RemoteDownloadPromise.group(promises)
        model.upload([blocking], expectedPath: model.path, connectionID: model.connectionID)
        model.pauseTransfer(try XCTUnwrap(model.transferItems.first).id)
        var callbacks = [0, 0]
        for index in 0..<2 {
            promises[index].filePromiseProvider(promises[index], writePromiseTo: root.appendingPathComponent("downloads/" + files[index].name)) { error in
                XCTAssertNotNil(error); callbacks[index] += 1
            }
        }
        try await eventually { manager.records.filter { $0.direction == .download }.count == 2 }
        XCTAssertEqual(manager.records.count, 3)
        model.disconnect()
        try await eventually { manager.activeIDs.isEmpty && callbacks == [1, 1] }
        let download = try XCTUnwrap(manager.pendingRecords.first { $0.direction == .download })
        XCTAssertTrue(download.requiresDestinationConfirmation)
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        try await eventually { model.canTransfer }
        let before = model.transferItems.count
        model.recoverTransfer(download.id)
        XCTAssertEqual(model.transferItems.count, before)
        model.recoverTransfer(download.id, confirmedDestination: root.appendingPathComponent("downloads/wrong.txt"))
        XCTAssertEqual(model.transferItems.count, before)
        model.recoverTransfer(download.id, confirmedDestination: URL(fileURLWithPath: download.roots[0].localPath))
        try await eventually { model.transferItems.last?.state == .completed }
        XCTAssertEqual(callbacks, [1, 1])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: download.roots[0].localPath)), Data((download.roots[0].remotePath as NSString).lastPathComponent.utf8))
        XCTAssertFalse(try manager.store.load().contains { $0.id == download.id })
    }

    @MainActor
    func testRecoveryRejectsChangedAccountAndPersistenceFailurePreventsStarting() async throws {
        let (session, model, manager, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/a.txt")
        try Data([1]).write(to: source)
        let record = RecoverableTransfer(account: TransferRecoveryAccount(profile: session.profile), name: "a", direction: .upload,
                                        roots: [.init(localPath: source.path, remotePath: root.appendingPathComponent("remote/a.txt").path)])
        try manager.store.save(record); manager.refresh()
        var changed = session.profile; changed.username = "other"
        model.disconnect()
        model.connect(profile: changed, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        model.recoverTransfer(record.id)
        XCTAssertTrue(model.transferItems.isEmpty)
        XCTAssertNotNil(model.error)
        model.disconnect()
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        let taskURL = manager.store.checkpointURL(for: record.id).deletingLastPathComponent().appendingPathComponent("task.json")
        try Data("broken".utf8).write(to: taskURL)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID)
        XCTAssertTrue(model.transferItems.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote/a.txt").path))
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "等待条件超时")
        if !condition() { throw ProfileError("等待条件超时") }
    }
}
