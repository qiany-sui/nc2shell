import Foundation

public struct RemoteDirectoryBookmark: Codable, Equatable, Hashable {
    public let profileID: UUID
    public let host: String
    public let port: Int
    public let username: String
    public let path: String

    public init(path: String, profile: ConnectionProfile) {
        profileID = profile.id
        host = profile.host
        port = profile.port
        username = profile.username
        self.path = path
    }

    public func belongs(to profile: ConnectionProfile) -> Bool {
        profileID == profile.id && host == profile.host && port == profile.port && username == profile.username
    }

    fileprivate func validate() throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ProfileError("收藏目录必须是绝对路径，且不能包含 NUL 字符。")
        }
        let profile = try ConnectionProfile(id: profileID, name: "目录收藏", host: host, port: port, username: username).validated()
        guard profile.host == host, profile.username == username else {
            throw ProfileError("目录收藏的连接信息无效，请先检查收藏文件。")
        }
    }
}

public struct RemoteBookmarkStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: RemoteBookmarkStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RemoteBookmarkStore(fileURL: root.appendingPathComponent("Nc2Shell/remote-directory-bookmarks.json"))
    }

    public func load() throws -> [RemoteDirectoryBookmark] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let bookmarks = try JSONDecoder().decode([RemoteDirectoryBookmark].self, from: data)
        try validate(bookmarks)
        return bookmarks
    }

    public func save(_ bookmarks: [RemoteDirectoryBookmark]) throws {
        // 保存前重读，损坏或不可读的收藏不能被空列表或旧内存快照覆盖。
        _ = try load()
        try validate(bookmarks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bookmarks)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ bookmarks: [RemoteDirectoryBookmark]) throws {
        guard Set(bookmarks).count == bookmarks.count else {
            throw ProfileError("目录收藏中存在重复项目，请先检查收藏文件。")
        }
        try bookmarks.forEach { try $0.validate() }
    }
}
