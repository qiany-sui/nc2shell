import XCTest
@testable import Nc2ShellCore

final class TransferAttributeOptionsTests: XCTestCase {
    func testOldSettingsAndTasksDefaultOffWhileNewOptionsRoundTrip() throws {
        let old = Data(#"{"maxConcurrentTransfers":2,"uploadLimitKiB":0,"downloadLimitKiB":0}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(TransferPreferences.self, from: old).attributes.isEnabled)
        let options = TransferAttributeOptions(preservePermissions: true, preserveModificationTime: true)
        let prefs = TransferPreferences(attributes: options)
        XCTAssertEqual(try JSONDecoder().decode(TransferPreferences.self, from: JSONEncoder().encode(prefs)).attributes, options)
        let task = RecoverableTransfer(account: .init(profile: ConnectionProfile(name: "test", host: "host")), name: "file", direction: .upload,
                                       roots: [.init(localPath: "/local/file", remotePath: "/remote/file")], attributes: options)
        let data = try JSONEncoder().encode(task)
        XCTAssertEqual(try JSONDecoder().decode(RecoverableTransfer.self, from: data).attributes, options)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "attributes")
        XCTAssertFalse(try JSONDecoder().decode(RecoverableTransfer.self, from: JSONSerialization.data(withJSONObject: json)).attributes.isEnabled)
    }

    func testMalformedAttributeSettingsCannotOverwriteExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-attribute-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let data = Data(#"{"maxConcurrentTransfers":2,"uploadLimitKiB":0,"downloadLimitKiB":0,"attributes":{"preservePermissions":"yes","preserveModificationTime":false}}"#.utf8)
        try data.write(to: file)
        let store = TransferPreferencesStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testWirePreservesSeparateAccessTimeAndUnknownTimes() throws {
        var wire = SFTPWriter()
        wire.uint32(8); wire.uint32(123); wire.uint32(456); wire.uint32(789)
        var reader = SFTPReader(wire.data)
        let attrs = try reader.attributes()
        XCTAssertEqual(attrs.accessedTime, 123); XCTAssertEqual(attrs.modifiedTime, 456)
        XCTAssertEqual(try reader.uint32(), 789)
        var empty = SFTPWriter(); empty.uint32(0)
        var missing = SFTPReader(empty.data)
        XCTAssertNil(try missing.attributes().accessedTime)
    }
}
