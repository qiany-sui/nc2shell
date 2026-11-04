import Foundation

public struct TransferPreferences: Codable, Equatable {
    public var maxConcurrentTransfers: Int
    public var uploadLimitKiB: Int
    public var downloadLimitKiB: Int
    public var attributes: TransferAttributeOptions

    public init(maxConcurrentTransfers: Int = 2, uploadLimitKiB: Int = 0, downloadLimitKiB: Int = 0,
                attributes: TransferAttributeOptions = .init()) {
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.uploadLimitKiB = uploadLimitKiB
        self.downloadLimitKiB = downloadLimitKiB
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey { case maxConcurrentTransfers, uploadLimitKiB, downloadLimitKiB, attributes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentTransfers = try values.decode(Int.self, forKey: .maxConcurrentTransfers)
        uploadLimitKiB = try values.decode(Int.self, forKey: .uploadLimitKiB)
        downloadLimitKiB = try values.decode(Int.self, forKey: .downloadLimitKiB)
        attributes = try values.decodeIfPresent(TransferAttributeOptions.self, forKey: .attributes) ?? .init()
    }

    public func validated() throws -> TransferPreferences {
        guard (1...4).contains(maxConcurrentTransfers) else {
            throw ProfileError("每个会话同时传输数量需要在 1–4 之间。")
        }
        guard (0...1_048_576).contains(uploadLimitKiB), (0...1_048_576).contains(downloadLimitKiB) else {
            throw ProfileError("上传和下载限速需要在 0–1048576 KiB/s 之间；0 表示不限速。")
        }
        return self
    }
}

public struct TransferPreferencesStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: Self {
        Self(fileURL: ConnectionStore.standard.fileURL.deletingLastPathComponent().appendingPathComponent("transfer-settings.json"))
    }

    public func load() throws -> TransferPreferences {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return TransferPreferences() }
        return try JSONDecoder().decode(TransferPreferences.self, from: data).validated()
    }

    public func save(_ preferences: TransferPreferences) throws {
        // 保存前重新验证现有文件，避免损坏或不可读的配置被默认值覆盖。
        _ = try load()
        let value = try preferences.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
