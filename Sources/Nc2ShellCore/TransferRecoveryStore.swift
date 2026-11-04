import Foundation
import Darwin
import CryptoKit

public struct RecoveryMetadataCandidate: Equatable, Identifiable {
    public let id: UUID
    public let path: String
    public let bytes: UInt64
    fileprivate let device: Int32
    fileprivate let inode: UInt64
    fileprivate let modified: timespec
    fileprivate let digest: Data

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.path == b.path && a.bytes == b.bytes && a.device == b.device && a.inode == b.inode &&
        a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec && a.digest == b.digest
    }
}

public struct TransferRecoveryAccount: Codable, Equatable {
    public let profileID: UUID
    public let host: String
    public let port: Int
    public let username: String

    public init(profile: ConnectionProfile) {
        profileID = profile.id
        host = profile.host
        port = profile.port
        username = profile.username
    }

    public func matches(_ profile: ConnectionProfile) -> Bool {
        profileID == profile.id && host == profile.host && port == profile.port && username == profile.username
    }

    fileprivate func validate() throws {
        let profile = try ConnectionProfile(id: profileID, name: "续传任务", host: host, port: port, username: username).validated()
        guard matches(profile) else {
            throw ProfileError("续传任务的连接信息无效，请先检查任务记录。")
        }
    }
}

public struct RecoverableTransfer: Codable, Identifiable, Equatable {
    public enum Direction: String, Codable {
        case upload, download
    }

    public struct Root: Codable, Equatable {
        public let localPath: String
        public let remotePath: String
        public let allowRootRename: Bool

        public init(localPath: String, remotePath: String, allowRootRename: Bool = true) {
            self.localPath = localPath
            self.remotePath = remotePath
            self.allowRootRename = allowRootRename
        }
    }

    public let id: UUID
    public let account: TransferRecoveryAccount
    public let name: String
    public let direction: Direction
    public let roots: [Root]
    public let requiresDestinationConfirmation: Bool
    public let createdAt: Date
    public var cleanupStartedAt: Date?
    public let attributes: TransferAttributeOptions

    public init(id: UUID = UUID(), account: TransferRecoveryAccount, name: String, direction: Direction,
                roots: [Root], requiresDestinationConfirmation: Bool = false, createdAt: Date = Date(),
                attributes: TransferAttributeOptions = .init()) {
        self.id = id
        self.account = account
        self.name = name
        self.direction = direction
        self.roots = roots
        self.requiresDestinationConfirmation = requiresDestinationConfirmation
        self.createdAt = createdAt
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey {
        case id, account, name, direction, roots, requiresDestinationConfirmation, createdAt, cleanupStartedAt, attributes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        account = try values.decode(TransferRecoveryAccount.self, forKey: .account)
        name = try values.decode(String.self, forKey: .name)
        direction = try values.decode(Direction.self, forKey: .direction)
        roots = try values.decode([Root].self, forKey: .roots)
        requiresDestinationConfirmation = try values.decode(Bool.self, forKey: .requiresDestinationConfirmation)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        cleanupStartedAt = try values.decodeIfPresent(Date.self, forKey: .cleanupStartedAt)
        attributes = try values.decodeIfPresent(TransferAttributeOptions.self, forKey: .attributes) ?? .init()
    }

    fileprivate func validate() throws {
        try account.validate()
        guard !roots.isEmpty else { throw ProfileError("续传任务至少需要一个传输项目。") }
        for root in roots {
            for path in [root.localPath, root.remotePath] {
                let components = path.split(separator: "/")
                guard path.hasPrefix("/"), !path.contains("\0"),
                      !components.contains(".."), !components.contains(".") else {
                    throw ProfileError("续传任务的路径必须是绝对路径，且不能包含 NUL、. 或 .. 路径段。")
                }
            }
        }
    }
}

public struct TransferRecoveryStore {
    public let directoryURL: URL

    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    public static var standard: TransferRecoveryStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TransferRecoveryStore(directoryURL: root.appendingPathComponent("Nc2Shell/transfer-recovery"))
    }

    public func load() throws -> [RecoverableTransfer] {
        guard try exists(directoryURL, as: .typeDirectory) else { return [] }
        var tasks: [RecoverableTransfer] = []
        for folder in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            guard folder.lastPathComponent == id.uuidString else {
                throw ProfileError("续传任务目录标识无效：\(folder.path)")
            }
            guard try exists(folder, as: .typeDirectory) else { continue }
            let file = folder.appendingPathComponent("task.json")
            // 移除任务后保留检查点目录；缺少描述不代表仍有可恢复任务。
            guard try exists(file, as: .typeRegular) else { continue }
            do {
                let task = try JSONDecoder().decode(RecoverableTransfer.self, from: Data(contentsOf: file))
                guard task.id == id else { throw ProfileError("续传任务标识与所在目录不匹配。") }
                try task.validate()
                tasks.append(task)
            } catch {
                throw ProfileError("无法读取续传任务记录 \(file.path)：\(error.localizedDescription)")
            }
        }
        return tasks.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }

    public func save(_ task: RecoverableTransfer) throws {
        try task.validate()
        let folder = taskDirectory(task.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try withMetadataLock(task.id) {
            // 放弃标记不能被此前读取的普通任务覆盖。
            let saved = try load()
            if let previous = saved.first(where: { $0.id == task.id }), previous.cleanupStartedAt != nil,
               task.cleanupStartedAt != previous.cleanupStartedAt { throw ProfileError("此任务已经放弃续传，不能恢复旧状态。") }
            if let previous = saved.first(where: { $0.id == task.id }), previous.attributes != task.attributes {
                throw ProfileError("已保存任务的属性选项不能改变，请发起新传输。")
            }
            if task.attributes.isEnabled {
                // 未启动的任务也先写 v3；旧 App 不能忽略属性选项后执行普通传输。
                _ = try TransferCheckpoint(fileURL: checkpointURL(for: task.id), attributes: task.attributes)
            }
            try writeTask(task)
        }
    }

    private func writeTask(_ task: RecoverableTransfer) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(task)
        let folder = taskDirectory(task.id)
        let file = folder.appendingPathComponent("task.json")
        _ = try exists(directoryURL, as: .typeDirectory)
        _ = try exists(folder, as: .typeDirectory)
        _ = try exists(file, as: .typeRegular)
        try data.write(to: file, options: .atomic)
    }

    public func remove(_ id: UUID) throws {
        guard try exists(directoryURL, as: .typeDirectory),
              try exists(taskDirectory(id), as: .typeDirectory) else { return }
        try withMetadataLock(id) {
            let file = taskDirectory(id).appendingPathComponent("task.json")
            guard try exists(file, as: .typeRegular) else { return }
            // 检查点和传输暂存由其他模块管理，移除描述不意味着删除用户内容。
            try FileManager.default.removeItem(at: file)
        }
    }

    public func markCleanupStarted(_ id: UUID) throws {
        try withMetadataLock(id) {
            guard var task = try load().first(where: { $0.id == id }) else { throw ProfileError("恢复任务已不存在。") }
            if task.cleanupStartedAt == nil { task.cleanupStartedAt = Date(); try writeTask(task) }
        }
    }

    public func removeCompletedCleanup(_ id: UUID) throws {
        try withMetadataLock(id) {
            guard let task = try load().first(where: { $0.id == id }), task.cleanupStartedAt != nil else {
                throw ProfileError("任务尚未明确放弃续传。")
            }
            let checkpoint = try TransferCheckpoint(fileURL: checkpointURL(for: id))
            try checkpoint.begin(); defer { checkpoint.end() }
            if try exists(checkpoint.fileURL, as: .typeRegular) {
                guard checkpoint.cleanupPlan != nil else { throw ProfileError("缺少清理完成的记录。") }
                try FileManager.default.removeItem(at: checkpoint.fileURL)
            }
            try FileManager.default.removeItem(at: taskDirectory(id).appendingPathComponent("task.json"))
        }
    }

    public func orphanedMetadata() throws -> [RecoveryMetadataCandidate] {
        guard try exists(directoryURL, as: .typeDirectory) else { return [] }
        var candidates: [RecoveryMetadataCandidate] = []
        for folder in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent), id.uuidString == folder.lastPathComponent else { continue }
            try withMetadataLock(id) {
                guard try !exists(folder.appendingPathComponent("task.json"), as: .typeRegular),
                      try exists(checkpointURL(for: id), as: .typeRegular) else { return }
                let checkpointLock = try RecoveryFileLock(checkpointURL(for: id).appendingPathExtension("lock"))
                try withExtendedLifetime(checkpointLock) { candidates.append(try metadataCandidate(id)) }
            }
        }
        return candidates.sorted { $0.path < $1.path }
    }

    public func removeOrphanedMetadata(expected: RecoveryMetadataCandidate) throws {
        try withMetadataLock(expected.id) {
            guard try !exists(taskDirectory(expected.id).appendingPathComponent("task.json"), as: .typeRegular) else {
                throw ProfileError("此资料已有关联任务，不能作为无任务资料清理。")
            }
            let checkpointLock = try RecoveryFileLock(checkpointURL(for: expected.id).appendingPathExtension("lock"))
            try withExtendedLifetime(checkpointLock) {
                guard try metadataCandidate(expected.id) == expected else { throw ProfileError("本地资料在预览后已变化，请重新检查。") }
                guard Darwin.unlink(expected.path) == 0 else { throw ProfileError("无法清理本地资料：\(expected.path)") }
            }
        }
    }

    private func metadataCandidate(_ id: UUID) throws -> RecoveryMetadataCandidate {
        let path = checkpointURL(for: id).path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProfileError("无法读取本地恢复资料：\(path)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var before = Darwin.stat(), after = Darwin.stat(), named = Darwin.stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 64 * 1024 * 1024 else { throw ProfileError("本地恢复资料不是有效的普通文件：\(path)") }
        let data = try file.readToEnd() ?? Data()
        guard fstat(fd, &after) == 0, lstat(path, &named) == 0, before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, data.count == before.st_size else {
            throw ProfileError("本地恢复资料在检查时已变化：\(path)")
        }
        return .init(id: id, path: path, bytes: UInt64(data.count), device: before.st_dev, inode: before.st_ino,
                     modified: before.st_mtimespec, digest: Data(SHA256.hash(data: data)))
    }

    private func withMetadataLock<T>(_ id: UUID, _ operation: () throws -> T) throws -> T {
        guard try exists(directoryURL, as: .typeDirectory), try exists(taskDirectory(id), as: .typeDirectory) else {
            throw ProfileError("恢复资料目录已不存在。")
        }
        let lock = try RecoveryFileLock(taskDirectory(id).appendingPathComponent("metadata.lock"))
        return try withExtendedLifetime(lock, operation)
    }

    public func checkpointURL(for id: UUID) -> URL {
        taskDirectory(id).appendingPathComponent("checkpoint.json")
    }

    private func taskDirectory(_ id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString)
    }

    private func exists(_ url: URL, as expectedType: FileAttributeType) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        guard attributes[.type] as? FileAttributeType == expectedType else {
            throw ProfileError("续传记录的位置不是预期的普通文件或目录，不能使用符号链接：\(url.path)")
        }
        return true
    }
}
