import Nc2ShellCore

/// 并行传输各自等待选择，但整个应用一次只展示一个冲突提示。
@MainActor
final class TransferConflictPresentationQueue {
    static let shared = TransferConflictPresentationQueue()

    private final class Entry {
        let server: String
        let conflict: TransferConflict
        let present: TransferConflictPrompt.Presenter
        let reply: TransferConflictPrompt.Reply
        var close: (() -> Void)?
        var response: (TransferConflictChoice, Bool)?
        var presenting = false
        var cancelled = false
        var finished = false

        init(server: String, conflict: TransferConflict, present: @escaping TransferConflictPrompt.Presenter,
             reply: @escaping TransferConflictPrompt.Reply) {
            self.server = server; self.conflict = conflict; self.present = present; self.reply = reply
        }
    }

    private var waiting: [Entry] = []
    private var active: Entry?
    private var draining = false

    func enqueue(server: String, conflict: TransferConflict, present: @escaping TransferConflictPrompt.Presenter,
                 reply: @escaping TransferConflictPrompt.Reply) -> () -> Void {
        let entry = Entry(server: server, conflict: conflict, present: present, reply: reply)
        waiting.append(entry)
        drain()
        return { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.cancel(entry)
        }
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while active == nil, !waiting.isEmpty {
            let entry = waiting.removeFirst()
            active = entry; entry.presenting = true
            entry.close = entry.present(entry.server, entry.conflict) { [weak self, weak entry] choice, remember in
                guard let self, let entry, !entry.finished, entry.response == nil else { return }
                entry.response = (choice, remember)
                self.finish(entry)
            }
            entry.presenting = false
            // presenter 可以同步回复；取得关闭句柄后才能释放展示位置。
            if entry.response != nil || entry.cancelled { finish(entry) }
        }
    }

    private func cancel(_ entry: Entry) {
        guard !entry.finished else { return }
        entry.cancelled = true
        if active === entry { finish(entry) }
        else {
            entry.finished = true
            waiting.removeAll { $0 === entry }
        }
    }

    private func finish(_ entry: Entry) {
        guard active === entry, !entry.presenting, !entry.finished else { return }
        entry.finished = true
        let close = entry.close; entry.close = nil
        // 关闭可能同步交付取消响应；先标记完成，且关闭返回前不展示下一项。
        close?()
        if let response = entry.response, !entry.cancelled { entry.reply(response.0, response.1) }
        active = nil
        drain()
    }
}
