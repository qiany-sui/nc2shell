import XCTest
@testable import Nc2ShellCore

final class ShellContextProbeTests: XCTestCase {
    func testProbeAcceptsLinuxTmuxClientProcessNameButNotServer() throws {
        // Linux tmux 使用 PR_SET_NAME 把 comm 改为“tmux: client”；以进程边界夹具执行真实观察脚本。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-probe-os-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executableName = "tmux 中文 '工具"
        let executable = root.appendingPathComponent(executableName).path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let context = try XCTUnwrap(ShellContext.parse(report: "file://context-test.invalid/100/501/dev/pts/1?tmux=" + executable, token: "test.invalid"))
        let scripts = [
            "ps": "#!/bin/sh\ncase \"$2\" in pts/1) printf '200 200 200 501 %s\\n' \"$NC2_TEST_COMM\";; pts/2) echo '300 300 300 501 bash';; esac\n",
            executableName: "#!/bin/sh\ncase \"$1\" in list-clients) echo '/dev/pts/1|%0|300|/dev/pts/2';; display-message) echo '/中文 work';; esac\n"
        ]
        for (name, text) in scripts {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        for name in ["tmux", "tmux: client", "tmux: server"] {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ShellContextProbe.command(context: context, token: "test.invalid")]
            process.environment = ["PATH": root.path + ":/usr/bin:/bin", "NC2_TEST_COMM": name]
            process.standardInput = input; process.standardOutput = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("tick\n".utf8)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var decoder = ShellContextProbe.Decoder(token: "test.invalid")
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try decoder.feed(data), name == "tmux: server" ? [.paused(.program)] : [.tmux("/中文 work")], name)
        }
    }

    func testProbeDecoderHandlesChunksNoiseAndRejectsInvalidPaths() throws {
        var decoder = ShellContextProbe.Decoder(token: "nc2-test.invalid")
        XCTAssertEqual(try decoder.feed(Data("banner\nNC2\told.invalid\toriginal\nNC2\tnc2-test.invalid\ttmux\t/%E4%B8".utf8)), [])
        XCTAssertEqual(try decoder.feed(Data("%AD%E6%96%87%20path\nNC2\tnc2-test.invalid\tpaused\tprogram\nNC2\tnc2-test.invalid\toriginal\n".utf8)), [.tmux("/中文 path"), .paused(.program), .original])
        for suffix in ["tmux\trelative", "tmux\t/a%0A", "tmux\t/a%00", "tmux\t/b%z", "tmux\t/abc\textra", "paused\tunknown", "original\textra"] {
            var invalid = ShellContextProbe.Decoder(token: "nc2-test.invalid")
            XCTAssertThrowsError(try invalid.feed(Data("NC2\tnc2-test.invalid\t\(suffix)\n".utf8)), suffix)
        }
        var huge = ShellContextProbe.Decoder(token: "nc2-test.invalid")
        XCTAssertThrowsError(try huge.feed(Data(repeating: 65, count: 16_385)))
    }

    func testProbeCommandCannotFallBackToNetworkAndArgumentsStaySeparate() throws {
        let context = try XCTUnwrap(ShellContext.parse(report: "file://context-nc2-test.invalid/123/501/dev/ttys001", token: "nc2-test.invalid"))
        let args = try ShellContextProbe.arguments(profile: .init(name: "Test", host: "alias", port: 2222), controlPath: "/tmp/with space", context: context, token: "nc2-test.invalid")
        XCTAssertTrue(args.contains("BatchMode=yes")); XCTAssertTrue(args.contains("ProxyCommand=/usr/bin/false"))
        XCTAssertTrue(args.contains("ControlMaster=no")); XCTAssertTrue(args.contains("/tmp/with space"))
        XCTAssertTrue(args.contains("-T")); XCTAssertTrue(args.contains("/dev/null")); XCTAssertFalse(args.contains("-s"))
        XCTAssertEqual(Array(args.suffix(3).prefix(2)), ["--", "alias"])
        XCTAssertTrue(try XCTUnwrap(args.last).hasPrefix("exec /bin/sh -c "))
    }
}
