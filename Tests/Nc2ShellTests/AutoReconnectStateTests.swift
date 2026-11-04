import XCTest
@testable import Nc2Shell

final class AutoReconnectStateTests: XCTestCase {
    @MainActor
    func testOnlyNormalWaitStatusesProduceSSHExitCodes() {
        XCTAssertEqual(TerminalSession.normalExitCode(0), 0)
        XCTAssertEqual(TerminalSession.normalExitCode(256), 1)
        XCTAssertEqual(TerminalSession.normalExitCode(65024), 254)
        XCTAssertEqual(TerminalSession.normalExitCode(65280), 255)
        for status: Int32? in [nil, -1, 9, 0x137f, 0xffff, 0x100ff00, 0x80] {
            XCTAssertNil(TerminalSession.normalExitCode(status))
        }
    }
}
