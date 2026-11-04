import XCTest
@testable import Nc2ShellCore

final class TransferSnapshotTests: XCTestCase {
    func testWireAttributesPreserveModificationTimeAndFollowingFields() throws {
        var wire = SFTPWriter()
        wire.uint32(0x8000000f)
        wire.uint64(3)
        wire.uint32(501); wire.uint32(20)
        wire.uint32(0o100600)
        wire.uint32(1_600_000_000); wire.uint32(1_700_000_060)
        wire.uint32(1); wire.text("example@test"); wire.text("ignored")
        wire.uint32(0x10203040)
        var reader = SFTPReader(wire.data)
        let attributes = try reader.attributes()
        XCTAssertEqual(attributes.modifiedTime, 1_700_000_060)
        XCTAssertEqual(attributes.size, 3)
        XCTAssertEqual(attributes.mode, 0o100600)
        XCTAssertEqual(try reader.uint32(), 0x10203040)
    }

    func testWireAttributesWithoutTimesRemainCompatible() throws {
        var wire = SFTPWriter()
        wire.uint32(5); wire.uint64(3); wire.uint32(0o100600)
        wire.uint32(0x10203040)
        var reader = SFTPReader(wire.data)
        XCTAssertNil(try reader.attributes().modifiedTime)
        XCTAssertEqual(try reader.uint32(), 0x10203040)
    }
}
