import XCTest
import Combine
import Nc2ShellCore
@testable import Nc2Shell

final class RemoteDirectoryBookmarkTests: XCTestCase {
    @MainActor
    func testTogglePersistsAndNotifiesAllObserversImmediately() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteBookmarkStore(fileURL: root.appendingPathComponent("bookmarks.json"))
        let bookmarks = RemoteDirectoryBookmarks(store: store)
        let profile = ConnectionProfile(name: "服务器", host: "example.test", username: "nc")
        var first: [[String]] = [], second: [[String]] = []
        let a = bookmarks.$bookmarks.sink { first.append($0.map(\.path)) }
        let b = bookmarks.$bookmarks.sink { second.append($0.map(\.path)) }
        defer { a.cancel(); b.cancel() }
        try bookmarks.toggle("/ 中文\n ", profile: profile)
        XCTAssertTrue(bookmarks.contains("/ 中文\n ", profile: profile))
        XCTAssertEqual(first, [[], ["/ 中文\n "]])
        XCTAssertEqual(second, first)
        XCTAssertEqual(RemoteDirectoryBookmarks(store: store).paths(for: profile), ["/ 中文\n "])
        try bookmarks.toggle("/ 中文\n ", profile: profile)
        XCTAssertFalse(bookmarks.contains("/ 中文\n ", profile: profile))
        XCTAssertEqual(RemoteDirectoryBookmarks(store: store).paths(for: profile), [])
    }

    @MainActor
    func testBookmarksUseProfileIDHostPortAndUsernameButIgnoreDisplayName() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = RemoteDirectoryBookmarks(store: RemoteBookmarkStore(fileURL: root.appendingPathComponent("bookmarks.json")))
        let original = ConnectionProfile(name: "服务器", host: "example.test", username: "nc")
        try bookmarks.toggle("/private", profile: original)
        var renamed = original
        renamed.name = "新名字"
        renamed.identityFile = "/another/key"
        XCTAssertEqual(bookmarks.paths(for: renamed), ["/private"])
        var newID = original; newID.id = UUID()
        var newHost = original; newHost.host = "another.test"
        var newPort = original; newPort.port = 2222
        var newUser = original; newUser.username = "another"
        for changed in [newID, newHost, newPort, newUser] {
            XCTAssertEqual(bookmarks.paths(for: changed), [])
            try bookmarks.toggle("/other", profile: changed)
            XCTAssertEqual(bookmarks.paths(for: changed), ["/other"])
            XCTAssertEqual(bookmarks.paths(for: original), ["/private"])
        }
    }

    @MainActor
    func testReadFailureIsVisibleAndBlocksToggle() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bookmarks.json")
        let original = Data("broken".utf8)
        try original.write(to: file)
        let bookmarks = RemoteDirectoryBookmarks(store: RemoteBookmarkStore(fileURL: file))
        let profile = ConnectionProfile(name: "服务器", host: "example.test")
        XCTAssertNotNil(bookmarks.readError)
        XCTAssertThrowsError(try bookmarks.toggle("/new", profile: profile))
        XCTAssertEqual(bookmarks.paths(for: profile), [])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testFailedSaveDoesNotPublishOrLoseExistingBookmarks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bookmarks.json")
        let bookmarks = RemoteDirectoryBookmarks(store: RemoteBookmarkStore(fileURL: file))
        let profile = ConnectionProfile(name: "服务器", host: "example.test")
        try bookmarks.toggle("/existing", profile: profile)
        var published: [[String]] = []
        let observation = bookmarks.$bookmarks.sink { published.append($0.map(\.path)) }
        defer { observation.cancel() }
        XCTAssertThrowsError(try bookmarks.toggle("relative", profile: profile))
        let corrupted = Data("external corruption".utf8)
        try corrupted.write(to: file)
        XCTAssertThrowsError(try bookmarks.toggle("/new", profile: profile))
        XCTAssertEqual(bookmarks.paths(for: profile), ["/existing"])
        XCTAssertEqual(published, [["/existing"]])
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-bookmark-state-\(UUID().uuidString)")
    }
}
