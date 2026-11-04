import XCTest
@testable import Nc2ShellCore

final class TransferBandwidthLimiterTests: XCTestCase {
    func testConcurrentClientsShareOneUploadAllowance() throws {
        let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: 256 * 1024)
        let finished = expectation(description: "两个上传客户端结束")
        finished.expectedFulfillmentCount = 2
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2 {
            DispatchQueue.global().async {
                do {
                    for _ in 0..<4 { try limiter.acquire(bytes: 32 * 1024, direction: .upload, check: {}) }
                } catch { XCTFail(error.localizedDescription) }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 4)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // 总计 256 KiB，最多预支 32 KiB，256 KiB/s 至少需要 0.875 秒。
        XCTAssertGreaterThanOrEqual(elapsed, 0.82)
        XCTAssertLessThan(elapsed, 3)
    }

    func testUploadWaitDoesNotBlockIndependentDownloadBudget() throws {
        let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: 1, downloadBytesPerSecond: 256 * 1024)
        try limiter.acquire(bytes: 32 * 1024, direction: .upload, check: {})
        let waiting = expectation(description: "上传等待中")
        let finished = expectation(description: "上传取消退出")
        let cancelled = LimiterTestFlag()
        DispatchQueue.global().async {
            var first = true
            do {
                try limiter.acquire(bytes: 32 * 1024, direction: .upload) {
                    if first { first = false; waiting.fulfill() }
                    if cancelled.value { throw LimiterTestError.cancelled }
                }
                XCTFail("已取消的限速请求不应成功")
            } catch { XCTAssertTrue(error is LimiterTestError) }
            finished.fulfill()
        }
        wait(for: [waiting], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        try limiter.acquire(bytes: 64 * 1024, direction: .download, check: {})
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 0.6)
        cancelled.value = true
        wait(for: [finished], timeout: 0.4)
    }

    func testCancellationInterruptsLowRateWaitPromptly() throws {
        let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: 1)
        try limiter.acquire(bytes: 32 * 1024, direction: .upload, check: {})
        var checks = 0
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try limiter.acquire(bytes: 32 * 1024, direction: .upload) {
            checks += 1
            if checks == 2 { throw LimiterTestError.cancelled }
        }) { XCTAssertTrue($0 is LimiterTestError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
    }

    func testSettingUnlimitedWakesExistingWaiter() throws {
        let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: 1)
        try limiter.acquire(bytes: 32 * 1024, direction: .upload, check: {})
        let waiting = expectation(description: "开始等待上传额度")
        let finished = expectation(description: "不限速后结束")
        DispatchQueue.global().async {
            var first = true
            do {
                try limiter.acquire(bytes: 32 * 1024, direction: .upload) {
                    if first { first = false; waiting.fulfill() }
                }
            } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        wait(for: [waiting], timeout: 1)
        limiter.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        wait(for: [finished], timeout: 0.2)
    }

    func testNewLimitAppliesAfterPreviouslyUnlimitedTraffic() throws {
        let limiter = TransferBandwidthLimiter()
        try limiter.acquire(bytes: 512 * 1024, direction: .upload, check: {})
        limiter.setLimits(uploadBytesPerSecond: 256 * 1024, downloadBytesPerSecond: 0)
        let start = ProcessInfo.processInfo.systemUptime
        try limiter.acquire(bytes: 96 * 1024, direction: .upload, check: {})
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.22)
    }

    func testCheckMayUpdateLimitsWithoutDeadlocking() {
        let limiter = TransferBandwidthLimiter(uploadBytesPerSecond: 1)
        let finished = expectation(description: "锁外执行检查")
        DispatchQueue.global().async {
            do {
                try limiter.acquire(bytes: 64 * 1024, direction: .upload) {
                    limiter.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
                }
            } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 0.5)
    }

    func testUnusedReadRefundRestoresCreditButCannotAccumulateMoreThanOneChunk() throws {
        let limiter = TransferBandwidthLimiter(downloadBytesPerSecond: 1)
        try limiter.acquire(bytes: 32 * 1024, direction: .download, check: {})
        limiter.refundUnusedReadBytes(16 * 1024)
        let immediate = ProcessInfo.processInfo.systemUptime
        try limiter.acquire(bytes: 16 * 1024, direction: .download) {
            if ProcessInfo.processInfo.systemUptime - immediate > 0.4 { throw LimiterTestError.cancelled }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - immediate, 0.2)
        limiter.setLimits(uploadBytesPerSecond: 0, downloadBytesPerSecond: 256 * 1024)
        limiter.refundUnusedReadBytes(512 * 1024)
        let start = ProcessInfo.processInfo.systemUptime
        try limiter.acquire(bytes: 64 * 1024, direction: .download, check: {})
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.10)
    }

    func testUnusedReadRefundWakesWaitingReader() throws {
        let limiter = TransferBandwidthLimiter(downloadBytesPerSecond: 1)
        try limiter.acquire(bytes: 32 * 1024, direction: .download, check: {})
        let waiting = expectation(description: "等待读取额度")
        let finished = expectation(description: "归还后结束等待")
        DispatchQueue.global().async {
            var first = true
            do {
                try limiter.acquire(bytes: 16 * 1024, direction: .download) {
                    if first { first = false; waiting.fulfill() }
                }
            } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        wait(for: [waiting], timeout: 1)
        limiter.refundUnusedReadBytes(16 * 1024)
        wait(for: [finished], timeout: 0.2)
    }

    func testUnlimitedTrafficStillChecksCancellation() {
        let limiter = TransferBandwidthLimiter()
        XCTAssertThrowsError(try limiter.acquire(bytes: 1, direction: .download) { throw LimiterTestError.cancelled })
    }
}

private enum LimiterTestError: Error { case cancelled }

private final class LimiterTestFlag {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
