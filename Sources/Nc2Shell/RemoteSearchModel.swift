import Foundation
import Combine
import Nc2ShellCore

@MainActor
final class RemoteSearchModel: ObservableObject {
    @Published var query = ""
    @Published var includeHidden = false
    @Published private(set) var directory = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var snapshot = RemoteSearchSnapshot()
    @Published private(set) var status = "输入文件名开始搜索"
    @Published private(set) var error: String?
    private(set) var connectionID = UUID()
    private var generation = UUID()
    private var makeClient: (() throws -> SFTPClient)?
    private var client: SFTPClient?

    func connect(connectionID: UUID, makeClient: @escaping () throws -> SFTPClient) {
        cancel()
        self.connectionID = connectionID; self.makeClient = makeClient
        isConnected = true; directory = ""; query = ""
        snapshot = RemoteSearchSnapshot(); error = nil; status = "输入文件名开始搜索"
    }

    func disconnect() {
        cancel()
        isConnected = false; makeClient = nil
        if !directory.isEmpty { error = "连接已断开，请重新连接后搜索。" }
    }

    func prepare(directory: String, includeHidden: Bool) {
        cancel()
        self.directory = directory; self.includeHidden = includeHidden
        query = ""; snapshot = RemoteSearchSnapshot(); error = nil; status = "输入文件名开始搜索"
    }

    func start() {
        guard isConnected, !isRunning, !directory.isEmpty, let makeClient else { return }
        guard !query.isEmpty, !query.contains("\0") else { error = "搜索名称不能为空或包含空字符。"; return }
        let id = UUID(), root = directory, name = query, hidden = includeHidden
        generation = id; snapshot = RemoteSearchSnapshot(); error = nil
        status = "正在搜索…"; isRunning = true
        Task {
            guard generation == id else { return }
            do {
                let worker = try makeClient(); client = worker
                let result = try await worker.search(directory: root, query: name, includeHidden: hidden) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.isRunning else { return }
                        self.snapshot = progress
                    }
                }
                guard generation == id else { return }
                snapshot = result
                status = result.truncated ? "已达到 1,000 条上限，结果可能不完整；请缩小范围或细化名称。" : result.skippedCount > 0 ? "搜索结束，部分目录未能搜索。" : "搜索完成"
            } catch {
                guard generation == id else { return }
                self.error = error.localizedDescription
                status = "搜索中断，已显示的结果可能不完整。"
            }
            guard generation == id else { return }
            client?.cancel(); client = nil; isRunning = false
        }
    }

    func cancel() {
        generation = UUID()
        client?.cancel(); client = nil
        if isRunning { status = "搜索已停止，已显示的结果可能不完整。" }
        isRunning = false
    }

    deinit { client?.cancel() }
}
