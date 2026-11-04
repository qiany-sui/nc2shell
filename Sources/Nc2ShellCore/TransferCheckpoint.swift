import Foundation
import Darwin
import CryptoKit

/// 一个队列任务共用一份检查点；回调报告本次调用确认复用的增量字节，不计入网络速度。
public final class TransferCheckpoint: @unchecked Sendable {
    public let fileURL: URL
    let onReusedBytes: @Sendable (UInt64) -> Void
    private let lock = NSLock()
    private var fileLock: RecoveryFileLock?
    private var original: Data?
    private var document = Document()
    private let requestedAttributes: TransferAttributeOptions?

    struct Snapshot: Codable, Equatable {
        var directory: Bool
        var size: UInt64?
        var modified: Double?
        var inode: UInt64?
        var digest: String?
        var children: [String: Snapshot]?
        var mode: UInt32?
        var resumable: Bool { directory ? (children?.values.allSatisfy(\.resumable) ?? false) : size != nil && modified != nil }
    }

    struct LocalIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct Record: Codable {
        let id: UUID
        let source: String
        let requested: String
        let upload: Bool
        let canKeepBoth: Bool
        let sourceSnapshot: Snapshot
        var target: String
        var previous: Snapshot?
        var choice: String
        var phase: String = "prepared"
        var offset: UInt64 = 0
        var prefixDigest: String?
        var localTemporaryIdentity: LocalIdentity?
        var result: Snapshot?
        var bytes: UInt64 = 0
        var skipped: Int = 0
        var temporary: String { Self.join(Self.parent(target), ".nc2shell-\(upload ? "upload" : "download")-\(id.uuidString)") }
        var backup: String { Self.join(Self.parent(target), ".nc2shell-backup-\(id.uuidString)") }
        static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        static func join(_ path: String, _ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }
    }

    private struct Document: Codable {
        var version = 1
        var records: [String: Record] = [:]
        var roots: [String: [String]] = [:]
        var cleanupPlan: TransferCleanupPlan?
        var attributes: TransferAttributeOptions?
        var metadataProgress: [String: [String: String]]?
    }

    public init(fileURL: URL, attributes: TransferAttributeOptions? = nil,
                onReusedBytes: @escaping @Sendable (UInt64) -> Void = { _ in }) throws {
        self.fileURL = fileURL.standardizedFileURL
        self.onReusedBytes = onReusedBytes
        self.requestedAttributes = attributes
        try reload()
        if let attributes {
            try begin(); defer { end() }
            if self.attributes != attributes {
                guard original == nil, document.records.isEmpty, document.roots.isEmpty, document.cleanupPlan == nil else {
                    throw SFTPError.message("传输属性选项与原检查点不一致，不能改变此任务的恢复方式。")
                }
                var updated = document; updated.version = 3; updated.attributes = attributes
                try persist(updated)
            }
        }
    }

    static func key(upload: Bool, source: String, requested: String) -> String {
        // JSON 编码避免文件名中的分隔符造成不同来源共用检查点。
        String(data: try! JSONEncoder().encode([upload ? "upload" : "download", source, requested]), encoding: .utf8)!
    }

    func begin() throws {
        guard lock.try() else { throw SFTPError.message("此续传记录正在使用。") }
        do {
            try validateParent()
            fileLock = try RecoveryFileLock(fileURL.appendingPathExtension("lock"))
            try reload()
        } catch { end(); throw error }
    }

    func end() {
        fileLock = nil
        lock.unlock()
    }

    func record(_ key: String) -> Record? { document.records[key] }
    var records: [Record] { Array(document.records.values) }
    var cleanupPlan: TransferCleanupPlan? { document.cleanupPlan }
    public var attributes: TransferAttributeOptions { document.attributes ?? .init() }
    func isBoundRoot(_ record: Record) -> Bool { document.roots.values.contains([record.source, record.requested]) }
    func metadataProgress(for root: String) -> [String: String]? { document.metadataProgress?[root] }

    func saveMetadataProgress(_ progress: [String: String], for root: String) throws {
        guard attributes.isEnabled, let record = record(root) else { throw SFTPError.message("缺少属性处理的根记录。") }
        let allowed = Set(try metadataItems(for: record).map(\.key))
        guard Set(progress.keys).isSubset(of: allowed), progress.values.allSatisfy({ ["applying", "complete"].contains($0) }),
              (metadataProgress(for: root) ?? [:]).allSatisfy({ progress[$0.key] != nil && ($0.value != "complete" || progress[$0.key] == "complete") }) else {
            throw SFTPError.message("属性处理状态无效或不属于此传输。")
        }
        var updated = document
        if updated.metadataProgress == nil { updated.metadataProgress = [:] }
        updated.metadataProgress?[root] = progress
        try persist(updated)
    }

    func markCleanupStarted(_ plan: TransferCleanupPlan) throws {
        if let existing = document.cleanupPlan {
            guard existing == plan else { throw SFTPError.message("清理清单已变化，不能覆盖原始删除意图。") }
            return
        }
        // 旧版本只接受 v1，避免它忽略新字段后把已放弃任务当作普通续传。
        var updated = document; updated.version = attributes.isEnabled ? 3 : 2; updated.cleanupPlan = plan
        try persist(updated)
    }

    func requireResumable() throws {
        guard document.cleanupPlan == nil else { throw SFTPError.message("此任务已放弃续传，只能继续检查并清理。") }
        guard requestedAttributes == nil || requestedAttributes == attributes else { throw SFTPError.message("传输属性选项与检查点不匹配。") }
    }

    func cleanupRoots(for task: RecoverableTransfer) throws -> [Record] {
        guard attributes == task.attributes else { throw SFTPError.message("清理任务的属性选项与检查点不匹配。") }
        let upload = task.direction == .upload
        var roots: [Record] = [], rootKeys = Set<String>(), visited = Set<String>()
        func validateSnapshot(_ snapshot: Snapshot, depth: Int) throws {
            guard depth < 64, snapshot.directory == (snapshot.children != nil) else { throw SFTPError.message("清理记录的目录结构无效。") }
            for (name, child) in snapshot.children ?? [:] {
                try RemoteFile.validateName(name)
                try validateSnapshot(child, depth: depth + 1)
            }
        }
        func visit(source: String, requested: String, canKeepBoth: Bool, expected: Snapshot?, depth: Int) throws {
            let key = Self.key(upload: upload, source: source, requested: requested)
            guard let record = document.records[key] else { return }
            guard depth < 64, visited.insert(key).inserted, record.canKeepBoth == canKeepBoth,
                  expected == nil || record.sourceSnapshot == expected else { throw SFTPError.message("清理记录与任务的来源目录不匹配。") }
            try validateSnapshot(record.sourceSnapshot, depth: depth)
            if record.target != requested {
                let name = (requested as NSString).lastPathComponent
                guard record.choice == "keepBoth", canKeepBoth,
                      (2...100_001).contains(where: { Record.join(Record.parent(requested), Self.copyName(name, directory: record.sourceSnapshot.directory, index: $0)) == record.target }) else {
                    throw SFTPError.message("清理记录的保留两份目标无效。")
                }
            }
            let parent = record.choice == "merge" ? record.target : record.temporary
            for (name, child) in record.sourceSnapshot.children ?? [:] {
                try visit(source: Record.join(source, name), requested: Record.join(parent, name), canKeepBoth: true, expected: child, depth: depth + 1)
            }
        }
        for root in task.roots {
            let source = upload ? root.localPath : root.remotePath, requested = upload ? root.remotePath : root.localPath
            let key = Self.key(upload: upload, source: source, requested: requested)
            guard rootKeys.insert(key).inserted else { throw SFTPError.message("清理任务包含重复的根路径。") }
            guard let resolved = document.roots[key] else { continue }
            let local = URL(fileURLWithPath: root.localPath)
            let canonical = local.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(local.lastPathComponent).path
            let expected = upload ? [canonical, root.remotePath] : [root.remotePath, canonical]
            guard resolved == expected else { throw SFTPError.message("清理任务的规范路径已变化或不匹配。") }
            try visit(source: resolved[0], requested: resolved[1], canKeepBoth: root.allowRootRename, expected: nil, depth: 0)
            if let record = document.records[Self.key(upload: upload, source: resolved[0], requested: resolved[1])] { roots.append(record) }
        }
        guard Set(document.roots.keys).isSubset(of: rootKeys), visited == Set(document.records.keys) else {
            throw SFTPError.message("检查点含有不属于此任务的根路径或子项，不能清理。")
        }
        if let plan = document.cleanupPlan {
            guard plan.taskID == task.id, Set(plan.items.map(\.path)).count == plan.items.count else { throw SFTPError.message("清理清单的任务或项目标识无效。") }
            let evidence = try cleanupEvidence(for: roots)
            for item in plan.items {
                guard item.remote == upload, let original = evidence[item.path] else { throw SFTPError.message("清理清单超出任务暂存范围：\(item.path)") }
                try original.validate(item)
            }
        }
        return roots
    }

    static func copyName(_ name: String, directory: Bool, index: Int) -> String {
        let suffix = directory ? "" : (name as NSString).pathExtension
        if suffix.isEmpty { return "\(name) (\(index))" }
        return "\((name as NSString).deletingPathExtension) (\(index)).\(suffix)"
    }

    func identifier(for key: String) -> UUID {
        let hash = SHA256.hash(data: Data((fileURL.path + "\0" + key).utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let value = Array(hex)
        return UUID(uuidString: [String(value[0..<8]), String(value[8..<12]), String(value[12..<16]), String(value[16..<20]), String(value[20..<32])].joined(separator: "-"))!
    }

    func bindRoot(source: String, requested: String, upload: Bool, resolvedSource: String, resolvedTarget: String) throws {
        let key = Self.key(upload: upload, source: source, requested: requested)
        let paths = [resolvedSource, resolvedTarget]
        if let original = document.roots[key] {
            guard original == paths else {
                let record = document.records[Self.key(upload: upload, source: original[0], requested: original[1])]
                let locations = record.map { "\n暂存：\($0.temporary)\n备份：\($0.backup)" } ?? ""
                throw SFTPError.message("来源或目标目录的规范路径已变化，不能重定向续传。\(locations)")
            }
        } else {
            var updated = document; updated.roots[key] = paths
            try persist(updated)
        }
    }

    func save(_ record: Record, key: String) throws {
        var updated = document
        updated.records[key] = record
        try persist(updated)
    }

    private func persist(_ updated: Document) throws {
        try validateParent()
        let current = try readData()
        guard current == original else { throw SFTPError.message("续传检查点已被外部修改，已停止写入：\(fileURL.path)") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        guard data.count <= 64 * 1024 * 1024 else { throw SFTPError.message("续传检查点过大，已保留上一次记录并停止传输。") }
        do { try data.write(to: fileURL, options: .atomic) }
        catch { throw SFTPError.message("无法保存续传检查点，传输已停止：\(fileURL.path)\n\(error.localizedDescription)") }
        document = updated; original = data
    }

    private func validateParent() throws {
        let parent = fileURL.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath() == parent,
              (try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw SFTPError.message("续传记录目录无效或包含符号链接。")
        }
    }

    private func readData() throws -> Data? {
        // 非阻塞打开后再检查类型，避免路径被替换成 FIFO 时阻塞在 open。
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SFTPError.message("无法读取续传检查点：\(fileURL.path)")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = Darwin.stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 64 * 1024 * 1024 else {
            throw SFTPError.message("续传检查点不是有效的普通文件。")
        }
        return try file.readToEnd() ?? Data()
    }

    private func reload() throws {
        try validateParent()
        original = try readData()
        guard let original else { document = Document(); return }
        do {
            document = try JSONDecoder().decode(Document.self, from: original)
            let legacy = document.attributes == nil && document.metadataProgress == nil
            guard (legacy && ((document.version == 1 && document.cleanupPlan == nil) || (document.version == 2 && document.cleanupPlan != nil))) ||
                    (document.version == 3 && document.attributes?.isEnabled == true),
                  document.roots.values.allSatisfy({ $0.count == 2 }) else { throw SFTPError.message("版本或根路径无效") }
            for (key, record) in document.records {
                guard key == Self.key(upload: record.upload, source: record.source, requested: record.requested),
                      record.id == identifier(for: key),
                      ["prepared", "copying", "installing", "complete", "skipped", "merging"].contains(record.phase),
                      ["new", "replace", "keepBoth", "merge", "skip"].contains(record.choice),
                      record.skipped >= 0, record.phase != "complete" || record.result != nil else { throw SFTPError.message("字段无效") }
                for path in [record.source, record.requested, record.target] {
                    guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw SFTPError.message("路径无效") }
                }
                guard Record.parent(record.target) == Record.parent(record.requested),
                      record.target == record.requested || (record.choice == "keepBoth" && record.canKeepBoth) else { throw SFTPError.message("目标不匹配") }
            }
            for (key, progress) in document.metadataProgress ?? [:] {
                guard let root = document.records[key], root.phase == "complete" else { throw SFTPError.message("属性处理根记录无效") }
                let allowed = Set(try metadataItems(for: root).map(\.key))
                guard Set(progress.keys).isSubset(of: allowed), progress.values.allSatisfy({ ["applying", "complete"].contains($0) }) else {
                    throw SFTPError.message("属性处理状态无效")
                }
            }
        } catch { throw SFTPError.message("续传检查点损坏或不受支持，原文件未覆盖：\(fileURL.path)\n\(error.localizedDescription)") }
    }
}
