import Foundation
import Combine
import Darwin
import Nc2ShellCore

/// 所有会话共用路径占用；旧任务完成清理前，调用方必须保留预约。
@MainActor
final class TransferPathReservations {
    static let shared = TransferPathReservations()
    let changes = PassthroughSubject<Void, Never>()

    struct Scope {
        private enum Location { case local, remote }
        private let location: Location
        private let writes: Bool
        private let components: [String]
        private let originalLocalPath: String?
        private let canonicalLocalPath: String?

        static func capture(roots: [RecoverableTransfer.Root], upload: Bool) throws -> [Scope] {
            try roots.flatMap { root in
                try validate(root.localPath); try validate(root.remotePath)
                let local = try canonicalLocal(root.localPath)
                return [Scope(location: .local, writes: !upload, components: familyComponents(local),
                              originalLocalPath: root.localPath, canonicalLocalPath: local),
                        // SSH 别名和不同账户仍可能访问同一目录，远端不按连接配置分区。
                        Scope(location: .remote, writes: upload, components: familyComponents(root.remotePath),
                              originalLocalPath: nil, canonicalLocalPath: nil)]
            }
        }

        func revalidate() throws {
            if let originalLocalPath, try Self.canonicalLocal(originalLocalPath) != canonicalLocalPath {
                throw ProfileError("本地路径在排队期间已变化，请重新添加传输：\(originalLocalPath)")
            }
        }

        fileprivate func conflicts(with other: Scope) -> Bool {
            guard location == other.location, writes || other.writes else { return false }
            return components.starts(with: other.components) || other.components.starts(with: components)
        }

        private static func canonicalLocal(_ path: String) throws -> String {
            var ancestor = URL(fileURLWithPath: path), missing: [String] = []
            while true {
                var metadata = stat()
                if lstat(ancestor.path, &metadata) == 0 {
                    guard let resolved = realpath(ancestor.path, nil) else {
                        throw ProfileError("无法确认本地路径，请检查目录与访问权限：\(path)")
                    }
                    defer { free(resolved) }
                    var canonical = URL(fileURLWithPath: String(cString: resolved))
                    for component in missing.reversed() { canonical.appendPathComponent(component) }
                    return canonical.path
                }
                guard errno == ENOENT, ancestor.path != "/" else {
                    throw ProfileError("无法确认本地路径，请检查目录与访问权限：\(path)")
                }
                // 目标尚不存在时，Foundation 不一定解析父目录别名，改为解析最近现有祖先。
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
        }

        private static func validate(_ path: String) throws {
            let components = path.split(separator: "/")
            guard path.hasPrefix("/"), !path.contains("\0"), !components.contains("."), !components.contains("..") else {
                throw ProfileError("传输路径必须是绝对路径，且不能包含 NUL、. 或 .. 路径段。")
            }
        }

        private static func familyComponents(_ path: String) -> [String] {
            let temporaryPrefixes = [".nc2shell-upload-", ".nc2shell-download-", ".nc2shell-backup-", ".nc2shell-copy-"]
            let guarded = path.split(separator: "/").prefix { component in
                let name = component.lowercased()
                return !temporaryPrefixes.contains { name.hasPrefix($0) }
            }
            // 显式选择暂存内容时扩大到父目录，避免读取另一任务尚未完成的隐藏文件。
            return guarded.map { component in
                var name = String(component).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping
                // 目录在全名后加序号，文件在最后一个扩展名前加序号；祖先段也必须比较名称族。
                let suffix = #" \((?:[2-9]|[1-9][0-9]+)\)\z"#
                while true {
                    let previous = name
                    name = name.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
                    let ext = (name as NSString).pathExtension
                    if !ext.isEmpty {
                        let stem = (name as NSString).deletingPathExtension
                        name = stem.replacingOccurrences(of: suffix, with: "", options: .regularExpression) + "." + ext
                    }
                    if name == previous { return name }
                }
            }
        }
    }

    private enum Reservation { case paths([Scope]), exclusive }
    private var reservations: [UUID: Reservation] = [:]
    private var changeScheduled = false
    var isIdle: Bool { reservations.isEmpty }

    func acquire(id: UUID, scopes: [Scope]) -> Bool {
        guard reservations[id] == nil else { return false }
        guard !scopes.isEmpty else { return acquireExclusive(id: id) }
        for reservation in reservations.values {
            switch reservation {
            case .exclusive: return false
            case .paths(let occupied):
                if scopes.contains(where: { scope in occupied.contains { scope.conflicts(with: $0) } }) { return false }
            }
        }
        reservations[id] = .paths(scopes)
        notifyChange()
        return true
    }

    func acquireExclusive(id: UUID) -> Bool {
        guard isIdle else { return false }
        reservations[id] = .exclusive
        notifyChange()
        return true
    }

    func release(id: UUID) {
        guard reservations.removeValue(forKey: id) != nil else { return }
        notifyChange()
    }

    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        // 完成回调可能同步入队；合并到下一轮主队列，避免跨会话调度重入。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.changes.send()
        }
    }
}
