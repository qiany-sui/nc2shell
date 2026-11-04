import Foundation
import Darwin

extension SFTPClient {
    func finishTransferMetadata(_ root: ResumeRecord, checkpoint: TransferCheckpoint) throws {
        let rootKey = TransferCheckpoint.key(upload: root.upload, source: root.source, requested: root.requested)
        var currentPath = root.target
        do {
            let items = try checkpoint.metadataItems(for: root)
            var progress = checkpoint.metadataProgress(for: rootKey) ?? [:]
            guard var actual = try resumeSnapshot(root.target, remote: root.upload, content: true, includePermissions: true),
                  let original = root.result else { throw SFTPError.message("已完成目标不存在。") }
            // 只归一化已有写入意图允许的属性变化，内容/身份/其他字段仍须匹配原结果。
            for item in items { try normalizeMetadataTree(&actual, item: item, progress: progress[item.key]) }
            guard actual == original else { throw SFTPError.message("已完成内容或其属性已变化，不能补写。") }
            try checkpoint.saveMetadataProgress(progress, for: rootKey)
            for item in items where progress[item.key] != "complete" {
                currentPath = item.path
                try waitUntilResumed()
                try verifyMetadataItem(item, remote: root.upload, progress: progress[item.key])
                progress[item.key] = "applying"
                try checkpoint.saveMetadataProgress(progress, for: rootKey)
                try writeTransferMetadata(item, remote: root.upload)
                guard var after = try resumeMetadata(item.path, remote: root.upload, includePermissions: true) else {
                    throw SFTPError.message("属性写入后的目标不存在。")
                }
                try normalizeMetadata(&after, item: item, progress: "complete")
                var expected = item.original; expected.children = nil; expected.digest = nil
                guard after == expected else { throw SFTPError.message("属性写入后的目标身份或内容大小已变化。") }
                progress[item.key] = "complete"
                try checkpoint.saveMetadataProgress(progress, for: rootKey)
            }
        } catch {
            throw SFTPError.message("内容传输阶段已完成，属性未确认完成：\(currentPath)\n传输目标：\(root.target)\n\(error.localizedDescription)\n本批已停止。恢复会先校验内容再补写属性；若目标权限使内容不可读，需先自行检查权限。")
        }
    }

    private func normalizeMetadataTree(_ snapshot: inout ResumeSnapshot, item: TransferCheckpoint.MetadataItem,
                                       progress: String?, index: Int = 0) throws {
        if index == item.components.count { try normalizeMetadata(&snapshot, item: item, progress: progress); return }
        let name = item.components[index]
        guard var child = snapshot.children?[name] else { throw SFTPError.message("属性目标的目录成员已变化：\(item.path)") }
        try normalizeMetadataTree(&child, item: item, progress: progress, index: index + 1)
        snapshot.children?[name] = child
    }

    private func normalizeMetadata(_ snapshot: inout ResumeSnapshot, item: TransferCheckpoint.MetadataItem, progress: String?) throws {
        let targetMode = item.permissions ?? item.original.mode
        let targetTime = item.modifiedTime.map(Double.init) ?? item.original.modified
        let mayUseOriginal = progress != "complete"
        let mayUseTarget = progress == "applying" || progress == "complete"
        guard (mayUseOriginal && snapshot.mode == item.original.mode) || (mayUseTarget && snapshot.mode == targetMode),
              (mayUseOriginal && snapshot.modified == item.original.modified) || (mayUseTarget && snapshot.modified == targetTime) else {
            throw SFTPError.message("目标权限或修改时间不符合原记录/本次设置：\(item.path)")
        }
        snapshot.mode = item.original.mode; snapshot.modified = item.original.modified
    }

    private func verifyMetadataItem(_ item: TransferCheckpoint.MetadataItem, remote: Bool, progress: String?) throws {
        var actual: ResumeSnapshot
        if item.original.directory {
            guard let metadata = try resumeMetadata(item.path, remote: remote, includePermissions: true) else { throw SFTPError.message("属性目标不存在：\(item.path)") }
            actual = metadata
            guard Set(try resumeNames(item.path, remote: remote)) == Set((item.original.children ?? [:]).keys) else {
                throw SFTPError.message("属性目录成员已变化：\(item.path)")
            }
        } else {
            guard let snapshot = try resumeSnapshot(item.path, remote: remote, content: true, includePermissions: true) else { throw SFTPError.message("属性目标不存在：\(item.path)") }
            actual = snapshot
        }
        try normalizeMetadata(&actual, item: item, progress: progress)
        var expected = item.original
        if expected.directory { expected.children = nil }
        guard actual == expected else { throw SFTPError.message("属性目标的内容或身份已变化：\(item.path)") }
    }

    private func writeTransferMetadata(_ item: TransferCheckpoint.MetadataItem, remote: Bool) throws {
        try waitUntilResumed()
        try requireResumeParent(item.path, remote: remote)
        if remote {
            var query = SFTPWriter(); query.text(item.path)
            var response = try request(7, query, expecting: 105)
            let current = try response.attributes()
            guard current.mode & 0o170000 == (item.original.directory ? 0o040000 : 0o100000) else {
                throw SFTPError.message("属性目标类型已变化：\(item.path)")
            }
            var body = SFTPWriter(); body.text(item.path)
            body.uint32((item.permissions == nil ? 0 : 4) | (item.modifiedTime == nil ? 0 : 8))
            if let mode = item.permissions { body.uint32(mode) }
            if let time = item.modifiedTime {
                guard let accessed = current.accessedTime else { throw SFTPError.message("服务器未提供访问时间，无法在保留访问时间的同时修改 mtime：\(item.path)") }
                body.uint32(accessed); body.uint32(time)
            }
            _ = try request(9, body, expecting: 101)
        } else {
            let fd = Darwin.open(item.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw SFTPError.message("无法打开本地属性目标：\(item.path)") }
            defer { _ = Darwin.close(fd) }
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0, UInt64(info.st_ino) == item.original.inode,
                  info.st_mode & S_IFMT == (item.original.directory ? S_IFDIR : S_IFREG),
                  item.original.directory || info.st_nlink == 1 else {
                throw SFTPError.message("本地属性目标已变化或存在硬链接：\(item.path)")
            }
            // 使用同一已验证句柄；先写时间，最后收紧权限，保持访问时间的纳秒值。
            if let time = item.modifiedTime {
                var times = [info.st_atimespec, timespec(tv_sec: Int(time), tv_nsec: 0)]
                guard futimens(fd, &times) == 0 else { throw SFTPError.message("无法设置本地修改时间：\(item.path)\n\(String(cString: strerror(errno)))") }
            }
            if let mode = item.permissions, fchmod(fd, mode_t(mode)) != 0 {
                throw SFTPError.message("无法设置本地权限：\(item.path)\n\(String(cString: strerror(errno)))")
            }
        }
    }
}
