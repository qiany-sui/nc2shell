import XCTest
import Nc2ShellCore
@testable import Nc2Shell

@MainActor
final class TransferSettingsTests: XCTestCase {
    func testStoredKiBLimitIsAppliedToTransferBytes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer-settings.json"))
        try store.save(TransferPreferences(uploadLimitKiB: 256, downloadLimitKiB: 256))
        let controller = TransferSettingsController(store: store)
        for direction in [TransferTrafficDirection.upload, .download] {
            let start = ProcessInfo.processInfo.systemUptime
            try controller.limiter.acquire(bytes: 96 * 1024, direction: direction) {
                if ProcessInfo.processInfo.systemUptime - start > 1 {
                    throw ProfileError("测试限速超时，KiB 应换算为 1024 字节。")
                }
            }
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.22)
        }
    }

    func testSavePersistsPreferencesAndUpdatesExistingSharedLimiter() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer-settings.json"))
        try store.save(TransferPreferences(uploadLimitKiB: 1, downloadLimitKiB: 1))
        let controller = TransferSettingsController(store: store)
        let activeLimiter = controller.limiter
        try activeLimiter.acquire(bytes: 32 * 1024, direction: .upload, check: {})
        try activeLimiter.acquire(bytes: 32 * 1024, direction: .download, check: {})
        let changed = TransferPreferences(maxConcurrentTransfers: 4)
        XCTAssertTrue(controller.save(changed))
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.preferences, changed)
        XCTAssertEqual(try store.load(), changed)
        XCTAssertTrue(activeLimiter === controller.limiter)
        let start = ProcessInfo.processInfo.systemUptime
        try activeLimiter.acquire(bytes: 128 * 1024, direction: .upload, check: {})
        try activeLimiter.acquire(bytes: 128 * 1024, direction: .download, check: {})
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
    }

    func testInvalidSavePreservesCurrentPreferencesAndFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer-settings.json"))
        let original = TransferPreferences(maxConcurrentTransfers: 3, uploadLimitKiB: 1024)
        try store.save(original)
        let controller = TransferSettingsController(store: store)
        XCTAssertFalse(controller.save(TransferPreferences(uploadLimitKiB: -1)))
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(controller.preferences, original)
        XCTAssertEqual(try store.load(), original)
    }

    func testCorruptSettingsExposeErrorAndCannotBeOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer-settings.json"))
        let bytes = Data("corrupt settings".utf8)
        try bytes.write(to: store.fileURL)
        let controller = TransferSettingsController(store: store)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(controller.preferences, TransferPreferences())
        XCTAssertFalse(controller.save(TransferPreferences(maxConcurrentTransfers: 1)))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(controller.preferences, TransferPreferences())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-transfer-controller-\(UUID().uuidString)")
    }
}
