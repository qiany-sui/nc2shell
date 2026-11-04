import AppKit
import UniformTypeIdentifiers
import Nc2ShellCore

@MainActor
final class RemoteDownloadPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let file: RemoteFile
    private var batch: RemoteDownloadBatch

    init(file: RemoteFile, directory: String, connectionID: UUID, model: RemoteFilesModel) {
        self.file = file
        batch = RemoteDownloadBatch(directory: directory, connectionID: connectionID, model: model, count: 1, allowRootRename: false)
        super.init()
        fileType = file.kind == .directory ? UTType.folder.identifier : UTType.data.identifier
        // 系统持有提供者直到承诺兑现；委托使用自身，避免列表刷新后弱委托失效。
        delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file.name }

    static func group(_ promises: [RemoteDownloadPromise]) {
        guard let first = promises.first, let model = first.batch.model else { return }
        let batch = RemoteDownloadBatch(directory: first.batch.directory, connectionID: first.batch.connectionID, model: model, count: promises.count, allowRootRename: false)
        for promise in promises { promise.batch = batch }
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping (Error?) -> Void) {
        // AppKit 可在工作队列兑现承诺；自有状态的读取和修改始终切回主线程。
        DispatchQueue.main.async {
            // Finder 可以调整最终名称；必须写入系统给出的 URL，不能自行重建落点。
            self.batch.enqueue(self.file, to: url, completion: completionHandler)
        }
    }
}
