import XCTest
@testable import Nc2ShellCore

final class ShellContextTests: XCTestCase {
    func testContextValidatesOptionalEncodedTmuxExecutable() throws {
        let base = "file://context-nc2-test.invalid/123/501/dev/pts/1"
        let context = try XCTUnwrap(ShellContext.parse(report: base + "?tmux=%2Fopt%2FMy%20Tools%2Ftmux", token: "nc2-test.invalid"))
        XCTAssertEqual(context.tmuxExecutable, "/opt/My Tools/tmux")
        XCTAssertNil(ShellContext.parse(report: base, token: "nc2-test.invalid")?.tmuxExecutable)
        for query in ["tmux=relative", "tmux=", "tmux=/bin/tmux%0A", "tmux=/bin/%00tmux", "tmux=/bad%ZZ", "tmux=/bin/tmux&tmux=/other", "other=/bin/tmux"] {
            XCTAssertNil(ShellContext.parse(report: base + "?" + query, token: "nc2-test.invalid"), query)
        }
    }

    func testContextAcceptsOnlyMatchingTokenNumericIdentityAndTTY() throws {
        for tty in ["/dev/ttys001", "/dev/pts/12"] {
            let context = try XCTUnwrap(ShellContext.parse(report: "file://context-nc2-test.invalid/123/501" + tty, token: "nc2-test.invalid"))
            XCTAssertEqual(context.pid, 123); XCTAssertEqual(context.uid, 501); XCTAssertEqual(context.tty, tty)
        }
        for value in ["file://wrong/123/501/dev/ttys001", "file://context-nc2-test.invalid/0/501/dev/ttys001",
                      "file://context-nc2-test.invalid/-1/501/dev/ttys001", "file://context-nc2-test.invalid/9999999999/501/dev/ttys001",
                      "file://context-nc2-test.invalid/123/-1/dev/ttys001", "file://context-nc2-test.invalid/123/４２/dev/ttys001",
                      "file://context-nc2-test.invalid/123/501/tmp/file", "file://context-nc2-test.invalid/123/501/dev/pts/1%0A",
                      "file://context-nc2-test.invalid/123/501/dev/tty%27bad", "file://context-nc2-test.invalid/123/501/dev/pts/1?x=2"] {
            XCTAssertNil(ShellContext.parse(report: value, token: "nc2-test.invalid"), value)
        }
    }
}
