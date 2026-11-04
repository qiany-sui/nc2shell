import Foundation

extension TransferCheckpoint {
    struct MetadataItem {
        let key: String
        let path: String
        let components: [String]
        let original: Snapshot
        let permissions: UInt32?
        let modifiedTime: UInt32?
    }

    func metadataItems(for root: Record) throws -> [MetadataItem] {
        guard attributes.isEnabled, isBoundRoot(root), root.phase == "complete", let result = root.result else {
            throw SFTPError.message("内容尚未完成或根路径不匹配，不能设置传输属性。")
        }
        var items: [MetadataItem] = [], visited = Set<String>()
        func visit(_ node: Record, path: String, components: [String], original: Snapshot, expectedSource: Snapshot, depth: Int) throws {
            let key = Self.key(upload: root.upload, source: node.source, requested: node.requested)
            guard depth < 64, visited.insert(key).inserted, node.upload == root.upload, node.sourceSnapshot == expectedSource else {
                throw SFTPError.message("属性记录的来源或目录结构无效。")
            }
            if node.target != node.requested {
                let name = (node.requested as NSString).lastPathComponent
                guard node.canKeepBoth, node.choice == "keepBoth", (2...100_001).contains(where: {
                    RemoteFile.join(Record.parent(node.requested), Self.copyName(name, directory: expectedSource.directory, index: $0)) == node.target
                }) else { throw SFTPError.message("属性记录的保留两份目标无效。") }
            }
            if node.phase == "skipped" { return }
            guard node.phase == "complete", node.result != nil, original.directory == expectedSource.directory,
                  let mode = expectedSource.mode, mode <= 0o7777, let previousMode = original.mode, previousMode <= 0o7777 else {
                throw SFTPError.message("属性记录缺少完整内容或权限证据：\(path)")
            }
            if expectedSource.directory {
                let childrenParent = node.choice == "merge" ? node.target : node.temporary
                for (name, snapshot) in (expectedSource.children ?? [:]).sorted(by: { $0.key < $1.key }) {
                    try RemoteFile.validateName(name)
                    let childKey = Self.key(upload: node.upload, source: RemoteFile.join(node.source, name), requested: RemoteFile.join(childrenParent, name))
                    guard let child = record(childKey) else { throw SFTPError.message("属性记录缺少目录成员：\(name)") }
                    let actualName = (child.target as NSString).lastPathComponent
                    try RemoteFile.validateName(actualName)
                    guard let originalChild = original.children?[actualName] else { throw SFTPError.message("属性目标不在已完成内容中：\(actualName)") }
                    try visit(child, path: RemoteFile.join(path, actualName), components: components + [actualName],
                              original: originalChild, expectedSource: snapshot, depth: depth + 1)
                }
            }
            // 合并保留现有目录自身的权限和时间，子项仍逐个按实际冲突结果处理。
            if node.choice == "merge" {
                guard expectedSource.directory else { throw SFTPError.message("文件不能使用目录合并属性。") }
                return
            }
            var modifiedTime: UInt32?
            if attributes.preserveModificationTime {
                guard let time = expectedSource.modified, time.isFinite, time >= 0, time < Double(UInt32.max) + 1 else {
                    throw SFTPError.message("来源修改时间未知或超出 SFTP v3 支持范围：\(node.source)")
                }
                modifiedTime = UInt32(time)
            }
            items.append(.init(key: key, path: path, components: components, original: original,
                               permissions: attributes.preservePermissions ? mode & 0o777 : nil, modifiedTime: modifiedTime))
        }
        try visit(root, path: root.target, components: [], original: result, expectedSource: root.sourceSnapshot, depth: 0)
        guard Set(items.map(\.path)).count == items.count else { throw SFTPError.message("属性处理目标重复。") }
        return items
    }
}
