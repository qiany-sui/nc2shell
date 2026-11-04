import XCTest
@testable import Nc2ShellCore

final class FileTests: XCTestCase {
    func testAutomaticBootstrapLoadsLoginConfigurationAndRestoresEnvironment() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-auto-\(UUID())")
            let temporary = root.appendingPathComponent("temporary")
            let custom = root.appendingPathComponent("custom zsh")
            let working = root.appendingPathComponent("My Files 中文")
            for directory in [temporary, custom, working] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            defer { try? FileManager.default.removeItem(at: root) }
            let configs: [URL: String] = [
                root.appendingPathComponent(".bash_profile"): "NC2_TEST_ORDER=P; . \"$HOME/.bashrc\"\n",
                root.appendingPathComponent(".bashrc"): "NC2_TEST_ORDER=${NC2_TEST_ORDER}R; PROMPT_COMMAND=\"printf 'OLD_HOOK_OK\\\\n'\"; cd \"$HOME/My Files 中文\"\n",
                custom.appendingPathComponent(".zshenv"): "NC2_TEST_ORDER=E\n",
                custom.appendingPathComponent(".zprofile"): "NC2_TEST_ORDER=${NC2_TEST_ORDER}P\n",
                custom.appendingPathComponent(".zshrc"): "NC2_TEST_ORDER=${NC2_TEST_ORDER}R; __test_hook() { printf 'OLD_HOOK_OK\\n'; }; precmd_functions+=(__test_hook); cd \"$HOME/My Files 中文\"\n",
                custom.appendingPathComponent(".zlogin"): "NC2_TEST_ORDER=${NC2_TEST_ORDER}L\n"
            ]
            for (url, text) in configs { try text.write(to: url, atomically: true, encoding: .utf8) }
            let command = "printf 'CONFIG_%s\\n' \"$NC2_TEST_ORDER\"; printf 'ENV_%s\\n' \"$ENV\"; printf 'ZDIR_%s\\n' \"$ZDOTDIR\"; printf 'HISTORY_%s\\n' \"$HISTFILE\"\n" + (shell.hasSuffix("bash") ? "case $- in *i*) echo INTERACTIVE_OK;; esac; set -o | /usr/bin/grep posix\n" : "[[ -o login ]] && echo LOGIN_OK\n") + "exit\n"
            let output = try runBootstrap(shell: shell, root: root, temporary: temporary, custom: custom, input: command)
            XCTAssertTrue(output.contains(shell.hasSuffix("bash") ? "CONFIG_PR" : "CONFIG_EPRL"), output)
            XCTAssertTrue(output.contains(shell.hasSuffix("bash") ? "INTERACTIVE_OK" : "LOGIN_OK"), output)
            XCTAssertTrue(output.contains("OLD_HOOK_OK"), output)
            XCTAssertTrue(output.contains("ENV_original-env"), output)
            XCTAssertTrue(output.contains("ZDIR_" + custom.path), output)
            if shell.hasSuffix("zsh") {
                XCTAssertTrue(output.contains("HISTORY_" + custom.appendingPathComponent(".zsh_history").path), output)
                XCTAssertFalse(output.contains("locking failed"), output)
                XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent(".zsh_history").path))
            }
            let reports = output.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { RemoteDirectory.parse(String($0.prefix { $0 != "\u{7}" })) }
            XCTAssertEqual(reports.first, RemoteDirectory(host: "nc2-auto.invalid", path: working.path), output)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
            for (url, text) in configs { XCTAssertEqual(try String(contentsOf: url), text) }
        }
    }

    func testUnsupportedShellStillStartsWithoutCreatingBootstrapFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-fallback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try runBootstrap(shell: "/bin/sh", root: root, temporary: root, custom: root, input: "printf 'FALLBACK_%s\\n' OK\nexit\n")
        XCTAssertTrue(output.contains("FALLBACK_OK"), output)
        XCTAssertFalse(output.contains("\u{1b}]7;file://nc2-auto.invalid"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testZshResettingPromptHooksKeepsNativeStartupAndHistoryUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-zsh-reset-\(UUID())")
        let temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "precmd_functions=(); PROMPT='native> '\n".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let output = try runBootstrap(shell: "/bin/zsh", root: root, temporary: temporary, custom: root,
                                      input: "printf 'SHELL_%s\\n' OK\nexit\n")
        // 用户明确重置提示符钩子时不强制恢复集成；终端和历史必须仍正常。
        XCTAssertTrue(output.contains("SHELL_OK"), output)
        XCTAssertFalse(output.contains("\u{1b}]7;file://nc2-auto.invalid"))
        XCTAssertFalse(output.contains("locking failed"), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".zsh_history").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    private func runBootstrap(shell: String, root: URL, temporary: URL, custom: URL, input: String) throws -> String {
        let process = Process(), incoming = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ShellIntegration.bootstrapCommand(token: "nc2-auto.invalid")]
        process.environment = ["HOME": root.path, "TMPDIR": temporary.path, "SHELL": shell, "ENV": "original-env", "ZDOTDIR": custom.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "HISTFILE": "/dev/null"]
        process.currentDirectoryURL = root
        process.standardInput = incoming; process.standardOutput = output; process.standardError = output
        try process.run()
        try incoming.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try incoming.fileHandleForWriting.close()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, result)
        return result
    }

    func testRejectsTruncatedAndOversizedWireStrings() throws {
        var reader = SFTPReader(Data([0, 0, 0, 8, 65]))
        XCTAssertThrowsError(try reader.string())
        var short = SFTPReader(Data([0, 0, 0]))
        XCTAssertThrowsError(try short.uint32())
        var utf8 = SFTPReader(Data([0, 0, 0, 1, 255]))
        XCTAssertThrowsError(try utf8.text())
    }

    func testWireRoundTripAndSafeNames() throws {
        var writer = SFTPWriter()
        writer.uint32(0x12345678)
        writer.uint64(0x123456789abcdef0)
        writer.text("中文 '空格'\n.txt")
        var reader = SFTPReader(writer.data)
        XCTAssertEqual(try reader.uint32(), 0x12345678)
        XCTAssertEqual(try reader.uint64(), 0x123456789abcdef0)
        XCTAssertEqual(try reader.text(), "中文 '空格'\n.txt")
        for name in ["..", ".", "../secret", "/etc", "a/b", "", "a\0b"] {
            XCTAssertThrowsError(try RemoteFile.validateName(name))
        }
        XCTAssertNoThrow(try RemoteFile.validateName("中文 '空格'\n.txt"))
    }

    func testMultiplexChannelCannotFallBackToNetworkOrRunRemoteShell() throws {
        let args = try SFTPClient.arguments(profile: .init(name: "Test", host: "alias", port: 2222), controlPath: "/tmp/test s")
        XCTAssertTrue(args.contains("ProxyCommand=/usr/bin/false"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertEqual(Array(args.suffix(3)), ["--", "alias", "sftp"])
        XCTAssertTrue(args.contains("-s"))
        XCTAssertTrue(args.contains("/tmp/test s"))
    }

    func testShellHooksPreserveExitStatusAndReportEncodedActualDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-hook-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("中文 #? % space")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for shell in ["/bin/bash", "/bin/zsh"] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-f", "-c", ShellIntegration.command(token: "nc2-test.invalid") + "\ncd " + ShellIntegration.quote(child.path) + "\nfalse; __nc2_report; printf 'STATUS=%s' \"$?\"\n"]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, shell)
            XCTAssertTrue(text.contains("STATUS=1"), text)
            let reports = text.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { RemoteDirectory.parse(String($0.prefix { $0 != "\u{7}" })) }
            XCTAssertEqual(reports.last?.path, child.path, text)
            XCTAssertEqual(reports.last?.host, "nc2-test.invalid")
        }
    }
}
