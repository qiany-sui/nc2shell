import XCTest
@testable import Nc2Shell

final class TransferQueueProgressTests: XCTestCase {
    @MainActor
    private func item() -> TransferQueueItem {
        TransferQueueItem(connectionID: UUID(), name: "sample", direction: .upload, source: "/source", target: "/target", isFilePromise: false)
    }

    @MainActor
    func testFinishedTransferRejectsLateProgress() {
        let item = item()
        item.state = .running
        item.record(40)
        item.state = .completed
        item.record(12)
        XCTAssertEqual(item.bytes, 40, "完成后的迟到进度不能把最终实际字节改小")
    }

    @MainActor
    func testEstimateUsesBytesAndWaitsForActualSuccessBeforeOneHundredPercent() throws {
        let item = item()
        item.state = .running
        item.finishEstimation(1_000)
        item.record(250)
        XCTAssertEqual(try XCTUnwrap(item.fractionCompleted), 0.25, accuracy: 0.001)
        item.record(1_000)
        XCTAssertLessThan(try XCTUnwrap(item.fractionCompleted), 1)
        item.state = .completed
        XCTAssertEqual(item.fractionCompleted, 1)
    }

    @MainActor
    func testUnknownZeroAndGrowingSourcesDoNotInventPercentages() {
        let item = item()
        item.state = .running
        item.finishEstimation(nil)
        XCTAssertNil(item.fractionCompleted)
        item.finishEstimation(0)
        XCTAssertNil(item.fractionCompleted)
        item.finishEstimation(10)
        item.record(11)
        XCTAssertNil(item.fractionCompleted)
        XCTAssertNil(item.remainingTime())
        item.state = .completed
        XCTAssertEqual(item.fractionCompleted, 1)
    }

    @MainActor
    func testRemainingTimeRequiresFreshThroughputAndStopsWhilePausedOrWaiting() throws {
        let item = item(), start = Date(timeIntervalSince1970: 1_000)
        item.state = .running
        item.finishEstimation(1_000, at: start)
        XCTAssertNil(item.remainingTime(at: start))
        item.record(200, at: start.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(item.remainingTime(at: start.addingTimeInterval(1))), 4, accuracy: 0.001)
        XCTAssertNil(item.remainingTime(at: start.addingTimeInterval(10)), "停滞后不能继续展示旧速率推导出的倒计时")
        item.state = .paused
        XCTAssertNil(item.remainingTime(at: start.addingTimeInterval(1)))
        item.state = .running
        item.isWaitingForConflict = true
        XCTAssertNil(item.remainingTime(at: start.addingTimeInterval(1)))
        item.isWaitingForConflict = false
        item.resetSpeed(at: start.addingTimeInterval(20))
        XCTAssertNil(item.remainingTime(at: start.addingTimeInterval(20)))
        item.record(400, at: start.addingTimeInterval(21))
        XCTAssertEqual(try XCTUnwrap(item.remainingTime(at: start.addingTimeInterval(21))), 3, accuracy: 0.001)
    }

    @MainActor
    func testHugeSourceDoesNotFormatRemainingTimeAsZeroOrNonfiniteValue() {
        let item = item(), start = Date(timeIntervalSince1970: 1_000)
        item.state = .running
        item.finishEstimation(UInt64.max, at: start)
        item.record(1, at: start.addingTimeInterval(1))
        XCTAssertEqual(item.remainingTimeText(at: start.addingTimeInterval(1)), "超过一年")
        item.bytesPerSecond = .leastNonzeroMagnitude
        XCTAssertNil(item.remainingTime(at: start.addingTimeInterval(1)))
        XCTAssertNil(item.remainingTimeText(at: start.addingTimeInterval(1)))
    }

    @MainActor
    func testReusedBytesAdvanceCompletionWithoutInflatingNetworkSpeed() throws {
        let item = item(), start = Date(timeIntervalSince1970: 1_000)
        item.state = .running
        item.finishEstimation(1_000, at: start)
        item.recordReused(600, at: start)
        item.record(600, at: start.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(item.fractionCompleted), 0.6, accuracy: 0.001)
        XCTAssertNil(item.currentSpeed(at: start.addingTimeInterval(1)))
        item.record(700, at: start.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(item.currentSpeed(at: start.addingTimeInterval(2))), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(item.remainingTime(at: start.addingTimeInterval(2))), 3, accuracy: 0.001)
        item.recordReused(200, at: start.addingTimeInterval(3))
        item.record(900, at: start.addingTimeInterval(4))
        XCTAssertNil(item.currentSpeed(at: start.addingTimeInterval(4)))
        item.record(1_000, at: start.addingTimeInterval(5))
        XCTAssertEqual(try XCTUnwrap(item.currentSpeed(at: start.addingTimeInterval(5))), 100, accuracy: 0.001)
        XCTAssertEqual(item.reusedBytes, 800)
    }
}
