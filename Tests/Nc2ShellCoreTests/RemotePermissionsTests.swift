import XCTest
@testable import Nc2ShellCore

final class RemotePermissionsTests: XCTestCase {
    func testOctalInputRejectsInvalidDigitsAndPrivilegedBits() throws {
        for text in ["", "64", "0644", "888", "-01", " 644", "644\n", "６４４", "7a5", "7777"] {
            XCTAssertThrowsError(try RemotePermissions.parse(text), text)
        }
        XCTAssertEqual(try RemotePermissions.parse("000"), 0)
        XCTAssertEqual(try RemotePermissions.parse("640"), 0o640)
        XCTAssertEqual(try RemotePermissions.parse("755"), 0o755)
        XCTAssertEqual(try RemotePermissions.parse("777"), 0o777)
    }

    func testOnlyOrdinaryBitsChangeAndExistingSpecialBitsArePreserved() throws {
        XCTAssertEqual(try RemotePermissions.mode(original: 0o104755, permissions: 0o640), 0o4640)
        XCTAssertEqual(try RemotePermissions.mode(original: 0o041770, permissions: 0o700), 0o1700)
        XCTAssertEqual(try RemotePermissions.mode(original: 0o100600, permissions: 0o755), 0o755)
        XCTAssertThrowsError(try RemotePermissions.mode(original: 0o100600, permissions: 0o4755))
        XCTAssertThrowsError(try RemotePermissions.mode(original: 0o100600, permissions: UInt32.max))
    }
}
