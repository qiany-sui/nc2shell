import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class TerminalIntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let port: Int
        let key: String
        let knownHosts: String
        let directory: String
    }

    private func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 integration-smoke.py 才会启用隔离 SSH 联调")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-terminal-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func makeSession(_ fixture: Fixture, profile: ConnectionProfile? = nil) -> TerminalSession {
        TerminalSession(profile: profile ?? .init(name: "隔离终端", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key), directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, path in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] +
                (try SSHCommand.arguments(profile: profile, controlPath: path))
        }
    }

    @MainActor
    func testCompactPromptKeepsFullDirectoryAndStartupFilesAcrossReconnect() async throws {
        let fixture = try fixture(), base = URL(fileURLWithPath: fixture.directory)
        let deep = base.appendingPathComponent("prompt-\(UUID())/one/two/output/html")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for zsh in [false, true] {
            let file = base.appendingPathComponent(zsh ? ".zshrc" : ".bash_profile")
            let original = try Data(contentsOf: file)
            defer { try? original.write(to: file) }
            let prompt = zsh ? #"PROMPT='%F{green}PROMPT<%~>%f '"# : #"PS1='\[\e[32m\]PROMPT<\w>\[\e[0m\] '"#
            let configured = original + Data(("\n" + prompt + "\ncd " + ShellIntegration.quote(deep.path) + "\n").utf8)
            try configured.write(to: file)
            let session = makeSession(fixture, profile: .init(name: "短路径", host: "127.0.0.1", port: fixture.port,
                                                             username: zsh ? "zsh-test" : "key-test", identityFile: fixture.key))
            defer { session.disconnect() }
            for _ in 0..<2 {
                session.start()
                try await eventually { session.state == .connected && session.files.locationValidated && session.files.path == deep.path }
                try await eventually { self.output(session).range(of: #"PROMPT<(~/)?\.\.\./output/html>"#, options: .regularExpression) != nil }
                XCTAssertEqual(session.remoteDirectory?.path, deep.path)
                session.terminal.send(txt: "pwd\rfalse\rprintf 'STATUS_%s\\n' $?\r")
                // 提示符缩短不影响 pwd；长输出仍会按终端列宽换行。
                try await eventually { self.output(session).contains("STATUS_1") && self.output(session).replacingOccurrences(of: "\n", with: "").contains(deep.path) }
                XCTAssertEqual(try Data(contentsOf: file), configured, "启动与重连不能改写远端配置")
                session.disconnect()
                try await eventually { !session.isRunning }
            }
        }
    }

    @MainActor
    func testCloseProfileConfirmsOnceCancelsTransferAndKeepsOtherLiveConnection() async throws {
        let fixture = try fixture(), root = try temporaryDirectory()
        let settings = TransferSettingsController(store: .init(fileURL: root.appendingPathComponent("transfers.json")))
        XCTAssertTrue(settings.save(.init(uploadLimitKiB: 1)))
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             transferSettings: settings, sessionFactory: { self.makeSession(fixture, profile: $0) })
        let profile = ConnectionProfile(name: "同名连接", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let other = ConnectionProfile(name: profile.name, host: profile.host, port: profile.port, username: profile.username, identityFile: profile.identityFile)
        model.save(profile); model.save(other)
        let first = model.connect(profile)
        let second = try XCTUnwrap(model.split(.columns))
        let third = model.connect(profile)
        let survivor = model.connect(other)
        defer { model.disconnectAll() }
        try await eventually { model.sessions.allSatisfy { $0.state == .connected } && first.files.locationValidated && !first.files.isLoading }
        let before = model.sessions.map(\.id), workspaces = model.workspaces.map(\.id)
        var confirmations = 0
        model.closeConnections(profile) { title, detail, _ in
            confirmations += 1
            XCTAssertTrue(title.contains(profile.name))
            XCTAssertTrue(detail.contains("3"))
            return false
        }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(model.sessions.map(\.id), before)
        XCTAssertEqual(model.workspaces.map(\.id), workspaces)
        XCTAssertTrue(model.sessions.allSatisfy { $0.state == .connected })
        let upload = root.appendingPathComponent("close-\(UUID()).bin")
        try Data(repeating: 42, count: 512 * 1024).write(to: upload)
        first.files.upload([upload], expectedPath: first.files.path, connectionID: first.files.connectionID, revision: first.files.locationRevision)
        try await eventually { first.files.isTransferring }
        let survivorPID = survivor.process?.shellPid
        model.closeConnections(profile) { _, _, _ in confirmations += 1; return true }
        XCTAssertEqual(confirmations, 2, "整组关闭只再确认一次")
        try await eventually { model.sessions.count == 1 && !first.files.isTransferring }
        XCTAssertTrue(model.sessions.first === survivor)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(survivor.process?.shellPid, survivorPID)
        XCTAssertFalse(first.isRunning || second.isRunning || third.isRunning)
        XCTAssertFalse(first.files.isConnected)
        XCTAssertEqual(try store.load(), [profile, other])
        survivor.terminal.send(txt: "printf 'OTHER_%s\\n' SURVIVED\r")
        try await eventually { self.output(survivor).contains("OTHER_SURVIVED") }
    }

    @MainActor
    func testCloseProfileCancelsPendingAutomaticReconnect() async throws {
        let fixture = try fixture(), root = try temporaryDirectory()
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { self.makeSession(fixture, profile: $0) })
        let profile = ConnectionProfile(name: "待重连", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key, autoReconnect: true)
        let session = model.connect(profile)
        defer { model.disconnectAll() }
        try await eventually { session.state == .connected }
        session.terminal.send(txt: "exit 255\r")
        try await eventually { session.state == .reconnecting }
        let endedProcess = session.process
        var confirmations = 0
        model.closeConnections(profile) { _, _, _ in confirmations += 1; return true }
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.workspaces.isEmpty)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertFalse(session.process?.running == true)
        XCTAssertTrue(session.process === endedProcess, "取消后不能再次创建 SSH 进程")
    }

    @MainActor
    func testSplitKeepsLiveSSHAndDirectoryStateIndependentAcrossFocusTabsAndClose() async throws {
        let fixture = try fixture(), root = try temporaryDirectory()
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { self.makeSession(fixture, profile: $0) })
        let profile = ConnectionProfile(name: "隔离终端", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key)
        let first = model.connect(profile)
        let second = try XCTUnwrap(model.split(.columns)), workspaceID = try XCTUnwrap(model.selectedWorkspace?.id)
        defer { model.disconnectAll() }
        try await eventually { first.state == .connected && second.state == .connected && first.files.locationValidated && second.files.locationValidated }
        let firstPID = first.process?.shellPid, secondPID = second.process?.shellPid
        XCTAssertNotEqual(firstPID, secondPID)
        XCTAssertNotEqual(first.controlPath, second.controlPath)
        first.terminal.send(txt: "cd 'My Files'\r")
        try await eventually { first.files.path == fixture.directory + "/My Files" && first.files.locationValidated }
        XCTAssertEqual(second.files.path, fixture.directory)
        model.focus(first.id)
        XCTAssertTrue(model.selectedSession?.files === first.files)
        model.focus(second.id)
        XCTAssertTrue(model.selectedSession?.files === second.files)
        let third = model.connect(profile)
        try await eventually { third.state == .connected }
        model.selectWorkspace(workspaceID)
        _ = model.split(.rows)
        XCTAssertEqual(first.process?.shellPid, firstPID)
        XCTAssertEqual(second.process?.shellPid, secondPID)
        XCTAssertEqual(first.files.path, fixture.directory + "/My Files")
        second.disconnect()
        try await eventually { !second.isRunning }
        model.close(second)
        XCTAssertTrue(model.selectedSession === first)
        XCTAssertNil(model.selectedWorkspace?.secondarySessionID)
        first.terminal.send(txt: "printf 'SURVIVING_%s\\n' CONNECTION\r")
        try await eventually { self.output(first).contains("SURVIVING_CONNECTION") }
        model.disconnectAll()
        try await eventually { !model.hasRunningSessions }
    }

    @MainActor
    func testBehaviorPreferencesSurviveFirstStartLiveUpdateManualAndAutomaticReconnect() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "终端行为", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.key, autoReconnect: true)
        let session = makeSession(fixture, profile: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalPreferences())) as? [String: Any])
        json["scrollbackLines"] = 50_000
        json["optionAsMetaKey"] = false
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        session.applyPreferences(preferences)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected }
        XCTAssertEqual(session.terminal.getTerminal().options.scrollback, 50_000)
        XCTAssertFalse(session.terminal.optionAsMetaKey)
        let view = session.terminal, process = session.process
        json["scrollbackLines"] = 5_000
        json["optionAsMetaKey"] = true
        session.applyPreferences(try JSONDecoder().decode(TerminalPreferences.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertTrue(session.terminal === view)
        XCTAssertTrue(session.process === process)
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
        XCTAssertTrue(view.optionAsMetaKey)
        session.disconnect()
        try await eventually { !session.isRunning }
        session.start()
        try await eventually { session.state == .connected }
        XCTAssertFalse(session.terminal === view)
        XCTAssertEqual(session.terminal.getTerminal().options.scrollback, 5_000)
        XCTAssertTrue(session.terminal.optionAsMetaKey)
        session.applyPreferences(preferences)
        let beforeAutomatic = session.process
        session.terminal.send(txt: "exit 255\r")
        try await eventually { session.state == .connected && session.process !== beforeAutomatic }
        XCTAssertEqual(session.terminal.getTerminal().options.scrollback, 50_000)
        XCTAssertFalse(session.terminal.optionAsMetaKey)
        session.terminal.send(txt: "printf 'BEHAVIOR_%s\\n' READY\r")
        try await eventually { self.output(session).contains("BEHAVIOR_READY") }
    }

    @MainActor
    func testManualLogOnlyCapturesRemoteOutputAndStopsAcrossDisconnectAndReconnect() async throws {
        let fixture = try fixture(), root = try temporaryDirectory(), session = makeSession(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && session.files.locationValidated }
        // 关闭回显的 read 模拟密码式输入，测试数据不是真实凭据。
        session.terminal.send(txt: "stty -echo; printf 'READY_%s\\n' FOR_INPUT; IFS= read -r answer; if [ \"$answer\" = 'nonsecret-test-input' ]; then printf '\\033[32m远端_%s\\033[0m\\n' 完成; else printf 'WRONG_INPUT\\n'; fi; stty echo\r")
        try await eventually { self.output(session).contains("READY_FOR_INPUT") }
        let file = root.appendingPathComponent("remote.log")
        try session.startLogging(to: file)
        session.showFind()
        session.searchText = "SEARCH_MUST_STAY_LOCAL"
        session.showFind(.next)
        session.showFind(.previous)
        session.terminal.send(txt: "nonsecret-test-input\r")
        try await eventually { self.output(session).contains("远端_完成") }
        session.stopLogging()
        let firstLog = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(firstLog.contains("远端_完成"))
        XCTAssertFalse(firstLog.contains("nonsecret-test-input"))
        XCTAssertFalse(firstLog.contains("SEARCH_MUST_STAY_LOCAL"))
        XCTAssertFalse(firstLog.contains("\u{1b}"))
        session.terminal.send(txt: "printf 'AFTER_%s\\n' STOP\r")
        try await eventually { self.output(session).contains("AFTER_STOP") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), firstLog)
        XCTAssertThrowsError(try session.startLogging(to: file))
        XCTAssertEqual(session.state, .connected)
        let disconnectFile = root.appendingPathComponent("disconnect.log")
        try session.startLogging(to: disconnectFile)
        let oldProcess = try XCTUnwrap(session.process)
        let oldDelegate = SessionProcessDelegate(owner: session)
        oldDelegate.process = oldProcess
        session.disconnect()
        XCTAssertNil(session.logURL)
        try await eventually { !session.isRunning }
        let stopped = try Data(contentsOf: disconnectFile)
        session.start()
        try await eventually { session.state == .connected }
        XCTAssertNil(session.logURL)
        oldDelegate.dataReceived(slice: Array("STALE_OUTPUT_MUST_BE_IGNORED".utf8)[...])
        oldDelegate.processTerminated(oldProcess, exitCode: 0)
        session.terminal.send(txt: "printf 'NEW_%s\\n' SESSION\r")
        try await eventually { self.output(session).contains("NEW_SESSION") }
        XCTAssertEqual(session.state, .connected)
        XCTAssertFalse(output(session).contains("STALE_OUTPUT_MUST_BE_IGNORED"))
        XCTAssertEqual(try Data(contentsOf: disconnectFile), stopped)
        session.disconnect()
        try await eventually { !session.isRunning }
    }

    @MainActor private func output(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    @MainActor
    func testLogIncludesFinalLargeOutputBeforeImmediateRemoteExit() async throws {
        let fixture = try fixture(), root = try temporaryDirectory(), session = makeSession(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && session.files.locationValidated }
        let file = root.appendingPathComponent("tail.log")
        try session.startLogging(to: file)
        session.terminal.send(txt: "printf 'TAIL_%s\\n' START; /usr/bin/awk 'BEGIN { for (i=0;i<1048576;i++) printf \"x\" }'; printf '\\nTAIL_%s\\n' END; exit\r")
        try await eventually { !session.isRunning }
        try await eventually { self.output(session).contains("TAIL_END") }
        XCTAssertNil(session.logURL)
        let log = try String(contentsOf: file, encoding: .utf8)
        let begin = try XCTUnwrap(log.range(of: "TAIL_START\r\n"))
        let end = try XCTUnwrap(log.range(of: "TAIL_END\r\n"), "日志字节 \(log.utf8.count)，日志尾部 \(String(log.suffix(100)))；终端尾部 \(String(output(session).suffix(100)))")
        XCTAssertEqual(log[begin.upperBound..<end.lowerBound].utf8.count, 1_048_578)
    }

    @MainActor
    func testMissingPTYEOFStopsWithExplicitIncompleteOutputError() async throws {
        // DispatchIO 的异常结束不保证把 childfd 置 -1；只替换这个外部边界，进程仍真实启动并退出。
        let session = TerminalSession(profile: .init(name: "隔离退出", host: "example.invalid"), outputHasEnded: { _ in false },
                                      directoryBookmarks: self.makeTestDirectoryBookmarks(), argumentBuilder: { _, _ in ["-V"] })
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .disconnecting }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        session.dataReceived(slice: Array("仍在排空的输出\n".utf8)[...])
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertTrue(session.isRunning, "新字节必须延后空闲截止，不能按总时长截断输出")
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.statusText.contains("末尾输出"))
        XCTAssertNil(session.process)
    }

    @MainActor private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待隔离终端状态超时", file: file, line: line)
        throw NSError(domain: "TerminalIntegrationTimeout", code: 1)
    }
}
