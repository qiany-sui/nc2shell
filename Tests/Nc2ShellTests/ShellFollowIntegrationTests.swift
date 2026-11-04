import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class ShellFollowIntegrationTests: XCTestCase {
    func fixture() throws -> SSHIntegrationTests.Fixture {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else { throw XCTSkip("需要隔离 SSH 服务") }
        return try JSONDecoder().decode(SSHIntegrationTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @MainActor
    func session(_ fixture: SSHIntegrationTests.Fixture, username: String) -> TerminalSession {
        let profile = ConnectionProfile(name: "目录跟随隔离验收", host: "127.0.0.1", port: fixture.port,
                                        username: username, identityFile: fixture.key)
        return TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, socket in
            ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(fixture.knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null",
             "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"] + (try SSHCommand.arguments(profile: profile, controlPath: socket))
        }
    }

    @MainActor
    func send(_ command: String, to session: TerminalSession) {
        session.send(source: session.terminal, data: ArraySlice(command.utf8))
    }

    @MainActor
    private func eventually(_ description: String, session: TerminalSession, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(description + ": " + String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self))
        throw NSError(domain: "ShellFollowTests", code: 1)
    }

    @MainActor
    func testRepeatedObservationDoesNotRestartSlowDirectoryListing() async throws {
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let slow = root.appendingPathComponent("nc2-follow-slow-list")
        try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: false)
        try Data([1]).write(to: slow.appendingPathComponent("ready.txt"))
        defer { try? FileManager.default.removeItem(at: slow) }
        let session = session(fixture, username: "key-test")
        defer { session.disconnect() }; session.start()
        try await eventually("连接", session: session) { session.state == .connected }
        let files = RemoteFilesModel()
        files.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        defer { files.disconnect() }
        try await eventually("初始目录", session: session) { files.locationValidated && !files.isLoading }
        var completedDuringUpdates = false
        for _ in 0..<18 {
            files.resumeFollowing(path: slow.path)
            try await Task.sleep(nanoseconds: 200_000_000)
            if files.locationValidated && files.path == slow.path { completedDuringUpdates = true }
        }
        XCTAssertTrue(completedDuringUpdates, "重复观察不能一直取消慢目录列举")
        XCTAssertTrue(files.canEnqueue)
        files.resumeFollowing(path: root.path)
        try await eventually("切回目录", session: session) { files.locationValidated && files.path == root.path }
        files.resumeFollowing(path: slow.path)
        try await Task.sleep(nanoseconds: 100_000_000)
        files.resumeFollowing(path: root.path)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(files.path, root.path); XCTAssertTrue(files.locationValidated)
    }

    @MainActor
    func testTmuxInstalledOnlyInInteractiveShellPathCanBeFollowed() async throws {
        guard let tmux = ProcessInfo.processInfo.environment["NC2SHELL_TEST_TMUX"] else { throw XCTSkip("需要隔离tmux") }
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let target = root.appendingPathComponent("login-only-tmux")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: target) }
        for shell in ["bash", "zsh", "fish"] {
            let session = session(fixture, username: shell + "-login-path-test")
            defer { try? tmuxCommand(tmux, root: root, ["kill-server"]); session.disconnect() }
            session.start()
            try await eventually("交互配置加载", session: session) { session.state == .connected && session.shellContext != nil && session.files.locationValidated }
            send("tmux -f /dev/null new-session -s nc2-login-path\r", to: session)
            try await eventually("进入tmux", session: session) { session.terminal.getTerminal().isCurrentBufferAlternate }
            send("cd " + ShellIntegration.quote(target.path) + "\r", to: session)
            try await eventually(shell + "的交互PATH能供观察通道定位tmux", session: session) { session.files.locationValidated && session.files.path == target.path && session.files.followSuspension == nil }
        }
    }

    @MainActor
    func testFishPTYAutomaticallyFollowsDirectoryAndReconnectsWithoutChangingConfig() async throws {
        guard ProcessInfo.processInfo.environment["NC2SHELL_TEST_FISH"] != nil else { throw XCTSkip("需要隔离 Fish") }
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let config = root.appendingPathComponent(".config/fish/config.fish")
        let original = try Data(contentsOf: config)
        let target = root.appendingPathComponent("Fish 中文 # % '路径")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: target) }
        let session = session(fixture, username: "fish-test")
        defer { session.disconnect() }
        for _ in 0..<2 {
            session.start()
            try await eventually("Fish首次自动跟随", session: session) { session.state == .connected && session.files.locationValidated && session.files.path == root.appendingPathComponent("My Files").path }
            // Fish 单引号只需要处理反斜线和单引号，不把 POSIX 引号拼接规则误用为路径输入。
            let quoted = "'" + target.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
            send("cd " + quoted + "\r", to: session)
            try await eventually("Fish中文目录跟随", session: session) { session.files.locationValidated && session.files.path == target.path }
            send("cd /nc2-no-such-directory\r", to: session)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(session.files.reportedPath, target.path)
            XCTAssertEqual(try Data(contentsOf: config), original)
            session.disconnect()
            try await eventually("断开回收", session: session) { !session.isRunning }
        }
    }

    private func observe(profile: ConnectionProfile, socket: String, context: ShellContext) async throws -> [ShellContextProbe.Event] {
        let arguments = try ShellContextProbe.arguments(profile: profile, controlPath: socket, context: context, token: "nc2-probe.invalid")
        return try await Task.detached {
            let process = Process(), incoming = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = arguments
            process.standardInput = incoming; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            defer { timeout.cancel() }
            try incoming.fileHandleForWriting.write(contentsOf: Data("tick\n".utf8)); try incoming.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var decoder = ShellContextProbe.Decoder(token: "nc2-probe.invalid")
            return try decoder.feed(data)
        }.value
    }

    private func tmuxCommand(_ binary: String, root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
        process.environment = ["TMUX_TMPDIR": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    @MainActor
    func testProbeUsesActualForegroundGroupAndRefusesDifferentIdentity() async throws {
        let fixture = try fixture(), session = session(try self.fixture(), username: "key-test")
        defer { session.disconnect() }
        session.start()
        try await eventually("原Shell上下文", session: session) { session.state == .connected && session.shellContext != nil && session.files.locationValidated }
        let context = try XCTUnwrap(session.shellContext), socket = try XCTUnwrap(session.controlPath)
        let first = try await observe(profile: session.profile, socket: socket, context: context)
        XCTAssertEqual(first, [.original])
        let different = try XCTUnwrap(ShellContext.parse(report: "file://context-nc2-test.invalid/\(context.pid)/\(context.uid + 1)\(context.tty)", token: "nc2-test.invalid"))
        let refused = try await observe(profile: session.profile, socket: socket, context: different)
        XCTAssertEqual(refused, [.paused(.identity)])
        send("set +m; sleep 3\r", to: session)
        try await Task.sleep(nanoseconds: 300_000_000)
        let sharedGroup = try await observe(profile: session.profile, socket: socket, context: context)
        XCTAssertEqual(sharedGroup, [.paused(.program)], "没有job control也不能只看组领导")
        send("\u{3}", to: session)
        try await Task.sleep(nanoseconds: 150_000_000)
        let resumed = try await observe(profile: session.profile, socket: socket, context: context)
        XCTAssertEqual(resumed, [.original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory))
    }

    @MainActor
    func testObservationTimeoutKeepsTerminalUsableAndRetryIgnoresOldConnection() async throws {
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let marker = root.appendingPathComponent(".nc2-follow-probe-delay")
        try Data().write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        let session = session(fixture, username: "key-test")
        defer { session.disconnect() }
        session.start()
        try await eventually("观察超时应明确提示", session: session) { session.files.followSuspension?.contains("超时") == true }
        XCTAssertEqual(session.state, .connected)
        send("printf 'TERMINAL_%s\\n' USABLE\r", to: session)
        try await eventually("观察失败不影响终端", session: session) { String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("TERMINAL_USABLE") }
        try FileManager.default.removeItem(at: marker)
        session.files.setFollowing(false); session.files.setFollowing(true)
        try await eventually("观察可重试", session: session) { session.files.followSuspension == nil && session.files.locationValidated }
        let previousTerminal = session.terminal, previousToken = session.directoryToken
        session.disconnect()
        try await eventually("旧连接退出", session: session) { !session.isRunning }
        session.start()
        try await eventually("新连接重新观察", session: session) { session.state == .connected && session.files.followSuspension == nil && session.files.locationValidated }
        XCTAssertNotEqual(session.directoryToken, previousToken)
        previousTerminal.feed(text: "\u{1b}]7;file://\(session.directoryToken)/must-not-follow\u{7}")
        XCTAssertEqual(session.files.reportedPath, root.path)
        XCTAssertNotEqual(session.remoteDirectory?.path, "/must-not-follow")
    }

    @MainActor
    func testTemporarySuspensionDiscardsAnInFlightFollowNavigation() async throws {
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let session = session(fixture, username: "key-test")
        defer { session.disconnect() }
        session.start()
        try await eventually("连接", session: session) { session.state == .connected }
        let files = RemoteFilesModel()
        files.connect(profile: session.profile, controlPath: try XCTUnwrap(session.controlPath), initialDirectory: root.path)
        defer { files.disconnect() }
        try await eventually("独立模型目录", session: session) { files.locationValidated && !files.isLoading }
        files.follow(root.appendingPathComponent("My Files").path)
        files.suspendFollowing(reason: "正在执行其他程序")
        try await eventually("旧导航不能迟到覆盖", session: session) { files.locationValidated && !files.isLoading }
        XCTAssertEqual(files.path, root.path)
        XCTAssertEqual(files.followSuspension, "正在执行其他程序")
    }

    @MainActor
    func testProbeTracksEachTmuxClientAndReturnsToOriginalShell() async throws {
        guard let tmux = ProcessInfo.processInfo.environment["NC2SHELL_TEST_TMUX"] else { throw XCTSkip("需要隔离tmux") }
        let fixture = try fixture(), root = URL(fileURLWithPath: try self.fixture().directory)
        let left = session(fixture, username: "key-test"), right = session(fixture, username: "key-test")
        let paths = [root.appendingPathComponent("tmux中文 ' A"), root.appendingPathComponent("tmux B")]
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        defer {
            try? tmuxCommand(tmux, root: root, ["kill-server"])
            // 自定义 socket 仅供本测试创建；不接触用户已有 tmux。
            let process = Process(); process.executableURL = URL(fileURLWithPath: tmux); process.arguments = ["-L", "nc2-custom", "kill-server"]
            process.environment = ["TMUX_TMPDIR": root.path, "PATH": "/usr/bin:/bin"]
            process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
            left.disconnect(); right.disconnect()
            for path in paths { try? FileManager.default.removeItem(at: path) }
        }
        for (index, session) in [left, right].enumerated() {
            session.start()
            try await eventually("原始会话", session: session) { session.state == .connected && session.shellContext != nil && session.files.locationValidated }
            send(ShellIntegration.quote(tmux) + " -f /dev/null new-session -s nc2-\(index) -c " + ShellIntegration.quote(paths[index].path) + "\r", to: session)
            try await eventually("进入tmux", session: session) { session.terminal.getTerminal().isCurrentBufferAlternate }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        for (index, session) in [left, right].enumerated() {
            let observed = try await observe(profile: session.profile, socket: XCTUnwrap(session.controlPath), context: XCTUnwrap(session.shellContext))
            XCTAssertEqual(observed, [.tmux(paths[index].path)], "不能采用最近活动客户端")
            try await eventually("文件面板跟随tmux", session: session) { session.files.locationValidated && session.files.path == paths[index].path }
        }
        send("cd " + ShellIntegration.quote(root.path) + "\r", to: left)
        try await Task.sleep(nanoseconds: 150_000_000)
        let changed = try await observe(profile: left.profile, socket: XCTUnwrap(left.controlPath), context: XCTUnwrap(left.shellContext))
        XCTAssertEqual(changed, [.tmux(root.path)])
        try await eventually("tmux中cd跟随", session: left) { left.files.locationValidated && left.files.path == root.path }
        send("sleep 30\r", to: left)
        try await eventually("前台程序暂缓跟随", session: left) { left.files.followSuspension != nil }
        send("\u{3}", to: left)
        try await eventually("返回tmux Shell恢复", session: left) { left.files.followSuspension == nil }
        left.files.setFollowing(false)
        send("cd " + ShellIntegration.quote(paths[0].path) + "\r", to: left)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(left.files.following); XCTAssertEqual(left.files.path, root.path)
        left.files.setFollowing(true)
        try await eventually("手动恢复后重新观察", session: left) { left.files.locationValidated && left.files.path == paths[0].path }
        try tmuxCommand(tmux, root: root, ["new-window", "-t", "nc2-0:", "-n", "second", "-c", root.path])
        try await eventually("tmux切窗口", session: left) { left.files.locationValidated && left.files.path == root.path }
        try tmuxCommand(tmux, root: root, ["split-window", "-h", "-t", "nc2-0:second", "-c", paths[0].path])
        try await eventually("tmux切窗格", session: left) { left.files.locationValidated && left.files.path == paths[0].path }
        try tmuxCommand(tmux, root: root, ["select-pane", "-t", "nc2-0:second.0"])
        try await eventually("tmux选择另一窗格", session: left) { left.files.locationValidated && left.files.path == root.path }
        send("\u{2}d", to: left)
        try await eventually("离开tmux", session: left) { !left.terminal.getTerminal().isCurrentBufferAlternate }
        let detached = try await observe(profile: left.profile, socket: XCTUnwrap(left.controlPath), context: XCTUnwrap(left.shellContext))
        XCTAssertEqual(detached, [.original])
        try await eventually("detach恢复原目录", session: left) { left.files.locationValidated && left.files.path == root.path }
        send(ShellIntegration.quote(tmux) + " -L nc2-custom -f /dev/null new-session -s nc2-other\r", to: left)
        try await eventually("自定义socket明确暂缓", session: left) { left.files.followSuspension?.contains("默认 tmux") == true }
        XCTAssertEqual(left.files.path, root.path)
        send("\u{2}d", to: left)
        try await eventually("离开自定义socket恢复", session: left) { left.files.followSuspension == nil }
    }
}
