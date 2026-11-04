import Foundation

public enum TransferTrafficDirection: Sendable { case upload, download }

public final class TransferBandwidthLimiter: @unchecked Sendable {
    private static let burstBytes = 32 * 1024
    private let lock = NSLock()
    private var waiters: [ObjectIdentifier: DispatchSemaphore] = [:]
    private let upload: Budget
    private let download: Budget

    public init(uploadBytesPerSecond: UInt64 = 0, downloadBytesPerSecond: UInt64 = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        upload = Budget(rate: uploadBytesPerSecond, now: now)
        download = Budget(rate: downloadBytesPerSecond, now: now)
    }

    public func setLimits(uploadBytesPerSecond: UInt64, downloadBytesPerSecond: UInt64) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        upload.refill(at: now)
        download.refill(at: now)
        upload.rate = uploadBytesPerSecond
        download.rate = downloadBytesPerSecond
        for waiter in waiters.values { waiter.signal() }
        lock.unlock()
    }

    public func limit(for direction: TransferTrafficDirection) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return direction == .upload ? upload.rate : download.rate
    }

    public func acquire(bytes: Int, direction: TransferTrafficDirection, check: () throws -> Void) throws {
        var remaining = max(0, bytes)
        repeat {
            // 暂停可能阻塞检查回调；必须在锁外调用，其他会话和设置仍可继续。
            try check()
            guard remaining > 0 else { return }
            lock.lock()
            let budget = direction == .upload ? upload : download
            if budget.rate == 0 { lock.unlock(); return }
            budget.refill(at: ProcessInfo.processInfo.systemUptime)
            let count = min(remaining, Self.burstBytes)
            if budget.credit >= Double(count) {
                budget.credit -= Double(count)
                remaining -= count
                lock.unlock()
            } else {
                let delay = (Double(count) - budget.credit) / Double(budget.rate)
                let waiter = DispatchSemaphore(value: 0)
                let id = ObjectIdentifier(waiter)
                waiters[id] = waiter
                lock.unlock()
                // 使用单调截止时间，不受系统校时影响；修改额度会立即唤醒所有等待者。
                _ = waiter.wait(timeout: .now() + min(delay, 0.05))
                lock.lock()
                waiters.removeValue(forKey: id)
                lock.unlock()
            }
        } while remaining > 0
    }

    public func refundUnusedReadBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        download.refill(at: ProcessInfo.processInfo.systemUptime)
        // READ 提前预留额度；短读和 EOF 只归还未收到的部分，不能积累多块突发。
        download.credit = min(Double(Self.burstBytes), download.credit + Double(bytes))
        for waiter in waiters.values { waiter.signal() }
        lock.unlock()
    }

    private final class Budget {
        var rate: UInt64
        var credit = Double(TransferBandwidthLimiter.burstBytes)
        private var lastRefill: TimeInterval

        init(rate: UInt64, now: TimeInterval) { self.rate = rate; lastRefill = now }

        func refill(at now: TimeInterval) {
            // 使用单调时间补充额度，空闲或暂停时最多积累一个数据块。
            credit = rate == 0 ? Double(TransferBandwidthLimiter.burstBytes) :
                min(Double(TransferBandwidthLimiter.burstBytes), credit + max(0, now - lastRefill) * Double(rate))
            lastRefill = now
        }
    }
}
