import XCTest
@testable import Nc2ShellCore

final class SFTPAttributePresenceTests: XCTestCase {
    func testMissingSizeIsDifferentFromKnownEmptyFileWithoutLosingFollowingFields() throws {
        for hasSize in [false, true] {
            var wire = SFTPWriter()
            wire.uint32(hasSize ? 5 : 4)
            if hasSize { wire.uint64(0) }
            wire.uint32(0o100600)
            wire.uint32(0x10203040)
            var reader = SFTPReader(wire.data)
            let attributes = try reader.attributes()
            XCTAssertEqual(attributes.hasSize, hasSize)
            XCTAssertEqual(attributes.mode, 0o100600)
            XCTAssertEqual(try reader.uint32(), 0x10203040)
            let file = RemoteFile(name: "empty", size: attributes.size, mode: attributes.mode, hasSize: attributes.hasSize)
            XCTAssertEqual(file.hasSize, hasSize)
            XCTAssertEqual(file == RemoteFile(name: "empty", size: 0, mode: 0o100600), hasSize)
        }
    }
}
