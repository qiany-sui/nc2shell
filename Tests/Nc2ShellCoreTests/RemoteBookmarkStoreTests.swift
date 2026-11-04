import XCTest
@testable import Nc2ShellCore

final class RemoteBookmarkStoreTests: XCTestCase {
    func testRoundTripPreservesRawPathsAndReplacesPreviousSnapshot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteBookmarkStore(fileURL: root.appendingPathComponent("nested/bookmarks.json"))
        XCTAssertEqual(try store.load(), [])
        let profile = ConnectionProfile(name: "服务器", host: "example.test", port: 2222, username: "nc")
        let values = [RemoteDirectoryBookmark(path: "/", profile: profile),
                      RemoteDirectoryBookmark(path: "/中文目录/ a\n ", profile: profile)]
        try store.save(values)
        XCTAssertEqual(try store.load(), values)
        try store.save([values[1]])
        XCTAssertEqual(try store.load(), [values[1]])
    }

    func testInvalidPathsCannotReplaceSavedBookmarks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteBookmarkStore(fileURL: root.appendingPathComponent("bookmarks.json"))
        let profile = ConnectionProfile(name: "服务器", host: "example.test")
        let original = [RemoteDirectoryBookmark(path: "/existing", profile: profile)]
        try store.save(original)
        for path in ["", "relative", " /wrong", "/bad\0path"] {
            XCTAssertThrowsError(try store.save([.init(path: path, profile: profile)]), path)
            XCTAssertEqual(try store.load(), original)
        }
    }

    func testCorruptAndSemanticallyInvalidFilesAreNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bookmarks.json")
        let profile = ConnectionProfile(name: "服务器", host: "example.test")
        let invalidPath = try JSONEncoder().encode([RemoteDirectoryBookmark(path: "relative", profile: profile)])
        let duplicated = RemoteDirectoryBookmark(path: "/same", profile: profile)
        let duplicateData = try JSONEncoder().encode([duplicated, duplicated])
        for bytes in [Data("invalid json".utf8), invalidPath, duplicateData] {
            try bytes.write(to: file)
            let store = RemoteBookmarkStore(fileURL: file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save([]))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testUnreadableFileCannotBeReplaced() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bookmarks.json")
        let original = Data("[]".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: original, attributes: [.posixPermissions: 0o000]))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = RemoteBookmarkStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-bookmarks-\(UUID().uuidString)")
    }
}
