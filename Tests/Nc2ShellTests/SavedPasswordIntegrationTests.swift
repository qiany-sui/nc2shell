import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class SavedPasswordIntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let port: Int
        let knownHosts: String
        let wrongKnownHosts: String
        let password: String
        let directory: String
        let encryptedKey: String
        let keyPassphrase: String
    }

    private func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("通过 integration-smoke.py 启用隔离 SSH 与随机钥匙串验证")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private var executable: URL {
        if let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_ASKPASS_EXECUTABLE"] {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/Nc2Shell").resolvingSymlinksInPath()
    }

    @MainActor
    private func session(_ fixture: Fixture, profile: ConnectionProfile, hostFile: String? = nil, strict: String = "yes", credentials: ConnectionCredentials = KeychainCredentials()) -> TerminalSession {
        TerminalSession(profile: profile, askpassExecutable: executable, credentials: credentials, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(hostFile ?? fixture.knownHosts)",
             "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=\(strict)",
             "-o", "IdentityAgent=none", "-o", "PubkeyAuthentication=no"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
    }

    @MainActor
    private func temporaryPasswordModel(_ fixture: Fixture, root: URL) -> AppModel {
        let credentials = NoKeychainCredentials()
        return AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                        settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                        credentials: credentials,
                        sessionFactory: { self.session(fixture, profile: $0, credentials: credentials) })
    }

    @MainActor
    func testEditorPasswordLogsInReconnectsAndSplitsWithoutPersistence() async throws {
        let fixture = try fixture()
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("temporary-password-\(UUID())")
        let model = temporaryPasswordModel(fixture, root: root)
        var profile = ConnectionProfile(name: "Temporary", host: "127.0.0.1", port: fixture.port, username: "password-test")
        model.save(profile, password: fixture.password)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(try XCTUnwrap(model.profiles.first).rememberPassword)
        let persisted = try Data(contentsOf: root.appendingPathComponent("connections.json"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(fixture.password))
        defer { model.sessions.forEach { $0.disconnect() } }
        let first = model.connect(profile)
        try await eventually(timeout: 5) { first.state == .connected }
        let split = try XCTUnwrap(model.split(.columns))
        try await eventually { split.state == .connected }
        first.disconnect()
        try await eventually { !first.isRunning }
        first.start()
        try await eventually { first.state == .connected }
        XCTAssertFalse(output(first).contains(fixture.password))

        profile.name = "Renamed"
        model.save(profile)
        let renamed = model.connect(profile)
        try await eventually { renamed.state == .connected }

        let reloaded = temporaryPasswordModel(fixture, root: root)
        let manual = reloaded.connect(try XCTUnwrap(reloaded.profiles.first))
        defer { manual.disconnect() }
        try await eventually { self.output(manual).contains("password:") }
        XCTAssertEqual(manual.state, .connecting)
        manual.terminal.send(txt: fixture.password + "\r")
        try await eventually { manual.state == .connected }

        first.disconnect()
        try await eventually { !first.isRunning }
        first.start(useRememberedPassword: false)
        try await eventually { self.output(first).contains("password:") }
        XCTAssertEqual(first.state, .connecting)
    }

    @MainActor
    func testTemporaryPasswordIsClearedAfterAccountChangeOrDeletion() async throws {
        let fixture = try fixture()
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("temporary-account-\(UUID())")
        let model = temporaryPasswordModel(fixture, root: root)
        let profile = ConnectionProfile(name: "Temporary", host: "127.0.0.1", port: fixture.port, username: "password-test")
        defer { model.sessions.forEach { $0.disconnect() } }
        for change in 0..<4 {
            model.save(profile, password: fixture.password)
            let original = model.connect(profile)
            try await eventually(timeout: 5) { original.state == .connected }
            original.disconnect()
            try await eventually { !original.isRunning }
            if change == 3 { model.deleteConfirmed(profile) }
            else {
                var changed = profile
                switch change {
                case 0: changed.host = "localhost"
                case 1: changed.port = fixture.port + 1
                default: changed.username = "other"
                }
                model.save(changed)
            }
            model.save(profile)
            XCTAssertNil(model.errorMessage)
            let cleared = model.connect(profile)
            try await eventually { self.output(cleared).contains("password:") }
            XCTAssertEqual(cleared.state, .connecting)
            cleared.disconnect()
            try await eventually { !cleared.isRunning }
        }
    }

    @MainActor
    func testSwitchingPasswordStorageDoesNotReviveOldTemporaryPassword() async throws {
        let fixture = try fixture()
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("password-storage-\(UUID())")
        let credentials = KeychainCredentials()
        var profile = ConnectionProfile(name: "Storage switch", host: "127.0.0.1", port: fixture.port, username: "password-test")
        defer { try? credentials.setPassword(nil, for: profile) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             credentials: credentials, sessionFactory: { self.session(fixture, profile: $0) })
        defer { model.sessions.forEach { $0.disconnect() } }
        model.save(profile, password: fixture.password)
        profile.rememberPassword = true
        model.save(profile, password: fixture.password)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try credentials.password(for: profile), fixture.password)
        profile.rememberPassword = false
        model.save(profile)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(try credentials.password(for: profile))
        let cleared = model.connect(profile)
        try await eventually { self.output(cleared).contains("password:") }
        XCTAssertEqual(cleared.state, .connecting)

        let rejecting = temporaryPasswordModel(fixture, root: root.appendingPathComponent("rejecting"))
        defer { rejecting.sessions.forEach { $0.disconnect() } }
        rejecting.save(profile, password: fixture.password)
        var remembered = profile
        remembered.rememberPassword = true
        rejecting.save(remembered, password: fixture.password)
        XCTAssertNotNil(rejecting.errorMessage)
        XCTAssertEqual(rejecting.profiles, [profile])
        let preserved = rejecting.connect(profile)
        try await eventually { preserved.state == .connected }
    }

    @MainActor
    func testFailedSaveKeepsPreviousTemporaryPasswordAndWrongPasswordCanUseManualRecovery() async throws {
        let fixture = try fixture()
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("temporary-save-\(UUID())")
        let model = temporaryPasswordModel(fixture, root: root)
        let profile = ConnectionProfile(name: "Temporary", host: "127.0.0.1", port: fixture.port, username: "password-test")
        let file = root.appendingPathComponent("connections.json")
        model.save(profile, password: fixture.password)
        let goodData = try Data(contentsOf: file)
        try Data("corrupt".utf8).write(to: file)
        model.save(profile, password: UUID().uuidString)
        XCTAssertNotNil(model.errorMessage)
        try goodData.write(to: file)
        defer { model.sessions.forEach { $0.disconnect() } }
        let preserved = model.connect(profile)
        try await eventually(timeout: 5) { preserved.state == .connected }

        let incorrect = UUID().uuidString
        model.errorMessage = nil
        model.save(profile, password: incorrect)
        XCTAssertNil(model.errorMessage)
        let rejected = model.connect(profile)
        try await eventually { !rejected.isRunning }
        XCTAssertEqual(rejected.state, .failed)
        XCTAssertFalse(output(rejected).contains(incorrect))
        rejected.start(useRememberedPassword: false)
        try await eventually { self.output(rejected).contains("password:") }
        rejected.terminal.send(txt: fixture.password + "\r")
        try await eventually { rejected.state == .connected }
        rejected.disconnect()
        try await eventually { !rejected.isRunning }
        model.save(profile, password: fixture.password)
        XCTAssertNil(model.errorMessage)
        rejected.start()
        try await eventually(timeout: 5) { rejected.state == .connected }
    }

    @MainActor
    func testAutomaticReconnectUsesSavedPasswordOnlyOnceAndStopsAfterRejection() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated reconnect password", host: "127.0.0.1", port: fixture.port, username: "password-test", rememberPassword: true, autoReconnect: true)
        let credentials = CountingKeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(fixture.password, for: profile)
        let session = session(fixture, profile: profile, credentials: credentials)
        defer { session.disconnect() }
        session.start()
        try await eventually { session.state == .connected }
        XCTAssertEqual(credentials.readCount, 1)
        let wrongPassword = UUID().uuidString
        try credentials.setPassword(wrongPassword, for: profile)
        try Data().write(to: URL(fileURLWithPath: fixture.directory).appendingPathComponent("disconnect-password-test"))
        try await eventually { session.state == .reconnecting }
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(credentials.readCount, 2)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(credentials.readCount, 2)
        XCTAssertFalse(output(session).contains(wrongPassword))
        XCTAssertFalse(output(session).contains(fixture.password))
    }

    @MainActor
    func testAutomaticReconnectRefusesPrivateKeyPassphraseWithoutWaitingForInput() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated reconnect passphrase", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.encryptedKey, rememberPassword: true, autoReconnect: true)
        let credentials = CountingKeychainCredentials()
        try credentials.setPassword(fixture.password, for: profile)
        defer { try? credentials.setPassword(nil, for: profile) }
        let session = TerminalSession(profile: profile, askpassExecutable: executable, credentials: credentials, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        defer { session.disconnect() }
        session.start()
        try await eventually { self.output(session).contains("Enter passphrase for key") }
        session.terminal.send(txt: fixture.keyPassphrase + "\r")
        try await eventually { session.state == .connected }
        try Data().write(to: URL(fileURLWithPath: fixture.directory).appendingPathComponent("disconnect-key-test"))
        try await eventually { session.state == .reconnecting }
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(credentials.readCount, 0)
        XCTAssertEqual(output(session).components(separatedBy: "Enter passphrase for key").count - 1, 1)
        XCTAssertFalse(output(session).contains(fixture.password))
        XCTAssertFalse(output(session).contains(fixture.keyPassphrase))
    }

    @MainActor
    func testSavedPasswordWaitsForKeychainAuthorizationBeyondFifteenSeconds() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated slow keychain", host: "127.0.0.1", port: fixture.port, username: "password-test", rememberPassword: true)
        let keychain = KeychainCredentials()
        try keychain.setPassword(fixture.password, for: profile)
        defer { try? keychain.setPassword(nil, for: profile) }
        let credentials = DelayedKeychainCredentials(delay: 16.5)
        let session = session(fixture, profile: profile, credentials: credentials)
        defer { session.disconnect() }
        session.start()
        try await eventually(timeout: 25) { credentials.finished }
        try await eventually { session.state == .connected || !session.isRunning }
        XCTAssertEqual(session.state, .connected, "等待用户授权钥匙串不应被本机助手的 15 秒读取超时中断")
        XCTAssertFalse(output(session).contains(fixture.password))
    }

    @MainActor
    func testDisconnectReleasesHelperWhileKeychainAuthorizationIsPending() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated cancelled keychain", host: "127.0.0.1", port: fixture.port, username: "password-test", rememberPassword: true)
        let keychain = KeychainCredentials()
        try keychain.setPassword(fixture.password, for: profile)
        defer { try? keychain.setPassword(nil, for: profile) }
        let gate = DispatchSemaphore(value: 0)
        let credentials = DelayedKeychainCredentials(beforeRead: { gate.wait() })
        let session = session(fixture, profile: profile, credentials: credentials)
        defer { gate.signal(); session.disconnect() }
        session.start()
        try await eventually { credentials.started }
        let sshPID = try XCTUnwrap(session.process?.shellPid)
        // 仅查询本测试 SSH 的直属子进程，确认解除的是实际等待中的 askpass。
        let query = Process(), pipe = Pipe()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        query.arguments = ["-P", String(sshPID)]
        query.standardOutput = pipe
        try query.run()
        query.waitUntilExit()
        let pids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 1)
        session.disconnect()
        try await eventually(timeout: 3) { !session.isRunning && pids.allSatisfy { kill($0, 0) == -1 } }
        XCTAssertFalse(credentials.finished, "停止会话不能等待用户的钥匙串授权")
        gate.signal()
        try await eventually { credentials.finished }
        XCTAssertFalse(output(session).contains(fixture.password))
    }

    @MainActor
    func testRememberedPasswordUsesKeychainAndReconnectsWithoutTerminalInput() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated password test", host: "127.0.0.1", port: fixture.port, username: "password-test", rememberPassword: true)
        let credentials = KeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(fixture.password, for: profile)
        XCTAssertTrue(try credentials.password(for: profile) == fixture.password, "独立钥匙串条目应能读回")
        let session = session(fixture, profile: profile)
        defer { session.disconnect() }
        for _ in 0..<2 {
            session.start()
            try await eventually { session.state == .connected && session.files.locationValidated }
            XCTAssertFalse(output(session).contains(fixture.password), "密码不能出现在终端输出")
            session.disconnect()
            try await eventually { !session.isRunning }
        }
        try credentials.setPassword(nil, for: profile)
        XCTAssertNil(try credentials.password(for: profile))
    }

    @MainActor
    func testWrongSavedPasswordStopsAndManualAuthenticationCanRecover() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated wrong password", host: "127.0.0.1", port: fixture.port, username: "password-attempt-test", rememberPassword: true)
        let credentials = KeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(UUID().uuidString, for: profile)
        let session = session(fixture, profile: profile)
        defer { session.disconnect() }
        session.start()
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.statusText.contains("手动认证"))
        let stats = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture.directory).appendingPathComponent("auth-stats.json"))) as? [String: Any]
        XCTAssertEqual(stats?["passwordAttempts"] as? Int, 1, "错密码只向服务器发送一次")
        session.start(useRememberedPassword: false)
        try await eventually { self.output(session).contains("password:") }
        session.terminal.send(txt: fixture.password + "\r")
        try await eventually { session.state == .connected }
        session.disconnect()
        try await eventually { !session.isRunning }
        try credentials.setPassword(fixture.password, for: profile)
        session.start()
        try await eventually { session.state == .connected }
    }

    @MainActor
    func testRememberedPasswordNeverAnswersLookalikeInteractiveChallenge() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated challenge", host: "127.0.0.1", port: fixture.port, username: "challenge-test", rememberPassword: true, autoReconnect: true)
        let credentials = CountingKeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(fixture.password, for: profile)
        let session = session(fixture, profile: profile, credentials: credentials)
        defer { session.disconnect() }
        session.start()
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        let statsURL = URL(fileURLWithPath: fixture.directory).appendingPathComponent("auth-stats.json")
        var stats = (try? JSONSerialization.jsonObject(with: Data(contentsOf: statsURL))) as? [String: Any] ?? [:]
        XCTAssertNil(stats["interactiveRequests"], "记住模式不接受服务端的任意交互挑战")
        session.start(useRememberedPassword: false)
        try await eventually { self.output(session).contains("password:") }
        session.terminal.send(txt: "manual-challenge\r")
        try await eventually { session.state == .connected }
        stats = try JSONSerialization.jsonObject(with: Data(contentsOf: statsURL)) as? [String: Any] ?? [:]
        XCTAssertEqual(stats["interactiveResponses"] as? Int, 1)
        XCTAssertNil(stats["savedPasswordSentToChallenge"])
        try Data().write(to: URL(fileURLWithPath: fixture.directory).appendingPathComponent("disconnect-challenge-test"))
        try await eventually { session.state == .reconnecting }
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(credentials.readCount, 0, "自动重连不能反向开启之前手动禁用的已保存密码")
        stats = try JSONSerialization.jsonObject(with: Data(contentsOf: statsURL)) as? [String: Any] ?? [:]
        XCTAssertEqual(stats["interactiveResponses"] as? Int, 1, "自动尝试不能再次进入交互挑战")
        XCTAssertNil(stats["savedPasswordSentToChallenge"])
    }

    @MainActor
    func testRememberedAccountPasswordDoesNotAnswerEncryptedPrivateKeyPrompt() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated key passphrase", host: "127.0.0.1", port: fixture.port, username: "key-test", identityFile: fixture.encryptedKey, rememberPassword: true)
        let credentials = KeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(fixture.password, for: profile)
        let session = TerminalSession(profile: profile, askpassExecutable: executable, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
        session.start()
        defer { session.disconnect() }
        try await eventually { self.output(session).contains("Enter passphrase for key") }
        XCTAssertEqual(session.state, .connecting)
        session.terminal.send(txt: fixture.keyPassphrase + "\r")
        try await eventually { session.state == .connected }
        XCTAssertFalse(output(session).contains(fixture.password))
        XCTAssertFalse(output(session).contains(fixture.keyPassphrase))
    }

    @MainActor
    func testRememberedModePreservesUnknownHostConfirmationAndRejectsChangedKey() async throws {
        let fixture = try fixture()
        let profile = ConnectionProfile(name: "Nc2Shell isolated host confirmation", host: "127.0.0.1", port: fixture.port, username: "password-test", rememberPassword: true)
        let credentials = KeychainCredentials()
        defer { try? credentials.setPassword(nil, for: profile) }
        try credentials.setPassword(fixture.password, for: profile)
        let unknown = URL(fileURLWithPath: fixture.directory).appendingPathComponent("remembered-known-\(UUID())")
        let session = session(fixture, profile: profile, hostFile: unknown.path, strict: "ask")
        session.start()
        defer { session.disconnect() }
        try await eventually { self.output(session).contains("continue connecting") }
        XCTAssertEqual(session.state, .connecting)
        session.terminal.send(txt: "yes\r")
        try await eventually { session.state == .connected }
        session.disconnect()
        try await eventually { !session.isRunning }
        let changed = self.session(fixture, profile: profile, hostFile: fixture.wrongKnownHosts)
        changed.start()
        defer { changed.disconnect() }
        try await eventually { !changed.isRunning }
        XCTAssertEqual(changed.state, .failed)
        XCTAssertTrue(output(changed).contains("HOST IDENTIFICATION HAS CHANGED"))
    }

    func testDirectHelperInvocationCannotReadCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-auth-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = RejectReadCredentials()
        let profile = ConnectionProfile(name: "Test", host: "host", username: "nc", rememberPassword: true)
        let broker = try SSHPasswordBroker(directory: root, profile: profile, executable: executable, credentials: credentials)
        broker.start(sshPID: getpid())
        defer { broker.stop() }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["nc@host's password: "]
        process.environment = [SSHAskpass.environmentKey: broker.socketPath]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertFalse(credentials.readAttempted)
    }

    @MainActor
    private func output(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 15, _ predicate: () -> Bool) async throws {
        for _ in 0..<Int(timeout * 10) {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ProfileError("等待隔离密码认证结果超时")
    }
}

private struct NoKeychainCredentials: ConnectionCredentials {
    func password(for profile: ConnectionProfile) throws -> String? { throw ProfileError("临时密码不应读取钥匙串") }
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws { throw ProfileError("临时密码不应写入钥匙串") }
}

private final class CountingKeychainCredentials: ConnectionCredentials {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func password(for profile: ConnectionProfile) throws -> String? {
        lock.lock(); reads += 1; lock.unlock()
        return try KeychainCredentials().password(for: profile)
    }
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws {
        try KeychainCredentials().setPassword(password, for: profile)
    }
}

private final class DelayedKeychainCredentials: ConnectionCredentials {
    private let beforeRead: () -> Void
    private let lock = NSLock()
    private var didFinish = false
    private var didStart = false
    init(delay: TimeInterval) { beforeRead = { Thread.sleep(forTimeInterval: delay) } }
    init(beforeRead: @escaping () -> Void) { self.beforeRead = beforeRead }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    func password(for profile: ConnectionProfile) throws -> String? {
        lock.lock(); didStart = true; lock.unlock()
        beforeRead()
        defer { lock.lock(); didFinish = true; lock.unlock() }
        return try KeychainCredentials().password(for: profile)
    }
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws {
        try KeychainCredentials().setPassword(password, for: profile)
    }
}

private final class RejectReadCredentials: ConnectionCredentials {
    private let lock = NSLock()
    private var attempted = false
    var readAttempted: Bool { lock.lock(); defer { lock.unlock() }; return attempted }
    func password(for profile: ConnectionProfile) throws -> String? {
        lock.lock(); attempted = true; lock.unlock()
        throw ProfileError("未授权请求不得读取密码")
    }
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws {}
}
