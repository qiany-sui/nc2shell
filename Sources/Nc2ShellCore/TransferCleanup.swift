import Foundation

public struct TransferCleanupPlan: Codable, Equatable {
    public struct Item: Codable, Equatable, Identifiable {
        public var id: String { path }
        public let path: String
        public let remote: Bool
        public var isDirectory: Bool { snapshot.directory }
        public var bytes: UInt64 { snapshot.size ?? 0 }
        let snapshot: TransferCheckpoint.Snapshot
        let localDevice: UInt64?
    }
    public let taskID: UUID
    public let items: [Item]
    public var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

enum CleanupEvidence {
    case directory
    case copying(TransferCheckpoint.Record)
    case completed(TransferCheckpoint.Snapshot)

    func validate(_ item: TransferCleanupPlan.Item) throws {
        let valid: Bool
        switch self {
        case .directory: valid = item.isDirectory
        case .completed(var snapshot):
            snapshot.children = nil
            var proposed = item.snapshot
            if snapshot.directory { snapshot.modified = nil; proposed.modified = nil }
            valid = snapshot == proposed
        case .copying(let record):
            let size = item.snapshot.size
            let identityMatches = record.upload || (record.localTemporaryIdentity != nil &&
                record.localTemporaryIdentity?.inode == item.snapshot.inode && record.localTemporaryIdentity?.device == item.localDevice)
            let prefixMatches = size != record.offset || record.offset == 0 || item.snapshot.digest == record.prefixDigest
            let sourceMatches = size != record.sourceSnapshot.size || record.sourceSnapshot.digest == nil || item.snapshot.digest == record.sourceSnapshot.digest
            valid = !item.isDirectory && size != nil && size! >= record.offset && size! <= (record.sourceSnapshot.size ?? 0) &&
                item.snapshot.digest != nil && identityMatches && prefixMatches && sourceMatches
        }
        guard valid else { throw SFTPError.message("清理清单与原始传输证据不匹配，未删除：\(item.path)") }
    }
}

extension TransferCheckpoint {
    func cleanupChildren(of record: Record) -> [Record] {
        let parent = record.choice == "merge" ? record.target : record.temporary
        return (record.sourceSnapshot.children ?? [:]).keys.sorted().compactMap { name in
            self.record(Self.key(upload: record.upload, source: RemoteFile.join(record.source, name), requested: RemoteFile.join(parent, name)))
        }
    }

    func cleanupEvidence(for roots: [Record]) throws -> [String: CleanupEvidence] {
        var paths: [String: CleanupEvidence] = [:]
        func result(_ snapshot: Snapshot, path: String, depth: Int) throws {
            guard depth < 64 else { throw SFTPError.message("清理目录过深。") }
            paths[path] = .completed(snapshot)
            for (name, child) in snapshot.children ?? [:] {
                try RemoteFile.validateName(name)
                try result(child, path: RemoteFile.join(path, name), depth: depth + 1)
            }
        }
        func visit(_ record: Record, inside: Bool) throws {
            switch record.phase {
            case "complete": if inside, let snapshot = record.result { try result(snapshot, path: record.target, depth: 0) }
            case "copying":
                paths[record.temporary] = record.sourceSnapshot.directory ? .directory : .copying(record)
                for child in cleanupChildren(of: record) { try visit(child, inside: true) }
            case "merging": for child in cleanupChildren(of: record) { try visit(child, inside: false) }
            case "prepared", "skipped": break
            default: throw SFTPError.message("安装结果不明，不能清理：\(record.target)\n暂存：\(record.temporary)\n备份：\(record.backup)")
            }
        }
        for root in roots { try visit(root, inside: false) }
        return paths
    }
}
