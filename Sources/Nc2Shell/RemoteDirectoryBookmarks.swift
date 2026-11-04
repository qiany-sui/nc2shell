import Foundation
import Combine
import Nc2ShellCore

@MainActor
final class RemoteDirectoryBookmarks: ObservableObject {
    static let shared = RemoteDirectoryBookmarks(store: .standard)

    @Published private(set) var bookmarks: [RemoteDirectoryBookmark] = []
    @Published private(set) var readError: String?
    private let store: RemoteBookmarkStore

    init(store: RemoteBookmarkStore) {
        self.store = store
        do { bookmarks = try store.load() }
        catch { readError = "无法读取目录收藏：\(error.localizedDescription)" }
    }

    func paths(for profile: ConnectionProfile) -> [String] {
        bookmarks.filter { $0.belongs(to: profile) }.map(\.path)
    }

    func contains(_ path: String, profile: ConnectionProfile) -> Bool {
        bookmarks.contains { $0.path == path && $0.belongs(to: profile) }
    }

    func toggle(_ path: String, profile: ConnectionProfile) throws {
        if let readError { throw ProfileError(readError) }
        var updated = bookmarks
        if let index = updated.firstIndex(where: { $0.path == path && $0.belongs(to: profile) }) {
            updated.remove(at: index)
        } else {
            updated.append(RemoteDirectoryBookmark(path: path, profile: profile))
        }
        try store.save(updated)
        bookmarks = updated
    }
}
