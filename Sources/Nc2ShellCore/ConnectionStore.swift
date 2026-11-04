import Foundation

public struct ConnectionStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: ConnectionStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConnectionStore(fileURL: root.appendingPathComponent("Nc2Shell/connections.json"))
    }

    public func load() throws -> [ConnectionProfile] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw ProfileError("连接配置中存在重复标识，请先检查配置文件。")
        }
        return try profiles.map { try $0.validated() }
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        // 先读取现有数据，避免把无法解析的用户配置覆盖成空列表。
        _ = try load()
        let values = try profiles.map { try $0.validated() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
