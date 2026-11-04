import Foundation
import Combine
import Nc2ShellCore

@MainActor
final class RemoteBrowserState: ObservableObject {
    enum SortField: String, CaseIterable, Identifiable {
        case name, size, modified
        var id: Self { self }
        var title: String {
            switch self { case .name: return "名称"; case .size: return "大小"; case .modified: return "修改时间" }
        }
    }

    @Published var query = ""
    @Published var showHidden = false
    @Published var sortField: SortField = .name
    @Published var ascending = true

    func sortBy(_ field: SortField) {
        if sortField == field { ascending.toggle() }
        else { sortField = field; ascending = true }
    }

    func visibleFiles(_ files: [RemoteFile]) -> [RemoteFile] {
        files.filter { file in
            (showHidden || !file.name.hasPrefix(".")) && (query.isEmpty || file.name.localizedCaseInsensitiveContains(query))
        }.sorted { left, right in
            if (left.kind == .directory) != (right.kind == .directory) { return left.kind == .directory }
            switch sortField {
            case .size:
                if left.kind != .directory {
                    if left.hasSize != right.hasSize { return left.hasSize }
                    if left.size != right.size { return ascending ? left.size < right.size : left.size > right.size }
                }
            case .modified:
                // 未上报时间始终放在已知时间后面，不把它当作1970年。
                if (left.modifiedTime == nil) != (right.modifiedTime == nil) { return left.modifiedTime != nil }
                if let a = left.modifiedTime, let b = right.modifiedTime, a != b { return ascending ? a < b : a > b }
            case .name: break
            }
            let order = left.name.localizedStandardCompare(right.name)
            if order == .orderedSame { return left.name < right.name }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    func selectedFiles(_ files: [RemoteFile], selection: Set<String>) -> [RemoteFile] {
        visibleFiles(files).filter { selection.contains($0.name) }
    }

    static func paths(_ files: [RemoteFile], in directory: String) -> String {
        files.map { RemoteFile.join(directory, $0.name) }.joined(separator: "\n")
    }

    static func kind(_ file: RemoteFile) -> String {
        switch file.kind {
        case .file: return "文件"
        case .directory: return "文件夹"
        case .symbolicLink: return "符号链接"
        case .other: return "其他或未知类型"
        }
    }

    static func modified(_ file: RemoteFile) -> String {
        guard let time = file.modifiedTime else { return "未知" }
        return Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .numeric, time: .standard)
    }

    static func permissions(_ file: RemoteFile) -> String {
        guard file.mode != 0 else { return "未知" }
        var text: String
        switch file.kind { case .file: text = "-"; case .directory: text = "d"; case .symbolicLink: text = "l"; case .other: text = "?" }
        for group in [6, 3, 0] {
            text += file.mode & UInt32(4 << group) != 0 ? "r" : "-"
            text += file.mode & UInt32(2 << group) != 0 ? "w" : "-"
            let executable = file.mode & UInt32(1 << group) != 0
            let special: UInt32 = group == 6 ? 0o4000 : group == 3 ? 0o2000 : 0o1000
            if file.mode & special != 0 { text += group == 0 ? (executable ? "t" : "T") : (executable ? "s" : "S") }
            else { text += executable ? "x" : "-" }
        }
        return text + " (" + String(format: "%04o", file.mode & 0o7777) + ")"
    }
}
