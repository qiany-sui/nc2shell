import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class AutoReconnectIntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let port: Int
        let key: String
        let knownHosts: String
        let directory: String
    }

    private func fixture() throws -> Fixture {
        guard let file = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离SSH服务") }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    }

    @MainActor
    private func connected(autoReconnect: Bool = true) async throws -> (TerminalSession, TransferRecoveryManager, URL, URL) {
        let fixture = try fixture()
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("reconnect-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let knownHosts = root.appendingPathComponent("known_hosts")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture.knownHosts), to: knownHosts)
        let configuration = root.appendingPathComponent("ssh_config")
        try Data().write(to: configuration)
        let initial = ConnectionProfile(name: "重连验收", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        object["autoReconnect"] = autoReconnect
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
        let recovery = TransferRecoveryManager(store: .init(directoryURL: root.appendingPathComponent("recovery")))
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", configuration.path, "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=ask", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        session.files.configureRecovery(recovery, profile: profile)
        session.start()
        try await eventually { session.state == .connected && session.files.canEnqueue }
        return (session, recovery, root, URL(fileURLWithPath: fixture.directory).appendingPathComponent("disconnect-key-test"))
    }

    @MainActor
    func testUnexpectedDisconnectReconnectsOnceWithoutReplayingCommandsOrTransfers() async throws {
        let (session, recovery, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let firstProcess = try XCTUnwrap(session.process), firstControl = session.controlPath
        session.terminal.send(txt: "printf 'BEFORE_%s\\n' DROP\r")
        try await eventually { self.output(session).contains("BEFORE_DROP") }
        let source = root.appendingPathComponent("unfinished-\(UUID()).bin")
        try Data(repeating: 1, count: 1_048_576).write(to: source)
        session.files.upload([source], expectedPath: session.files.path, connectionID: session.files.connectionID, revision: session.files.locationRevision)
        let task = try XCTUnwrap(session.files.transferItems.first)
        session.files.pauseTransfer(task.id)
        try Data().write(to: trigger)
        try await eventually(timeout: 8) { session.state == .connected && session.process !== firstProcess }
        XCTAssertNotEqual(session.controlPath, firstControl)
        try await eventually { session.files.canEnqueue && recovery.activeIDs.isEmpty }
        XCTAssertEqual(task.state, .failed)
        XCTAssertEqual(session.files.transferItems.count, 1)
        XCTAssertEqual(recovery.pendingRecords.count, 1)
        XCTAssertEqual(output(session).components(separatedBy: "BEFORE_DROP").count - 1, 1)
        XCTAssertNil(session.logURL)
        let secondProcess = session.process
        try Data().write(to: trigger)
        try await eventually { !session.isRunning }
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.process === secondProcess)
    }

    @MainActor
    func testReconnectResetsFullScreenModesAndUnfinishedControlSequencesButKeepsText() async throws {
        for suffix in ["", "\\033]0;unfinished", "\\033Punfinished"] {
            let (session, _, root, trigger) = try await connected()
            defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
            session.terminal.send(txt: "printf 'OLD_%s\\n' CONTEXT; printf '\\033[?1049h\\033[?25l\\033[?1000h\\033[?1hFULL_SCREEN\(suffix)'; sleep 20\r")
            try await eventually { session.terminal.getTerminal().isCurrentBufferAlternate && self.output(session).contains("FULL_SCREEN") }
            let old = session.process
            try Data().write(to: trigger)
            try await eventually { session.state == .connected && session.process !== old }
            XCTAssertFalse(session.terminal.getTerminal().isCurrentBufferAlternate)
            XCTAssertFalse(session.terminal.getTerminal().applicationCursor)
            XCTAssertEqual(session.terminal.getTerminal().mouseMode, .off)
            session.terminal.send(txt: "printf 'AFTER_%s\\n' RESET\r")
            try await eventually { self.output(session).contains("AFTER_RESET") }
            XCTAssertTrue(output(session).contains("OLD_CONTEXT"))
            XCTAssertTrue(output(session).contains("FULL_SCREEN"))
        }
    }

    @MainActor
    func testAutomaticReconnectStopsBeforeLaunchingConfiguredProxy() async throws {
        for setting in ["ProxyJump password-test@127.0.0.1:1", "ProxyCommand /usr/bin/false", "Match exec \"/bin/test -t 2\"\n  ProxyCommand /usr/bin/false"] {
            let (session, _, root, trigger) = try await connected()
            defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let original = session.process
            try Data("Host *\n  \(setting)\n".utf8).write(to: root.appendingPathComponent("ssh_config"))
            try Data().write(to: trigger)
            try await eventually { !session.isRunning }
            XCTAssertEqual(session.state, .failed)
            XCTAssertTrue(session.process === original, "无法约束代理链时不能启动自动尝试，也不能绕过代理直连")
            XCTAssertTrue(session.statusText.contains("代理") || session.statusText.contains("动态配置"))
            XCTAssertTrue(session.statusText.contains("手动"))
        }
    }

    @MainActor
    func testCancelDuringConfigurationCheckPreventsLateConnection() async throws {
        let (session, _, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let original = session.process
        let pidFile = root.appendingPathComponent("configuration-pid")
        try Data("Match exec \"echo $$ > '\(pidFile.path)'; exec /bin/sleep 20\"\n  ServerAliveInterval 15\n".utf8).write(to: root.appendingPathComponent("ssh_config"))
        try Data().write(to: trigger)
        try await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) } }
        session.disconnect()
        try await eventually { kill(childPID, 0) == -1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertTrue(session.process === original)
    }

    @MainActor
    func testConfigurationTimeoutReapsItsChildAndDoesNotStartConnection() async throws {
        let (session, _, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let original = session.process, pidFile = root.appendingPathComponent("timeout-pid")
        try Data("Match exec \"echo $$ > '\(pidFile.path)'; exec /bin/sleep 20\"\n  ServerAliveInterval 15\n".utf8).write(to: root.appendingPathComponent("ssh_config"))
        try Data().write(to: trigger)
        try await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) } }
        try await eventually { !session.isRunning && kill(childPID, 0) == -1 }
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.statusText.contains("超时"))
        XCTAssertTrue(session.process === original)
    }

    @MainActor
    func testCancellingWaitPreventsLateAutomaticStart() async throws {
        let (session, recovery, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        try Data().write(to: trigger)
        try await eventually { session.statusText.contains("自动重连") && session.isRunning }
        session.disconnect()
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertTrue(recovery.activeIDs.isEmpty)
    }

    @MainActor
    func testOrdinaryShellExitsAndManualDisconnectNeverScheduleRetry() async throws {
        for code in [0, 1, 254] {
            let (session, _, root, _) = try await connected()
            defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
            let original = session.process
            session.terminal.send(txt: "exit \(code)\r")
            try await eventually { !session.isRunning }
            try await Task.sleep(nanoseconds: 3_200_000_000)
            XCTAssertFalse(session.isRunning)
            XCTAssertTrue(session.process === original)
            XCTAssertEqual(session.state, code == 0 ? .disconnected : .failed)
        }
        let (session, _, root, _) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        session.disconnect()
        try await eventually { !session.isRunning }
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(session.state, .disconnected)
    }

    @MainActor
    func testDisabledOptionKeepsUnexpectedDisconnectStopped() async throws {
        let (session, _, root, trigger) = try await connected(autoReconnect: false)
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let original = session.process
        try Data().write(to: trigger)
        try await eventually { !session.isRunning }
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.process === original)
    }

    @MainActor
    func testAutomaticAttemptDoesNotAskToTrustUnknownHost() async throws {
        let (session, _, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        let original = session.process
        try Data().write(to: trigger)
        try await eventually { session.state == .reconnecting }
        try Data().write(to: root.appendingPathComponent("known_hosts"))
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertFalse(session.process === original)
        XCTAssertTrue(output(session).contains("Host key verification failed"))
        XCTAssertFalse(output(session).contains("continue connecting"))
    }

    @MainActor
    func testFirstAuthenticationFailureDoesNotRetry() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "拒绝认证", host: "127.0.0.1", port: fixture.port, username: "denied-test", identityFile: fixture.key, autoReconnect: true)
        let session = TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, control in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: control))
        }
        defer { session.disconnect() }
        session.start()
        let original = session.process
        try await eventually { !session.isRunning }
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.process === original)
    }

    @MainActor
    func testExit255UsesDocumentedErrorCodeBoundaryAndManualStartRenewsOneAttempt() async throws {
        let (session, _, root, _) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<2 {
            let original = session.process
            session.terminal.send(txt: "exit 255\r")
            try await eventually { session.state == .connected && session.process !== original }
            session.disconnect()
            try await eventually { !session.isRunning }
            session.start()
            try await eventually { session.state == .connected }
        }
    }

    @MainActor
    func testDisconnectAllCancelsWaitingSessionAndNotifiesExit() async throws {
        let (session, recovery, root, trigger) = try await connected()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        session.disconnect(); try await eventually { !session.isRunning }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), recovery: recovery,
                             sessionFactory: { _ in session })
        _ = model.connect(session.profile)
        try await eventually { session.state == .connected }
        try Data().write(to: trigger)
        try await eventually { session.state == .reconnecting }
        XCTAssertTrue(model.hasRunningSessions)
        var replies = 0
        model.onAllSessionsEnded = { replies += 1 }
        model.disconnectAll()
        try await eventually { !model.hasActiveWork }
        XCTAssertEqual(replies, 1)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertFalse(model.hasRunningSessions)
        XCTAssertEqual(session.state, .disconnected)
    }

    @MainActor private func output(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    @MainActor private func eventually(timeout: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(predicate(), "等待重连状态超时")
        if !predicate() { throw ProfileError("等待重连状态超时") }
    }
}
