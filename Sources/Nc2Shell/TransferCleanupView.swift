import SwiftUI
import Nc2ShellCore

struct TransferCleanupView: View {
    @ObservedObject var controller: TransferCleanupController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("清理传输半成品").font(.headline)
            if let record = controller.record {
                Text(record.name).font(.subheadline)
                Text(verbatim: "\(record.account.username)@\(record.account.host):\(record.account.port)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if controller.phase == .ready, let plan = controller.plan {
                Text(plan.items.isEmpty ? "未发现需要删除的半成品；确认后将放弃续传并清理本任务的恢复资料。" : "将永久删除下面列出的半成品，并放弃本任务的续传。删除无法撤销；清理中断时，已删除的部分不会恢复。")
                Text("\(plan.items.count) 个文件或文件夹 · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.bytes), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.items) { item in
                            Label("\(item.remote ? "远程" : "本地")：\(item.path)", systemImage: item.isDirectory ? "folder" : "doc")
                                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: .infinity)
            } else if controller.isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(controller.phase == .inspecting ? "正在校验任务与暂存内容…" : controller.phase == .cancelling ? "正在停止，等待文件操作结束…" : "正在清理…")
                }
                Text("文件较大时，内容校验可能需要一些时间。").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if controller.phase == .done {
                Text("清理完成，任务恢复资料已移除。")
                Spacer()
            } else {
                if let error = controller.error { ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                Spacer()
            }
            HStack {
                Spacer()
                Button(controller.isWorking ? "停止" : controller.phase == .ready ? "取消" : "关闭") {
                    if controller.isWorking { controller.cancel() }
                    else { controller.cancel(); dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(controller.phase == .cancelling)
                if controller.phase == .ready {
                    Button("永久清理并放弃续传", role: .destructive) { controller.confirm() }
                }
            }
        }
        .padding(20).frame(width: 680, height: 440)
        .interactiveDismissDisabled(controller.isWorking)
        .onChange(of: controller.isConnected) { _, connected in if !connected { dismiss() } }
        .onDisappear { controller.cancel() }
    }
}

struct RecoveryMetadataCleanupView: View {
    let store: TransferRecoveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RecoveryMetadataCandidate]?
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("清理无任务的本地恢复资料").font(.headline)
            Text("只清理下面列出的本机检查点资料。来源、下载文件及服务器上的内容均会保留。")
            if working { ProgressView("正在检查或清理…").controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if done { Text("本地恢复资料清理完成。") }
            if let candidates {
                Text("\(candidates.count) 份资料 · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: candidates.reduce(0) { $0 + $1.bytes }), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { Text($0.path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            }
            Spacer()
            HStack {
                if error != nil { Button("重新检查") { inspect() }.disabled(working) }
                Spacer()
                Button(done ? "关闭" : "取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                if let candidates, !candidates.isEmpty, !done {
                    Button("永久清理这些资料", role: .destructive) { clean(candidates) }.disabled(working)
                }
            }
        }.padding(20).frame(width: 680, height: 400)
            .interactiveDismissDisabled(working)
            .task { inspect() }
    }

    private func inspect() {
        guard !working else { return }
        working = true; error = nil; done = false
        let store = store
        Task {
            do { candidates = try await Task.detached { try store.orphanedMetadata() }.value }
            catch { self.error = error.localizedDescription; candidates = nil }
            working = false
        }
    }

    private func clean(_ candidates: [RecoveryMetadataCandidate]) {
        working = true; error = nil
        let store = store
        Task {
            do {
                try await Task.detached { for candidate in candidates { try store.removeOrphanedMetadata(expected: candidate) } }.value
                self.candidates = []; done = true
            } catch { self.error = "清理已停止；此前已清理的资料不会恢复。\n\(error.localizedDescription)"; self.candidates = nil }
            working = false
        }
    }
}
