import Foundation
import Nc2ShellCore

@MainActor
final class RemoteDownloadBatch {
    let directory: String
    let connectionID: UUID
    let count: Int
    let allowRootRename: Bool
    let conflicts: TransferConflictPrompt
    var skippedCount = 0
    weak var model: RemoteFilesModel?
    var hasStarted = false
    private(set) var completed = 0
    private var running = false
    private var failure: Error?
    private struct Request {
        let file: RemoteFile
        let target: URL
        let recoveryTicket: TransferRecoveryTicket?
        let completion: (Error?) -> Void
    }
    private var pending: [Request] = []
    var hasPendingRequests: Bool { !pending.isEmpty }

    init(directory: String, connectionID: UUID, model: RemoteFilesModel, count: Int, allowRootRename: Bool = true) {
        self.directory = directory; self.connectionID = connectionID; self.model = model; self.count = count
        self.allowRootRename = allowRootRename
        conflicts = model.makeConflictPrompt()
    }

    func enqueue(_ file: RemoteFile, to target: URL, completion: @escaping (Error?) -> Void) {
        if let failure { completion(failure); return }
        do {
            guard let model else { throw ProfileError("连接已关闭，请重新连接后拖出文件。") }
            let ticket = try model.preparePromiseRecovery(file, target: target, batch: self)
            pending.append(Request(file: file, target: target, recoveryTicket: ticket, completion: completion))
        } catch { completion(error); stop(error); return }
        startNext()
    }

    func stop(_ error: Error) {
        conflicts.cancel()
        if failure == nil { failure = error }
        let remaining = pending; pending.removeAll()
        for request in remaining {
            if let ticket = request.recoveryTicket { ticket.manager.finish(ticket, completed: false) }
            request.completion(failure)
        }
    }

    private func startNext() {
        guard !running, !pending.isEmpty else { return }
        guard let model else {
            stop(SFTPError.message("连接已关闭，请重新连接后拖出文件。")); return
        }
        let request = pending.removeFirst()
        running = true
        // Finder 可能逐项等待完成后才请求下一项，不能等全部目标 URL 到齐再开始。
        model.downloadPromise(request.file, to: request.target, batch: self, recoveryTicket: request.recoveryTicket) { [self] error in
            let result = error ?? failure
            // 入队前校验失败也要释放占用；已由 TransferWork 结束的 ticket 不会重复生效。
            if let ticket = request.recoveryTicket { ticket.manager.finish(ticket, completed: result == nil) }
            if let result { stop(result) } else { completed += 1 }
            request.completion(result)
            running = false
            startNext()
        }
    }
}
