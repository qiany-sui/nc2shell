import XCTest
@testable import Nc2ShellCore

final class ShellPromptTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-prompt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func run(_ shell: String, root: URL, setup: String, commands: String) throws -> String {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-i"] : ["-f", "-i"]
        process.currentDirectoryURL = root
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        let script = setup + "\n" + ShellIntegration.command(token: "nc2-prompt.invalid") + "\n" + commands + "\nexit 0\n"
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, result)
        return result
    }

    func testBashAndZshKeepLastTwoComponentsAndReportFullPath() throws {
        let root = try directory()
        let deep = root.appendingPathComponent("one/two/output/html")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for shell in ["/bin/bash", "/bin/zsh"] {
            let bash = shell.hasSuffix("bash")
            let setup = bash ? #"PS1='NC2<\w> '; PROMPT_COMMAND='printf "[HOOK:%s]" "$?"'"#
                : #"PROMPT='NC2<%~> '; original_prompt() { printf '[HOOK:%s]' "$?"; }; precmd_functions=(original_prompt)"#
            let result = try run(shell, root: root, setup: setup, commands:
                "cd " + ShellIntegration.quote(deep.path) + "\n(exit 23)\nprintf 'FULL_PATH[%s]\\n' \"$PWD\"\ncd \"$HOME\"")
            XCTAssertNotNil(result.range(of: #"NC2<(~/)?\.\.\./output/html>"#, options: .regularExpression), result)
            XCTAssertTrue(result.contains("NC2<~>"), result)
            XCTAssertTrue(result.contains("[HOOK:23]"), result)
            XCTAssertTrue(result.contains("FULL_PATH[\(deep.path)]"), result)
            let reports = result.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap {
                RemoteDirectory.parse(String($0.prefix { $0 != "\u{7}" }))
            }
            XCTAssertTrue(reports.contains { $0.host == "nc2-prompt.invalid" && $0.path == deep.path }, result)
        }
    }

    func testSpecialPathCharactersRemainDataAndDoNotRunCommands() throws {
        let root = try directory()
        let deep = root.appendingPathComponent("one/two/中文 空格/$(touch NC2_INJECTED)`touch NC2_BACKTICK`'")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for shell in ["/bin/bash", "/bin/zsh"] {
            let setup = shell.hasSuffix("bash") ? #"PS1='NC2<\w> '"# : #"PROMPT='NC2<%~> '"#
            let result = try run(shell, root: root, setup: setup, commands: "cd " + ShellIntegration.quote(deep.path) + "\npwd")
            XCTAssertTrue(result.contains(".../中文 空格/$(touch NC2_INJECTED)`touch NC2_BACKTICK`'"), result)
            XCTAssertFalse(FileManager.default.fileExists(atPath: deep.appendingPathComponent("NC2_INJECTED").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: deep.appendingPathComponent("NC2_BACKTICK").path))
        }
    }

    func testEscapedAndDynamicPromptsArePreservedAndChildBashDoesNotError() throws {
        let root = try directory()
        let bash = try run("/bin/bash", root: root, setup: #"PS1='literal \\w $(printf custom)> '; export PS1"#,
                           commands: #"/bin/bash --noprofile --norc -i -c 'printf CHILD_OK'"#)
        XCTAssertTrue(bash.contains("literal \\w custom> "), bash)
        XCTAssertTrue(bash.contains("CHILD_OK"), bash)
        XCTAssertFalse(bash.contains("command not found"), bash)
        let zsh = try run("/bin/zsh", root: root, setup: #"PROMPT='literal %%~ %D{%Y-%m-%d}> '"#, commands: "true")
        XCTAssertTrue(zsh.contains("literal %~ "), zsh)
        XCTAssertFalse(zsh.contains(".../"), zsh)
    }

    func testBashPreservesColorAndEscapedPathAndExportedPrompt() throws {
        let root = try directory(), deep = root.appendingPathComponent("one/two/output/html")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let result = try run("/bin/bash", root: root, setup: #"PS1='\[\e[32m\]NC2<\w>\[\e[0m\] \\w '"#,
                             commands: "cd " + ShellIntegration.quote(deep.path) + "\nexport PS1\nprintf 'true\\nexit\\n' | /bin/bash --noprofile --norc -i")
        XCTAssertTrue(result.contains("\u{1b}[32mNC2<.../output/html>\u{1b}[0m \\w "), result)
        XCTAssertFalse(result.contains("command not found"), result)
    }

    func testBashPathExpansionPreservesExitStatusBeforeAndAfterPath() throws {
        let root = try directory()
        let result = try run("/bin/bash", root: root, setup: #"PS1='BEFORE=$? PATH<\w> AFTER=$? '"#, commands: "cd \"$HOME\"\nfalse\ntrue")
        XCTAssertTrue(result.contains("BEFORE=1 PATH<~> AFTER=1"), result)
        XCTAssertTrue(result.contains("BEFORE=0 PATH<~> AFTER=0"), result)
    }
}
