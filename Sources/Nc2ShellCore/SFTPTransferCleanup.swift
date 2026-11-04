import Foundation
import Darwin

extension SFTPClient {
    public func inspectCleanup(task: RecoverableTransfer, checkpoint: TransferCheckpoint) async throws -> TransferCleanupPlan {
        try await perform {
            try checkpoint.begin(); defer { checkpoint.end() }
            return try self.cleanupPlan(task: task, checkpoint: checkpoint)
        }
    }

    public func executeCleanup(task: RecoverableTransfer, checkpoint: TransferCheckpoint, expectedPlan: TransferCleanupPlan) async throws {
        try await perform {
            try checkpoint.begin(); defer { checkpoint.end() }
            let current = try self.cleanupPlan(task: task, checkpoint: checkpoint)
            guard current == expectedPlan else { throw SFTPError.message("清理内容在确认后已变化，请重新检查。") }
            try checkpoint.markCleanupStarted(checkpoint.cleanupPlan ?? current)
            // 整份清单先落盘；某次删除响应丢失时，重新检查只允许这些成员减少。
            let ordered = current.items.sorted { a, b in
                let left = a.path.split(separator: "/").count, right = b.path.split(separator: "/").count
                return left == right ? a.path < b.path : left > right
            }
            for item in ordered {
                try self.checkCancellation()
                guard try self.checkCleanupItem(item, allowMissing: true) else { continue }
                if item.isDirectory, try !self.resumeNames(item.path, remote: item.remote).isEmpty {
                    throw SFTPError.message("暂存目录出现新内容，已保留：\(item.path)")
                }
                if item.remote {
                    var body = SFTPWriter(); body.text(item.path)
                    _ = try self.request(item.isDirectory ? 15 : 13, body, expecting: 101)
                } else {
                    let result = item.isDirectory ? Darwin.rmdir(item.path) : Darwin.unlink(item.path)
                    guard result == 0 else { throw SFTPError.message("无法清理暂存，已保留剩余内容：\(item.path)\n\(String(cString: strerror(errno)))") }
                }
            }
        }
    }

    private func cleanupPlan(task: RecoverableTransfer, checkpoint: TransferCheckpoint) throws -> TransferCleanupPlan {
        let roots = try checkpoint.cleanupRoots(for: task)
        if let saved = checkpoint.cleanupPlan {
            let permitted = try checkpoint.cleanupEvidence(for: roots)
            var remaining: [TransferCleanupPlan.Item] = []
            let allPaths = Set(saved.items.map(\.path))
            var missing = Set<String>()
            // 先检查父目录；父目录已删时，不再尝试通过不存在的父路径读孩子。
            for item in saved.items.sorted(by: { $0.path.count < $1.path.count }) {
                if missing.contains(where: { item.path.hasPrefix($0 + "/") }) { missing.insert(item.path); continue }
                if try checkCleanupItem(item, allowMissing: true) {
                    if case .copying(let record) = permitted[item.path] {
                        guard try inspectCleanupFile(record) == item else { throw SFTPError.message("暂存文件与原始传输证据不匹配：\(item.path)") }
                    }
                    if item.isDirectory {
                        let actual = Set(try resumeNames(item.path, remote: item.remote).map { RemoteFile.join(item.path, $0) })
                        guard actual.isSubset(of: allPaths) else { throw SFTPError.message("清理目录出现新内容，已保留：\(item.path)") }
                    }
                    remaining.append(item)
                } else { missing.insert(item.path) }
            }
            for root in roots { try checkCleanupBackups(root, checkpoint: checkpoint, missing: missing) }
            return TransferCleanupPlan(taskID: task.id, items: remaining.sorted { $0.path < $1.path })
        }
        var items: [TransferCleanupPlan.Item] = []
        for root in roots { try inspectCleanupNode(root, insideStaging: false, checkpoint: checkpoint, items: &items) }
        guard Set(items.map(\.path)).count == items.count else { throw SFTPError.message("清理路径重叠，已停止。") }
        return TransferCleanupPlan(taskID: task.id, items: items.sorted { $0.path < $1.path })
    }

    private func cleanupChildren(_ record: ResumeRecord, checkpoint: TransferCheckpoint) -> [ResumeRecord] {
        checkpoint.cleanupChildren(of: record)
    }

    private func checkCleanupBackups(_ record: ResumeRecord, checkpoint: TransferCheckpoint, missing: Set<String>) throws {
        if missing.contains(where: { record.backup.hasPrefix($0 + "/") }) { return }
        guard try resumeMetadata(record.backup, remote: record.upload) == nil else {
            throw SFTPError.message("清理期间出现备份，已保留剩余内容：\(record.backup)")
        }
        if record.phase == "copying" || record.phase == "merging" {
            for child in cleanupChildren(record, checkpoint: checkpoint) {
                try checkCleanupBackups(child, checkpoint: checkpoint, missing: missing)
            }
        }
    }

    private func inspectCleanupNode(_ record: ResumeRecord, insideStaging: Bool, checkpoint: TransferCheckpoint, items: inout [TransferCleanupPlan.Item]) throws {
        try checkCancellation()
        guard try resumeMetadata(record.backup, remote: record.upload) == nil else {
            throw SFTPError.message("存在结果不明的备份，未清理：\(record.backup)")
        }
        switch record.phase {
        case "complete":
            if insideStaging {
                guard let result = record.result else { throw SFTPError.message("缺少已完成内容证据。") }
                try requireResumeSnapshot(result, at: record.target, remote: record.upload, content: true)
                try collectCleanupTree(path: record.target, remote: record.upload, snapshot: result, items: &items)
            }
        case "skipped": break
        case "prepared":
            guard try resumeMetadata(record.temporary, remote: record.upload) == nil else {
                throw SFTPError.message("暂存创建结果不明，未清理：\(record.temporary)")
            }
        case "copying", "merging":
            try requireResumeSnapshot(record.sourceSnapshot, at: record.source, remote: !record.upload, content: record.upload)
            if record.phase == "merging" {
                guard let target = try resumeMetadata(record.target, remote: record.upload), target.directory,
                      record.upload || target.inode == record.previous?.inode else { throw SFTPError.message("合并目录已变化：\(record.target)") }
                for child in cleanupChildren(record, checkpoint: checkpoint) {
                    try inspectCleanupNode(child, insideStaging: false, checkpoint: checkpoint, items: &items)
                }
            } else if record.sourceSnapshot.directory {
                guard let directory = try resumeMetadata(record.temporary, remote: record.upload), directory.directory else {
                    throw SFTPError.message("暂存目录缺失或类型变化：\(record.temporary)")
                }
                let start = items.count
                for child in cleanupChildren(record, checkpoint: checkpoint) {
                    try inspectCleanupNode(child, insideStaging: true, checkpoint: checkpoint, items: &items)
                }
                let actual = Set(try resumeNames(record.temporary, remote: record.upload).map { RemoteFile.join(record.temporary, $0) })
                let expected = Set(items[start...].map(\.path).filter { resumeParent($0) == record.temporary })
                guard actual == expected else { throw SFTPError.message("暂存目录含有未经确认的成员，未清理：\(record.temporary)") }
                items.append(try cleanupItem(record.temporary, remote: record.upload, snapshot: directory))
            } else {
                items.append(try inspectCleanupFile(record))
            }
        default:
            throw SFTPError.message("安装结果不明，未清理：\(record.target)\n暂存：\(record.temporary)\n备份：\(record.backup)")
        }
    }

    private func inspectCleanupFile(_ record: ResumeRecord) throws -> TransferCleanupPlan.Item {
        try requireResumeSnapshot(record.sourceSnapshot, at: record.source, remote: !record.upload, content: record.upload)
        guard let temporary = try resumeSnapshot(record.temporary, remote: record.upload, content: true), !temporary.directory,
              let size = temporary.size, size >= record.offset, size <= (record.sourceSnapshot.size ?? 0) else {
            throw SFTPError.message("暂存文件大小或类型已变化：\(record.temporary)")
        }
        if !record.upload {
            guard let identity = record.localTemporaryIdentity else { throw SFTPError.message("缺少本地暂存身份。") }
            try requireLocalTemporary(record.temporary, identity: identity)
        }
        let sourceDigest = try resumeDigest(resumeHash(record.source, remote: !record.upload, limit: size).0)
        guard temporary.digest == sourceDigest else { throw SFTPError.message("暂存内容与来源不匹配，未清理：\(record.temporary)") }
        if record.offset > 0 {
            guard let digest = record.prefixDigest, try resumeDigest(resumeHash(record.temporary, remote: record.upload, limit: record.offset).0) == digest else {
                throw SFTPError.message("暂存已确认片段发生变化：\(record.temporary)")
            }
        }
        try requireResumeSnapshot(record.sourceSnapshot, at: record.source, remote: !record.upload, content: record.upload)
        return try cleanupItem(record.temporary, remote: record.upload, snapshot: temporary)
    }

    private func collectCleanupTree(path: String, remote: Bool, snapshot: ResumeSnapshot, items: inout [TransferCleanupPlan.Item]) throws {
        items.append(try cleanupItem(path, remote: remote, snapshot: snapshot))
        for (name, child) in snapshot.children ?? [:] {
            try collectCleanupTree(path: RemoteFile.join(path, name), remote: remote, snapshot: child, items: &items)
        }
    }

    private func cleanupItem(_ path: String, remote: Bool, snapshot: ResumeSnapshot) throws -> TransferCleanupPlan.Item {
        var metadata = snapshot; metadata.children = nil
        var device: UInt64?
        if !remote {
            var info = Darwin.stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == (snapshot.directory ? S_IFDIR : S_IFREG),
                  snapshot.directory || info.st_nlink == 1, UInt64(info.st_ino) == snapshot.inode else {
                throw SFTPError.message("本地暂存身份已变化或存在硬链接：\(path)")
            }
            device = UInt64(UInt32(bitPattern: info.st_dev))
        }
        return .init(path: path, remote: remote, snapshot: metadata, localDevice: device)
    }

    private func checkCleanupItem(_ item: TransferCleanupPlan.Item, allowMissing: Bool) throws -> Bool {
        guard var actual = try resumeMetadata(item.path, remote: item.remote, includePermissions: item.snapshot.mode != nil) else {
            if allowMissing { return false }
            throw SFTPError.message("暂存已缺失：\(item.path)")
        }
        if !actual.directory { actual = try resumeSnapshot(item.path, remote: item.remote, content: true, includePermissions: item.snapshot.mode != nil) ?? actual }
        var expected = item.snapshot
        if item.isDirectory { actual.modified = nil; expected.modified = nil }
        guard actual == expected else { throw SFTPError.message("待清理内容已变化，未删除：\(item.path)") }
        let verified = try cleanupItem(item.path, remote: item.remote, snapshot: actual)
        guard verified.localDevice == item.localDevice else { throw SFTPError.message("本地暂存所在设备已变化：\(item.path)") }
        return true
    }
}
