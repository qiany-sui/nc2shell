import Foundation
import Combine

@MainActor
final class RemoteNavigationState: ObservableObject {
    struct Target: Equatable {
        let path: String
        let index: Int
        fileprivate let revision: UInt64
    }

    struct Breadcrumb: Identifiable, Equatable {
        let name: String
        let path: String
        var id: String { path }
    }

    @Published private(set) var paths: [String] = []
    @Published private(set) var index: Int?
    private var revision: UInt64 = 0

    var currentPath: String? {
        guard let index, paths.indices.contains(index) else { return nil }
        return paths[index]
    }
    var canGoBack: Bool { backTarget != nil }
    var canGoForward: Bool { forwardTarget != nil }

    var backTarget: Target? {
        guard let index, index > 0, paths.indices.contains(index - 1) else { return nil }
        return Target(path: paths[index - 1], index: index - 1, revision: revision)
    }

    var forwardTarget: Target? {
        guard let index, index + 1 < paths.count else { return nil }
        return Target(path: paths[index + 1], index: index + 1, revision: revision)
    }

    func commit(_ resolvedPath: String, target: Target? = nil) {
        guard resolvedPath.hasPrefix("/"), !resolvedPath.contains("\0") else { return }
        if let target {
            // 目录异步加载成功后再移动索引，旧连接或旧分支的目标不能改写新历史。
            guard target.revision == revision, paths.indices.contains(target.index), paths[target.index] == target.path else { return }
            paths[target.index] = resolvedPath
            index = target.index
        } else {
            guard currentPath != resolvedPath else { return }
            if let index { paths = Array(paths.prefix(index + 1)) }
            paths.append(resolvedPath)
            index = paths.count - 1
        }
        revision &+= 1
    }

    func reset() {
        paths = []
        index = nil
        revision &+= 1
    }

    static func breadcrumbs(for path: String) -> [Breadcrumb] {
        guard path.hasPrefix("/"), !path.contains("\0") else { return [] }
        return [Breadcrumb(name: "/", path: "/")] + path.split(separator: "/").map { component in
            Breadcrumb(name: String(component), path: String(path[..<component.endIndex]))
        }
    }
}
