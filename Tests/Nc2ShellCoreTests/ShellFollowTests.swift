import XCTest
@testable import Nc2ShellCore

final class ShellFollowTests: XCTestCase {
    func testExportedBashPromptWorksInChildShellWithoutInstalledHook() throws {
        let child = #"for value in 0 1 23; do (exit "$value"); eval "$PROMPT_COMMAND"; done"#
        let script = #"export PROMPT_COMMAND='printf "ORIGINAL_STATUS_%s\n" "$?"'"# + "\n"
            + ShellIntegration.command(token: "nc2-inheritance.invalid") + "\n"
            + #"for value in 0 1 23; do (exit "$value"); eval "$PROMPT_COMMAND"; done"# + "\n"
            + "/bin/bash --noprofile --norc -c " + ShellIntegration.quote(child)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertFalse(text.contains("command not found"), text)
        for value in [0, 1, 23] {
            XCTAssertEqual(text.components(separatedBy: "ORIGINAL_STATUS_\(value)\n").count - 1, 2, text)
        }
    }

    func testFishBootstrapKeepsConfigurationAndReportsRealDirectory() throws {
        guard let fish = ProcessInfo.processInfo.environment["NC2SHELL_TEST_FISH"] else {
            throw XCTSkip("需要隔离 Fish 测试可执行文件")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-fish-\(UUID())")
        let config = root.appendingPathComponent(".config/fish"), temporary = root.appendingPathComponent("tmp")
        let working = root.appendingPathComponent("中文 #? % space")
        for url in [config, temporary, working] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let text = """
        set -g fish_greeting
        set -g NC2_CONFIG yes
        function fish_prompt; printf 'custom> '; end
        function previous_prompt --on-event fish_prompt; printf 'OLD_HOOK_OK\\n'; end
        cd "$HOME/中文 #? % space"
        """
        let file = config.appendingPathComponent("config.fish")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let process = Process(), incoming = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: fish)
        process.arguments = ["-c", ShellIntegration.bootstrapCommand(token: "nc2-fish.invalid")]
        process.environment = ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path,
                               "XDG_DATA_HOME": root.appendingPathComponent("data").path, "TMPDIR": temporary.path,
                               "SHELL": fish, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"]
        process.standardInput = incoming; process.standardOutput = output; process.standardError = output
        try process.run()
        // 管道输入不会触发 Fish 的原生提示符循环；这里主动发事件验证钩子共存，真实 PTY 另由 SSH 测试覆盖。
        let input = "printf 'CONFIG_%s\\n' $NC2_CONFIG; status is-login; and echo LOGIN_OK\nemit fish_prompt; fish_prompt\nfalse; __nc2_report; printf 'STATUS_%s\\n' $status\ncd /nc2-no-such-dir; emit fish_prompt\nexit 0\n"
        try incoming.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try incoming.fileHandleForWriting.close()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, result)
        XCTAssertTrue(result.contains("CONFIG_yes"), result)
        XCTAssertTrue(result.contains("LOGIN_OK"), result)
        XCTAssertTrue(result.contains("OLD_HOOK_OK"), result)
        XCTAssertTrue(result.contains("custom> "), result)
        XCTAssertTrue(result.contains("STATUS_1\n"), result)
        let reports = result.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { RemoteDirectory.parse(String($0.prefix { $0 != "\u{7}" })) }.filter { $0.host == "nc2-fish.invalid" }
        XCTAssertFalse(reports.isEmpty, result)
        XCTAssertTrue(reports.allSatisfy { $0.path == working.path }, "失败 cd 不得伪造新目录")
        XCTAssertEqual(try String(contentsOf: file), text)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("nc2shell-init.") }, "启动脚本未清理：\(remaining)")
    }
}
