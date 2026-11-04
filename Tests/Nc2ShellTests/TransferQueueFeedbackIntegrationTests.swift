import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class TransferQueueFeedbackIntegrationTests: XCTestCase {
    @MainActor
    private func connected(present: @escaping TransferConflictPrompt.Presenter = { _, _, reply in reply(.skip, false); return {} }) async throws -> (TerminalSession, RemoteFilesModel, URL) {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        let fixture = try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let profile = ConnectionProfile(name: "传输反馈测试", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.start()
        try await eventually { session.state == .connected }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("queue-feedback-\(UUID())")
        for name in ["remote", "local", "download"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let model = RemoteFilesModel(conflictPresenter: present)
        model.connect(profile: profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer }
        return (session, model, root)
    }

    @MainActor
    func testMixedUploadEstimateWaitAndSkipFinishWithActualBytesThenDownloadEstimatesDirectories() async throws {
        var reply: TransferConflictPrompt.Reply?
        let (session, model, root) = try await connected { _, _, respond in reply = respond; return {} }
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("local/目录"), file = root.appendingPathComponent("local/skip.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4, 5]).write(to: folder.appendingPathComponent("nested"))
        try Data([6, 7, 8]).write(to: file)
        try Data([9, 9, 9]).write(to: root.appendingPathComponent("remote/skip.txt"))
        model.upload([folder, file], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        let upload = try XCTUnwrap(model.transferItems.first)
        XCTAssertTrue(upload.isEstimating)
        try await eventually { reply != nil }
        XCTAssertEqual(upload.estimatedTotalBytes, 8)
        XCTAssertTrue(upload.isWaitingForConflict)
        XCTAssertNil(upload.remainingTime())
        try XCTUnwrap(reply)(.skip, false)
        try await eventually { model.canTransfer }
        XCTAssertEqual(upload.state, .completed)
        XCTAssertEqual(upload.bytes, 5)
        XCTAssertTrue(upload.detail?.contains("跳过 1") == true)
        model.download(model.files, into: root.appendingPathComponent("download"), expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        let download = try XCTUnwrap(model.transferItems.last)
        XCTAssertEqual(download.estimatedTotalBytes, 8)
        XCTAssertEqual(download.bytes, 8)
        XCTAssertEqual(download.state, .completed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download/目录/nested")), Data([1, 2, 3, 4, 5]))
    }

    @MainActor
    func testClearRemovesOnlySuccessAndRetryReestimatesMissingSource() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("local/good"), missing = root.appendingPathComponent("local/missing")
        try Data([1]).write(to: good)
        model.upload([good], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        model.upload([missing], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        let failed = try XCTUnwrap(model.transferItems.last)
        XCTAssertEqual(failed.state, .failed)
        model.upload([good], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        let paused = try XCTUnwrap(model.transferItems.last)
        model.pauseTransfer(paused.id)
        model.upload([good], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        let queued = try XCTUnwrap(model.transferItems.last)
        model.upload([good], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        let cancelled = try XCTUnwrap(model.transferItems.last)
        model.cancelQueuedTransfer(cancelled.id)
        model.clearCompletedTransfers()
        XCTAssertEqual(model.transferItems.map(\.id), [failed.id, paused.id, queued.id, cancelled.id])
        XCTAssertEqual(model.transferItems.map(\.state), [.failed, .paused, .queued, .cancelled])
        XCTAssertTrue(model.canRetry(failed))
        try Data([1, 2, 3, 4]).write(to: missing)
        model.retryTransfer(failed.id)
        model.cancelQueuedTransfer(paused.id)
        try await eventually { model.canTransfer }
        let retried = try XCTUnwrap(model.transferItems.last)
        XCTAssertEqual(retried.state, .completed)
        XCTAssertEqual(retried.estimatedTotalBytes, 4)
        XCTAssertEqual(retried.bytes, 4)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/missing")), Data([1, 2, 3, 4]))
        model.clearCompletedTransfers()
        XCTAssertEqual(model.transferItems.map(\.state), [.failed, .cancelled, .cancelled])
    }

    @MainActor
    func testClearingInsideFinderCallbackKeepsLaterRequestsAndExactlyOnceCompletions() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try Data([1, 2]).write(to: root.appendingPathComponent("remote/" + name)) }
        model.refresh(); try await eventually { model.canTransfer }
        let promises = try model.files.sorted { $0.name < $1.name }.map { try XCTUnwrap(model.promiseProvider(for: $0) as? RemoteDownloadPromise) }
        RemoteDownloadPromise.group(promises)
        var callbacks = [0, 0]
        for (index, promise) in promises.enumerated() {
            promise.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("download/finder-\(index)")) { error in
                XCTAssertNil(error)
                XCTAssertEqual(model.transferItems.last?.estimatedTotalBytes, 2)
                callbacks[index] += 1
                model.clearCompletedTransfers()
            }
        }
        try await eventually { callbacks == [1, 1] && model.canTransfer }
        XCTAssertTrue(model.transferItems.isEmpty)
        for index in 0..<2 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download/finder-\(index)")), Data([1, 2])) }
        model.clearCompletedTransfers()
        XCTAssertEqual(callbacks, [1, 1])
    }

    @MainActor
    func testDisconnectWhileStatisticsPausedCannotPublishIntoReconnectedQueue() async throws {
        let (session, model, root) = try await connected()
        defer { model.disconnect(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local/source")
        try Data([1, 2, 3]).write(to: source)
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        let old = try XCTUnwrap(model.transferItems.first)
        model.pauseTransfer(old.id)
        XCTAssertTrue(old.isEstimating)
        model.disconnect()
        model.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.appendingPathComponent("remote").path)
        try await eventually { model.canTransfer && old.state.isFinished }
        model.upload([source], expectedPath: model.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        XCTAssertEqual(old.state, .failed)
        XCTAssertNil(old.estimatedTotalBytes)
        XCTAssertEqual(old.bytes, 0)
        XCTAssertEqual(model.transferItems.last?.bytes, 3)
        XCTAssertEqual(model.transferItems.last?.state, .completed)
        model.clearCompletedTransfers()
        XCTAssertEqual(model.transferItems.map(\.id), [old.id])
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("等待传输反馈条件超时")
        throw NSError(domain: "Nc2Shell.TransferFeedback", code: 1)
    }
}
