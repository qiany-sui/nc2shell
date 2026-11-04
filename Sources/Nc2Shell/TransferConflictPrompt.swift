import AppKit
import Nc2ShellCore

/// 一批传输共享选择；取消/断线必须结束等待，不能留下悬挂的文件承诺。
@MainActor
final class TransferConflictPrompt {
    typealias Reply = @MainActor (TransferConflictChoice, Bool) -> Void
    typealias Presenter = @MainActor (String, TransferConflict, @escaping Reply) -> (() -> Void)
    private struct Kind: Hashable {
        let sourceDirectory: Bool
        let destinationDirectory: Bool
    }
    private let server: String
    private let present: Presenter
    private var remembered: [Kind: TransferConflictChoice] = [:]
    private var pending: (id: UUID, continuation: CheckedContinuation<TransferConflictChoice, Error>)?
    private var closePrompt: (() -> Void)?
    private var cancelled = false
    // 断线会调用 cancel()；只有用户回复取消才把队列任务标为“已取消”。
    private(set) var wasCancelledByUser = false

    init(server: String, present: @escaping Presenter = TransferConflictPrompt.presentAlert) {
        self.server = server; self.present = present
    }

    func resolve(_ conflict: TransferConflict) async throws -> TransferConflictChoice {
        if cancelled || Task.isCancelled { return .cancel }
        let kind = Kind(sourceDirectory: conflict.sourceIsDirectory, destinationDirectory: conflict.destinationIsDirectory)
        if let choice = remembered[kind], choice != .keepBoth || conflict.canKeepBoth { return choice }
        guard pending == nil else { throw SFTPError.message("已有文件冲突等待处理，请先完成当前选择。") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancelled, !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                let id = UUID()
                pending = (id, continuation)
                let close = TransferConflictPresentationQueue.shared.enqueue(server: server, conflict: conflict, present: present) { [weak self] choice, applyToBatch in
                    guard let self, self.pending?.id == id else { return }
                    let valid = choice != .merge || (conflict.sourceIsDirectory && conflict.destinationIsDirectory)
                    let allowed = valid && (choice != .keepBoth || conflict.canKeepBoth)
                    let result: TransferConflictChoice = allowed ? choice : .cancel
                    if result == .cancel { self.cancelled = true; self.wasCancelledByUser = true }
                    else if applyToBatch { self.remembered[kind] = result }
                    self.finish(id, result)
                }
                if pending?.id == id { closePrompt = close } else { close() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        if let pending { finish(pending.id, .cancel) }
    }

    private func finish(_ id: UUID, _ result: TransferConflictChoice) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        let close = closePrompt; closePrompt = nil
        close?()
        current.continuation.resume(returning: result)
    }

    private static func presentAlert(_ server: String, _ conflict: TransferConflict, reply: @escaping Reply) -> () -> Void {
        guard var window = NSApp.mainWindow ?? NSApp.keyWindow else {
            reply(.cancel, false); return {}
        }
        while let parent = window.sheetParent { window = parent }
        let alert = NSAlert(); alert.alertStyle = .warning
        let sameFolders = conflict.sourceIsDirectory && conflict.destinationIsDirectory
        alert.messageText = sameFolders ? "目标已存在同名文件夹" : "目标已存在同名项目"
        let explanation: String
        if sameFolders {
            explanation = "合并：保留目标独有内容，并继续处理其中的同名文件。\n替换整个文件夹：移除目标原有内容，包含源目录中没有的文件。"
        } else if conflict.destinationIsDirectory {
            explanation = "替换会移除目标文件夹及其全部内容，再写入源文件。"
        } else {
            explanation = "覆盖会替换目标原有内容；跳过则保留目标，继续处理其余项目。"
        }
        alert.informativeText = "服务器：\(server)\n来源：\(conflict.sourcePath)\n目标：\(conflict.destinationPath)\n\n\(explanation)"
        var choices: [TransferConflictChoice] = [.cancel, .skip]
        alert.addButton(withTitle: "取消本批")
        alert.addButton(withTitle: "跳过")
        if conflict.canKeepBoth { choices.append(.keepBoth); alert.addButton(withTitle: "保留两份") }
        if sameFolders { choices.append(.merge); alert.addButton(withTitle: "合并文件夹") }
        choices.append(.replace)
        let replace = alert.addButton(withTitle: conflict.destinationIsDirectory ? "替换整个文件夹" : "覆盖")
        replace.hasDestructiveAction = true; replace.keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "对本批同类型冲突使用此选择"
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            reply(choices.indices.contains(index) ? choices[index] : .cancel, alert.suppressionButton?.state == .on)
        }
        return {
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
            alert.window.orderOut(nil)
        }
    }
}
