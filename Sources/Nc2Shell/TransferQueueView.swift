import SwiftUI
import Combine

/// 汇总多个会话的队列；只订阅列表与状态变化，进度由任务行自己观察。
@MainActor
final class TransferQueuePresentation: ObservableObject {
    struct Entry: Identifiable {
        let session: TerminalSession
        let item: TransferQueueItem
        var id: UUID { item.id }
    }
    @Published private(set) var entries: [Entry] = []
    private var sessionObserver: AnyCancellable?
    private var queueObservers: [AnyCancellable] = []
    private var stateObservers: [AnyCancellable] = []

    var active: [Entry] { entries.filter { !$0.item.state.isFinished } }
    var attention: [Entry] { entries.filter { $0.item.state == .failed || $0.item.state == .cancelled } }
    var completed: [Entry] { entries.filter { $0.item.state == .completed } }

    init(model: AppModel) {
        sessionObserver = model.$sessions.sink { [weak self] sessions in
            guard let self else { return }
            self.queueObservers = []
            self.entries = []
            self.stateObservers = []
            self.queueObservers = sessions.map { session in
                session.files.$transferItems.sink { [weak self, weak session] items in
                    guard let self, let session else { return }
                    self.entries = self.entries.filter { $0.session.id != session.id } + items.map { Entry(session: session, item: $0) }
                    self.stateObservers = self.entries.map { entry in
                        entry.item.$state.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
                    }
                }
            }
        }
    }
}

struct TransferQueueView: View {
    @ObservedObject var model: AppModel
    @StateObject private var presentation: TransferQueuePresentation
    @State private var showCompleted = false

    init(model: AppModel) {
        self.model = model
        _presentation = StateObject(wrappedValue: TransferQueuePresentation(model: model))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if presentation.active.isEmpty && presentation.attention.isEmpty {
                    Text(presentation.completed.isEmpty ? "暂无传输任务" : "当前传输已结束")
                        .font(.system(size: 13)).foregroundStyle(WorkspaceAppearance.secondary).padding(.vertical, 6)
                }
                ForEach(presentation.active) { entry in
                    TransferQueueRow(session: entry.session, item: entry.item, model: entry.session.files)
                }
                ForEach(presentation.attention) { entry in
                    TransferQueueRow(session: entry.session, item: entry.item, model: entry.session.files)
                }
                if !presentation.completed.isEmpty {
                    HStack {
                        Button { showCompleted.toggle() } label: {
                            Label("已完成 · \(presentation.completed.count)", systemImage: showCompleted ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain)
                        Spacer()
                        Button("清理已完成") { model.sessions.forEach { $0.files.clearCompletedTransfers() } }
                            .buttonStyle(.plain).help("只移除成功记录，保留失败、取消和未完成任务；不删除文件。")
                    }.font(.system(size: 13)).foregroundStyle(WorkspaceAppearance.secondary).padding(.vertical, 4)
                    if showCompleted {
                        ForEach(presentation.completed) { entry in
                            TransferQueueRow(session: entry.session, item: entry.item, model: entry.session.files)
                        }
                    }
                }
                if let recovery = model.recovery {
                    RecoveryTransfersView(model: model, recovery: recovery)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

private struct TransferQueueRow: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var item: TransferQueueItem
    @ObservedObject var model: RemoteFilesModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: item.direction == .upload ? "tray.and.arrow.up" : "tray.and.arrow.down")
                    .foregroundStyle(WorkspaceAppearance.accent).help(item.direction.rawValue)
                Text(item.name).font(.system(size: 14)).lineLimit(1).help(item.name)
                Text(item.isEstimating ? "正在统计" : item.isWaitingForConflict ? "等待处理冲突" : item.state.rawValue)
                    .font(.system(size: 12)).foregroundStyle(item.state == .failed ? .red : WorkspaceAppearance.secondary)
                Text(session.profile.name).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                    .lineLimit(1).help(session.profile.destination)
                Spacer(minLength: 4)
                if item.state == .running || item.state == .queued {
                    Button { model.pauseTransfer(item.id) } label: { Image(systemName: "pause.fill").font(.system(size: 13)) }
                        .help("暂停传输").accessibilityLabel("暂停传输")
                }
                if item.state == .paused {
                    Button { model.resumeTransfer(item.id) } label: { Image(systemName: "play.fill").font(.system(size: 13)) }
                        .help("继续传输").accessibilityLabel("继续传输")
                }
                if !item.state.isFinished {
                    Button { model.cancelQueuedTransfer(item.id) } label: { Image(systemName: "xmark").font(.system(size: 13)) }
                        .help("取消此任务").accessibilityLabel("取消此任务")
                }
                if model.canRetry(item) {
                    Button { model.retryTransfer(item.id) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14)) }
                        .help("重试传输").accessibilityLabel("重试传输")
                }
                Button { showDetails.toggle() } label: { Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.system(size: 12)) }
                    .help(showDetails ? "收起传输详情" : "查看来源、目标与详情").accessibilityLabel("传输详情")
            }.buttonStyle(WorkspaceIconButton())
            if item.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in progressDetails(at: context.date) }
            } else { progressDetails(at: Date()) }
            if showDetails {
                Text("来源：\(item.source)\n目标：\(item.target)")
                    .font(.caption).foregroundStyle(WorkspaceAppearance.secondary).textSelection(.enabled)
                if item.reusedBytes > 0 { Text("已校验并复用 \(formatted(item.reusedBytes))").font(.caption) }
            }
            if let detail = item.detail, showDetails || item.state == .failed || item.state == .cancelled {
                Text(detail).font(.caption).foregroundStyle(item.state == .failed ? .red : WorkspaceAppearance.secondary)
                    .lineLimit(showDetails ? nil : 2).help(detail).textSelection(.enabled)
            }
            if item.state == .failed || item.state == .cancelled {
                if item.recoveryID != nil {
                    Text("可在下方待恢复传输中续传。").font(.caption).foregroundStyle(WorkspaceAppearance.secondary)
                } else if item.isFilePromise {
                    Text("请重新拖到 Finder 选择目标。").font(.caption).foregroundStyle(WorkspaceAppearance.secondary)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(WorkspaceAppearance.selected, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func progressDetails(at date: Date) -> some View {
        if item.isEstimating {
            HStack(spacing: 8) {
                if item.state == .running { ProgressView().controlSize(.mini) }
                Text("正在统计源文件大小…")
            }.font(.caption).foregroundStyle(WorkspaceAppearance.secondary)
        } else {
            VStack(spacing: 5) {
                if !item.state.isFinished, let fraction = item.fractionCompleted {
                    HStack {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(WorkspaceAppearance.accent)
                        Text("\(Int(fraction * 100))%").monospacedDigit()
                    }
                }
                HStack {
                    Text(formatted(item.bytes) + (!item.state.isFinished ? item.estimatedTotalBytes.map { " / " + formatted($0) } ?? " · 总量未知" : ""))
                    Spacer(minLength: 8)
                    if item.state == .running {
                        if item.isWaitingForConflict { Text("等待处理冲突") }
                        else if let speed = item.currentSpeed(at: date) {
                            Text("\(formatted(UInt64(speed)))/秒" + (item.remainingTimeText(at: date).map { " · 剩余 \($0)" } ?? ""))
                        } else { Text("等待进展") }
                    }
                }
            }.font(.caption).foregroundStyle(WorkspaceAppearance.secondary)
        }
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
