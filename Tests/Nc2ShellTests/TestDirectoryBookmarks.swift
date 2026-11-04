import XCTest
import Nc2ShellCore
@testable import Nc2Shell

extension XCTestCase {
    @MainActor
    func makeTestDirectoryBookmarks() -> RemoteDirectoryBookmarks {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-test-bookmarks-\(UUID().uuidString)")
        // 每次创建独立存储，避免读取真实收藏，也避免不同测试会话相互污染。
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return RemoteDirectoryBookmarks(store: .init(fileURL: root.appendingPathComponent("bookmarks.json")))
    }
}
