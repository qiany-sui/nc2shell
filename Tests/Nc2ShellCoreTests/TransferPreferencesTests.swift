import XCTest
@testable import Nc2ShellCore

final class TransferPreferencesTests: XCTestCase {
    func testMissingSettingsUseDefaultsAndSaveRoundTrips() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("nested/transfer-settings.json"))
        let initial = try store.load()
        XCTAssertEqual(initial.maxConcurrentTransfers, 2)
        XCTAssertEqual(initial.uploadLimitKiB, 0)
        XCTAssertEqual(initial.downloadLimitKiB, 0)
        let value = TransferPreferences(maxConcurrentTransfers: 4, uploadLimitKiB: 1, downloadLimitKiB: 1_048_576)
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        try store.save(TransferPreferences(maxConcurrentTransfers: 1))
        XCTAssertEqual(try store.load().maxConcurrentTransfers, 1)
    }

    func testInvalidBoundsCannotReplaceSavedSettings() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer-settings.json"))
        let original = TransferPreferences(uploadLimitKiB: 512, downloadLimitKiB: 1024)
        try store.save(original)
        let invalid = [TransferPreferences(maxConcurrentTransfers: 0), TransferPreferences(maxConcurrentTransfers: 5),
                       TransferPreferences(uploadLimitKiB: -1), TransferPreferences(downloadLimitKiB: -1),
                       TransferPreferences(uploadLimitKiB: 1_048_577), TransferPreferences(downloadLimitKiB: 1_048_577)]
        for value in invalid {
            XCTAssertThrowsError(try value.validated())
            XCTAssertThrowsError(try store.save(value))
            XCTAssertEqual(try store.load(), original)
        }
    }

    func testCorruptOrInvalidSettingsAreNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("transfer-settings.json")
        for bytes in [Data("invalid json".utf8),
                      Data("{\"maxConcurrentTransfers\":2,\"uploadLimitKiB\":-1,\"downloadLimitKiB\":0}".utf8)] {
            try bytes.write(to: file)
            let store = TransferPreferencesStore(fileURL: file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TransferPreferences()))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testUnreadableSettingsAreNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("transfer-settings.json")
        let bytes = try JSONEncoder().encode(TransferPreferences())
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o000]))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = TransferPreferencesStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(TransferPreferences(uploadLimitKiB: 1)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-transfer-settings-\(UUID().uuidString)")
    }
}
