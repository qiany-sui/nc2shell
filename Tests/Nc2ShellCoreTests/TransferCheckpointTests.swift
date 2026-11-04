import XCTest
import Darwin
@testable import Nc2ShellCore

final class TransferCheckpointTests: XCTestCase {
    private func checkpointURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("checkpoint.json")
    }

    func testCheckpointRejectsFIFOWithoutWaitingForWriter() throws {
        let fifo = try checkpointURL()
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try TransferCheckpoint(fileURL: fifo)
                XCTFail("FIFO 不能作为检查点读取")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("普通文件"))
            }
        }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            XCTFail("无写端的 FIFO 不应阻塞检查点读取")
            // 旧实现会阻塞在 open，打开写端让测试线程退出。
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            defer { if writer >= 0 { close(writer) } }
            XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        }
    }

    func testCheckpointReadsValidRegularFileAndPreservesMalformedData() throws {
        let url = try checkpointURL()
        try Data(#"{"version":1,"records":{},"roots":{}}"#.utf8).write(to: url)
        XCTAssertTrue(try TransferCheckpoint(fileURL: url).records.isEmpty)

        let malformed = Data("{".utf8)
        try malformed.write(to: url)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testCheckpointDoesNotFollowSymbolicLinkToValidFile() throws {
        let url = try checkpointURL()
        let valid = url.deletingLastPathComponent().appendingPathComponent("valid.json")
        try Data(#"{"version":1,"records":{},"roots":{}}"#.utf8).write(to: valid)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: valid)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: url))
    }
}
