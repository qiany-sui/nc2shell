import Foundation
import Combine
import Nc2ShellCore

@MainActor
final class TransferQueueItem: ObservableObject, Identifiable {
    enum Direction: String { case upload = "上传", download = "下载" }
    enum State: String {
        case queued = "等待中", running = "进行中", paused = "已暂停", completed = "完成", failed = "失败", cancelled = "已取消"
        var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    let id = UUID()
    let connectionID: UUID
    let name: String
    let direction: Direction
    let source: String
    let target: String
    let isFilePromise: Bool
    var recoveryID: UUID?
    @Published var state: State = .queued
    @Published var bytes: UInt64 = 0
    @Published private(set) var reusedBytes: UInt64 = 0
    @Published var bytesPerSecond: Double = 0
    @Published var detail: String?
    @Published private(set) var estimatedTotalBytes: UInt64?
    @Published var isEstimating = false
    @Published var isWaitingForConflict = false
    private var sampleDate = Date()
    private var sampleBytes: UInt64 = 0
    private var lastProgressDate: Date?

    init(connectionID: UUID, name: String, direction: Direction, source: String, target: String, isFilePromise: Bool) {
        self.connectionID = connectionID; self.name = name; self.direction = direction
        self.source = source; self.target = target; self.isFilePromise = isFilePromise
    }

    var fractionCompleted: Double? {
        if state == .completed { return 1 }
        guard !isEstimating, let total = estimatedTotalBytes, total > 0, bytes <= total else { return nil }
        // 写完字节后仍需关闭句柄、安装目标，只有实际成功才显示 100%。
        return min(Double(bytes) / Double(total), 0.99)
    }

    func finishEstimation(_ total: UInt64?, at date: Date = Date()) {
        guard !state.isFinished else { return }
        estimatedTotalBytes = total; isEstimating = false; resetSpeed(at: date)
    }

    func resetSpeed(at date: Date = Date()) {
        sampleDate = date; sampleBytes = bytes > reusedBytes ? bytes - reusedBytes : 0
        bytesPerSecond = 0; lastProgressDate = nil
    }

    func recordReused(_ value: UInt64, at date: Date = Date()) {
        guard !state.isFinished else { return }
        let transferred = bytes > reusedBytes ? bytes - reusedBytes : 0
        reusedBytes += value
        // 恢复确认的字节计入总进度，但不能当作刚传输的数据计算速度。
        resetSpeed(at: date)
        // 总进度回调随后才包含新增复用量，采样起点应保持原来的实际传输量。
        sampleBytes = transferred
    }

    func currentSpeed(at date: Date = Date()) -> Double? {
        guard state == .running, !isEstimating, !isWaitingForConflict,
              bytesPerSecond > 0, bytesPerSecond.isFinite, let lastProgressDate,
              date.timeIntervalSince(lastProgressDate) < 3 else { return nil }
        return bytesPerSecond
    }

    func remainingTime(at date: Date = Date()) -> TimeInterval? {
        guard let total = estimatedTotalBytes, total > bytes, let speed = currentSpeed(at: date) else { return nil }
        let seconds = Double(total - bytes) / speed
        return seconds.isFinite ? seconds : nil
    }

    func remainingTimeText(at date: Date = Date()) -> String? {
        guard let seconds = remainingTime(at: date) else { return nil }
        // 服务器的 UInt64 大小可超过日期格式器范围，不能溢出成“0 分钟”。
        if seconds >= 365 * 24 * 3_600 { return "超过一年" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)) ?? "未知"
    }

    func record(_ value: UInt64, at date: Date = Date()) {
        guard !state.isFinished, value >= bytes else { return }
        if value > bytes { lastProgressDate = date }
        bytes = value
        if let total = estimatedTotalBytes, value > total { estimatedTotalBytes = nil }
        guard state == .running else { return }
        let interval = date.timeIntervalSince(sampleDate)
        if interval >= 0.25 {
            let transferred = value > reusedBytes ? value - reusedBytes : 0
            bytesPerSecond = Double(transferred >= sampleBytes ? transferred - sampleBytes : 0) / interval
            sampleBytes = transferred; sampleDate = date
        }
    }
}

@MainActor
final class TransferWork {
    typealias Estimate = @MainActor (SFTPClient) async throws -> UInt64?
    typealias Resolver = @MainActor (TransferConflict) async throws -> TransferConflictChoice
    typealias Action = @MainActor (SFTPClient, @escaping Resolver, @escaping SFTPClient.Progress) async throws -> TransferResult
    let label: String
    let itemCount: Int?
    let successMessage: String?
    let batch: RemoteDownloadBatch?
    let estimate: Estimate
    let action: Action
    let scopes: [TransferPathReservations.Scope]
    let recoveryTicket: TransferRecoveryTicket?
    private let recoveryManager: TransferRecoveryManager?
    var completion: ((Error?) -> Void)?
    var cancelRequested = false

    init(label: String, itemCount: Int?, successMessage: String?, batch: RemoteDownloadBatch?, scopes: [TransferPathReservations.Scope], estimate: @escaping Estimate,
         recoveryTicket: TransferRecoveryTicket? = nil, recoveryManager: TransferRecoveryManager? = nil,
         completion: @escaping (Error?) -> Void, action: @escaping Action) {
        self.label = label; self.itemCount = itemCount; self.successMessage = successMessage; self.batch = batch
        self.estimate = estimate; self.completion = completion; self.action = action
        self.scopes = scopes
        self.recoveryTicket = recoveryTicket; self.recoveryManager = recoveryManager
    }

    func finish(_ error: Error?) {
        guard let callback = completion else { return }
        completion = nil
        if let recoveryTicket { recoveryManager?.finish(recoveryTicket, completed: error == nil) }
        callback(error)
    }
}

@MainActor
final class TransferExecution {
    let work: TransferWork
    let conflicts: TransferConflictPrompt
    var client: SFTPClient?

    init(work: TransferWork, conflicts: TransferConflictPrompt) {
        self.work = work; self.conflicts = conflicts
    }
}
