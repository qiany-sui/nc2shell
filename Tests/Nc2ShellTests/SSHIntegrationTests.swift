import XCTest
import AppKit
import Nc2ShellCore
@testable import Nc2Shell

final class SSHIntegrationTests: XCTestCase {
    struct Fixture: Decodable {
        let port: Int
        let key: String
        let knownHosts: String
        let wrongKnownHosts: String
        let password: String
        let directory: String
    }

    private func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FIXTURE"] else {
            throw XCTSkip("运行 scripts/integration-smoke.py 才会启用隔离 SSH 联调")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @MainActor
    private func session(_ fixture: Fixture, password: Bool = false, wrongHostKey: Bool = false, username: String? = nil) -> TerminalSession {
        let profile = ConnectionProfile(name: "隔离测试", host: "127.0.0.1", port: fixture.port,
                                        username: username ?? (password ? "password-test" : "key-test"), identityFile: password ? "" : fixture.key)
        return TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { profile, controlPath in
            // 只替换测试环境的主机信任文件，仍走真实 OpenSSH、PTY 和产品参数构造。
            let isolated = ["-F", "/dev/null", "-o", "UserKnownHostsFile=\(wrongHostKey ? fixture.wrongKnownHosts : fixture.knownHosts)",
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
                            "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes"]
            let auth = password ? ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password"] : []
            return isolated + auth + (try SSHCommand.arguments(profile: profile, controlPath: controlPath))
        }
    }

    @MainActor
    func testKeyLoginCommandResizeDirectoryCtrlCAndReconnect() async throws {
        let fixture = try fixture()
        let session = session(fixture)
        defer { session.disconnect() }
        session.start()
        try await eventually { session.state == .connected && session.remoteDirectory != nil }
        XCTAssertEqual(session.remoteDirectory?.host, "nc2shell-test")
        send("printf 'SSH_%s_中文\\n' OK\r", to: session)
        try await eventually { self.output(session).contains("SSH_OK_中文") }

        session.terminal.setFrameSize(NSSize(width: 1000, height: 650))
        let size = session.getWindowSize()
        send("stty size\r", to: session)
        try await eventually { self.output(session).contains("\(size.ws_row) \(size.ws_col)") }

        send("cd 'My Files'\r", to: session)
        try await eventually { session.remoteDirectory?.path.hasSuffix("/My Files") == true }
        send("cd /nc2shell-no-such-directory\r", to: session)
        try await eventually { self.output(session).contains("No such file or directory") }
        XCTAssertTrue(session.remoteDirectory?.path.hasSuffix("/My Files") == true)

        send("sleep 30\r", to: session)
        try await Task.sleep(nanoseconds: 200_000_000)
        send("\u{3}", to: session)
        send("printf 'AFTER_%s\\n' INTERRUPT\r", to: session)
        try await eventually { self.output(session).contains("AFTER_INTERRUPT") }

        let promptCount = output(session).components(separatedBy: "nc2test$ ").count
        send("vim -u NONE -n\r", to: session)
        try await eventually { session.terminal.getTerminal().isCurrentBufferAlternate }
        send("\u{1b}:q!\r", to: session)
        // 等 Shell 真正接回终端，避免下一条命令被尚在退出的 vim 消耗。
        try await eventually {
            !session.terminal.getTerminal().isCurrentBufferAlternate &&
            self.output(session).components(separatedBy: "nc2test$ ").count > promptCount
        }
        send("printf 'AFTER_%s\\n' VIM\r", to: session)
        try await eventually { self.output(session).contains("AFTER_VIM") }

        let oldPID = session.process?.shellPid
        session.files.setFollowing(false)
        session.disconnect()
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .disconnected)
        if let oldPID { XCTAssertEqual(kill(oldPID, 0), -1, "已关闭的 SSH 子进程应已被回收") }
        session.start()
        try await eventually { session.state == .connected && session.files.reportedPath != nil && session.files.locationValidated }
        XCTAssertTrue(session.files.following, "重连后应重新默认开启跟随")
        send("exit\r", to: session)
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .disconnected)
    }

    @MainActor
    func testAutomaticZshFollowingIncludesStartupDirectoryAndPreservesPromptHook() async throws {
        let fixture = try fixture(), session = session(fixture, username: "zsh-test")
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && session.files.locationValidated && session.files.reportedPath != nil }
        XCTAssertTrue(session.files.following)
        XCTAssertEqual(session.files.path, fixture.directory + "/My Files")
        send("cd ..\r", to: session)
        try await eventually { session.files.path == fixture.directory && session.files.locationValidated }
        send("printf 'OLD_%s\\n' \"${precmd_functions[(Ie)__old_prompt]}\"\r", to: session)
        try await eventually { self.output(session).contains("OLD_2") }
        // sshd 先用账户 Shell 执行 -c，Zsh 的 .zshenv 因而也在外层执行。
        send("printf 'STARTUPS_%s\\n' \"$NC2_STARTUPS\"\r", to: session)
        try await eventually { self.output(session).contains("STARTUPS_2") }
        XCTAssertFalse(output(session).contains("__nc2_report()"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory + "/startup-temporary").isEmpty)
    }

    @MainActor
    func testSlowStartupReceivesNoInjectedTerminalInput() async throws {
        let fixture = try fixture(), session = session(fixture, username: "slow-test")
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && self.output(session).contains("STARTUP_WAIT") }
        XCTAssertNil(session.files.reportedPath)
        XCTAssertTrue(session.files.following)
        try await eventually { self.output(session).contains("STARTUP_READY") && session.files.reportedPath != nil && session.files.locationValidated }
        XCTAssertFalse(output(session).contains("UNEXPECTED_STARTUP_INPUT"))
        XCTAssertFalse(output(session).contains("__nc2_report()"))
        send("printf 'INTERACTIVE_%s\\n' OK\r", to: session)
        try await eventually { self.output(session).contains("INTERACTIVE_OK") }
    }

    @MainActor
    func testPasswordLoginAndSimultaneousIndependentSessions() async throws {
        let fixture = try fixture()
        let passwordSession = session(fixture, password: true)
        let keySession = session(fixture)
        defer { passwordSession.disconnect(); keySession.disconnect() }
        passwordSession.start()
        try await eventually { self.output(passwordSession).lowercased().contains("password:") }
        XCTAssertEqual(passwordSession.state, .connecting)
        send(fixture.password + "\r", to: passwordSession)
        try await eventually { passwordSession.state == .connected && passwordSession.files.reportedPath != nil }
        XCTAssertTrue(passwordSession.files.following)
        keySession.start()
        try await eventually { keySession.state == .connected }
        XCTAssertNotEqual(passwordSession.process?.shellPid, keySession.process?.shellPid)
        send("printf 'PASSWORD_%s\\n' OK\r", to: passwordSession)
        try await eventually { self.output(passwordSession).contains("PASSWORD_OK") }
        XCTAssertFalse(output(passwordSession).contains(fixture.password))
        XCTAssertFalse(output(keySession).contains("PASSWORD_OK"))
        passwordSession.disconnect()
        keySession.disconnect()
        try await eventually { !passwordSession.isRunning && !keySession.isRunning }
    }

    @MainActor
    func testSFTPPasswordReuseUnicodeFolderRoundTripConflictAndCancellation() async throws {
        let fixture = try fixture(), session = session(fixture, password: true)
        session.start()
        defer { session.disconnect() }
        try await eventually { self.output(session).lowercased().contains("password:") }
        send(fixture.password + "\r", to: session)
        try await eventually { session.state == .connected && session.files.locationValidated }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let base = URL(fileURLWithPath: fixture.directory)
        let local = base.appendingPathComponent("local-\(UUID())")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        let folder = local.appendingPathComponent("中文 '目录' %")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let data = Data((0..<100_001).map { UInt8($0 % 251) })
        let filename = "file \"引号\"\n$.bin"
        try data.write(to: folder.appendingPathComponent(filename))
        let remote = base.appendingPathComponent("remote-\(UUID())").path
        try await client.upload(local: folder, remote: remote)
        let listing = try await client.list(path: remote)
        XCTAssertEqual(listing.files.map(\.name), [filename])
        XCTAssertEqual(listing.files.first?.size, UInt64(data.count))
        let download = local.appendingPathComponent("download")
        try await client.download(remote: remote, local: download)
        XCTAssertEqual(try Data(contentsOf: download.appendingPathComponent(filename)), data)
        do { try await client.upload(local: folder, remote: remote); XCTFail("同名上传应被拒绝") } catch { XCTAssertTrue(error.localizedDescription.contains("同名")) }
        do { try await client.download(remote: remote, local: download); XCTFail("同名下载应被拒绝") } catch { XCTAssertTrue(error.localizedDescription.contains("同名")) }
        XCTAssertEqual(try Data(contentsOf: download.appendingPathComponent(filename)), data)

        let cancelled = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        cancelled.cancel()
        do { _ = try await cancelled.list(path: "."); XCTFail("取消后不应执行请求") } catch { XCTAssertTrue(error.localizedDescription.contains("取消")) }
        session.disconnect()
        try await eventually { !session.isRunning }
        let disconnected = try SFTPClient(profile: session.profile, controlPath: "/tmp/nc2shell-missing-\(UUID())")
        defer { disconnected.cancel() }
        do { _ = try await disconnected.list(path: "."); XCTFail("主通道不存在时不能重新认证") } catch {}
    }

    @MainActor
    func testFilePanelUsesLatestDirectoryDuringTransferAndKeepsInterruptedUploadLocation() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && session.files.locationValidated }
        let base = URL(fileURLWithPath: fixture.directory)
        let sources = base.appendingPathComponent("sources-\(UUID())")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let small = sources.appendingPathComponent("small-\(UUID()).bin")
        try Data(repeating: 19, count: 65_537).write(to: small)
        session.files.setFollowing(true)
        session.files.upload([small], expectedPath: session.files.path, connectionID: session.files.connectionID)
        XCTAssertTrue(session.files.isTransferring)
        let queued = sources.appendingPathComponent("queued-\(UUID()).bin")
        try Data(repeating: 21, count: 65_537).write(to: queued)
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(queued)]), "传输时应接受新的拖入并排队")
        try await eventually { !session.files.isPreparingUpload }
        session.files.follow(fixture.directory + "/My Files")
        session.files.follow(fixture.directory)
        try await eventually { !session.files.isTransferring && !session.files.isLoading }
        XCTAssertEqual(session.files.path, fixture.directory)
        XCTAssertEqual(session.files.message, "传输完成")
        XCTAssertEqual(session.files.transferredBytes, 65_537)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(queued.lastPathComponent)), Data(repeating: 21, count: 65_537))
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(small.lastPathComponent)), Data(repeating: 19, count: 65_537))

        let paused = sources.appendingPathComponent("paused-\(UUID()).bin")
        try Data([1, 2, 3]).write(to: paused)
        session.files.upload([paused], expectedPath: session.files.path, connectionID: session.files.connectionID)
        session.files.follow(fixture.directory + "/My Files")
        session.files.setFollowing(false)
        try await eventually { !session.files.isTransferring && !session.files.isLoading }
        XCTAssertEqual(session.files.path, fixture.directory, "暂停跟随应丢弃尚未执行的目录跳转")

        let large = sources.appendingPathComponent("large-\(UUID()).bin")
        try Data(repeating: 23, count: 20 * 1_048_576).write(to: large)
        session.files.upload([large], expectedPath: session.files.path, connectionID: session.files.connectionID)
        try await eventually { session.files.transferredBytes > 0 }
        XCTAssertTrue(session.files.isTransferring)
        session.disconnect()
        // 主动断开后，进程退出还会再次清理；重复清理不能丢失待返回的传输错误。
        session.files.disconnect()
        try await eventually { !session.isRunning && session.files.transferItems.last?.state.isFinished == true }
        XCTAssertTrue(session.files.error?.contains(".nc2shell-upload-") == true,
                      "未保留中断上传的位置：\(session.files.error ?? "无错误提示")")
        XCTAssertFalse(session.files.isTransferring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(large.lastPathComponent).path))
    }

    @MainActor
    func testDroppedFilesAndFoldersUseExistingUploadAndConflictProtection() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let sources = base.appendingPathComponent("drag-sources-\(UUID())")
        let folder = sources.appendingPathComponent("拖入 文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("拖入 #文件.txt")
        let nested = folder.appendingPathComponent("子文件.txt")
        let data = Data("Nc2Shell 拖入上传".utf8)
        try data.write(to: file); try data.write(to: nested)
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(file, delay: 0.1), fileDropProvider(folder)]))
        XCTAssertTrue(session.files.isPreparingUpload)
        XCTAssertFalse(session.files.uploadDroppedItems([fileDropProvider(file)]))
        try await eventually { !session.files.isPreparingUpload && !session.files.isTransferring && !session.files.isLoading }
        XCTAssertEqual(session.files.message, "传输完成")
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(file.lastPathComponent)), data)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(nested.lastPathComponent)), data)
        XCTAssertEqual(try Data(contentsOf: file), data, "拖入为复制，不能移动本地源文件")
        XCTAssertEqual(try Data(contentsOf: nested), data)
        try Data("changed".utf8).write(to: file)
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(file)]))
        try await eventually { !session.files.isPreparingUpload && !session.files.isTransferring && !session.files.isLoading }
        XCTAssertTrue(session.files.error?.contains("取消") == true, "无可用交互窗口时取消冲突，不能默认覆盖")
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(file.lastPathComponent)), data)
    }

    @MainActor
    func testDropLoadingRejectsChangedDirectoryAndCannotSurviveReconnect() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let sources = base.appendingPathComponent("delayed-sources-\(UUID())")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("must-not-upload.txt")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(file, delay: 0.5)]))
        session.files.follow(fixture.directory + "/My Files")
        try await eventually { !session.files.isPreparingUpload && session.files.locationValidated }
        XCTAssertNotNil(session.files.error)
        XCTAssertFalse(session.files.isTransferring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(file.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("My Files").appendingPathComponent(file.lastPathComponent).path))
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(file, delay: 1)]))
        session.disconnect()
        try await eventually { !session.isRunning }
        session.start()
        try await eventually { session.files.canTransfer }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertFalse(session.files.isPreparingUpload)
        XCTAssertFalse(session.files.isTransferring)
        XCTAssertNil(session.files.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(file.lastPathComponent).path))
    }

    @MainActor
    func testFilePromisesDownloadFilesAndFoldersToFinderChosenNames() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let source = base.appendingPathComponent("promise-file-\(UUID()).txt")
        let folder = base.appendingPathComponent("promise-folder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let data = Data("Nc2Shell 拖出下载 #空格".utf8)
        try data.write(to: source); try data.write(to: folder.appendingPathComponent("子文件.txt"))
        session.files.refresh()
        try await eventually { session.files.canTransfer }
        let file = try XCTUnwrap(session.files.files.first { $0.name == source.lastPathComponent })
        let directory = try XCTUnwrap(session.files.files.first { $0.name == folder.lastPathComponent })
        let filePromise = try XCTUnwrap(session.files.promiseProvider(for: file))
        XCTAssertFalse(session.files.isTransferring)
        let target = base.appendingPathComponent("Finder 选择的名称-\(UUID()).txt")
        try await fulfill(filePromise, to: target)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try Data(contentsOf: source), data)
        try await eventually { session.files.canTransfer }
        let folderPromise = try XCTUnwrap(session.files.promiseProvider(for: directory))
        let directoryTarget = base.appendingPathComponent("Finder 文件夹-\(UUID())")
        try await fulfill(folderPromise, to: directoryTarget)
        XCTAssertEqual(try Data(contentsOf: directoryTarget.appendingPathComponent("子文件.txt")), data)
        try await eventually { session.files.canTransfer }
        // 此处只检查发布的系统承诺类型；真实拖动中的兑现另做 GUI 验收。
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let receiverPromise = try XCTUnwrap(session.files.promiseProvider(for: file))
        XCTAssertTrue(pasteboard.writeObjects([receiverPromise]))
        let receivers = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver])
        XCTAssertEqual(receivers.count, 1)
        XCTAssertEqual(receivers[0].fileTypes, ["public.data"])
        withExtendedLifetime(receiverPromise) {}
        do { try await fulfill(filePromise, to: target); XCTFail("未确认覆盖时必须保留同名目标") }
        catch { XCTAssertTrue(error.localizedDescription.contains("取消")) }
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    @MainActor
    func testFilePromiseRejectsChangedDirectoryBusySessionAndReconnect() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let file = try XCTUnwrap(session.files.files.first { $0.name == ".bash_profile" })
        let promise = try XCTUnwrap(session.files.promiseProvider(for: file))
        XCTAssertNil(session.files.promiseProvider(for: RemoteFile(name: "link", size: 0, mode: 0o120700)))
        let target = base.appendingPathComponent("must-not-fulfill-\(UUID())")
        session.files.browse(fixture.directory + "/My Files")
        try await eventually { session.files.canTransfer }
        do { try await fulfill(promise, to: target); XCTFail("目录已改变") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        session.files.browse(fixture.directory)
        try await eventually { session.files.canTransfer }
        // 批次一旦失败就会记住错误；不同拒绝条件必须使用独立的新承诺。
        let busyPromise = try XCTUnwrap(session.files.promiseProvider(for: file))
        let reconnectPromise = try XCTUnwrap(session.files.promiseProvider(for: file))
        let delayed = fileDropProvider(base.appendingPathComponent("unused"), delay: 0.5)
        XCTAssertTrue(session.files.uploadDroppedItems([delayed]))
        do { try await fulfill(busyPromise, to: target); XCTFail("准备上传时不能开始承诺下载") }
        catch { XCTAssertTrue(error.localizedDescription.contains("正在")) }
        session.disconnect()
        try await eventually { !session.isRunning }
        session.start()
        try await eventually { session.files.canTransfer }
        do { try await fulfill(reconnectPromise, to: target); XCTFail("旧承诺不能跨越重连") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接已变化")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testFilePromiseCancellationAndDisconnectionCompleteAndCleanPartialFiles() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let source = base.appendingPathComponent("promise-large-\(UUID()).bin")
        try Data(repeating: 31, count: 20 * 1_048_576).write(to: source)
        session.files.refresh()
        try await eventually { session.files.canTransfer }
        let file = try XCTUnwrap(session.files.files.first { $0.name == source.lastPathComponent })
        for disconnect in [false, true] {
            let promise = try XCTUnwrap(session.files.promiseProvider(for: file))
            let target = base.appendingPathComponent("partial-\(UUID()).bin")
            let download = Task { try await self.fulfill(promise, to: target) }
            try await eventually { session.files.transferredBytes > 0 && session.files.isTransferring }
            if disconnect { session.disconnect() } else { session.files.cancelTransfer() }
            do { try await download.value; XCTFail("取消或断线不能完成文件承诺") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".nc2shell-download-") })
            if !disconnect { try await eventually { session.files.canTransfer } }
        }
    }

    @MainActor
    func testDownloadSelectionIntoDirectoryPreservesNamesAndContents() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory), prefix = "actions-\(UUID())"
        let names = [prefix + " 中文.txt", prefix + " 文件夹", prefix + " #.txt"]
        let data = Data("按钮及右键批量下载".utf8)
        try data.write(to: base.appendingPathComponent(names[0]))
        try FileManager.default.createDirectory(at: base.appendingPathComponent(names[1]), withIntermediateDirectories: false)
        try data.write(to: base.appendingPathComponent(names[1] + "/子文件.txt"))
        try data.write(to: base.appendingPathComponent(names[2]))
        let destination = base.appendingPathComponent("local-" + prefix)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let selected = try names.map { name in try XCTUnwrap(session.files.files.first { $0.name == name }) }
        XCTAssertTrue(session.files.canDownload(selected))
        session.files.download(selected, into: destination, expectedPath: session.files.path, connectionID: session.files.connectionID)
        XCTAssertTrue(session.files.isTransferring)
        session.files.follow(fixture.directory + "/My Files")
        try await eventually { session.files.canTransfer && session.files.path.hasSuffix("/My Files") }
        XCTAssertNil(session.files.error)
        XCTAssertEqual(session.files.message, "已下载 3/3 项")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[0])), data)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[1] + "/子文件.txt")), data)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[2])), data)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(names[0])), data)
    }

    @MainActor
    func testDownloadSelectionRejectsInvalidItemsAndChangedPickerContext() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory)
        let destination = base.appendingPathComponent("rejected-actions-\(UUID())")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let linkName = "selection-link-\(UUID())"
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(linkName), withDestinationURL: base.appendingPathComponent(".bash_profile"))
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let file = try XCTUnwrap(session.files.files.first { $0.name == ".bash_profile" })
        let path = session.files.path, connection = session.files.connectionID
        XCTAssertFalse(session.files.canDownload([]))
        let link = try XCTUnwrap(session.files.files.first { $0.name == linkName })
        XCTAssertEqual(link.kind, .symbolicLink)
        let invalid = [file, link]
        XCTAssertFalse(session.files.canDownload(invalid))
        session.files.download(invalid, into: destination, expectedPath: path, connectionID: connection)
        XCTAssertFalse(session.files.isTransferring); XCTAssertNotNil(session.files.error)
        session.files.download([RemoteFile(name: "../escape", size: 0, mode: 0o100600)], into: destination, expectedPath: path, connectionID: connection)
        XCTAssertFalse(session.files.isTransferring)
        session.files.browse(fixture.directory + "/My Files")
        try await eventually { session.files.canTransfer }
        session.files.download([file], into: destination, expectedPath: path, connectionID: connection)
        XCTAssertTrue(session.files.error?.contains("目录或连接已变化") == true)
        session.files.browse(path); try await eventually { session.files.canTransfer }
        XCTAssertTrue(session.files.uploadDroppedItems([fileDropProvider(base.appendingPathComponent("unused"), delay: 0.5)]))
        session.files.download([file], into: destination, expectedPath: path, connectionID: connection)
        XCTAssertTrue(session.files.error?.contains("正在") == true)
        session.disconnect(); try await eventually { !session.isRunning }; session.start()
        try await eventually { session.files.canTransfer }
        session.files.download([file], into: destination, expectedPath: path, connectionID: connection)
        XCTAssertTrue(session.files.error?.contains("目录或连接已变化") == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertFalse(session.files.isTransferring)
    }

    @MainActor
    func testDownloadSelectionConflictAndCancellationStopRemainingItems() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory), prefix = "stop-actions-\(UUID())"
        let names = (0..<3).map { "\(prefix)-\($0).bin" }, small = Data(repeating: 27, count: 8)
        for (index, name) in names.enumerated() {
            try (index == 1 ? Data(repeating: 27, count: 20 * 1_048_576) : small).write(to: base.appendingPathComponent(name))
        }
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let selected = try names.map { name in try XCTUnwrap(session.files.files.first { $0.name == name }) }
        for cancel in [false, true] {
            let destination = base.appendingPathComponent("local-\(cancel)-" + prefix)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let existing = Data("不能覆盖".utf8)
            if !cancel { try existing.write(to: destination.appendingPathComponent(names[1])) }
            session.files.download(selected, into: destination, expectedPath: session.files.path, connectionID: session.files.connectionID)
            if cancel {
                try await eventually { session.files.message?.contains("2/3") == true && session.files.transferredBytes > 0 }
                session.files.cancelTransfer()
            }
            try await eventually { session.files.canTransfer }
            XCTAssertNotNil(session.files.error)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[0])), small)
            if cancel { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(names[1]).path)) }
            else { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(names[1])), existing) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(names[2]).path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".nc2shell-download-") })
        }
    }

    @MainActor
    func testBatchPromisesQueueMixedItemsAndKeepSourceDuringFollow() async throws {
        let fixture = try fixture(), session = session(fixture)
        let base = URL(fileURLWithPath: fixture.directory), prefix = "batch-\(UUID())"
        let settings = TransferSettingsController(store: .init(fileURL: base.appendingPathComponent(prefix + "-settings.json")))
        XCTAssertTrue(settings.save(.init(maxConcurrentTransfers: 1, downloadLimitKiB: 128)))
        session.files.configureTransferSettings(settings)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let large = Data(repeating: 13, count: 1_048_576), text = Data("中文 批量下载 #".utf8)
        try large.write(to: base.appendingPathComponent(prefix + ".bin"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent(prefix), withIntermediateDirectories: false)
        try text.write(to: base.appendingPathComponent(prefix + "/子文件.txt"))
        try text.write(to: base.appendingPathComponent(prefix + ".txt"))
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let names = [prefix + ".bin", prefix, prefix + ".txt"]
        let promises = try batchPromises(names, model: session.files)
        let separate = try XCTUnwrap(session.files.promiseProvider(for: session.files.files.first { $0.name == names[2] }!))
        let targets = names.map { base.appendingPathComponent("received-" + $0) }
        let task = Task { await self.fulfillTogether(promises, to: targets) }
        try await eventually { session.files.isTransferring && session.files.transferredBytes > 0 }
        let activeID = try XCTUnwrap(session.files.transferItems.first).id
        session.files.pauseTransfer(activeID)
        let separateTarget = base.appendingPathComponent("separate-" + prefix)
        let separateTask = Task { try await self.fulfill(separate, to: separateTarget) }
        try await eventually { session.files.transferItems.contains { $0.target == separateTarget.path } }
        XCTAssertEqual(session.files.transferItems.first { $0.target == separateTarget.path }?.state, .queued, "独立批次可以排队，但不能抢占当前传输")
        XCTAssertFalse(FileManager.default.fileExists(atPath: separateTarget.path))
        session.files.follow(fixture.directory + "/My Files")
        XCTAssertTrue(settings.save(.init(maxConcurrentTransfers: 1)))
        session.files.resumeTransfer(activeID)
        let result = await task.value
        XCTAssertEqual(result.finished, [0, 1, 2]); XCTAssertTrue(result.errors.isEmpty)
        try await separateTask.value
        XCTAssertEqual(try Data(contentsOf: separateTarget), text)
        XCTAssertEqual(try Data(contentsOf: targets[0]), large)
        XCTAssertEqual(try Data(contentsOf: targets[1].appendingPathComponent("子文件.txt")), text)
        XCTAssertEqual(try Data(contentsOf: targets[2]), text)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(names[0])), large)
        try await eventually { session.files.canTransfer && session.files.path.hasSuffix("/My Files") }
    }

    @MainActor
    func testBatchPromisesAcceptSerialRequestsWithoutWaitingForAllItems() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory), prefix = "serial-\(UUID())"
        let names = (0..<3).map { "\(prefix)-\($0).txt" }
        for name in names {
            try Data("原目录".utf8).write(to: base.appendingPathComponent(name))
            try Data("错误目录".utf8).write(to: base.appendingPathComponent("My Files/" + name))
        }
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let promises = try batchPromises(names, model: session.files)
        try await fulfill(promises[0], to: base.appendingPathComponent("first-" + prefix))
        try await eventually { session.files.canTransfer }
        session.files.browse(fixture.directory + "/My Files")
        let target = base.appendingPathComponent("second-" + prefix)
        try await fulfill(promises[1], to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("原目录".utf8))
        // Finder 未请求第三项，面板也不能永远停留在传输状态。
        try await eventually { session.files.canTransfer && session.files.path.hasSuffix("/My Files") }
        session.disconnect(); try await eventually { !session.isRunning }; session.start()
        try await eventually { session.files.canTransfer }
        let late = base.appendingPathComponent("late-" + prefix)
        do { try await fulfill(promises[2], to: late); XCTFail("已开始但空闲的批次也不能跨越重连") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接已变化")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    @MainActor
    func testBatchConflictStopsQueuedAndLateRequestsButKeepsCompletedFiles() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory), prefix = "conflict-batch-\(UUID())"
        let names = (0..<4).map { "\(prefix)-\($0).txt" }, data = Data("批量文件".utf8)
        for name in names { try data.write(to: base.appendingPathComponent(name)) }
        session.files.refresh(); try await eventually { session.files.canTransfer }
        let promises = try batchPromises(names, model: session.files)
        let targets = names.map { base.appendingPathComponent("received-" + $0) }
        let existing = Data("原有文件不能覆盖".utf8)
        try existing.write(to: targets[1])
        let result = await fulfillTogether(Array(promises.prefix(3)), to: Array(targets.prefix(3)))
        XCTAssertEqual(result.finished.count, 3); XCTAssertEqual(result.errors.count, 2)
        XCTAssertEqual(try Data(contentsOf: targets[0]), data)
        XCTAssertEqual(try Data(contentsOf: targets[1]), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[2].path))
        do { try await fulfill(promises[3], to: targets[3]); XCTFail("失败批次的迟到请求必须结束并报错") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[3].path))
    }

    @MainActor
    func testBatchCancelAndDisconnectStopPendingAndLatePromises() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let base = URL(fileURLWithPath: fixture.directory), prefix = "cancel-batch-\(UUID())"
        let names = (0..<4).map { "\(prefix)-\($0).bin" }
        for (index, name) in names.enumerated() {
            try Data(repeating: 19, count: index == 1 ? 20 * 1_048_576 : 8).write(to: base.appendingPathComponent(name))
        }
        session.files.refresh(); try await eventually { session.files.canTransfer }
        for disconnect in [false, true] {
            let promises = try batchPromises(names, model: session.files)
            let targets = names.map { base.appendingPathComponent("received-\(disconnect)-" + $0) }
            try await fulfill(promises[0], to: targets[0])
            let task = Task { await self.fulfillTogether(Array(promises[1...2]), to: Array(targets[1...2])) }
            try await eventually { session.files.isTransferring && session.files.transferredBytes > 0 }
            if disconnect { session.disconnect() } else { session.files.cancelTransfer() }
            let result = await task.value
            XCTAssertEqual(result.finished.count, 2); XCTAssertEqual(result.errors.count, 2)
            XCTAssertEqual(try Data(contentsOf: targets[0]), Data(repeating: 19, count: 8))
            for target in targets[1...2] { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".nc2shell-download-") })
            if disconnect {
                try await eventually { !session.isRunning }; session.start()
            }
            try await eventually { session.files.canTransfer }
            do { try await fulfill(promises[3], to: targets[3]); XCTFail("取消或重连后不得启动旧批次") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: targets[3].path))
        }
    }

    @MainActor
    private func batchPromises(_ names: [String], model: RemoteFilesModel) throws -> [RemoteDownloadPromise] {
        let promises = try names.map { name in
            let file = try XCTUnwrap(model.files.first { $0.name == name })
            return try XCTUnwrap(model.promiseProvider(for: file) as? RemoteDownloadPromise)
        }
        RemoteDownloadPromise.group(promises)
        return promises
    }

    @MainActor
    private func fulfillTogether(_ promises: [RemoteDownloadPromise], to targets: [URL]) async -> (finished: [Int], errors: [Error]) {
        let done = expectation(description: "每个文件承诺恰好回调一次")
        done.expectedFulfillmentCount = promises.count; done.assertForOverFulfill = true
        var finished: [Int] = [], errors: [Error] = []
        for (index, promise) in promises.enumerated() {
            promise.filePromiseProvider(promise, writePromiseTo: targets[index]) { error in
                finished.append(index)
                if let error { errors.append(error) }
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 15)
        return (finished, errors)
    }

    @MainActor
    private func fulfill(_ promise: NSFilePromiseProvider, to url: URL) async throws {
        let delegate = try XCTUnwrap(promise.delegate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.filePromiseProvider(promise, writePromiseTo: url) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    @MainActor
    func testMidTransferCancellationLeavesNoFinalTargetAndRejectsLinks() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected }
        let base = URL(fileURLWithPath: fixture.directory)
        let local = base.appendingPathComponent("large-\(UUID()).bin")
        try Data(repeating: 37, count: 1_048_576).write(to: local)
        let remote = base.appendingPathComponent("cancelled-upload-\(UUID()).bin")
        let upload = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        do {
            try await upload.upload(local: local, remote: remote.path) { _ in upload.cancel() }
            XCTFail("传输中取消必须失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("取消"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(".nc2shell-upload-"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        let download = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        let target = base.appendingPathComponent("cancelled-download-\(UUID()).bin")
        do { try await download.download(remote: local.path, local: target) { _ in download.cancel() }; XCTFail("传输中取消必须失败") }
        catch { XCTAssertTrue(error.localizedDescription.contains("取消"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".nc2shell-download-") })

        let link = base.appendingPathComponent("link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        do { try await client.download(remote: link.path, local: target); XCTFail("不得跟随符号链接下载") }
        catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
        do { try await client.upload(local: link, remote: remote.path); XCTFail("不得跟随符号链接上传") }
        catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
    }

    @MainActor
    func testDirectoryFollowingTracksActualShellAndManualBrowsePausesIt() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start()
        defer { session.disconnect() }
        try await eventually { session.state == .connected && session.files.locationValidated }
        try await eventually { session.files.reportedPath != nil && session.files.following }
        XCTAssertFalse(output(session).contains("__nc2_report()"), "自动集成不能把脚本作为终端输入显示")
        send("cd 'My Files'\r", to: session)
        try await eventually { session.files.path.hasSuffix("/My Files") && session.files.locationValidated }
        send("cd /nc2shell-nonexistent\r", to: session)
        try await eventually { self.output(session).contains("No such file or directory") }
        XCTAssertTrue(session.files.path.hasSuffix("/My Files"))
        session.files.browse(fixture.directory)
        try await eventually { session.files.path == fixture.directory && session.files.locationValidated }
        XCTAssertFalse(session.files.following)
        let snapshotID = session.files.connectionID
        let target = URL(fileURLWithPath: fixture.directory).appendingPathComponent("must-not-download")
        session.files.download(RemoteFile(name: "anything", size: 0, mode: 0o100600), to: target,
                               expectedPath: fixture.directory + "/My Files", connectionID: snapshotID)
        XCTAssertTrue(session.files.error?.contains("目录或连接已变化") == true)
        XCTAssertFalse(session.files.isTransferring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        session.files.setFollowing(true)
        try await eventually { session.files.path.hasSuffix("/My Files") && session.files.locationValidated }
        session.files.browse(fixture.directory + "/does-not-exist")
        try await eventually { !session.files.isLoading }
        XCTAssertFalse(session.files.locationValidated)
        XCTAssertNotNil(session.files.error)
        session.files.browse(fixture.directory + "/My Files")
        session.files.browse(fixture.directory)
        try await eventually { !session.files.isLoading && session.files.path == fixture.directory && session.files.locationValidated }
        session.disconnect()
        XCTAssertFalse(session.files.isConnected)
        XCTAssertTrue(session.files.files.isEmpty)
        XCTAssertNotEqual(session.files.connectionID, snapshotID)
    }

    @MainActor
    func testRemoteManagementCreatesAndRenamesWithoutOverwriting() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("manage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let original = "中文 '目录' $\n空格"
        try await client.createDirectory(in: root.path, name: original)
        let folderListing = try await client.list(path: root.path)
        let folder = try XCTUnwrap(folderListing.files.first)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(original).appendingPathComponent("child.txt"))
        try await client.rename(folder, in: root.path, to: "重命名后的目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(original).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("重命名后的目录/child.txt")), Data([1, 2, 3]))
        let target = root.appendingPathComponent("keep.txt")
        try Data([9]).write(to: target)
        do { try await client.createDirectory(in: root.path, name: "keep.txt"); XCTFail("不能覆盖已有文件") } catch {}
        let listing = try await client.list(path: root.path)
        let file = try XCTUnwrap(listing.files.first { $0.name == "keep.txt" })
        do { try await client.rename(file, in: root.path, to: "重命名后的目录"); XCTFail("不能覆盖已有目录") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data([9]))
        try await client.rename(file, in: root.path, to: "新文件名 \"引号\".txt")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("新文件名 \"引号\".txt")), Data([9]))
    }

    @MainActor
    func testRemoteManagementRejectsInvalidNamesChangedTypesAndCancelledRequests() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("invalid-manage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data([7]).write(to: root.appendingPathComponent("source"))
        let listing = try await client.list(path: root.path), source = try XCTUnwrap(listing.files.first)
        for name in ["", ".", "..", "../escape", "nested/item", "bad\0name"] {
            do { try await client.createDirectory(in: root.path, name: name); XCTFail("不能创建非法名称") } catch {}
            do { try await client.rename(source, in: root.path, to: name); XCTFail("不能改成非法名称") } catch {}
            do { try await client.delete(RemoteFile(name: name, size: 0, mode: 0o100600), in: root.path); XCTFail("不能删除非法名称") } catch {}
        }
        for directory in ["", ".", root.path + "/..", root.path + "/bad\0"] {
            do { try await client.delete(source, in: directory); XCTFail("拒绝非规范目录") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source")), Data([7]))
        let wrongType = RemoteFile(name: "source", size: 0, mode: 0o040700)
        do { try await client.delete(wrongType, in: root.path); XCTFail("类型变化不能继续删除") } catch {}
        do { try await client.rename(wrongType, in: root.path, to: "wrong"); XCTFail("类型变化不能改名") } catch {}
        client.cancel()
        do { try await client.delete(source, in: root.path); XCTFail("取消后不能删除") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }

    @MainActor
    func testRemoteManagementDeletesTreeWithoutFollowingLinks() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let client = try SFTPClient(profile: session.profile, controlPath: XCTUnwrap(session.controlPath))
        defer { client.cancel() }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("delete-tree-\(UUID())")
        let tree = root.appendingPathComponent("中文目录"), keep = root.appendingPathComponent("保留")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: false)
        try Data([4, 5]).write(to: keep.appendingPathComponent("keep.txt"))
        try Data([8]).write(to: tree.appendingPathComponent("nested/child.txt"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: keep.path)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("broken").path, withDestinationPath: root.appendingPathComponent("missing").path)
        let listing = try await client.list(path: root.path)
        let selected = try XCTUnwrap(listing.files.first { $0.name == "中文目录" })
        try await client.delete(selected, in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try Data(contentsOf: keep.appendingPathComponent("keep.txt")), Data([4, 5]))
        let remaining = try await client.list(path: root.path)
        XCTAssertEqual(remaining.files.map(\.name), ["保留"])
    }

    @MainActor
    func testRemoteManagementModelKeepsTargetAndRefreshesAfterFollowing() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer && session.files.reportedPath != nil }
        let model = session.files, directory = model.path, connection = model.connectionID
        let name = "面板新建-\(UUID())"
        model.createDirectory(name, expectedPath: directory, connectionID: connection, revision: model.locationRevision)
        XCTAssertTrue(model.isManagingFiles)
        XCTAssertFalse(model.canTransfer)
        model.follow(directory + "/My Files")
        try await eventually { !model.isTransferring && !model.isLoading }
        XCTAssertEqual(model.path, directory + "/My Files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/" + name))
        model.browse(directory)
        try await eventually { model.canTransfer && model.path == directory }
        let file = try XCTUnwrap(model.files.first { $0.name == name })
        model.rename(file, to: name + " renamed", expectedPath: directory, connectionID: connection, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        XCTAssertNil(model.error)
        let renamed = try XCTUnwrap(model.files.first { $0.name == name + " renamed" })
        model.delete([renamed], expectedPath: directory, connectionID: connection, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/" + renamed.name))
        XCTAssertFalse(model.isManagingFiles)
    }

    @MainActor
    func testRemoteManagementModelRejectsStaleSelectionConnectionAndBusyState() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let model = session.files, directory = model.path, connection = model.connectionID
        let root = URL(fileURLWithPath: directory).appendingPathComponent("guard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceURL = root.appendingPathComponent("keep.txt")
        try Data([6]).write(to: sourceURL)
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        let file = try XCTUnwrap(model.files.first)
        model.delete([file], expectedPath: directory, connectionID: connection, revision: model.locationRevision)
        XCTAssertFalse(model.isTransferring)
        model.rename(file, to: "wrong", expectedPath: root.path, connectionID: UUID(), revision: model.locationRevision)
        XCTAssertFalse(model.isTransferring)
        model.createDirectory("wrong", expectedPath: root.path, connectionID: UUID(), revision: model.locationRevision)
        XCTAssertFalse(model.isTransferring)
        model.delete([RemoteFile(name: "../keep.txt", size: 1, mode: 0o100600)], expectedPath: root.path, connectionID: connection, revision: model.locationRevision)
        XCTAssertFalse(model.isTransferring)
        XCTAssertFalse(model.canManage([]))
        model.createDirectory("busy", expectedPath: root.path, connectionID: connection, revision: model.locationRevision)
        model.delete([file], expectedPath: root.path, connectionID: connection, revision: model.locationRevision)
        XCTAssertNotNil(model.error)
        try await eventually { model.canTransfer }
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([6]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wrong").path))
        model.createDirectory("cancelled", expectedPath: root.path, connectionID: connection, revision: model.locationRevision)
        model.cancelTransfer()
        try await eventually { model.canTransfer }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path))
    }

    @MainActor
    func testRemoteManagementBatchDeleteStopsOnPermissionFailure() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let model = session.files
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("partial-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["a.txt", "nc2-denied-delete.txt", "z.txt"] { try Data([2]).write(to: root.appendingPathComponent(name)) }
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        model.delete(model.files, expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { model.canTransfer }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("nc2-denied-delete.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("z.txt").path))
        XCTAssertTrue(model.error?.contains("没有访问权限") == true)
        XCTAssertTrue(model.error?.contains("部分") == true)
        XCTAssertEqual(model.files.map(\.name), ["nc2-denied-delete.txt", "z.txt"])
        XCTAssertEqual(session.state, .connected)
    }

    @MainActor
    func testRemoteManagementRejectsConfirmationAfterDirectoryRoundTripAndRefresh() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let model = session.files
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("keep.txt")
        try Data([3]).write(to: target)
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        let selected = model.files, connection = model.connectionID, revision = model.locationRevision
        model.browse(fixture.directory)
        try await eventually { model.canTransfer && model.path == fixture.directory }
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        model.delete(selected, expectedPath: root.path, connectionID: connection, revision: revision)
        try await eventually { model.canTransfer }
        XCTAssertNotNil(model.error, "返回同一路径也不能接受旧确认")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let refreshRevision = model.locationRevision
        model.refresh()
        try await eventually { model.canTransfer }
        model.createDirectory("stale", expectedPath: root.path, connectionID: connection, revision: refreshRevision)
        try await eventually { model.canTransfer }
        XCTAssertNotNil(model.error, "刷新应使旧确认失效")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stale").path))
    }

    @MainActor
    func testRemoteManagementInterruptedReplyReportsPossibleChanges() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let model = session.files
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("reply-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data([5]).write(to: root.appendingPathComponent("source"))
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        model.createDirectory("nc2-delay-create", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("nc2-delay-create").path) }
        model.cancelTransfer()
        try await eventually { model.canTransfer }
        XCTAssertTrue(model.error?.contains("可能已生效") == true, model.error ?? "missing error")
        let file = try XCTUnwrap(model.files.first { $0.name == "source" })
        model.rename(file, to: "nc2-delay-rename", expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("nc2-delay-rename").path) }
        session.disconnect()
        try await eventually { !session.isRunning && model.error?.contains("已中断：") == true }
        XCTAssertTrue(model.error?.contains("可能已生效") == true, model.error ?? "missing error")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("nc2-delay-rename")), Data([5]))
    }

    @MainActor
    func testRemoteManagementCancellingDeleteKeepsUnprocessedFiles() async throws {
        let fixture = try fixture(), session = session(fixture)
        session.start(); defer { session.disconnect() }
        try await eventually { session.files.canTransfer }
        let model = session.files
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("cancel-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["nc2-delay-delete.txt", "z.txt"] { try Data([2]).write(to: root.appendingPathComponent(name)) }
        model.browse(root.path)
        try await eventually { model.canTransfer && model.path == root.path }
        model.delete(model.files, expectedPath: root.path, connectionID: model.connectionID, revision: model.locationRevision)
        try await eventually { !FileManager.default.fileExists(atPath: root.appendingPathComponent("nc2-delay-delete.txt").path) }
        model.cancelTransfer()
        try await eventually { model.canTransfer }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("z.txt").path))
        XCTAssertTrue(model.error?.contains("部分") == true)
        XCTAssertEqual(model.files.map(\.name), ["z.txt"])
    }

    @MainActor
    func testChangedHostKeyRefusesLogin() async throws {
        let fixture = try fixture()
        let session = session(fixture, wrongHostKey: true)
        session.start()
        try await eventually { !session.isRunning }
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(output(session).contains("HOST IDENTIFICATION HAS CHANGED"))
    }

    @MainActor
    private func output(_ session: TerminalSession) -> String {
        // SwiftTerm 导出宽字符的第二个终端格时使用 NUL 占位，它不是用户看到的文本。
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    @MainActor
    private func send(_ text: String, to session: TerminalSession) { session.terminal.send(txt: text) }

    @MainActor
    private func eventually(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Nc2Shell.Integration", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待 SSH 交互结果超时，调用行 \(line)"])
    }
}
